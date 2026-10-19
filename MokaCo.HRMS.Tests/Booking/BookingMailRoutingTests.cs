using MokaCo.HRMS.Model.Booking;

namespace MokaCo.HRMS.Tests.Booking;

/// <summary>
/// QA3 BKG-7: booking mail goes out through the bookings mailbox, as the bookings mailbox, with the
/// booking WhatsApp template — the outbox rows said so (FromEmail, FromName, SmtpAccount 'Booking') and
/// the worker ignored them, sending everything as the HR account with the HR template.
/// <see cref="BookingMailRouting"/> is the whole decision; the worker only builds the clients.
/// </summary>
public class BookingMailRoutingTests
{
    private static readonly BookingMailSettings Bookings = new(
        Host: "smtp.office365.com", Port: 587, User: "bookings@mokanco.com.lb", Password: "not-real",
        FromEmail: "bookings@mokanco.com.lb", FromName: "MOKA & CO", WhatsAppTemplate: "booking_update", WhatsAppLang: "en_US");

    private static BookingMailSender BookingRow(string? account = "Booking", string? from = "bookings@mokanco.com.lb", string? name = "MOKA & CO Bookings", string? template = null)
        => new() { EmailId = 1, BookingId = 7, MailKind = "Confirmation", SmtpAccount = account, FromEmail = from, FromName = name, Template = template };

    [Fact]
    public void A_booking_row_goes_through_the_bookings_mailbox_as_itself()
    {
        var route = BookingMailRouting.Email(BookingRow(), Bookings, "hr@mokanco.com.lb", "MokaCo HRMS");
        Assert.Equal(new MailRoute(MailAccount.Booking, "bookings@mokanco.com.lb", "MOKA & CO Bookings"), route);
    }

    [Fact]
    public void A_booking_row_without_its_own_sender_takes_the_booking_settings()
    {
        var route = BookingMailRouting.Email(BookingRow(from: null, name: " "), Bookings, "hr@mokanco.com.lb", "MokaCo HRMS");
        Assert.Equal(new MailRoute(MailAccount.Booking, "bookings@mokanco.com.lb", "MOKA & CO"), route);
    }

    [Fact]
    public void A_request_row_and_a_booking_row_queued_without_the_account_go_as_before()
    {
        Assert.Equal(new MailRoute(MailAccount.Main, "hr@mokanco.com.lb", "MokaCo HRMS"),
            BookingMailRouting.Email(null, Bookings, "hr@mokanco.com.lb", "MokaCo HRMS"));
        Assert.Equal(new MailRoute(MailAccount.Main, "hr@mokanco.com.lb", "MokaCo HRMS"),
            BookingMailRouting.Email(BookingRow(account: null), Bookings, "hr@mokanco.com.lb", "MokaCo HRMS"));
    }

    /// <summary>
    /// The mailbox's login was removed after the row was queued: the row still goes, through the HR
    /// account AS the HR sender — "send as" another mailbox would be refused by the provider.
    /// </summary>
    [Fact]
    public void A_booking_row_whose_mailbox_cannot_log_in_falls_back_to_the_hr_account_and_sender()
    {
        var noLogin = Bookings with { Password = string.Empty };
        Assert.Equal(new MailRoute(MailAccount.Main, "hr@mokanco.com.lb", "MokaCo HRMS"),
            BookingMailRouting.Email(BookingRow(), noLogin, "hr@mokanco.com.lb", "MokaCo HRMS"));
        Assert.False(BookingMailSettings.None.HasOwnAccount);
    }

    [Fact]
    public void WhatsApp_uses_the_rows_template_then_the_booking_one_and_the_booking_language()
    {
        Assert.Equal("booking_confirmed", BookingMailRouting.WhatsAppTemplate(BookingRow(template: "booking_confirmed"), Bookings, "request_update"));
        Assert.Equal("booking_update", BookingMailRouting.WhatsAppTemplate(BookingRow(), Bookings, "request_update"));
        Assert.Equal("request_update", BookingMailRouting.WhatsAppTemplate(BookingRow(), BookingMailSettings.None, "request_update"));
        Assert.Equal("request_update", BookingMailRouting.WhatsAppTemplate(null, Bookings, "request_update"));      // a request's message

        Assert.Equal("en_US", BookingMailRouting.WhatsAppLanguage(BookingRow(), Bookings, "ar"));
        Assert.Equal("ar", BookingMailRouting.WhatsAppLanguage(BookingRow(), BookingMailSettings.None, "ar"));
        Assert.Equal("ar", BookingMailRouting.WhatsAppLanguage(null, Bookings, "ar"));
        Assert.Equal("en", BookingMailRouting.WhatsAppLanguage(null, Bookings, "fr"));
    }

    /// <summary>The Cloud API refuses a template parameter with a line break, a tab or 5+ spaces (error 132018); every body has CRLFs.</summary>
    [Fact]
    public void A_WhatsApp_parameter_is_one_line()
    {
        var body = "Dear Rami,\r\n\r\nYour booking is confirmed.\r\nRoom:     Mokha\r\nTime:\t22:00 - 01:00\r\n";

        var text = BookingMailRouting.WhatsAppParameter(body);

        Assert.Equal("Dear Rami, · Your booking is confirmed. · Room: Mokha · Time: 22:00 - 01:00", text);
        Assert.DoesNotContain('\n', text);
        Assert.DoesNotContain('\t', text);
        Assert.DoesNotContain("  ", text);
        Assert.Equal(string.Empty, BookingMailRouting.WhatsAppParameter(string.Empty));
    }
}
