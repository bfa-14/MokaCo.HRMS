using System.Net;
using System.Net.Mail;
using MokaCo.HRMS.Repository.Core;
using MokaCo.HRMS.Services.Core;

namespace MokaCo.HRMS.Api.Jobs;

/// <summary>
/// Drains the mail outbox: queue what has closed, send what is waiting, record what happened.
///
/// WHY AN OUTBOX AND NOT A SEND AT THE MOMENT OF APPROVAL. Closing a request and telling the
/// employee about it fail in completely different ways. The approval is a signature that must commit
/// whether or not a mail server is reachable; the mail is a best-effort message that may need three
/// attempts and a working DNS. Sending inline would put a socket to a third party inside the
/// transaction that locks somebody's leave — so the closing writes a ROW, and this worker turns rows
/// into mail on its own time.
///
/// A BackgroundService rather than a Quartz job, for the same reason MachinePullWorker is one: this
/// is a heartbeat, not a calendar. The two Quartz jobs run at "01:00, whatever else is happening";
/// this runs every minute and nobody cares which minute.
///
/// FAILURE POLICY: one bad address must never stop the others, and no failure may stop the worker.
/// Every send is caught individually and recorded against its own row; the cycle itself is wrapped
/// again, because an exception escaping ExecuteAsync ends the service for the life of the process.
/// </summary>
public class EmailWorker : BackgroundService
{
    /// <summary>Once a minute, as specified — and NOT a setting: nobody has ever needed to tune it.</summary>
    private static readonly TimeSpan Interval = TimeSpan.FromMinutes(1);

    /// <summary>Long enough for the app to finish starting; short enough that a test mail is not a coffee break.</summary>
    private static readonly TimeSpan StartupDelay = TimeSpan.FromSeconds(15);

    /// <summary>Matches the Error column's NVARCHAR(500). A truncated reason beats a SQL error that loses it entirely.</summary>
    private const int MaxErrorLength = 500;

    private readonly IServiceScopeFactory _scopes;
    private readonly ILogger<EmailWorker> _logger;

    /// <summary>
    /// Whether the previous cycle found mail CONFIGURED, so the "no host, doing nothing" line is
    /// logged when that becomes true rather than every single minute.
    ///
    /// The switched-off case is meant to be quiet — an installation with no mail server is a normal
    /// installation, not a broken one. But it must not be INVISIBLE: silence in the one state where
    /// a worker does nothing is exactly how a worker that is running perfectly becomes
    /// indistinguishable from one that never started.
    /// </summary>
    private bool? _lastConfigured;

    public EmailWorker(IServiceScopeFactory scopes, ILogger<EmailWorker> logger)
    {
        _scopes = scopes;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        _logger.LogInformation(
            "Email worker started. First cycle in {DelaySeconds}s, then every {IntervalSeconds}s. The SMTP " +
            "settings are re-read before EVERY cycle, so changing them on the Settings page takes effect " +
            "without restarting the API.",
            (int)StartupDelay.TotalSeconds, (int)Interval.TotalSeconds);

        try
        {
            await Task.Delay(StartupDelay, stoppingToken);
        }
        catch (OperationCanceledException)
        {
            return;
        }

        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                await RunCycleAsync(stoppingToken);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                return;
            }
            catch (Exception ex)
            {
                // THE BACKSTOP. Anything that escapes the per-mail handling is logged and the loop
                // continues — a worker that dies here would stop sending silently, and the only
                // symptom would be employees not hearing about decisions nobody knows were missed.
                _logger.LogError(ex,
                    "Email cycle failed outright. The worker CONTINUES and will try again in {IntervalSeconds}s.",
                    (int)Interval.TotalSeconds);
            }

            try
            {
                await Task.Delay(Interval, stoppingToken);
            }
            catch (OperationCanceledException)
            {
                return;
            }
        }
    }

    /// <summary>
    /// One pass: read the settings, fill the outbox, and send what is in it.
    ///
    /// THE SETTINGS ARE READ FIRST AND THE QUEUEING SECOND, deliberately. With no mail server
    /// configured there is no point writing rows nobody will ever send — they would pile up until
    /// somebody set a host and then arrive all at once, announcing decisions from months ago.
    /// </summary>
    private async Task RunCycleAsync(CancellationToken ct)
    {
        using var scope = _scopes.CreateScope();

        var settings = scope.ServiceProvider.GetRequiredService<ISettingService>();
        var outbox = scope.ServiceProvider.GetRequiredService<IEmailRepository>();

        var mail = await ReadMailSettingsAsync(settings);

        if (string.IsNullOrWhiteSpace(mail.Host))
        {
            // SILENTLY, as specified — but once, on the way into the state, not every minute.
            if (_lastConfigured != false)
            {
                _logger.LogInformation(
                    "Email sending is OFF: no SmtpHost is set, so nothing is queued or sent. This line is " +
                    "logged again the moment a host appears.");
                _lastConfigured = false;
            }
            return;
        }

        if (_lastConfigured != true)
        {
            _logger.LogInformation("Email sending is ON via {Host}:{Port}.", mail.Host, mail.Port);
            _lastConfigured = true;
        }

        // Cheap and idempotent: the procedure checks its own on/off setting, looks back only seven
        // days, and a unique index keeps it to one mail per request however often this runs.
        var queued = await outbox.QueueClosedRequestsAsync();
        if (queued > 0)
            _logger.LogInformation("Email outbox: {Queued} closed request(s) queued.", queued);

        var pending = (await outbox.GetPendingAsync()).ToList();
        if (pending.Count == 0)
            return;

        var sent = 0;
        var failed = 0;

        // ONE CLIENT FOR THE BATCH. SmtpClient holds the connection open across sends, and opening a
        // fresh TLS session per message is the difference between a batch of twenty taking a second
        // and taking half a minute.
        using var client = BuildClient(mail);

        foreach (var email in pending)
        {
            if (ct.IsCancellationRequested)
                return;

            try
            {
                using var message = new MailMessage
                {
                    From = new MailAddress(mail.FromEmail, mail.FromName),
                    Subject = email.Subject,
                    Body = email.Body,
                    // The bodies are composed in SQL as plain text with CRLFs. Sending them as HTML
                    // would collapse every line break and turn the message into one paragraph.
                    IsBodyHtml = false,
                };
                message.To.Add(email.ToAddress);

                await client.SendMailAsync(message, ct);

                await outbox.MarkResultAsync(email.EmailId, true, null);
                sent++;
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                // Shutting down. The row stays Pending and goes out on the next start — which is the
                // whole advantage of an outbox, and why nothing is written against it here.
                return;
            }
            catch (Exception ex)
            {
                failed++;

                // Warning, not Error: a typo in somebody's address is ordinary, and the reason is
                // recorded against the row where whoever fixes the address will find it.
                _logger.LogWarning(ex,
                    "Email {EmailId} to {To} could not be sent: {Reason}",
                    email.EmailId, email.ToAddress, ex.Message);

                await outbox.MarkResultAsync(email.EmailId, false, Truncate(ex.Message));
            }
        }

        _logger.LogInformation("Email cycle: {Sent} sent, {Failed} failed.", sent, failed);
    }

    /// <summary>
    /// Builds the client from the settings as they stand THIS cycle — never cached, so a corrected
    /// password works on the next pass rather than after a restart.
    /// </summary>
    private static SmtpClient BuildClient(MailSettings mail)
    {
        var client = new SmtpClient(mail.Host, mail.Port)
        {
            // PORT 25 IS THE PLAIN ONE. Everything else in practice means submission (587, STARTTLS)
            // or implicit TLS (465), and both want this on; an internal relay on 25 usually has no
            // certificate at all and would refuse the negotiation.
            EnableSsl = mail.Port != 25,
            DeliveryMethod = SmtpDeliveryMethod.Network,
        };

        // An anonymous relay is a real configuration, so an empty user is not an error. Setting
        // UseDefaultCredentials would be wrong here — that offers the SERVICE ACCOUNT's Windows
        // identity to the mail server, which is not what "no user configured" means.
        if (!string.IsNullOrWhiteSpace(mail.User))
            client.Credentials = new NetworkCredential(mail.User, mail.Password);

        return client;
    }

    /// <summary>
    /// The six mail settings, read fresh every cycle.
    ///
    /// FAILS SAFE: an unreadable setting comes back as an empty host, which the caller reads as "not
    /// configured" and skips. Blowing up here would take the worker down over a database blip.
    /// </summary>
    private async Task<MailSettings> ReadMailSettingsAsync(ISettingService settings)
    {
        try
        {
            var host = (await settings.GetAsync("SmtpHost"))?.SettingValue;
            var port = (await settings.GetAsync("SmtpPort"))?.SettingValue;
            var user = (await settings.GetAsync("SmtpUser"))?.SettingValue;
            var password = (await settings.GetAsync("SmtpPassword"))?.SettingValue;
            var fromEmail = (await settings.GetAsync("SmtpFromEmail"))?.SettingValue;
            var fromName = (await settings.GetAsync("SmtpFromName"))?.SettingValue;

            return new MailSettings(
                (host ?? string.Empty).Trim(),
                int.TryParse(port, out var parsed) && parsed > 0 ? parsed : 587,
                (user ?? string.Empty).Trim(),
                password ?? string.Empty,
                // The From address falls back to the user, which for almost every provider IS the
                // mailbox — a blank From is rejected outright and would fail every mail in the queue.
                string.IsNullOrWhiteSpace(fromEmail) ? (user ?? string.Empty).Trim() : fromEmail.Trim(),
                string.IsNullOrWhiteSpace(fromName) ? "MokaCo HRMS" : fromName.Trim());
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Could not read the mail settings; skipping this cycle.");
            return new MailSettings(string.Empty, 587, string.Empty, string.Empty, string.Empty, "MokaCo HRMS");
        }
    }

    private static string Truncate(string value)
        => value.Length <= MaxErrorLength ? value : value[..MaxErrorLength];

    private readonly record struct MailSettings(
        string Host, int Port, string User, string Password, string FromEmail, string FromName);
}
