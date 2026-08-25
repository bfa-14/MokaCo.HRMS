using System.Net;
using System.Net.Http.Headers;
using System.Net.Mail;
using System.Text;
using System.Text.Json;
using MokaCo.HRMS.Model.Core;
using MokaCo.HRMS.Repository.Core;
using MokaCo.HRMS.Services.Core;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Api.Jobs;

/// <summary>
/// Drains the notification outbox: queue what has closed, send what is waiting, record what happened.
///
/// WHY AN OUTBOX AND NOT A SEND AT THE MOMENT OF APPROVAL. Closing a request and telling the
/// employee about it fail in completely different ways. The approval is a signature that must commit
/// whether or not a mail server is reachable; the message is a best-effort thing that may need three
/// attempts and a working DNS. Sending inline would put a socket to a third party inside the
/// transaction that locks somebody's leave — so the closing writes a ROW, and this worker turns rows
/// into messages on its own time.
///
/// TWO CHANNELS, ONE QUEUE. A row carries its Channel, and this worker is the switch: 'Email' goes
/// over SMTP with the request PDF attached, 'WhatsApp' goes over the Cloud API as a template message.
/// They are separate rows for the same request precisely so they fail separately — a bounced address
/// must not suppress the WhatsApp message, and neither one retries the other.
///
/// RETRY IS THE DATABASE'S. usp_Email_MarkResult counts the attempts and decides whether a failure
/// leaves the row Pending with a delay or marks it Failed for good. There is deliberately no retry
/// logic here: a worker that also retried would compound two policies and neither would be readable.
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

    /// <summary>
    /// How much of a rejected API response is worth keeping. The Cloud API's errors are JSON objects
    /// whose useful half — code and message — is at the front; the trace ids behind it would eat the
    /// column and tell the reader nothing they can act on.
    /// </summary>
    private const int MaxResponseLength = 400;

    private readonly IServiceScopeFactory _scopes;
    private readonly IHttpClientFactory _http;
    private readonly ILogger<EmailWorker> _logger;

    /// <summary>
    /// Whether the previous cycle found ANY channel configured, so the "doing nothing" line is
    /// logged when that becomes true rather than every single minute.
    ///
    /// The switched-off case is meant to be quiet — an installation with no mail server is a normal
    /// installation, not a broken one. But it must not be INVISIBLE: silence in the one state where
    /// a worker does nothing is exactly how a worker that is running perfectly becomes
    /// indistinguishable from one that never started.
    /// </summary>
    private bool? _lastConfigured;

    public EmailWorker(IServiceScopeFactory scopes, IHttpClientFactory http, ILogger<EmailWorker> logger)
    {
        _scopes = scopes;
        _http = http;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        _logger.LogInformation(
            "Email worker started. First cycle in {DelaySeconds}s, then every {IntervalSeconds}s. The SMTP " +
            "and WhatsApp settings are re-read before EVERY cycle, so changing them on the Settings page " +
            "takes effect without restarting the API.",
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
                // THE BACKSTOP. Anything that escapes the per-message handling is logged and the loop
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
    /// THE SETTINGS ARE READ FIRST AND THE QUEUEING SECOND, deliberately. With no channel configured
    /// at all there is no point writing rows nobody will ever send — they would pile up until
    /// somebody set a host and then arrive all at once, announcing decisions from weeks ago.
    /// </summary>
    private async Task RunCycleAsync(CancellationToken ct)
    {
        using var scope = _scopes.CreateScope();

        var settings = scope.ServiceProvider.GetRequiredService<ISettingService>();
        var outbox = scope.ServiceProvider.GetRequiredService<IEmailRepository>();
        var pdfs = scope.ServiceProvider.GetRequiredService<IRequestPdfBuilder>();

        var config = await ReadSettingsAsync(settings);

        // EITHER channel is enough to make the cycle worth running. Gating the whole thing on SMTP
        // would leave a WhatsApp-only installation queueing nothing at all.
        var smtpReady = !string.IsNullOrWhiteSpace(config.Host);
        var whatsAppReady = config.WhatsAppEnabled
            && !string.IsNullOrWhiteSpace(config.WhatsAppApiUrl)
            && !string.IsNullOrWhiteSpace(config.WhatsAppPhoneNumberId)
            && !string.IsNullOrWhiteSpace(config.WhatsAppAccessToken);

        if (!smtpReady && !whatsAppReady)
        {
            // SILENTLY, as specified — but once, on the way into the state, not every minute.
            if (_lastConfigured != false)
            {
                _logger.LogInformation(
                    "Notifications are OFF: no SmtpHost is set and WhatsApp is not enabled, so nothing is " +
                    "queued or sent. This line is logged again the moment either appears.");
                _lastConfigured = false;
            }
            return;
        }

        if (_lastConfigured != true)
        {
            _logger.LogInformation("Notifications are ON. Email: {Email}. WhatsApp: {WhatsApp}.",
                smtpReady ? $"{config.Host}:{config.Port}" : "off",
                whatsAppReady ? "on" : "off");
            _lastConfigured = true;
        }

        // FIRST, AND BEFORE GetPending — a cycle that only drained the outbox would send nothing
        // automatic ever, because nothing else in the system writes those rows. Cheap and idempotent:
        // the procedure checks its own on/off setting, looks back only seven days, and a unique index
        // keeps it to one row per request per channel however often this runs.
        var queued = await outbox.QueueClosedRequestsAsync();

        // EVERY CYCLE, INCLUDING ZERO. "queued 0" is the answer to "is this thing running at all?",
        // and logging only the non-zero case makes a worker that is working perfectly look identical
        // to one that never started — which is exactly how this came to be doubted.
        _logger.LogInformation("queued {Queued}", queued);

        /*
         * THE ROWS THIS CALL CLAIMED, and nobody else's.
         *
         * usp_Email_GetPending is not a read. It flips each row it returns to 'Sending' with a
         * ClaimedUtc in the same statement and OUTPUTs what it flipped, so every row in this list is
         * already spoken for — and the ONLY thing that takes it back out of 'Sending' is a MarkResult
         * call naming its EmailId. Two consequences the loop below depends on:
         *
         *   1. EVERY row here must reach MarkResult, on every path. A row returned without one sits
         *      in 'Sending' until the ten-minute crash sweep releases it, is claimed again, and is
         *      sent again — which is the duplicate, arriving every ten minutes for ever.
         *   2. There is no need to guard against a second worker taking the same row. The claim is
         *      atomic; the database has already settled that.
         */
        var pending = (await outbox.GetPendingAsync()).ToList();
        if (pending.Count == 0)
            return;

        var sent = 0;
        var failed = 0;

        // ONE CLIENT FOR THE BATCH, and only once there is something to use it for. SmtpClient holds
        // the connection open across sends, and opening a fresh TLS session per message is the
        // difference between a batch of twenty taking a second and taking half a minute.
        SmtpClient? smtp = null;

        try
        {
            foreach (var row in pending)
            {
                if (ct.IsCancellationRequested)
                    return;

                var isWhatsApp = string.Equals(row.Channel, "WhatsApp", StringComparison.OrdinalIgnoreCase);

                /*
                 * NO PATH OUT OF THIS BLOCK THAT DOES NOT MARK THE ROW.
                 *
                 * A channel that is switched off used to `continue` here without marking, and THAT
                 * WAS THE DUPLICATE: the row had already been CLAIMED, so skipping it left it in
                 * 'Sending' for the ten-minute sweep to release, for the next cycle to claim and
                 * send again, for ever.
                 *
                 * It is a FAILURE now, with a sentence saying why — three attempts, then Failed,
                 * which is a terminal state a person can see on the request page. That is the honest
                 * answer: with the channel off the message is not going to be delivered, and
                 * pretending it was merely waiting is exactly what made it repeat.
                 *
                 * So the guards THROW rather than skip, and every outcome — refused, thrown,
                 * unconfigured — leaves through the one catch below, which marks it.
                 */
                try
                {
                    if (isWhatsApp)
                    {
                        if (!whatsAppReady)
                            throw new InvalidOperationException(
                                "WhatsApp is switched off, or its API URL, number id or token is blank.");

                        await SendWhatsAppAsync(row, config, ct);
                    }
                    else
                    {
                        if (!smtpReady)
                            throw new InvalidOperationException("No SmtpHost is configured.");

                        smtp ??= BuildClient(config);
                        await SendEmailAsync(smtp, row, config, pdfs, ct);
                    }

                    // IMMEDIATELY, naming THIS row — never collected and written after the loop. The
                    // row has been in 'Sending' since it was claimed, and this call is the only thing
                    // that ends that state.
                    await outbox.MarkResultAsync(row.EmailId, true, null);
                    sent++;

                    // ONE LINE PER ROW, in the same shape whichever way it went, so "did it go out?"
                    // is answered by grepping the id or the address rather than by reading a cycle
                    // summary and guessing which of the twenty it counted.
                    _logger.LogInformation("outbox #{EmailId} {Channel} → {ToAddress}: Sent",
                        row.EmailId, row.Channel, row.ToAddress);
                }
                catch (OperationCanceledException) when (ct.IsCancellationRequested)
                {
                    // Shutting down mid-row. Deliberately NOT marked: the send may well have reached
                    // the server, and recording either result would be a guess. The row stays claimed
                    // and the ten-minute sweep returns it to Pending after the restart.
                    return;
                }
                catch (Exception ex)
                {
                    failed++;

                    // BEFORE the log line, so a logger that throws cannot cost the row its result —
                    // an unmarked row is a duplicate; a missing log line is only a missing log line.
                    await outbox.MarkResultAsync(row.EmailId, false, Truncate(ex.Message, MaxErrorLength));

                    // Warning, not Error: a typo in somebody's address is ordinary, and the reason is
                    // recorded against the row where whoever fixes the address will find it. The
                    // procedure decides from here whether this was the last attempt.
                    _logger.LogWarning(ex, "outbox #{EmailId} {Channel} → {ToAddress}: Failed({Reason})",
                        row.EmailId, row.Channel, row.ToAddress, ex.Message);
                }
            }
        }
        finally
        {
            smtp?.Dispose();
        }

        _logger.LogInformation("Email cycle: {Sent} sent, {Failed} failed.", sent, failed);
    }

    /* ─────────────────────────────── Email ─────────────────────────────── */

    /// <summary>
    /// One email, with the request PDF attached where there is a request to build one from.
    ///
    /// THE PDF NEVER BLOCKS THE MAIL. It is the nicety; the message is the point. A rendering fault,
    /// a request that has since been removed, a repository that will not answer — all of them log and
    /// send the mail without an attachment, because an employee who hears the outcome without a
    /// document is better off than one who does not hear it at all.
    /// </summary>
    private async Task SendEmailAsync(
        SmtpClient client, OutboxEmail row, NotificationSettings config,
        IRequestPdfBuilder pdfs, CancellationToken ct)
    {
        using var message = new MailMessage
        {
            From = new MailAddress(config.FromEmail, config.FromName),
            Subject = row.Subject,
            Body = row.Body,
            // The bodies are composed in SQL as plain text with CRLFs. Sending them as HTML would
            // collapse every line break and turn the message into one paragraph.
            IsBodyHtml = false,
        };
        message.To.Add(row.ToAddress);

        // The stream must outlive SendMailAsync — an Attachment reads from it when the message is
        // written to the wire, not when it is added — so it is disposed after the send, not before.
        MemoryStream? pdfStream = null;

        try
        {
            if (row.RequestInstanceId is { } requestId)
            {
                try
                {
                    var bytes = await pdfs.BuildAsync(requestId);
                    if (bytes is { Length: > 0 })
                    {
                        pdfStream = new MemoryStream(bytes);
                        message.Attachments.Add(
                            new Attachment(pdfStream, $"request-{requestId}.pdf", "application/pdf"));
                    }
                }
                catch (Exception ex)
                {
                    _logger.LogWarning(ex,
                        "email #{EmailId}: the PDF for request {RequestId} could not be built, so the mail " +
                        "goes WITHOUT the attachment.",
                        row.EmailId, requestId);
                }
            }

            await client.SendMailAsync(message, ct);
        }
        finally
        {
            pdfStream?.Dispose();
        }
    }

    /// <summary>
    /// Builds the client from the settings as they stand THIS cycle — never cached, so a corrected
    /// password works on the next pass rather than after a restart.
    /// </summary>
    private SmtpClient BuildClient(NotificationSettings mail)
    {
        var client = new SmtpClient(mail.Host, mail.Port);

        /*
         * THE ORDER OF THESE THREE LINES IS LOAD-BEARING, and only the first two for the reason
         * people expect.
         *
         * UseDefaultCredentials does not sit beside Credentials — it OVERWRITES it. Setting it false
         * nulls whatever login is there; setting it true replaces the login with the service
         * account's Windows identity. Assigning it AFTER the credential silently discards the
         * credential, and the server then answers "Authentication Required" for a password that was
         * entered correctly on the Settings page. First, always.
         *
         * EnableSsl is order-independent as far as SmtpClient is concerned, but it is written here
         * rather than in an object initialiser so all three settings that decide whether the session
         * authenticates read in one place, top to bottom, in the order they must be applied.
         */
        client.UseDefaultCredentials = false;
        client.Credentials = new NetworkCredential(mail.User, mail.Password);
        client.EnableSsl = true;
        client.DeliveryMethod = SmtpDeliveryMethod.Network;

        /*
         * THE USER NAME, NEVER THE PASSWORD, and quoted so an EMPTY one is visible as '' rather than
         * as a line that merely looks short. This is the fastest way to tell the two authentication
         * failures apart: no user reaching the server is a settings problem, and a user that IS
         * reaching it and still being refused is a credential the provider rejects.
         */
        _logger.LogInformation("authenticating as '{SmtpUser}'", mail.User);

        return client;
    }

    /* ────────────────────────────── WhatsApp ───────────────────────────── */

    /// <summary>
    /// One WhatsApp template message over the Cloud API.
    ///
    /// A TEMPLATE, NOT FREE TEXT, because that is the only thing WhatsApp will deliver to somebody
    /// who has not messaged the business in the last 24 hours — which is every employee this ever
    /// writes to. The row's Body goes in as the template's single body parameter.
    ///
    /// A NON-2xx IS A FAILURE CARRYING THE RESPONSE, not a status code. The Cloud API says why in the
    /// body — an unapproved template name, an expired token, a number not on WhatsApp — and each of
    /// those is a different thing to go and fix, so the body is what gets recorded against the row.
    /// </summary>
    private async Task SendWhatsAppAsync(OutboxEmail row, NotificationSettings config, CancellationToken ct)
    {
        var to = DigitsOnly(row.ToAddress);
        if (to.Length == 0)
            throw new InvalidOperationException("The recipient has no usable phone number.");

        var payload = new
        {
            messaging_product = "whatsapp",
            to,
            type = "template",
            template = new
            {
                name = config.WhatsAppTemplateName,
                // Anything that is not Arabic is English. The template must exist in the language
                // asked for, and asking for one it was never published in is a rejection.
                language = new
                {
                    code = string.Equals(row.Lang, "ar", StringComparison.OrdinalIgnoreCase) ? "ar" : "en",
                },
                components = new object[]
                {
                    new
                    {
                        type = "body",
                        parameters = new object[] { new { type = "text", text = row.Body } },
                    },
                },
            },
        };

        var url = $"{config.WhatsAppApiUrl.TrimEnd('/')}/{config.WhatsAppPhoneNumberId}/messages";

        using var request = new HttpRequestMessage(HttpMethod.Post, url)
        {
            Content = new StringContent(JsonSerializer.Serialize(payload), Encoding.UTF8, "application/json"),
        };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", config.WhatsAppAccessToken);

        var client = _http.CreateClient();
        using var response = await client.SendAsync(request, ct);

        if (response.IsSuccessStatusCode)
            return;

        var body = await response.Content.ReadAsStringAsync(ct);
        throw new InvalidOperationException(
            $"WhatsApp refused the message ({(int)response.StatusCode}): {Truncate(body, MaxResponseLength)}");
    }

    /// <summary>
    /// The number as the API wants it: digits only, international, no '+' and no separators.
    ///
    /// A LEADING 00 IS THE SAME PREFIX WRITTEN THE OTHER WAY — "0044…" and "+44…" are one number, and
    /// sending the zeros would make it a different one. Nothing else is guessed: a national number
    /// with no country code is not something this can repair, and the API's rejection names that
    /// better than a wrong guess would.
    /// </summary>
    private static string DigitsOnly(string value)
    {
        var digits = new string(value.Where(char.IsDigit).ToArray());
        return digits.StartsWith("00", StringComparison.Ordinal) ? digits[2..] : digits;
    }

    /* ─────────────────────────────── Settings ──────────────────────────── */

    /// <summary>
    /// Every setting the two channels need, read fresh every cycle.
    ///
    /// FAILS SAFE: an unreadable setting comes back as an empty host with WhatsApp off, which the
    /// caller reads as "not configured" and skips. Blowing up here would take the worker down over a
    /// database blip.
    /// </summary>
    private async Task<NotificationSettings> ReadSettingsAsync(ISettingService settings)
    {
        try
        {
            var host = (await settings.GetAsync("SmtpHost"))?.SettingValue;
            var port = (await settings.GetAsync("SmtpPort"))?.SettingValue;
            var user = (await settings.GetAsync("SmtpUser"))?.SettingValue;
            var password = (await settings.GetAsync("SmtpPassword"))?.SettingValue;
            var fromEmail = (await settings.GetAsync("SmtpFromEmail"))?.SettingValue;
            var fromName = (await settings.GetAsync("SmtpFromName"))?.SettingValue;

            var waEnabled = (await settings.GetAsync("WhatsAppEnabled"))?.SettingValue;
            var waUrl = (await settings.GetAsync("WhatsAppApiUrl"))?.SettingValue;
            var waPhoneId = (await settings.GetAsync("WhatsAppPhoneNumberId"))?.SettingValue;
            var waToken = (await settings.GetAsync("WhatsAppAccessToken"))?.SettingValue;
            var waTemplate = (await settings.GetAsync("WhatsAppTemplateName"))?.SettingValue;

            return new NotificationSettings(
                (host ?? string.Empty).Trim(),
                int.TryParse(port, out var parsed) && parsed > 0 ? parsed : 587,
                (user ?? string.Empty).Trim(),
                password ?? string.Empty,
                // The From address falls back to the user, which for almost every provider IS the
                // mailbox — a blank From is rejected outright and would fail every mail in the queue.
                string.IsNullOrWhiteSpace(fromEmail) ? (user ?? string.Empty).Trim() : fromEmail.Trim(),
                string.IsNullOrWhiteSpace(fromName) ? "MokaCo HRMS" : fromName.Trim(),
                IsOn(waEnabled),
                (waUrl ?? string.Empty).Trim(),
                (waPhoneId ?? string.Empty).Trim(),
                (waToken ?? string.Empty).Trim(),
                string.IsNullOrWhiteSpace(waTemplate) ? "request_update" : waTemplate.Trim());
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Could not read the notification settings; skipping this cycle.");
            return new NotificationSettings(
                string.Empty, 587, string.Empty, string.Empty, string.Empty, "MokaCo HRMS",
                false, string.Empty, string.Empty, string.Empty, "request_update");
        }
    }

    /// <summary>
    /// core.SETTING stores bools in two dialects — '1' in some rows and 'true' in others — and a
    /// reader that knows only one of them reports the other as OFF. The specified rule for this flag
    /// is "not '1' means off"; accepting the words as well costs nothing and removes the failure
    /// where a switch saved as 'true' turns a channel off while the page displays it as on.
    /// </summary>
    private static bool IsOn(string? value)
        => value?.Trim().ToLowerInvariant() is "1" or "true" or "yes" or "on";

    private static string Truncate(string value, int max)
        => value.Length <= max ? value : value[..max];

    /// <summary>Both channels' settings as one frozen snapshot, so a cycle cannot half-change under itself.</summary>
    private readonly record struct NotificationSettings(
        string Host, int Port, string User, string Password, string FromEmail, string FromName,
        bool WhatsAppEnabled, string WhatsAppApiUrl, string WhatsAppPhoneNumberId,
        string WhatsAppAccessToken, string WhatsAppTemplateName);
}
