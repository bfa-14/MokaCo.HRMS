using Microsoft.Extensions.Logging.Abstractions;
using Moq;
using MokaCo.HRMS.Model.Booking;
using MokaCo.HRMS.Repository.Booking;
using MokaCo.HRMS.Services.Booking.Payments;

namespace MokaCo.HRMS.Tests.Booking;

/// <summary>
/// Opening a checkout session and SETTLING a payment, with the repositories and the gateway mocked:
/// the deposit comes from the booking, a second /pay asks about the first session before opening
/// another, and the three callers of the settlement (the gateway's return, the job, the guest's
/// release) each do what the table and their own patience allow.
/// </summary>
public class OnlineDepositServiceTests
{
    private const string Ref = "MC-1A2B3C4D";
    private static readonly DateTime Now = new(2026, 9, 26, 12, 0, 0, DateTimeKind.Utc);

    private sealed class FixedClock(DateTime utc) : TimeProvider
    {
        public override DateTimeOffset GetUtcNow() => new(utc);
    }

    private static readonly MpgsOptions Gateway = new()
    {
        BaseUrl = "https://test-bobsal.gateway.mastercard.com",
        MerchantId = "TESTMOKANDCO",
        ApiPassword = "pw-not-real",
        ApiVersion = 73,
        SiteUrl = "https://mokanco.com.lb",
        ApiPublicUrl = "https://api.mokanco.com.lb",
    };

    private sealed class Rig
    {
        public Mock<IOnlineDepositRepository> Deposits { get; } = new();
        public Mock<IBookingRepository> Bookings { get; } = new();
        public Mock<IMpgsClient> Client { get; } = new(MockBehavior.Strict);

        public OnlineDepositService Service => new(Deposits.Object, Bookings.Object, Client.Object, Gateway,
            new OnlineDepositOptions { ReconcileAfterMinutes = 10, GiveUpAfterMinutes = 30 },
            NullLogger<OnlineDepositService>.Instance, new FixedClock(Now));

        public void State(string status = "Pending", int openedMinutesAgo = 5, bool gatewayPaid = false, bool opened = true)
            => Deposits.Setup(d => d.GetPaymentStateAsync(Ref)).ReturnsAsync(new PaymentState
            {
                BookingId = 42, BookingRef = Ref, Status = status, Source = "Website", DepositDue = 12.50m, CurrencyCode = "USD",
                PaymentOpenedUtc = opened ? Now.AddMinutes(-openedMinutesAgo) : null, GatewayPaid = gatewayPaid,
            });

        public void Order(MpgsOrderLookup order)
            => Client.Setup(c => c.RetrieveOrderAsync(Ref, It.IsAny<CancellationToken>())).ReturnsAsync(order);

        public void Confirms(string outcome, string status = "Confirmed")
            => Deposits.Setup(d => d.ConfirmOnlinePaymentAsync(Ref, 12.50m, "USD", Ref, "7"))
                .ReturnsAsync(new OnlinePaymentRecorded { Outcome = outcome, BookingRef = Ref, Status = status, PaidAmount = 12.50m });

        public void Releases(string status = "Cancelled")
            => Bookings.Setup(b => b.ReleaseHoldAsync(Ref)).ReturnsAsync(new BookingHoldReleased { BookingRef = Ref, Status = status });
    }

    private static MpgsOrderLookup Captured => new(MpgsLookupKind.Found, "SUCCESS", "CAPTURED", 12.50m, "USD", 12.50m, "7");
    private static MpgsOrderLookup Authorized => new(MpgsLookupKind.Found, "SUCCESS", "AUTHORIZED", 12.50m, "USD", 0m, "7");
    private static MpgsOrderLookup Declined => new(MpgsLookupKind.Found, "FAILURE", "FAILED", 12.50m, "USD", 0m, "7");

    private static PaymentStarted Started() => new()
    {
        BookingId = 42, BookingRef = Ref, DepositDue = 12.50m, CurrencyCode = "USD", TotalAmount = 62.50m,
        BookDate = new DateTime(2026, 10, 1), StartMin = 600, EndMin = 750, Hours = 2.5m, RoomName = "Studio",
        HoldExpiresUtc = Now.AddMinutes(15), PaymentOpenedUtc = Now,
    };

    /* ---- /pay -------------------------------------------------------------------------------- */

    [Fact]
    public async Task Pay_charges_the_bookings_own_deposit_and_returns_the_session()
    {
        var rig = new Rig();
        rig.Deposits.Setup(d => d.StartPaymentAsync(Ref)).ReturnsAsync(Started());
        rig.Client.Setup(c => c.InitiateCheckoutAsync(Ref, 12.50m, "USD", "Room deposit: Studio, 2026-10-01, 2.5h (total USD 62.50)",
                "https://api.mokanco.com.lb/api/public/booking/verify?ref=MC-1A2B3C4D",
                "https://mokanco.com.lb/reservations/?payment=cancelled",
                "https://mokanco.com.lb/reservations/?payment=unconfirmed&ref=MC-1A2B3C4D",
                It.IsAny<CancellationToken>()))
            .ReturnsAsync("SESSION0001");

        var opening = await rig.Service.OpenAsync(Ref);

        Assert.Equal(PayOpenResult.Opened, opening.Result);
        Assert.Equal("SESSION0001", opening.SessionId);
        Assert.Equal(12.50m, opening.Deposit);
        rig.Deposits.Verify(d => d.SetPaymentSessionAsync(Ref, "SESSION0001"), Times.Once());
        rig.Client.Verify(c => c.RetrieveOrderAsync(It.IsAny<string>(), It.IsAny<CancellationToken>()), Times.Never());
    }

    [Fact]
    public async Task Pay_again_after_an_unused_session_opens_a_new_session_on_the_same_order()
    {
        var rig = new Rig();
        rig.State(openedMinutesAgo: 3);
        rig.Deposits.Setup(d => d.StartPaymentAsync(Ref)).ReturnsAsync(Started());
        rig.Order(MpgsOrderLookup.NotFound());
        rig.Client.Setup(c => c.InitiateCheckoutAsync(Ref, 12.50m, "USD", It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync("SESSION0002");

        var opening = await rig.Service.OpenAsync(Ref);

        Assert.Equal(PayOpenResult.Opened, opening.Result);
        Assert.Equal("SESSION0002", opening.SessionId);
    }

    [Fact]
    public async Task Pay_again_after_a_declined_session_opens_a_new_one()
    {
        var rig = new Rig();
        rig.State(openedMinutesAgo: 3);
        rig.Deposits.Setup(d => d.StartPaymentAsync(Ref)).ReturnsAsync(Started());
        rig.Order(Declined);
        rig.Client.Setup(c => c.InitiateCheckoutAsync(Ref, 12.50m, "USD", It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync("SESSION0003");

        Assert.Equal(PayOpenResult.Opened, (await rig.Service.OpenAsync(Ref)).Result);
    }

    [Fact]
    public async Task Pay_again_after_a_paid_session_records_it_and_opens_nothing()
    {
        var rig = new Rig();
        rig.State(openedMinutesAgo: 3);
        rig.Order(Captured);
        rig.Confirms(OnlinePaymentRecorded.Confirmed);

        var opening = await rig.Service.OpenAsync(Ref);

        Assert.Equal(PayOpenResult.AlreadyPaid, opening.Result);
        Assert.True(opening.Changed);
        rig.Deposits.Verify(d => d.ConfirmOnlinePaymentAsync(Ref, 12.50m, "USD", Ref, "7"), Times.Once());
        rig.Deposits.Verify(d => d.StartPaymentAsync(It.IsAny<string>()), Times.Never());
    }

    [Fact]
    public async Task Pay_again_while_the_earlier_session_is_unconfirmed_is_refused_without_restamping()
    {
        var rig = new Rig();
        rig.State(openedMinutesAgo: 3);
        rig.Order(Authorized);

        Assert.Equal(PayOpenResult.PreviousUnconfirmed, (await rig.Service.OpenAsync(Ref)).Result);

        // the hold is kept, and PaymentOpenedUtc (the job's clock) is NOT reset by the second press
        rig.Deposits.Verify(d => d.PaymentCheckedAsync(Ref, true), Times.Once());
        rig.Deposits.Verify(d => d.StartPaymentAsync(It.IsAny<string>()), Times.Never());
    }

    [Fact]
    public async Task Pay_on_a_booking_that_is_not_pending_goes_straight_to_the_procedure()
    {
        var rig = new Rig();
        rig.State(status: "Cancelled", openedMinutesAgo: 3);
        rig.Deposits.Setup(d => d.StartPaymentAsync(Ref)).ThrowsAsync(new InvalidOperationException("the procedure's refusal"));

        await Assert.ThrowsAsync<InvalidOperationException>(() => rig.Service.OpenAsync(Ref));
        rig.Client.Verify(c => c.RetrieveOrderAsync(It.IsAny<string>(), It.IsAny<CancellationToken>()), Times.Never());
    }

    [Fact]
    public async Task Pay_when_the_gateway_will_not_open_a_session_is_a_gateway_error()
    {
        var rig = new Rig();
        rig.Deposits.Setup(d => d.StartPaymentAsync(Ref)).ReturnsAsync(Started());
        rig.Client.Setup(c => c.InitiateCheckoutAsync(Ref, 12.50m, "USD", It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string>(), It.IsAny<CancellationToken>()))
            .ThrowsAsync(new MpgsException("no"));

        Assert.Equal(PayOpenResult.GatewayError, (await rig.Service.OpenAsync(Ref)).Result);
    }

    /* ---- /verify (the gateway's return) ------------------------------------------------------ */

    [Fact]
    public async Task Return_paid_records_the_payment_and_confirms()
    {
        var rig = new Rig();
        rig.State();
        rig.Order(Captured);
        rig.Confirms(OnlinePaymentRecorded.Confirmed);

        var settled = await rig.Service.SettleAsync(Ref, SettleTrigger.GatewayReturn);

        Assert.Equal((SettlementResult.Paid, true, "Confirmed"), (settled.Result, settled.Changed, settled.Status));
    }

    [Fact]
    public async Task Return_replay_neither_asks_the_gateway_nor_writes()
    {
        var rig = new Rig();
        rig.State(status: "Confirmed", gatewayPaid: true);

        var settled = await rig.Service.SettleAsync(Ref, SettleTrigger.GatewayReturn);

        Assert.Equal((SettlementResult.Paid, false), (settled.Result, settled.Changed));
        rig.Client.Verify(c => c.RetrieveOrderAsync(It.IsAny<string>(), It.IsAny<CancellationToken>()), Times.Never());
        rig.Deposits.Verify(d => d.ConfirmOnlinePaymentAsync(It.IsAny<string>(), It.IsAny<decimal>(), It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string?>()), Times.Never());
    }

    [Fact]
    public async Task Return_race_the_procedure_says_replay_and_nothing_changed()
    {
        var rig = new Rig();
        rig.State();                                   // read before the job's confirmation committed
        rig.Order(Captured);
        rig.Confirms(OnlinePaymentRecorded.Replay);

        var settled = await rig.Service.SettleAsync(Ref, SettleTrigger.GatewayReturn);

        Assert.Equal((SettlementResult.Paid, false), (settled.Result, settled.Changed));
    }

    [Fact]
    public async Task Return_failed_releases_the_hold_at_once()
    {
        var rig = new Rig();
        rig.State(openedMinutesAgo: 2);
        rig.Order(Declined);
        rig.Releases();

        var settled = await rig.Service.SettleAsync(Ref, SettleTrigger.GatewayReturn);

        Assert.Equal((SettlementResult.Released, true), (settled.Result, settled.Changed));
        rig.Bookings.Verify(b => b.ReleaseHoldAsync(Ref), Times.Once());
    }

    [Theory]
    [MemberData(nameof(NotSettled))]
    public async Task Return_unconfirmed_keeps_the_hold(MpgsOrderLookup order)
    {
        var rig = new Rig();
        rig.State();
        rig.Order(order);

        var settled = await rig.Service.SettleAsync(Ref, SettleTrigger.GatewayReturn);

        Assert.Equal(SettlementResult.Unconfirmed, settled.Result);
        rig.Deposits.Verify(d => d.PaymentCheckedAsync(Ref, true), Times.Once());
        rig.Bookings.Verify(b => b.ReleaseHoldAsync(It.IsAny<string>()), Times.Never());
    }

    public static TheoryData<MpgsOrderLookup> NotSettled => new()
    {
        new MpgsOrderLookup(MpgsLookupKind.Found, "SUCCESS", "AUTHORIZED", 12.50m, "USD", 0m, "7"),
        new MpgsOrderLookup(MpgsLookupKind.Found, "SUCCESS", "CAPTURED", 10m, "USD", 10m, "7"),       // amount mismatch
        MpgsOrderLookup.Error("HTTP 503"),
        MpgsOrderLookup.NotFound(),
    };

    [Fact]
    public async Task Return_paid_on_a_closed_booking_needs_staff()
    {
        var rig = new Rig();
        rig.State(status: "Cancelled");
        rig.Order(Captured);
        rig.Confirms(OnlinePaymentRecorded.PaidButClosed, status: "Cancelled");

        var settled = await rig.Service.SettleAsync(Ref, SettleTrigger.GatewayReturn);

        Assert.Equal((SettlementResult.PaidNeedsStaff, true), (settled.Result, settled.Changed));
    }

    [Fact]
    public async Task Return_for_a_booking_no_payment_was_opened_for_asks_nobody_and_writes_nothing()
    {
        var rig = new Rig();
        rig.State(opened: false);      // a step-1 request: no hold, no session — someone knows its reference

        var settled = await rig.Service.SettleAsync(Ref, SettleTrigger.GatewayReturn);

        Assert.Equal((SettlementResult.NotApplicable, false), (settled.Result, settled.Changed));
        rig.Client.Verify(c => c.RetrieveOrderAsync(It.IsAny<string>(), It.IsAny<CancellationToken>()), Times.Never());
        rig.Deposits.Verify(d => d.PaymentCheckedAsync(It.IsAny<string>(), It.IsAny<bool>()), Times.Never());
        rig.Bookings.Verify(b => b.ReleaseHoldAsync(It.IsAny<string>()), Times.Never());
    }

    [Fact]
    public async Task Return_for_an_unknown_reference_asks_nobody()
    {
        var rig = new Rig();

        var settled = await rig.Service.SettleAsync(Ref, SettleTrigger.GatewayReturn);

        Assert.Equal(SettlementResult.UnknownBooking, settled.Result);
    }

    /* ---- the reconciliation job ------------------------------------------------------------- */

    [Fact]
    public async Task Job_confirms_a_paid_order_whose_return_never_came()
    {
        var rig = new Rig();
        rig.State(openedMinutesAgo: 12);
        rig.Order(Captured);
        rig.Confirms(OnlinePaymentRecorded.Confirmed);

        Assert.Equal(SettlementResult.Paid, (await rig.Service.SettleAsync(Ref, SettleTrigger.Reconciliation)).Result);
    }

    [Fact]
    public async Task Job_waits_on_a_young_failure_the_guest_may_still_be_retrying()
    {
        var rig = new Rig();
        rig.State(openedMinutesAgo: 12);
        rig.Order(Declined);

        var settled = await rig.Service.SettleAsync(Ref, SettleTrigger.Reconciliation);

        Assert.Equal(SettlementResult.Unconfirmed, settled.Result);
        rig.Bookings.Verify(b => b.ReleaseHoldAsync(It.IsAny<string>()), Times.Never());
        rig.Deposits.Verify(d => d.PaymentCheckedAsync(Ref, true), Times.Once());
    }

    [Fact]
    public async Task Job_releases_an_old_failure()
    {
        var rig = new Rig();
        rig.State(openedMinutesAgo: 31);
        rig.Order(Declined);
        rig.Releases();

        Assert.Equal(SettlementResult.Released, (await rig.Service.SettleAsync(Ref, SettleTrigger.Reconciliation)).Result);
    }

    [Fact]
    public async Task Job_releases_an_old_session_the_gateway_never_saw()
    {
        var rig = new Rig();
        rig.State(openedMinutesAgo: 45);
        rig.Order(MpgsOrderLookup.NotFound());
        rig.Releases();

        Assert.Equal(SettlementResult.Released, (await rig.Service.SettleAsync(Ref, SettleTrigger.Reconciliation)).Result);
    }

    [Fact]
    public async Task Job_keeps_a_young_session_the_gateway_has_not_seen_yet()
    {
        var rig = new Rig();
        rig.State(openedMinutesAgo: 12);
        rig.Order(MpgsOrderLookup.NotFound());

        Assert.Equal(SettlementResult.Unconfirmed, (await rig.Service.SettleAsync(Ref, SettleTrigger.Reconciliation)).Result);
        rig.Bookings.Verify(b => b.ReleaseHoldAsync(It.IsAny<string>()), Times.Never());
    }

    [Theory]
    [InlineData(12, false)]
    [InlineData(31, true)]
    public async Task Job_alerts_staff_only_once_the_wait_is_over(int openedMinutesAgo, bool alerts)
    {
        var rig = new Rig();
        rig.State(openedMinutesAgo: openedMinutesAgo);
        rig.Order(MpgsOrderLookup.Error("timeout"));
        rig.Deposits.Setup(d => d.QueuePaymentAlertAsync(42, "PayUnconfirmed", It.IsAny<string?>())).ReturnsAsync(true);

        var settled = await rig.Service.SettleAsync(Ref, SettleTrigger.Reconciliation);

        Assert.Equal(SettlementResult.Unconfirmed, settled.Result);
        rig.Deposits.Verify(d => d.QueuePaymentAlertAsync(42, "PayUnconfirmed", It.IsAny<string?>()), alerts ? Times.Once() : Times.Never());
        rig.Deposits.Verify(d => d.PaymentCheckedAsync(Ref, true), Times.Once());   // the hold is kept either way
    }

    [Fact]
    public async Task Job_skips_a_booking_staff_already_decided()
    {
        var rig = new Rig();
        rig.State(status: "Cancelled", openedMinutesAgo: 40);

        Assert.Equal(SettlementResult.NotApplicable, (await rig.Service.SettleAsync(Ref, SettleTrigger.Reconciliation)).Result);
    }

    /* ---- /release ---------------------------------------------------------------------------- */

    [Fact]
    public async Task Release_without_a_payment_is_the_old_release()
    {
        var rig = new Rig();
        rig.State(opened: false);
        rig.Releases(status: "Pending");     // step-1 booking with no hold: the procedure leaves it alone

        var settled = await rig.Service.SettleAsync(Ref, SettleTrigger.GuestRelease);

        Assert.Equal((SettlementResult.NotApplicable, "Pending"), (settled.Result, settled.Status));
        rig.Client.Verify(c => c.RetrieveOrderAsync(It.IsAny<string>(), It.IsAny<CancellationToken>()), Times.Never());
    }

    [Fact]
    public async Task Release_asks_the_gateway_and_does_not_release_what_may_be_paid()
    {
        var rig = new Rig();
        rig.State(openedMinutesAgo: 3);
        rig.Order(Authorized);

        var settled = await rig.Service.SettleAsync(Ref, SettleTrigger.GuestRelease);

        Assert.Equal((SettlementResult.Unconfirmed, "Pending"), (settled.Result, settled.Status));
        rig.Bookings.Verify(b => b.ReleaseHoldAsync(It.IsAny<string>()), Times.Never());
    }

    [Fact]
    public async Task Release_of_a_session_the_gateway_never_saw_releases()
    {
        var rig = new Rig();
        rig.State(openedMinutesAgo: 3);
        rig.Order(MpgsOrderLookup.NotFound());
        rig.Releases();

        var settled = await rig.Service.SettleAsync(Ref, SettleTrigger.GuestRelease);

        Assert.Equal((SettlementResult.Released, "Cancelled"), (settled.Result, settled.Status));
    }
}
