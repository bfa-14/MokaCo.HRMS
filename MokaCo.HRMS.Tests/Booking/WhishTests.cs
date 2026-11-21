using System.Net;
using System.Text;
using System.Text.Json;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Logging.Abstractions;
using Moq;
using MokaCo.HRMS.Api.Controllers;
using MokaCo.HRMS.Api.Hubs;
using MokaCo.HRMS.Model.Booking;
using MokaCo.HRMS.Repository.Booking;
using MokaCo.HRMS.Services.Booking;
using MokaCo.HRMS.Services.Booking.Payments;

namespace MokaCo.HRMS.Tests.Booking;

/// <summary>
/// WHISH PAY as the second way to pay a booking deposit (script 118; Whish Pay doc v2.0.0). No network: the client
/// talks to a recorded answer, the service to mocks. What is held: the request Whish is sent and how its envelope
/// is read (a "pending" answer is sent again with the SAME id, a refusal is not), what each collect status means for
/// a booking, that a Whish attempt is settled through the card flow's own path, and the three public endpoints.
/// The credentials here are made up.
/// </summary>
public class WhishTests
{
    private const string Ref = "MC-1A2B3C4D";
    private static readonly DateTime Now = new(2026, 11, 21, 12, 0, 0, DateTimeKind.Utc);

    private static readonly WhishOptions Options = WhishOptions.FromSettings(key => key switch
    {
        WhishOptions.BaseKey => "https://partner.api.sbx.whish.money/itel-service/api/",
        WhishOptions.ChannelKey => "10000001",
        WhishOptions.SecretKey => "not-a-real-secret",
        WhishOptions.WebsiteUrlKey => "Example.com.lb",
        MpgsOptions.SiteUrlKey => "https://mokanco.com.lb",
        MpgsOptions.ApiPublicUrlKey => "https://mokanco.com.lb/",
        _ => null,
    });

    /* ---- configuration ----------------------------------------------------------------------- */

    [Fact]
    public void All_the_keys_configure_it_none_is_silence_and_some_is_a_problem_that_names_keys_only()
    {
        Assert.True(Options.IsConfigured);
        Assert.Null(Options.Problem);
        Assert.Equal("https://partner.api.sbx.whish.money/itel-service/api", Options.BaseUrl);
        Assert.Contains("SANDBOX", Options.ToString());
        Assert.DoesNotContain("not-a-real-secret", Options.ToString());

        var none = WhishOptions.FromSettings(_ => null);
        Assert.False(none.IsConfigured);
        Assert.Null(none.Problem);

        var some = WhishOptions.FromSettings(key => key == WhishOptions.SecretKey ? "not-a-real-secret" : key == WhishOptions.BaseKey ? "http://plain.example" : null);
        Assert.False(some.IsConfigured);
        Assert.Contains("WHISH_CHANNEL is missing", some.Problem);
        Assert.Contains("WHISH_WEBSITE_URL is missing", some.Problem);
        Assert.Contains("WHISH_BASE must be https", some.Problem);
        Assert.Contains("API_PUBLIC_URL is missing", some.Problem);
        Assert.DoesNotContain("not-a-real-secret", some.Problem);
    }

    [Fact]
    public void An_attempt_id_is_the_reference_and_a_number_and_the_bare_reference_is_a_card_order()
    {
        Assert.Equal("MC-1A2B3C4D-A3", WhishOptions.AttemptId(Ref, 3));
        Assert.Equal(3, WhishOptions.AttemptNumber("MC-1A2B3C4D-A3", Ref));
        Assert.Equal(12, WhishOptions.AttemptNumber("mc-1a2b3c4d-a12", Ref));
        Assert.Null(WhishOptions.AttemptNumber(Ref, Ref));
        Assert.Null(WhishOptions.AttemptNumber(null, Ref));
        Assert.Null(WhishOptions.AttemptNumber("MC-1A2B3C4D-A0", Ref));
        Assert.Null(WhishOptions.AttemptNumber("MC-1A2B3C4D-Ax", Ref));
        Assert.Null(WhishOptions.AttemptNumber("MC-ZZZZZZZZ-A1", Ref));
        Assert.True(WhishOptions.IsAttemptId("MC-1A2B3C4D-A1", Ref));
    }

    [Fact]
    public void The_callback_address_carries_a_token_only_this_booking_has()
    {
        var url = Options.CallbackUrl(Ref);
        Assert.StartsWith("https://mokanco.com.lb/api/public/booking/whish/callback?ref=MC-1A2B3C4D&t=", url);
        var token = url[(url.IndexOf("&t=", StringComparison.Ordinal) + 3)..];

        Assert.Equal(24, token.Length);
        Assert.True(Options.IsCallbackToken(Ref, token));
        Assert.True(Options.IsCallbackToken("mc-1a2b3c4d", token.ToUpperInvariant()));
        Assert.False(Options.IsCallbackToken("MC-ZZZZZZZZ", token));
        Assert.False(Options.IsCallbackToken(Ref, null));
        Assert.False(Options.IsCallbackToken(Ref, "junk"));
        Assert.False(WhishOptions.Unconfigured.IsCallbackToken(Ref, token));
        Assert.Equal("https://mokanco.com.lb/api/public/booking/whish/return?ref=MC-1A2B3C4D", Options.ReturnUrl(Ref));
    }

    /* ---- the client -------------------------------------------------------------------------- */

    /// <summary>Answers each request with the next recorded response and keeps what was sent.</summary>
    private sealed class Recorded(params (HttpStatusCode Status, string Body)[] answers) : HttpMessageHandler
    {
        private readonly Queue<(HttpStatusCode Status, string Body)> _answers = new(answers);
        public List<(string Url, string Body, HttpRequestMessage Request)> Sent { get; } = [];

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Sent.Add((request.RequestUri!.ToString(), request.Content is null ? string.Empty : await request.Content.ReadAsStringAsync(cancellationToken), request));
            if (_answers.Count == 0) throw new HttpRequestException("no recorded answer left");
            var (status, body) = _answers.Dequeue();
            return new HttpResponseMessage(status) { Content = new StringContent(body, Encoding.UTF8, body.StartsWith('<') ? "text/html" : "application/json") };
        }
    }

    private static WhishClient Client(Recorded handler)
        => new(new HttpClient(handler), Options, NullLogger<WhishClient>.Instance) { RetryPause = TimeSpan.Zero };

    private static (HttpStatusCode, string) Json(string body) => (HttpStatusCode.OK, body);

    private const string Link = """{"status":true,"code":null,"dialog":null,"actions":null,"extra":null,"data":{"collectUrl":"https://partner.api.sbx.whish.money/pay/AbCdEf1"}}""";
    private const string Pending500 = """{"status":false,"code":"500","dialog":null,"actions":null,"extra":null,"data":null}""";

    private static Task<string> Create(WhishClient client, string invoice = "MOKA&CO room deposit")
        => client.CreateCollectAsync("MC-1A2B3C4D-A1", 30m, "USD", invoice, "https://x.example/cb", "https://x.example/cb", "https://x.example/back", "https://x.example/back");

    [Fact]
    public async Task Create_sends_the_documented_body_and_headers_and_returns_the_link()
    {
        var handler = new Recorded(Json(Link));

        var url = await Create(Client(handler), "MOKA&CO room deposit 🎉 MC-1A2B3C4D: Studio ☕");

        Assert.Equal("https://partner.api.sbx.whish.money/pay/AbCdEf1", url);
        var (sentTo, body, request) = Assert.Single(handler.Sent);
        Assert.Equal("https://partner.api.sbx.whish.money/itel-service/api/payment/whish", sentTo);
        Assert.Equal(HttpMethod.Post, request.Method);
        Assert.Equal("10000001", request.Headers.GetValues("channel").Single());
        Assert.Equal("not-a-real-secret", request.Headers.GetValues("secret").Single());
        Assert.Equal("Example.com.lb", request.Headers.GetValues("websiteUrl").Single());
        Assert.Equal(WhishOptions.UserAgent, string.Join(' ', request.Headers.GetValues("User-Agent")));

        using var json = JsonDocument.Parse(body);
        var root = json.RootElement;
        Assert.Equal(JsonValueKind.String, root.GetProperty("amount").ValueKind);            // a JSON string, per the spec
        Assert.Equal("30.00", root.GetProperty("amount").GetString());
        Assert.Equal("USD", root.GetProperty("currency").GetString());
        Assert.Equal("MC-1A2B3C4D-A1", root.GetProperty("externalId").GetString());
        Assert.Equal("MOKA&CO room deposit MC-1A2B3C4D: Studio", root.GetProperty("invoice").GetString());   // no emoji
        foreach (var field in new[] { "successCallbackUrl", "failureCallbackUrl", "successRedirectUrl", "failureRedirectUrl" })
            Assert.StartsWith("https://x.example/", root.GetProperty(field).GetString());
    }

    [Fact]
    public void Amounts_are_text_two_decimals_for_usd_and_none_for_lbp()
    {
        Assert.Equal("30.00", WhishClient.AmountText(30m, "USD"));
        Assert.Equal("12.35", WhishClient.AmountText(12.345m, "usd"));
        Assert.Equal("2700000", WhishClient.AmountText(2700000.4m, "LBP"));
        Assert.Equal("Arabic الغرفة stays, 100% & (brackets) too", WhishClient.CleanInvoice("Arabic الغرفة stays,  100% & (brackets) too 😀"));
        Assert.True(WhishClient.CleanInvoice(new string('a', 500)).Length <= WhishClient.MaxInvoice);
    }

    [Fact]
    public async Task A_pending_answer_or_a_lost_one_is_sent_again_with_the_same_id_and_body()
    {
        // Whish: status false + code "500" = pending, not failed - resend the SAME externalId; it never runs twice.
        var handler = new Recorded(Json(Pending500), (HttpStatusCode.BadGateway, "<html>502</html>"), Json(Link.Replace("\"data\"", "\"retrieved\":true,\"data\"")));

        var url = await Create(Client(handler));

        Assert.EndsWith("/pay/AbCdEf1", url);
        Assert.Equal(3, handler.Sent.Count);
        Assert.Single(handler.Sent.Select(s => s.Body).Distinct());                       // identical every time
    }

    [Fact]
    public async Task A_refusal_is_not_sent_again_and_no_link_is_an_error()
    {
        var refused = new Recorded(Json("""{"status":false,"code":"currency.not_supported","dialog":{"title":"Error","message":"x"},"data":null}"""), Json(Link));
        var problem = await Assert.ThrowsAsync<WhishException>(() => Create(Client(refused)));
        Assert.Contains("currency.not_supported", problem.Message);
        Assert.Single(refused.Sent);

        // What Whish's edge answers a localhost callback address with: a 403 page, not an envelope.
        var forbidden = new Recorded((HttpStatusCode.Forbidden, "<html><head><title>403 Forbidden</title></head></html>"), Json(Link));
        await Assert.ThrowsAsync<WhishException>(() => Create(Client(forbidden)));
        Assert.Single(forbidden.Sent);

        // "A different amount: a success without a link" - the id was used for another amount.
        var noLink = new Recorded(Json("""{"status":true,"code":null,"retrieved":true,"data":null}"""));
        await Assert.ThrowsAsync<WhishException>(() => Create(Client(noLink)));

        // Pending three times: given up, still an error and never a made-up link.
        var stuck = new Recorded(Json(Pending500), Json(Pending500), Json(Pending500));
        await Assert.ThrowsAsync<WhishException>(() => Create(Client(stuck)));
        Assert.Equal(WhishClient.CreateAttempts, stuck.Sent.Count);
    }

    [Theory]
    [InlineData("""{"status":true,"code":null,"data":{"collectStatus":"success","payerPhoneNumber":"96170000000"}}""", WhishLookupKind.Found, "success", "96170000000")]
    [InlineData("""{"status":true,"code":null,"data":{"collectStatus":"pending","payerPhoneNumber":""}}""", WhishLookupKind.Found, "pending", null)]
    [InlineData("""{"status":true,"code":null,"data":{"collectStatus":"FAILED","payerPhoneNumber":""}}""", WhishLookupKind.Found, "failed", null)]
    [InlineData("""{"status":false,"code":"external_id.not_exists","dialog":null,"data":null}""", WhishLookupKind.NotFound, null, null)]
    [InlineData("""{"status":false,"code":"collect.not_exists","dialog":null,"data":null}""", WhishLookupKind.NotFound, null, null)]
    [InlineData("""{"status":false,"code":"auth.session_not_exist","dialog":{"title":"Error"},"data":null}""", WhishLookupKind.Error, null, null)]
    [InlineData("""{"status":true,"code":null,"data":{}}""", WhishLookupKind.Error, null, null)]
    public async Task Status_reads_the_persisted_state_and_never_throws(string answer, WhishLookupKind kind, string? status, string? phone)
    {
        var handler = new Recorded(Json(answer));

        var lookup = await Client(handler).GetStatusAsync("MC-1A2B3C4D-A1", "usd");

        Assert.Equal((kind, status, phone), (lookup.Kind, lookup.CollectStatus, lookup.PayerPhoneNumber));
        var (sentTo, body, _) = Assert.Single(handler.Sent);
        Assert.EndsWith("/payment/collect/status", sentTo);
        Assert.Equal("""{"currency":"USD","externalId":"MC-1A2B3C4D-A1"}""", body);
    }

    [Fact]
    public async Task Status_that_cannot_be_told_is_an_error_after_one_more_try()
    {
        var pending = new Recorded(Json(Pending500), Json(Pending500));
        Assert.Equal(WhishLookupKind.Error, (await Client(pending).GetStatusAsync("MC-1A2B3C4D-A1", "USD")).Kind);
        Assert.Equal(WhishClient.StatusAttempts, pending.Sent.Count);

        var down = new Recorded();                                                       // the handler throws: no network
        Assert.Equal(WhishLookupKind.Error, (await Client(down).GetStatusAsync("MC-1A2B3C4D-A1", "USD")).Kind);

        var recovers = new Recorded((HttpStatusCode.ServiceUnavailable, "<html>503</html>"), Json("""{"status":true,"code":null,"data":{"collectStatus":"success","payerPhoneNumber":""}}"""));
        Assert.Equal("success", (await Client(recovers).GetStatusAsync("MC-1A2B3C4D-A1", "USD")).CollectStatus);
    }

    [Fact]
    public async Task Refund_says_done_already_done_or_why_not()
    {
        var done = new Recorded(Json("""{"status":true,"code":null,"dialog":null,"data":null}"""));
        var first = await Client(done).RefundAsync("MC-1A2B3C4D-A1", "USD", "Guest cancelled 🙁");
        Assert.True(first.Refunded);
        Assert.False(first.AlreadyDone);
        Assert.Equal("""{"currency":"USD","externalId":"MC-1A2B3C4D-A1","refundReason":"Guest cancelled"}""", done.Sent[0].Body);
        Assert.EndsWith("/payment/whish/refund", done.Sent[0].Url);

        var replay = new Recorded(Json("""{"status":true,"code":null,"retrieved":true,"data":null}"""));
        Assert.True((await Client(replay).RefundAsync("MC-1A2B3C4D-A1", "USD", " ")).AlreadyDone);
        Assert.Contains("\"refundReason\":\"Booking cancelled\"", replay.Sent[0].Body);  // never blank

        // Our server's IP is not registered with Whish yet.
        var notAllowed = new Recorded(Json("""{"status":false,"code":"auth.error","dialog":null,"data":null}"""));
        var refused = await Client(notAllowed).RefundAsync("MC-1A2B3C4D-A1", "USD", "x");
        Assert.False(refused.Refunded);
        Assert.Equal("auth.error", refused.Code);
    }

    [Fact]
    public void The_envelope_is_judged_by_its_body_never_by_the_http_status()
    {
        Assert.True(WhishClient.ParseEnvelope(500, """{"status":true,"code":null,"data":{}}""").Ok);
        var pending = WhishClient.ParseEnvelope(200, Pending500);
        Assert.False(pending.Ok);
        Assert.True(pending.Transient);
        var refusedCode = WhishClient.ParseEnvelope(200, """{"status":false,"code":"emoji.not_supported"}""");
        Assert.False(refusedCode.Transient);
        Assert.Equal("emoji.not_supported", refusedCode.Code);
        Assert.Equal("400", WhishClient.ParseEnvelope(200, """{"status":false,"code":400}""").Code);     // a number where a string is promised
        Assert.True(WhishClient.ParseEnvelope(502, "<html>").Transient);
        Assert.False(WhishClient.ParseEnvelope(403, "<html>").Transient);
        Assert.True(WhishClient.ParseEnvelope(200, "").Transient);
    }

    /* ---- what a status means ----------------------------------------------------------------- */

    [Theory]
    [InlineData("success", false, PaymentOutcome.Paid, false)]
    [InlineData("success", true, PaymentOutcome.Paid, false)]
    [InlineData("failed", false, PaymentOutcome.Failed, false)]
    [InlineData("pending", false, PaymentOutcome.Unconfirmed, false)]      // the link can still be paid
    [InlineData("pending", true, PaymentOutcome.Unconfirmed, true)]        // the link is over: never paid
    [InlineData("refunded", true, PaymentOutcome.Unconfirmed, false)]
    [InlineData("unknown", true, PaymentOutcome.Unconfirmed, false)]
    [InlineData("something-new", false, PaymentOutcome.Unconfirmed, false)]
    public void A_collect_status_becomes_the_card_flows_decision(string status, bool linkOver, PaymentOutcome outcome, bool abandoned)
    {
        var decision = WhishDecisionTable.Decide(new WhishCollectLookup(WhishLookupKind.Found, status), linkOver);
        Assert.Equal((outcome, abandoned), (decision.Outcome, decision.NothingAttempted));
    }

    [Fact]
    public void No_answer_is_never_abandonment_and_an_id_whish_never_saw_is()
    {
        var error = WhishDecisionTable.Decide(WhishCollectLookup.Error("timed out"), linkOver: true);
        Assert.Equal((PaymentOutcome.Unconfirmed, false), (error.Outcome, error.NothingAttempted));

        var unknownId = WhishDecisionTable.Decide(WhishCollectLookup.NotFound("external_id.not_exists"), linkOver: false);
        Assert.Equal((PaymentOutcome.Unconfirmed, true), (unknownId.Outcome, unknownId.NothingAttempted));
    }

    /* ---- the deposit service ----------------------------------------------------------------- */

    private sealed class FixedClock(DateTime utc) : TimeProvider
    {
        public override DateTimeOffset GetUtcNow() => new(utc);
    }

    private sealed class Rig
    {
        public Mock<IOnlineDepositRepository> Deposits { get; } = new();
        public Mock<IBookingRepository> Bookings { get; } = new();
        public Mock<IMpgsClient> Card { get; } = new(MockBehavior.Strict);
        public Mock<IWhishClient> Whish { get; } = new(MockBehavior.Strict);
        public WhishOptions WhishOptions { get; init; } = Options;
        public bool Enabled { get; init; } = true;

        public OnlineDepositService Service
        {
            get
            {
                Deposits.Setup(d => d.IsWhishEnabledAsync()).ReturnsAsync(Enabled);
                return new OnlineDepositService(Deposits.Object, Bookings.Object, Card.Object,
                    new MpgsOptions { IsConfigured = false, Problem = "no card gateway in this test" },
                    new OnlineDepositOptions { ReconcileAfterMinutes = 10, GiveUpAfterMinutes = 30 },
                    NullLogger<OnlineDepositService>.Instance, new FixedClock(Now), Whish.Object, WhishOptions);
            }
        }

        /// <param name="attempt">The Whish attempt the booking is on; null = no payment opened; 0 = a card order.</param>
        public void State(int? attempt = 1, string status = "Pending", double openedMinutesAgo = 2, int holdMinutesLeft = 13, bool paid = false)
            => Deposits.Setup(d => d.GetPaymentStateAsync(Ref)).ReturnsAsync(new PaymentState
            {
                BookingId = 42, BookingRef = Ref, Status = status, Source = "Website", DepositDue = 30m, CurrencyCode = "USD",
                PaymentOpenedUtc = attempt is null ? null : Now.AddMinutes(-openedMinutesAgo),
                HoldExpiresUtc = attempt is null ? null : Now.AddMinutes(holdMinutesLeft),
                GatewayOrderId = attempt switch { null => null, 0 => Ref, _ => WhishOptions.AttemptId(Ref, attempt.Value) },
                GatewayPaid = paid,
            });

        public void Says(string externalId, string status, string? phone = null)
            => Whish.Setup(w => w.GetStatusAsync(externalId, "USD", It.IsAny<CancellationToken>()))
                .ReturnsAsync(new WhishCollectLookup(WhishLookupKind.Found, status, phone));

        public void Records(string externalId, string? phone, string outcome = OnlinePaymentRecorded.Confirmed, string status = "Confirmed")
            => Deposits.Setup(d => d.ConfirmOnlinePaymentAsync(Ref, 30m, "USD", externalId, phone, PaymentMethods.WhishLineName))
                .ReturnsAsync(new OnlinePaymentRecorded { Outcome = outcome, BookingRef = Ref, Status = status, PaidAmount = 30m });

        public void Releases()
            => Bookings.Setup(b => b.ReleaseHoldAsync(Ref)).ReturnsAsync(new BookingHoldReleased { BookingRef = Ref, Status = "Cancelled" });

        public void NothingRecordedOrReleased()
        {
            Deposits.Verify(d => d.ConfirmOnlinePaymentAsync(It.IsAny<string>(), It.IsAny<decimal>(), It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string?>(), It.IsAny<string>()), Times.Never());
            Bookings.Verify(b => b.ReleaseHoldAsync(It.IsAny<string>()), Times.Never());
        }
    }

    private static PaymentStarted Started() => new()
    {
        BookingId = 42, BookingRef = Ref, DepositDue = 30m, CurrencyCode = "USD", TotalAmount = 60m,
        BookDate = new DateTime(2026, 12, 1), StartMin = 600, EndMin = 720, Hours = 2m, RoomName = "Mokha",
        HoldExpiresUtc = Now.AddMinutes(15), PaymentOpenedUtc = Now,
    };

    [Fact]
    public async Task The_methods_on_offer_follow_the_keys_and_the_switch()
    {
        Assert.Equal([PaymentMethods.Whish], await new Rig().Service.MethodsAsync());
        Assert.Empty(await new Rig { Enabled = false }.Service.MethodsAsync());
        Assert.Empty(await new Rig { WhishOptions = WhishOptions.Unconfigured }.Service.MethodsAsync());
    }

    [Fact]
    public async Task Opening_a_whish_attempt_stamps_the_hold_numbers_the_attempt_and_returns_whishs_link()
    {
        var rig = new Rig();
        rig.State(attempt: null);                                                     // nothing opened before
        rig.Deposits.Setup(d => d.StartPaymentAsync(Ref)).ReturnsAsync(Started());
        rig.Deposits.Setup(d => d.StartWhishAttemptAsync(Ref)).ReturnsAsync(new WhishAttemptStarted { BookingRef = Ref, ExternalId = "MC-1A2B3C4D-A1", Attempt = 1 });
        rig.Whish.Setup(w => w.CreateCollectAsync("MC-1A2B3C4D-A1", 30m, "USD", "MOKA&CO room deposit MC-1A2B3C4D: Mokha, 2026-12-01, 2h",
                Options.CallbackUrl(Ref), Options.CallbackUrl(Ref), Options.ReturnUrl(Ref), Options.ReturnUrl(Ref), It.IsAny<CancellationToken>()))
            .ReturnsAsync("https://partner.api.sbx.whish.money/pay/AbCdEf1");

        var opening = await rig.Service.OpenAsync(Ref, "whish");

        Assert.Equal(PayOpenResult.Opened, opening.Result);
        Assert.Equal((PaymentMethods.Whish, "https://partner.api.sbx.whish.money/pay/AbCdEf1", 30m, "USD"), (opening.Method, opening.CollectUrl, opening.Deposit, opening.Currency));
        Assert.Null(opening.SessionId);
        Assert.True(opening.Changed);
        rig.Whish.VerifyAll();
    }

    [Fact]
    public async Task Whish_that_is_not_set_up_or_switched_off_opens_nothing_and_puts_no_hold()
    {
        foreach (var rig in new[] { new Rig { Enabled = false }, new Rig { WhishOptions = WhishOptions.Unconfigured } })
        {
            var opening = await rig.Service.OpenAsync(Ref, "whish");

            Assert.Equal(PayOpenResult.GatewayError, opening.Result);
            rig.Deposits.Verify(d => d.StartPaymentAsync(It.IsAny<string>()), Times.Never());
            rig.Deposits.Verify(d => d.GetPaymentStateAsync(It.IsAny<string>()), Times.Never());
        }
    }

    [Fact]
    public async Task A_second_pay_while_the_first_link_can_still_be_paid_opens_nothing()
    {
        var rig = new Rig();
        rig.State(attempt: 1, openedMinutesAgo: 2);
        rig.Says("MC-1A2B3C4D-A1", "pending");

        var opening = await rig.Service.OpenAsync(Ref, "whish");

        Assert.Equal(PayOpenResult.PreviousUnconfirmed, opening.Result);
        rig.Deposits.Verify(d => d.StartPaymentAsync(It.IsAny<string>()), Times.Never());
        rig.Deposits.Verify(d => d.StartWhishAttemptAsync(It.IsAny<string>()), Times.Never());
    }

    [Theory]
    [InlineData("failed", 3)]        // Whish says the link expired unpaid
    [InlineData("pending", 7)]       // still "pending", but the five minutes (and the grace) are over
    public async Task A_second_pay_after_the_first_attempt_is_over_gets_a_new_id_and_link(string firstStatus, double openedMinutesAgo)
    {
        var rig = new Rig();
        rig.State(attempt: 1, openedMinutesAgo: openedMinutesAgo);
        rig.Says("MC-1A2B3C4D-A1", firstStatus);
        rig.Deposits.Setup(d => d.StartPaymentAsync(Ref)).ReturnsAsync(Started());
        rig.Deposits.Setup(d => d.StartWhishAttemptAsync(Ref)).ReturnsAsync(new WhishAttemptStarted { BookingRef = Ref, ExternalId = "MC-1A2B3C4D-A2", Attempt = 2 });
        rig.Whish.Setup(w => w.CreateCollectAsync("MC-1A2B3C4D-A2", 30m, "USD", It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync("https://partner.api.sbx.whish.money/pay/Second2");

        var opening = await rig.Service.OpenAsync(Ref, "whish");

        Assert.Equal((PayOpenResult.Opened, "https://partner.api.sbx.whish.money/pay/Second2"), (opening.Result, opening.CollectUrl));
        rig.NothingRecordedOrReleased();                                              // the hold was not released under the guest
    }

    [Fact]
    public async Task A_second_pay_that_finds_the_first_attempt_paid_records_it_and_opens_nothing()
    {
        var rig = new Rig();
        rig.State(attempt: 1);
        rig.Says("MC-1A2B3C4D-A1", "success", "96170000000");
        rig.Records("MC-1A2B3C4D-A1", "96170000000");

        var opening = await rig.Service.OpenAsync(Ref, "whish");

        Assert.Equal(PayOpenResult.AlreadyPaid, opening.Result);
        Assert.True(opening.Changed);
        rig.Deposits.Verify(d => d.SetWhishPayerAsync(Ref, "MC-1A2B3C4D-A1", "96170000000"), Times.Once());
        rig.Deposits.Verify(d => d.StartPaymentAsync(It.IsAny<string>()), Times.Never());
    }

    [Fact]
    public async Task Whish_not_creating_the_payment_is_a_gateway_error()
    {
        var rig = new Rig();
        rig.State(attempt: null);
        rig.Deposits.Setup(d => d.StartPaymentAsync(Ref)).ReturnsAsync(Started());
        rig.Deposits.Setup(d => d.StartWhishAttemptAsync(Ref)).ReturnsAsync(new WhishAttemptStarted { BookingRef = Ref, ExternalId = "MC-1A2B3C4D-A1", Attempt = 1 });
        rig.Whish.Setup(w => w.CreateCollectAsync(It.IsAny<string>(), It.IsAny<decimal>(), It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string>(), It.IsAny<CancellationToken>()))
            .ThrowsAsync(new WhishException("Whish did not create the payment: code 500."));

        Assert.Equal(PayOpenResult.GatewayError, (await rig.Service.OpenAsync(Ref, "whish")).Result);
    }

    [Theory]
    [InlineData(SettleTrigger.GatewayCallback)]
    [InlineData(SettleTrigger.GatewayReturn)]
    [InlineData(SettleTrigger.Reconciliation)]
    public async Task A_paid_attempt_is_recorded_through_the_card_flows_procedure_as_whish_whoever_asks(SettleTrigger trigger)
    {
        var rig = new Rig();
        rig.State(attempt: 2, openedMinutesAgo: 12);
        rig.Says("MC-1A2B3C4D-A2", "success", "96170000000");
        rig.Records("MC-1A2B3C4D-A2", "96170000000");

        var settled = await rig.Service.SettleAsync(Ref, trigger);

        Assert.Equal((SettlementResult.Paid, true, "Confirmed"), (settled.Result, settled.Changed, settled.Status));
        rig.Deposits.Verify(d => d.ConfirmOnlinePaymentAsync(Ref, 30m, "USD", "MC-1A2B3C4D-A2", "96170000000", "Whish"), Times.Once());
        rig.Deposits.Verify(d => d.SetWhishPayerAsync(Ref, "MC-1A2B3C4D-A2", "96170000000"), Times.Once());
    }

    [Fact]
    public async Task A_replayed_callback_changes_nothing()
    {
        var rig = new Rig();
        rig.State(attempt: 1, status: "Confirmed", paid: true);                       // already on the books

        var settled = await rig.Service.SettleAsync(Ref, SettleTrigger.GatewayCallback);

        Assert.Equal((SettlementResult.Paid, false), (settled.Result, settled.Changed));
        rig.NothingRecordedOrReleased();                                              // and the strict Whish mock was not asked
    }

    [Fact]
    public async Task While_the_link_can_still_be_paid_the_hold_is_kept_and_nobody_is_told_nothing_was_charged()
    {
        // Also what a FAILED attempt reads until the link's five minutes are over.
        foreach (var trigger in new[] { SettleTrigger.GatewayReturn, SettleTrigger.GatewayCallback, SettleTrigger.GuestRelease, SettleTrigger.Reconciliation })
        {
            var rig = new Rig();
            rig.State(attempt: 1, openedMinutesAgo: 3);
            rig.Says("MC-1A2B3C4D-A1", "pending");

            var settled = await rig.Service.SettleAsync(Ref, trigger);

            Assert.Equal(SettlementResult.Unconfirmed, settled.Result);
            rig.Deposits.Verify(d => d.PaymentCheckedAsync(Ref, true), Times.Once());
            rig.NothingRecordedOrReleased();
        }
    }

    [Fact]
    public async Task An_expired_link_releases_the_booking_when_the_guest_comes_back_or_walks_away()
    {
        var back = new Rig();
        back.State(attempt: 1, openedMinutesAgo: 6);
        back.Says("MC-1A2B3C4D-A1", "failed");
        back.Releases();
        Assert.Equal(SettlementResult.Released, (await back.Service.SettleAsync(Ref, SettleTrigger.GatewayReturn)).Result);

        // Still "pending" after the link is over: the guest walking away releases it at once...
        var away = new Rig();
        away.State(attempt: 1, openedMinutesAgo: 7);
        away.Says("MC-1A2B3C4D-A1", "pending");
        away.Releases();
        Assert.Equal(SettlementResult.Released, (await away.Service.SettleAsync(Ref, SettleTrigger.GuestRelease)).Result);

        // ... and the job once the hold has run out, not before.
        var holding = new Rig();
        holding.State(attempt: 1, openedMinutesAgo: 11, holdMinutesLeft: 4);
        holding.Says("MC-1A2B3C4D-A1", "pending");
        Assert.Equal(SettlementResult.Unconfirmed, (await holding.Service.SettleAsync(Ref, SettleTrigger.Reconciliation)).Result);
        holding.NothingRecordedOrReleased();

        var over = new Rig();
        over.State(attempt: 1, openedMinutesAgo: 16, holdMinutesLeft: -1);
        over.Says("MC-1A2B3C4D-A1", "pending");
        over.Releases();
        Assert.Equal(SettlementResult.Released, (await over.Service.SettleAsync(Ref, SettleTrigger.Reconciliation)).Result);
    }

    [Fact]
    public async Task The_job_frees_the_slot_as_soon_as_whish_says_the_link_expired_unpaid()
    {
        // Twelve minutes after opening: well inside the 30 minutes a failed CARD order is given. Whish's "failed" is final.
        var rig = new Rig();
        rig.State(attempt: 1, openedMinutesAgo: 12, holdMinutesLeft: 3);
        rig.Says("MC-1A2B3C4D-A1", "failed");
        rig.Releases();

        var settled = await rig.Service.SettleAsync(Ref, SettleTrigger.Reconciliation);

        Assert.Equal((SettlementResult.Released, true), (settled.Result, settled.Changed));
        rig.Deposits.Verify(d => d.PaymentCheckedAsync(Ref, true), Times.Never());      // the hold is not extended
        Assert.True(WhishDecisionTable.Decide(new WhishCollectLookup(WhishLookupKind.Found, "failed"), linkOver: true).Final);
    }

    [Fact]
    public async Task The_job_finds_an_earlier_attempt_that_was_paid_after_a_new_one_was_opened()
    {
        var rig = new Rig();
        rig.State(attempt: 3, openedMinutesAgo: 12, holdMinutesLeft: 3);
        rig.Says("MC-1A2B3C4D-A3", "pending");
        rig.Says("MC-1A2B3C4D-A2", "failed");
        rig.Says("MC-1A2B3C4D-A1", "success", "96171111111");                        // paid in its last second
        rig.Records("MC-1A2B3C4D-A1", "96171111111");

        var settled = await rig.Service.SettleAsync(Ref, SettleTrigger.Reconciliation);

        Assert.Equal(SettlementResult.Paid, settled.Result);
        rig.Deposits.Verify(d => d.ConfirmOnlinePaymentAsync(Ref, 30m, "USD", "MC-1A2B3C4D-A1", "96171111111", "Whish"), Times.Once());
    }

    [Fact]
    public async Task Earlier_attempts_are_the_jobs_business_only()
    {
        var rig = new Rig();
        rig.State(attempt: 2, openedMinutesAgo: 3);
        rig.Says("MC-1A2B3C4D-A2", "pending");                                        // attempt 1 is not asked about: the strict mock would throw

        Assert.Equal(SettlementResult.Unconfirmed, (await rig.Service.SettleAsync(Ref, SettleTrigger.GatewayReturn)).Result);
    }

    [Fact]
    public async Task A_whish_attempt_whose_keys_are_gone_is_left_as_it_is()
    {
        var rig = new Rig { WhishOptions = WhishOptions.Unconfigured };
        rig.State(attempt: 1, openedMinutesAgo: 40);

        var settled = await rig.Service.SettleAsync(Ref, SettleTrigger.Reconciliation);

        Assert.Equal(SettlementResult.Unconfirmed, settled.Result);
        rig.Deposits.Verify(d => d.PaymentCheckedAsync(It.IsAny<string>(), It.IsAny<bool>()), Times.Never());
        rig.NothingRecordedOrReleased();
    }

    [Fact]
    public async Task Paid_on_whish_after_the_booking_was_closed_is_recorded_and_left_to_staff()
    {
        var rig = new Rig();
        rig.State(attempt: 1, status: "Cancelled", openedMinutesAgo: 20);
        rig.Says("MC-1A2B3C4D-A1", "success", null);
        rig.Records("MC-1A2B3C4D-A1", null, OnlinePaymentRecorded.PaidButClosed, "Cancelled");

        var settled = await rig.Service.SettleAsync(Ref, SettleTrigger.Reconciliation);

        Assert.Equal(SettlementResult.PaidNeedsStaff, settled.Result);
    }

    /* ---- the endpoints ----------------------------------------------------------------------- */

    private static (PublicBookingController Controller, Mock<IOnlineDepositService> Deposits, Mock<IBookingLivePublisher> Live) Controller(string? body = null)
    {
        var deposits = new Mock<IOnlineDepositService>();
        deposits.SetupGet(d => d.Whish).Returns(Options);
        var live = new Mock<IBookingLivePublisher>();
        var http = new DefaultHttpContext();
        if (body is not null)
        {
            var bytes = Encoding.UTF8.GetBytes(body);
            http.Request.Body = new MemoryStream(bytes);
            http.Request.ContentLength = bytes.Length;
            http.Request.ContentType = "application/json";
        }
        var controller = new PublicBookingController(Mock.Of<IBookingService>(), Mock.Of<IRoomService>(), live.Object, deposits.Object)
        {
            ControllerContext = new ControllerContext { HttpContext = http },
        };
        return (controller, deposits, live);
    }

    private static object? Prop(object body, string name) => body.GetType().GetProperty(name)?.GetValue(body);

    [Theory]
    [InlineData("""{"method":"whish"}""", null)]
    [InlineData("""{ "method": "WHISH" }""", null)]
    [InlineData(null, "whish")]
    public async Task Pay_with_whish_answers_the_link_instead_of_a_session(string? body, string? query)
    {
        var (controller, deposits, live) = Controller(body);
        deposits.Setup(d => d.OpenAsync(Ref, PaymentMethods.Whish, It.IsAny<CancellationToken>()))
            .ReturnsAsync(new PaymentOpening(PayOpenResult.Opened, Ref, Deposit: 30m, Currency: "USD", HoldExpiresUtc: new DateTime(2026, 11, 21, 12, 15, 0),
                Changed: true, Method: PaymentMethods.Whish, CollectUrl: "https://partner.api.sbx.whish.money/pay/AbCdEf1"));

        var ok = Assert.IsType<OkObjectResult>(await controller.Pay(Ref, query));

        Assert.Equal("whish", Prop(ok.Value!, "method"));
        Assert.Equal("https://partner.api.sbx.whish.money/pay/AbCdEf1", Prop(ok.Value!, "collectUrl"));
        Assert.Equal((Ref, 30m, "USD"), (Prop(ok.Value!, "ref"), Prop(ok.Value!, "deposit"), Prop(ok.Value!, "currency")));
        Assert.NotNull(Prop(ok.Value!, "holdExpiresUtc"));
        Assert.NotNull(Prop(ok.Value!, "expiresAt"));
        Assert.Null(Prop(ok.Value!, "sessionId"));
        live.Verify(l => l.PublishAsync(Ref), Times.Once());
    }

    [Theory]
    [InlineData(null)]                         // no body: what the site sent before Whish
    [InlineData("{}")]
    [InlineData("""{"method":"card"}""")]
    [InlineData("""{"method":null}""")]
    public async Task Pay_without_a_method_is_still_the_card(string? body)
    {
        var (controller, deposits, _) = Controller(body);
        deposits.Setup(d => d.OpenAsync(Ref, It.IsAny<CancellationToken>()))
            .ReturnsAsync(new PaymentOpening(PayOpenResult.Opened, Ref, "SESSION0001", 12.50m, "USD"));

        var ok = Assert.IsType<OkObjectResult>(await controller.Pay(Ref));

        Assert.Equal(("card", "SESSION0001"), (Prop(ok.Value!, "method"), Prop(ok.Value!, "sessionId")));
        deposits.Verify(d => d.OpenAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<CancellationToken>()), Times.Never());
    }

    [Theory]
    [InlineData("""{"method":"bitcoin"}""")]
    [InlineData("""{"method":5}""")]
    [InlineData("not json at all")]
    [InlineData("[]")]
    public async Task Pay_with_a_method_that_is_neither_is_refused_before_anything_is_opened(string body)
    {
        var (controller, deposits, _) = Controller(body);

        var bad = Assert.IsType<BadRequestObjectResult>(await controller.Pay(Ref));

        Assert.Equal("invalid_input", Prop(bad.Value!, "code"));
        deposits.Verify(d => d.OpenAsync(It.IsAny<string>(), It.IsAny<CancellationToken>()), Times.Never());
        deposits.Verify(d => d.OpenAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<CancellationToken>()), Times.Never());
    }

    [Theory]
    [InlineData(PayOpenResult.AlreadyPaid, 409, "already_paid")]
    [InlineData(PayOpenResult.PreviousUnconfirmed, 409, "payment_unconfirmed")]
    [InlineData(PayOpenResult.GatewayError, 502, "gateway_error")]
    [InlineData(PayOpenResult.UnknownBooking, 404, "not_found")]
    public async Task Whish_refusals_carry_the_codes_the_site_already_knows(PayOpenResult result, int status, string code)
    {
        var (controller, deposits, _) = Controller("""{"method":"whish"}""");
        deposits.Setup(d => d.OpenAsync(Ref, PaymentMethods.Whish, It.IsAny<CancellationToken>())).ReturnsAsync(new PaymentOpening(result, Ref, Method: PaymentMethods.Whish));

        var answer = Assert.IsAssignableFrom<ObjectResult>(await controller.Pay(Ref));

        Assert.Equal((status, code), (answer.StatusCode, Prop(answer.Value!, "code")));
    }

    [Fact]
    public async Task The_callback_settles_on_a_good_token_and_answers_200_whatever_came_of_it()
    {
        var (controller, deposits, live) = Controller();
        deposits.Setup(d => d.SettleAsync(Ref, SettleTrigger.GatewayCallback, It.IsAny<CancellationToken>()))
            .ReturnsAsync(new Settlement(SettlementResult.Paid, Ref, true, "Confirmed", "Confirmed"));

        Assert.IsType<OkResult>(await controller.WhishCallback("mc-1a2b3c4d", Options.CallbackToken(Ref)));
        live.Verify(l => l.PublishAsync(Ref), Times.Once());
        Assert.Equal("no-store", controller.Response.Headers.CacheControl.ToString());

        // A settlement that throws is the job's to finish: Whish is still told the signal arrived.
        deposits.Setup(d => d.SettleAsync(Ref, SettleTrigger.GatewayCallback, It.IsAny<CancellationToken>())).ThrowsAsync(new TimeoutException());
        Assert.IsType<OkResult>(await controller.WhishCallback(Ref, Options.CallbackToken(Ref)));
    }

    [Theory]
    [InlineData("MC-1A2B3C4D", "wrong-token")]
    [InlineData("MC-1A2B3C4D", null)]
    [InlineData("not-a-reference", "x")]
    [InlineData(null, null)]
    public async Task The_callback_without_the_bookings_token_asks_whish_nothing(string? reference, string? token)
    {
        var (controller, deposits, _) = Controller();

        Assert.IsType<NotFoundResult>(await controller.WhishCallback(reference, token));

        deposits.Verify(d => d.SettleAsync(It.IsAny<string>(), It.IsAny<SettleTrigger>(), It.IsAny<CancellationToken>()), Times.Never());
    }

    [Theory]
    [InlineData(SettlementResult.Paid, "https://mokanco.com.lb/reservations/confirmed/?ref=MC-1A2B3C4D")]
    [InlineData(SettlementResult.Released, "https://mokanco.com.lb/reservations/?payment=failed")]
    [InlineData(SettlementResult.Failed, "https://mokanco.com.lb/reservations/?payment=failed")]
    [InlineData(SettlementResult.NotApplicable, "https://mokanco.com.lb/reservations/?payment=failed")]
    [InlineData(SettlementResult.UnknownBooking, "https://mokanco.com.lb/reservations/?payment=failed")]
    [InlineData(SettlementResult.Unconfirmed, "https://mokanco.com.lb/reservations/?payment=unconfirmed&ref=MC-1A2B3C4D")]
    [InlineData(SettlementResult.PaidNeedsStaff, "https://mokanco.com.lb/reservations/?payment=unconfirmed&ref=MC-1A2B3C4D")]
    public async Task The_return_from_whishs_page_goes_to_the_same_three_places_as_the_cards(SettlementResult result, string location)
    {
        var (controller, deposits, _) = Controller();
        deposits.Setup(d => d.SettleAsync(Ref, SettleTrigger.GatewayReturn, It.IsAny<CancellationToken>()))
            .ReturnsAsync(new Settlement(result, Ref, true, null, "test"));

        var redirect = Assert.IsType<RedirectResult>(await controller.WhishReturn(Ref));

        Assert.False(redirect.Permanent);
        Assert.Equal(location, redirect.Url);
    }

    [Fact]
    public async Task The_return_with_a_bad_reference_or_a_failed_settlement_never_says_paid()
    {
        var (controller, deposits, _) = Controller();
        Assert.Equal("https://mokanco.com.lb/reservations/?payment=failed", Assert.IsType<RedirectResult>(await controller.WhishReturn("junk")).Url);

        deposits.Setup(d => d.SettleAsync(Ref, SettleTrigger.GatewayReturn, It.IsAny<CancellationToken>())).ThrowsAsync(new TimeoutException());
        Assert.Equal("https://mokanco.com.lb/reservations/?payment=unconfirmed&ref=MC-1A2B3C4D", Assert.IsType<RedirectResult>(await controller.WhishReturn(Ref)).Url);
    }
}
