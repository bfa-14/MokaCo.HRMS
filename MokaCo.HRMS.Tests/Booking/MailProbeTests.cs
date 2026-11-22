using MokaCo.HRMS.Api.Jobs;
using MokaCo.HRMS.Model.Booking;

namespace MokaCo.HRMS.Tests.Booking;

/// <summary>
/// The Settings page's mail test and the bookings mailbox on its own (22 Nov 2026): which server a message goes
/// through, when a test cannot even be tried, and what a mail server's refusal is called.
/// </summary>
public class MailProbeTests
{
    private static BookingMailSettings Mailbox(string host = "", int port = 0, string user = "bookings@example.test", string password = "pw",
        string from = "bookings@example.test")
        => new(host, port, user, password, from, "Bookings", string.Empty, string.Empty);

    private static MailAccountSettings Accounts(string host, BookingMailSettings booking, string user = "hr@example.test", string from = "hr@example.test")
        => new(host, 587, user, "hr-pw", from, "HR", booking);

    private static readonly MailRoute BookingRoute = new(MailAccount.Booking, "bookings@example.test", "Bookings");
    private static readonly MailRoute MainRoute = new(MailAccount.Main, "hr@example.test", "HR");

    [Fact]
    public void A_booking_message_goes_through_the_mailboxs_own_server_when_it_has_one()
    {
        Assert.Equal("smtp.own.test", BookingMailRouting.Host(BookingRoute, Mailbox("smtp.own.test", 2525), "smtp.hr.test"));
        Assert.Equal(2525, BookingMailRouting.Port(BookingRoute, Mailbox("smtp.own.test", 2525), 587));
    }

    [Fact]
    public void A_booking_message_falls_back_to_the_HR_server_and_port()
    {
        Assert.Equal("smtp.hr.test", BookingMailRouting.Host(BookingRoute, Mailbox(), " smtp.hr.test "));
        Assert.Equal(587, BookingMailRouting.Port(BookingRoute, Mailbox(), 587));
    }

    [Fact]
    public void An_HR_message_never_uses_the_bookings_server()
    {
        Assert.Equal("smtp.hr.test", BookingMailRouting.Host(MainRoute, Mailbox("smtp.own.test", 2525), "smtp.hr.test"));
        Assert.Equal(587, BookingMailRouting.Port(MainRoute, Mailbox("smtp.own.test", 2525), 587));
        Assert.Equal(string.Empty, BookingMailRouting.Host(MainRoute, Mailbox("smtp.own.test"), null));
    }

    [Fact]
    public void The_mailbox_stands_alone_only_with_a_login_a_password_and_a_server()
    {
        Assert.True(Mailbox("smtp.own.test").StandsAlone);
        Assert.False(Mailbox().StandsAlone);                                    // would need the HR server
        Assert.False(Mailbox("smtp.own.test", password: "").StandsAlone);
        Assert.False(Mailbox("smtp.own.test", user: " ").StandsAlone);
        Assert.False(BookingMailSettings.None.StandsAlone);
    }

    [Fact]
    public void The_booking_test_uses_what_the_worker_would()
    {
        var plan = MailProbe.Plan(MailProbe.Booking, Accounts(string.Empty, Mailbox("smtp.gmail.com")));
        Assert.Null(plan.Refusal);
        Assert.Equal("smtp.gmail.com:587", plan.Through);
        Assert.Equal("bookings@example.test", plan.FromEmail);
        Assert.Equal("bookings@example.test", plan.User);

        var viaHr = MailProbe.Plan(MailProbe.Booking, Accounts("smtp.hr.test", Mailbox(port: 2525, from: "")));
        Assert.Null(viaHr.Refusal);
        Assert.Equal("smtp.hr.test:2525", viaHr.Through);
        Assert.Equal("bookings@example.test", viaHr.FromEmail);                  // no From: the login
    }

    [Fact]
    public void The_booking_test_says_why_it_cannot_be_tried()
    {
        Assert.Equal(MailProblem.NoLogin, MailProbe.Plan(MailProbe.Booking, Accounts("smtp.hr.test", Mailbox(password: ""))).RefusalKind);
        Assert.Equal(MailProblem.NoServer, MailProbe.Plan(MailProbe.Booking, Accounts(string.Empty, Mailbox())).RefusalKind);
        var token = MailProbe.Plan(MailProbe.Booking, Accounts("smtp.hr.test", Mailbox(user: "a-provider-token", from: "")));
        Assert.Equal(MailProblem.BadFrom, token.RefusalKind);
        Assert.False(string.IsNullOrWhiteSpace(token.Refusal));
    }

    [Fact]
    public void The_HR_test_needs_a_server_and_a_sender()
    {
        Assert.Null(MailProbe.Plan(MailProbe.Hr, Accounts("smtp.hr.test", BookingMailSettings.None)).Refusal);
        Assert.Equal(MailProblem.HrOff, MailProbe.Plan(MailProbe.Hr, Accounts(string.Empty, BookingMailSettings.None)).RefusalKind);
        Assert.Equal(MailProblem.BadFrom, MailProbe.Plan(MailProbe.Hr, Accounts("smtp.hr.test", BookingMailSettings.None, from: "")).RefusalKind);
    }

    [Theory]
    [InlineData("hr", "hr")]
    [InlineData(" Booking ", "booking")]
    [InlineData("bookings", "booking")]
    [InlineData("", null)]
    [InlineData("everything", null)]
    [InlineData(null, null)]
    public void Only_the_two_accounts_can_be_tested(string? typed, string? expected)
        => Assert.Equal(expected, MailProbe.ParseAccount(typed));

    [Theory]
    [InlineData("The SMTP server requires a secure connection or the client was not authenticated. The server response was: 5.7.0 Authentication Required.", MailProblem.Login)]
    [InlineData("Mailbox unavailable. The server response was: 5.7.8 Username and Password not accepted.", MailProblem.Login)]
    [InlineData("535 5.7.139 Authentication unsuccessful, SmtpClientAuthentication is disabled for the Tenant.", MailProblem.Login)]
    [InlineData("Failure sending mail. | Unable to connect to the remote server | Connection refused", MailProblem.Unreachable)]
    [InlineData("Failure sending mail. | No such host is known.", MailProblem.Unreachable)]
    [InlineData("The mail server did not answer within 25 seconds (timed out).", MailProblem.Unreachable)]
    [InlineData("The remote certificate is invalid according to the validation procedure.", MailProblem.Certificate)]
    [InlineData("Mailbox unavailable. The server response was: 5.7.60 SMTP; Client does not have permissions to send as this sender", MailProblem.Refused)]
    [InlineData("Mailbox unavailable. The server response was: 5.1.1 The email account that you tried to reach does not exist.", MailProblem.Refused)]
    [InlineData("Something nobody has seen before.", MailProblem.Other)]
    [InlineData("", MailProblem.Other)]
    [InlineData(null, MailProblem.Other)]
    public void A_refusal_is_named(string? serverAnswer, string kind)
    {
        Assert.Equal(kind, MailProblem.Kind(serverAnswer));
        Assert.False(string.IsNullOrWhiteSpace(MailProblem.Explain(kind)));
    }

    [Fact]
    public void Production_writes_to_whoever_the_outbox_names()
    {
        var guard = MailGuard.Of(production: true, list: null);
        Assert.True(guard.Allows("guest@example.test"));
        Assert.True(guard.Allows("+96170000001"));
    }

    [Fact]
    public void A_test_system_writes_to_nobody_until_somebody_is_listed()
    {
        var guard = MailGuard.Of(production: false, list: "  ");
        Assert.False(guard.Allows("guest@example.test"));
        Assert.False(guard.Allows("+96170000001"));
        Assert.False(guard.Allows(null));
        Assert.False(guard.Allows(""));
        Assert.Contains("nobody", guard.Describe());
    }

    [Fact]
    public void A_test_system_writes_only_to_its_listed_recipients()
    {
        var guard = MailGuard.Of(production: false, list: "Owner@Example.test; tester@example.test,\n+961 70 000 001");
        Assert.True(guard.Allows("owner@example.test"));
        Assert.True(guard.Allows(" TESTER@example.test "));
        Assert.True(guard.Allows("96170000001"));            // a WhatsApp number, by its digits
        Assert.True(guard.Allows("+961 70 000 001"));
        Assert.False(guard.Allows("guest@example.test"));
        Assert.False(guard.Allows("owner@example.test.evil.test"));
        Assert.False(guard.Allows("96170000002"));
        Assert.False(guard.Allows("@"));
        Assert.Equal(3, guard.Allowed.Count);
    }

    [Fact]
    public void The_words_the_test_deploy_looks_for_are_the_words_the_worker_logs()
    {
        var script = File.ReadAllText(Path.Combine(RepoRoot(), "deploy", "test-env", "deploy-test.sh"));
        Assert.Contains(MailGuard.StartupLine, script);
    }

    private static string RepoRoot()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !File.Exists(Path.Combine(dir.FullName, "MokaCo.HRMS.slnx"))) dir = dir.Parent;
        return dir?.FullName ?? throw new InvalidOperationException("MokaCo.HRMS.slnx not found above the test folder.");
    }
}
