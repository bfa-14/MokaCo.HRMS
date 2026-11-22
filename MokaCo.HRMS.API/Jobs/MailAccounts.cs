using System.Net.Mail;
using MokaCo.HRMS.Model.Booking;
using MokaCo.HRMS.Services.Core;

namespace MokaCo.HRMS.Api.Jobs;

/// <summary>
/// The two mail accounts as core.SETTING holds them: the HR account (SmtpHost/Port/User/Password,
/// SmtpFromEmail/Name) and the bookings mailbox (BookingSmtp*, BookingFrom*). ONE reader, used by the e-mail
/// worker every cycle and by the Settings page's test button, so the test tries exactly what the worker sends with.
/// </summary>
public sealed record MailAccountSettings(
    string Host, int Port, string User, string Password, string FromEmail, string FromName, BookingMailSettings Booking)
{
    public const int DefaultPort = 587;
    public const string DefaultFromName = "MokaCo HRMS";

    public static readonly MailAccountSettings None =
        new(string.Empty, DefaultPort, string.Empty, string.Empty, string.Empty, DefaultFromName, BookingMailSettings.None);

    public static async Task<MailAccountSettings> ReadAsync(ISettingService settings)
    {
        async Task<string?> Get(string key) => (await settings.GetAsync(key))?.SettingValue;
        static string Trimmed(string? value) => (value ?? string.Empty).Trim();

        var host = await Get("SmtpHost");
        var port = await Get("SmtpPort");
        var user = await Get("SmtpUser");
        var password = await Get("SmtpPassword");
        var fromEmail = await Get("SmtpFromEmail");
        var fromName = await Get("SmtpFromName");

        // The bookings mailbox (QA3 BKG-7).
        var bookingPort = await Get("BookingSmtpPort");
        var booking = new BookingMailSettings(
            Trimmed(await Get("BookingSmtpHost")),
            int.TryParse(bookingPort, out var parsedBookingPort) && parsedBookingPort > 0 ? parsedBookingPort : 0,
            Trimmed(await Get("BookingSmtpUser")),
            await Get("BookingSmtpPassword") ?? string.Empty,
            Trimmed(await Get("BookingFromEmail")),
            Trimmed(await Get("BookingFromName")),
            Trimmed(await Get("BookingWhatsAppTemplate")),
            Trimmed(await Get("BookingWhatsAppLang")));

        return new MailAccountSettings(
            Trimmed(host),
            int.TryParse(port, out var parsed) && parsed > 0 ? parsed : DefaultPort,
            Trimmed(user),
            password ?? string.Empty,
            // The From address falls back to the user, which for almost every provider IS the
            // mailbox — a blank From is rejected outright and would fail every mail in the queue.
            string.IsNullOrWhiteSpace(fromEmail) ? Trimmed(user) : fromEmail.Trim(),
            string.IsNullOrWhiteSpace(fromName) ? DefaultFromName : fromName.Trim(),
            booking);
    }
}

/// <summary>
/// THE TEST-SYSTEM GUARD. Any system that is not the production one (the test API runs as Staging, on a COPY of
/// production: real staff, real guests) writes only to the addresses and numbers on a list an admin keeps
/// (core.SETTING TestMailRecipients, on Settings > Notifications). An empty list means nobody. Production is
/// never guarded. This is what makes it safe to fill a mail account on the test side and try a booking's
/// e-mail there: whoever else the outbox names is refused, in the worker, whatever the settings say.
/// Pure, so every branch is tested.
/// </summary>
public sealed class MailGuard
{
    public const string SettingKey = "TestMailRecipients";

    /// <summary>The words deploy-test.sh looks for in the journal before it leaves a test API running.</summary>
    public const string StartupLine = "Mail guard: this is not the production system";

    public const string Refusal =
        "TEST SYSTEM: not sent. A test system writes only to the test recipients listed on Settings > Notifications.";

    private readonly HashSet<string> _allowed;

    private MailGuard(bool production, HashSet<string> allowed)
    {
        Production = production;
        _allowed = allowed;
    }

    public bool Production { get; }

    /// <summary>The list as it is applied: lower-case addresses, digits-only numbers.</summary>
    public IReadOnlyCollection<string> Allowed => _allowed;

    public static MailGuard Of(bool production, string? list)
    {
        var allowed = new HashSet<string>(StringComparer.Ordinal);
        // Commas, semicolons and new lines separate entries. Spaces do not: a phone number is typed with them.
        // Several ADDRESSES typed with only spaces between them are still told apart.
        foreach (var entry in (list ?? string.Empty).Split([',', ';', '\r', '\n'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            var pieces = entry.Contains('@') ? entry.Split([' ', '\t'], StringSplitOptions.RemoveEmptyEntries) : [entry];
            foreach (var piece in pieces)
                if (Normalize(piece) is { Length: > 1 } key) allowed.Add(key);
        }
        return new MailGuard(production, allowed);
    }

    /// <summary>May this message go out? Production: always. Elsewhere: only to somebody on the list.</summary>
    public bool Allows(string? recipient)
        => Production || (Normalize(recipient) is { Length: > 0 } key && _allowed.Contains(key));

    /// <summary>An address compares in lower case; anything without an @ is a phone number and compares by its digits.</summary>
    public static string Normalize(string? recipient)
    {
        var value = (recipient ?? string.Empty).Trim();
        if (value.Contains('@')) return value.ToLowerInvariant();
        return new string(value.Where(char.IsAsciiDigit).ToArray());
    }

    public string Describe()
        => Production ? "production: no guard"
         : _allowed.Count == 0 ? "nobody (the list of test recipients is empty)"
         : string.Join(", ", _allowed.Order(StringComparer.Ordinal));
}

/// <summary>What a mail server's refusal means, in words an owner can act on. Pure, so every branch is tested.</summary>
public static class MailProblem
{
    public const string Login = "login";
    public const string Unreachable = "unreachable";
    public const string Refused = "refused";
    public const string Certificate = "certificate";
    public const string Other = "other";

    // Why a test could not even be tried (the settings, not the mail server).
    public const string NoLogin = "no-login";
    public const string NoServer = "no-server";
    public const string BadFrom = "bad-from";
    public const string HrOff = "hr-off";

    /// <summary>The kind of problem, from the text of the exception chain (SmtpClient answers in English).</summary>
    public static string Kind(string? error)
    {
        var e = (error ?? string.Empty).ToLowerInvariant();
        if (e.Length == 0) return Other;

        if (e.Contains("authenticat") || e.Contains("5.7.0") || e.Contains("5.7.3") || e.Contains("5.7.8") || e.Contains("5.7.9")
            || e.Contains("5.7.139") || e.Contains("credential") || e.Contains("username and password") || e.Contains("535") || e.Contains("534"))
            return Login;
        if (e.Contains("certificate") || e.Contains("ssl connection could not be established"))
            return Certificate;
        if (e.Contains("timed out") || e.Contains("timeout") || e.Contains("no such host") || e.Contains("name or service not known")
            || e.Contains("connection refused") || e.Contains("actively refused") || e.Contains("unable to connect")
            || e.Contains("network is unreachable") || e.Contains("unable to read data") || e.Contains("server does not support secure connections")
            || e.Contains("name resolution"))
            return Unreachable;
        if (e.Contains("5.1.") || e.Contains("5.5.") || e.Contains("5.7.") || e.Contains("mailbox unavailable") || e.Contains("not allowed")
            || e.Contains("sendas") || e.Contains("send as") || e.Contains("relay"))
            return Refused;
        return Other;
    }

    public static string Explain(string kind) => kind switch
    {
        Login => "The mail server refused the login. Check the user name and the password. A Google mailbox needs an "
               + "\"app password\" (Google account > Security > 2-Step Verification > App passwords), not the normal one; "
               + "a Microsoft 365 mailbox must have \"Authenticated SMTP\" switched on.",
        Unreachable => "The mail server could not be reached. Check the server name and the port: use 587 (HRMS cannot send "
                     + "through 465). If both are right, this server's network does not let it out on that port.",
        Certificate => "The connection to the mail server could not be secured. Check the server name: it must be the "
                     + "provider's own mail server (for Google, smtp.gmail.com).",
        Refused => "The mail server refused the message. The From address must be one this login may send as (usually the "
                 + "login itself), and the recipient must exist.",
        _ => "Read the mail server's answer below.",
    };
}

/// <summary>
/// The answer of one test message. Kind names the problem (a <see cref="MailProblem"/> constant; the page has its
/// own words for each, in both languages), Message says it in English, ServerAnswer is the mail server's own text.
/// </summary>
public sealed record MailTestResult(
    bool Ok, string Account, string Through, string From, string To, string? Kind, string? Message, string? ServerAnswer);

public interface IMailProbe
{
    /// <summary>Sends ONE test message now through the HR account ("hr") or the bookings mailbox ("booking"). Never throws for a mail fault.</summary>
    Task<MailTestResult> SendTestAsync(string account, string to, CancellationToken cancellationToken = default);
}

/// <summary>
/// The Settings page's "send a test message": the same settings reader, the same client and the same routing
/// as the worker, so "the test arrived" means booking mail will too. The password never leaves the server and
/// is never in the answer.
/// </summary>
public sealed class MailProbe(ISettingService settings, ILogger<MailProbe> logger) : IMailProbe
{
    public const string Hr = "hr";
    public const string Booking = "booking";
    private static readonly TimeSpan Patience = TimeSpan.FromSeconds(25);

    public static string? ParseAccount(string? value) => value?.Trim().ToLowerInvariant() switch
    {
        Hr => Hr,
        Booking or "bookings" => Booking,
        _ => null,
    };

    public async Task<MailTestResult> SendTestAsync(string account, string to, CancellationToken cancellationToken = default)
    {
        var mail = await MailAccountSettings.ReadAsync(settings);
        var plan = Plan(account, mail);
        if (plan.Refusal is not null)
            return new MailTestResult(false, account, plan.Through, plan.FromEmail, to, plan.RefusalKind, plan.Refusal, null);

        try
        {
            using var patience = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            patience.CancelAfter(Patience);
            using var client = EmailWorker.BuildClient(plan.Host, plan.Port, plan.User, plan.Password, logger);
            using var message = new MailMessage
            {
                From = new MailAddress(plan.FromEmail, plan.FromName),
                Subject = "MokaCo HRMS: test message",
                Body = $"This is a test message from HRMS (Settings > Notifications), sent through {plan.Label} "
                     + $"({plan.Through}) at {DateTime.UtcNow:yyyy-MM-dd HH:mm} UTC.\r\n\r\n"
                     + "If you are reading it, that account can send.\r\n\r\nMokaCo\r\n",
                IsBodyHtml = false,
            };
            message.To.Add(to);
            await client.SendMailAsync(message, patience.Token);

            logger.LogInformation("Mail test through {Account} ({Through}): sent.", account, plan.Through);
            return new MailTestResult(true, account, plan.Through, plan.FromEmail, to, null, null, null);
        }
        catch (Exception ex) when (ex is not OperationCanceledException || !cancellationToken.IsCancellationRequested)
        {
            var answer = Chain(ex);
            if (ex is OperationCanceledException)
                answer = $"The mail server did not answer within {Patience.TotalSeconds:0} seconds (timed out).";
            var kind = MailProblem.Kind(answer);
            logger.LogWarning("Mail test through {Account} ({Through}) failed: {Answer}", account, plan.Through, answer);
            return new MailTestResult(false, account, plan.Through, plan.FromEmail, to, kind, MailProblem.Explain(kind), answer);
        }
    }

    /// <summary>What the test will use, or why it cannot be tried. Pure.</summary>
    public static MailTestPlan Plan(string account, MailAccountSettings mail)
    {
        if (account == Booking)
        {
            var route = new MailRoute(MailAccount.Booking,
                FirstFilled(mail.Booking.FromEmail, mail.Booking.User) ?? string.Empty,
                FirstFilled(mail.Booking.FromName, mail.FromName) ?? MailAccountSettings.DefaultFromName);
            var host = BookingMailRouting.Host(route, mail.Booking, mail.Host);
            var port = BookingMailRouting.Port(route, mail.Booking, mail.Port);
            var through = host.Length == 0 ? string.Empty : $"{host}:{port}";
            (string Kind, string Text)? refusal =
                !mail.Booking.HasOwnAccount
                    ? (MailProblem.NoLogin, "The bookings mailbox has no login or no password. Until both are filled, booking mail goes out from the HR address.")
                : host.Length == 0
                    ? (MailProblem.NoServer, "There is no mail server for the bookings mailbox: fill its own, or the HR Mail server, which it uses when its own is empty.")
                : !MailAddress.TryCreate(route.FromEmail, out _)
                    ? (MailProblem.BadFrom, "The bookings mailbox's From address is not an e-mail address.")
                : null;
            return new MailTestPlan("the bookings mailbox", host, port, mail.Booking.User, mail.Booking.Password, route.FromEmail, route.FromName,
                through, refusal?.Kind, refusal?.Text);
        }

        var hrThrough = mail.Host.Length == 0 ? string.Empty : $"{mail.Host}:{mail.Port}";
        (string Kind, string Text)? hrRefusal =
            mail.Host.Length == 0 ? (MailProblem.HrOff, "The HR Mail server is empty, so the HR mail is switched off.")
            : !MailAddress.TryCreate(mail.FromEmail, out _) ? (MailProblem.BadFrom, "The HR From address is empty or not an e-mail address (From address, or the User name it falls back to).")
            : null;
        return new MailTestPlan("the HR account", mail.Host, mail.Port, mail.User, mail.Password, mail.FromEmail, mail.FromName,
            hrThrough, hrRefusal?.Kind, hrRefusal?.Text);
    }

    private static string? FirstFilled(params string?[] values)
        => values.Select(v => v?.Trim()).FirstOrDefault(v => !string.IsNullOrEmpty(v));

    /// <summary>The exception chain's messages, outermost first: SmtpClient puts the server's own words in the inner ones.</summary>
    internal static string Chain(Exception ex)
    {
        var parts = new List<string>();
        for (Exception? e = ex; e is not null && parts.Count < 4; e = e.InnerException)
            if (!string.IsNullOrWhiteSpace(e.Message) && !parts.Contains(e.Message.Trim())) parts.Add(e.Message.Trim());
        var text = string.Join(" | ", parts).Replace("\r", " ").Replace("\n", " ");
        return text.Length <= 500 ? text : text[..500];
    }
}

/// <summary>The account a test goes through. Refusal set = it cannot be tried, and why.</summary>
public sealed record MailTestPlan(
    string Label, string Host, int Port, string User, string Password, string FromEmail, string FromName, string Through,
    string? RefusalKind, string? Refusal);
