namespace MokaCo.HRMS.Model.Booking;

/// <summary>
/// One row of core.usp_Email_GetBookingSenders (docs/104_qa3_booking.sql): the booking mail's own
/// sender, SMTP account and WhatsApp template, as trg_Booking_Notify and usp_Booking_QueuePaymentAlert
/// wrote them on the outbox row (QA3 BKG-7). Only booking rows are returned; a request's mail has none.
/// </summary>
public class BookingMailSender
{
    public int EmailId { get; set; }
    public int? BookingId { get; set; }

    /// <summary>Request, Confirmation, Cancellation, Refund, StaffAlert, PayReceived …</summary>
    public string? MailKind { get; set; }

    /// <summary>The bookings mailbox (core.SETTING BookingFromEmail at queue time).</summary>
    public string? FromEmail { get; set; }

    public string? FromName { get; set; }

    /// <summary>'Booking' = send through the bookings mailbox's own SMTP login; null = the HR account.</summary>
    public string? SmtpAccount { get; set; }

    /// <summary>The WhatsApp template the row asks for, where the outbox carries one.</summary>
    public string? Template { get; set; }
}

/// <summary>
/// The bookings mailbox's SMTP login and WhatsApp template (core.SETTING BookingSmtpHost/Port/User/
/// Password, BookingFromEmail/Name, BookingWhatsAppTemplate/Lang), read with the HR settings every
/// cycle of the e-mail worker. Blank host or port fall back to the HR account's (one provider, two
/// mailboxes is the usual set-up).
/// </summary>
public sealed record BookingMailSettings(
    string Host, int Port, string User, string Password,
    string FromEmail, string FromName,
    string WhatsAppTemplate, string WhatsAppLang)
{
    /// <summary>The bookings mailbox can log in on its own: it has a user and a password.</summary>
    public bool HasOwnAccount => !string.IsNullOrWhiteSpace(User) && !string.IsNullOrEmpty(Password);

    public static readonly BookingMailSettings None = new(string.Empty, 0, string.Empty, string.Empty,
        string.Empty, string.Empty, string.Empty, string.Empty);
}

/// <summary>Which SMTP login a message goes out through, and as whom.</summary>
public enum MailAccount
{
    /// <summary>The HR account (core.SETTING SmtpHost/User/Password, SmtpFromEmail).</summary>
    Main,

    /// <summary>The bookings mailbox (core.SETTING BookingSmtp*, the row's own From).</summary>
    Booking,
}

/// <summary>The decision for one outbox row: the account, and the sender it is written as.</summary>
public sealed record MailRoute(MailAccount Account, string FromEmail, string FromName);

/// <summary>
/// THE ONE PLACE that decides how a booking row is sent (QA3 BKG-7). Pure, so every branch is tested.
///
///   e-mail    a row marked SmtpAccount 'Booking' goes through the bookings mailbox, written as the
///             row's own From (else BookingFromEmail/Name) — when that mailbox can log in. When it
///             cannot (the login was removed after the row was queued) the row still goes, through the
///             HR account and as the HR sender: a mail the provider would refuse ("send as" another
///             mailbox) helps nobody. Every other row: the HR account and sender, as before.
///   WhatsApp  a booking row uses the row's template, else BookingWhatsAppTemplate, else the HR one;
///             its language is BookingWhatsAppLang when set (the code the template was approved in),
///             else the row's own 'en'/'ar'.
/// </summary>
public static class BookingMailRouting
{
    public const string BookingAccount = "Booking";

    public static MailRoute Email(BookingMailSender? sender, BookingMailSettings booking, string mainFromEmail, string mainFromName)
    {
        var wantsBookingAccount = sender is not null
            && string.Equals(sender.SmtpAccount?.Trim(), BookingAccount, StringComparison.OrdinalIgnoreCase);

        if (!wantsBookingAccount || !booking.HasOwnAccount)
            return new MailRoute(MailAccount.Main, mainFromEmail, mainFromName);

        var fromEmail = FirstFilled(sender!.FromEmail, booking.FromEmail, booking.User) ?? mainFromEmail;
        var fromName = FirstFilled(sender.FromName, booking.FromName) ?? mainFromName;
        return new MailRoute(MailAccount.Booking, fromEmail, fromName);
    }

    public static string WhatsAppTemplate(BookingMailSender? sender, BookingMailSettings booking, string mainTemplate)
        => sender is null ? mainTemplate : FirstFilled(sender.Template, booking.WhatsAppTemplate) ?? mainTemplate;

    public static string WhatsAppLanguage(BookingMailSender? sender, BookingMailSettings booking, string rowLang)
    {
        var own = string.Equals(rowLang, "ar", StringComparison.OrdinalIgnoreCase) ? "ar" : "en";
        return sender is null ? own : FirstFilled(booking.WhatsAppLang) ?? own;
    }

    /// <summary>
    /// A WhatsApp template PARAMETER may not hold a new line, a tab or more than four spaces in a row:
    /// the Cloud API refuses the whole message (error 132018). The bodies are composed with CRLFs for
    /// e-mail, so every line break becomes " · " and runs of spaces are cut to one.
    /// </summary>
    public static string WhatsAppParameter(string body)
    {
        var lines = (body ?? string.Empty)
            .Replace("\t", " ")
            .Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Select(line => System.Text.RegularExpressions.Regex.Replace(line, " {2,}", " "))
            .Where(line => line.Length > 0);
        return string.Join(" · ", lines);
    }

    private static string? FirstFilled(params string?[] values)
        => values.Select(v => v?.Trim()).FirstOrDefault(v => !string.IsNullOrEmpty(v));
}
