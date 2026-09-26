using System.Globalization;
using Microsoft.Extensions.Logging;
using MokaCo.HRMS.Model.Booking;
using MokaCo.HRMS.Repository.Booking;

namespace MokaCo.HRMS.Services.Booking.Payments;

/// <summary>Who is asking for a payment to be settled. The table is the same; what may be done about "not yet" differs.</summary>
public enum SettleTrigger
{
    /// <summary>GET /verify — the guest's browser came back from the gateway. Failed releases at once.</summary>
    GatewayReturn,

    /// <summary>The Quartz job. Waits until GiveUpAfterMinutes before releasing or alerting.</summary>
    Reconciliation,

    /// <summary>POST /{ref}/release — the guest walked away. Released only if the gateway says nothing was paid.</summary>
    GuestRelease,
}

public enum SettlementResult
{
    /// <summary>The deposit is on the books and the booking confirmed (or was already).</summary>
    Paid,

    /// <summary>Money was taken but the booking was closed or its slot taken meanwhile: recorded, staff alerted. The guest is not sent to the confirmed page.</summary>
    PaidNeedsStaff,

    /// <summary>The hold was given back (the gateway said failed, or nothing was ever attempted).</summary>
    Released,

    /// <summary>The gateway said failed but the booking was not releasable (e.g. staff confirmed it meanwhile).</summary>
    Failed,

    /// <summary>Cannot tell. The hold is kept.</summary>
    Unconfirmed,

    UnknownBooking,

    /// <summary>Nothing to do: not Pending any more (reconciliation), or nothing to release.</summary>
    NotApplicable,
}

/// <param name="Changed">The booking row changed: the hub should be told.</param>
/// <param name="Status">The booking's status after settling, when known.</param>
public sealed record Settlement(SettlementResult Result, string BookingRef, bool Changed, string? Status, string Reason);

public enum PayOpenResult
{
    Opened,

    /// <summary>An earlier session on this booking was paid; it has now been recorded. No new session.</summary>
    AlreadyPaid,

    /// <summary>An earlier session cannot be confirmed either way yet; opening another could charge twice.</summary>
    PreviousUnconfirmed,

    /// <summary>The gateway did not open a session.</summary>
    GatewayError,

    UnknownBooking,
}

public sealed record PaymentOpening(
    PayOpenResult Result,
    string BookingRef,
    string? SessionId = null,
    decimal Deposit = 0,
    string Currency = "",
    DateTime? HoldExpiresUtc = null,
    bool Changed = false);

/// <summary>
/// Online deposits end to end: opening a checkout session for a booking, and SETTLING it — one code
/// path shared by the gateway's return trip (/verify), the reconciliation job and the guest's release,
/// so that a payment is judged the same way whoever asks.
/// </summary>
public interface IOnlineDepositService
{
    /// <summary>The gateway configuration, for the redirect targets.</summary>
    MpgsOptions Gateway { get; }

    /// <summary>
    /// POST /{ref}/pay. The procedure's refusals (not found, not pending, hold expired, already paid,
    /// nothing due) propagate as SqlException 50000 for the controller's error filter.
    /// </summary>
    Task<PaymentOpening> OpenAsync(string bookingRef, CancellationToken cancellationToken = default);

    Task<Settlement> SettleAsync(string bookingRef, SettleTrigger trigger, CancellationToken cancellationToken = default);
}

public sealed class OnlineDepositService : IOnlineDepositService
{
    public const string AlertUnconfirmed = "PayUnconfirmed";

    private readonly IOnlineDepositRepository _deposits;
    private readonly IBookingRepository _bookings;
    private readonly IMpgsClient _gateway;
    private readonly OnlineDepositOptions _timing;
    private readonly TimeProvider _clock;
    private readonly ILogger<OnlineDepositService> _log;

    public OnlineDepositService(IOnlineDepositRepository deposits, IBookingRepository bookings, IMpgsClient gateway,
        MpgsOptions options, OnlineDepositOptions timing, ILogger<OnlineDepositService> log, TimeProvider? clock = null)
    {
        _deposits = deposits;
        _bookings = bookings;
        _gateway = gateway;
        Gateway = options;
        _timing = timing;
        _log = log;
        _clock = clock ?? TimeProvider.System;
    }

    public MpgsOptions Gateway { get; }

    /* ---- opening --------------------------------------------------------------------------- */

    public async Task<PaymentOpening> OpenAsync(string bookingRef, CancellationToken cancellationToken = default)
    {
        // A SECOND /pay FOR THE SAME BOOKING reuses the order id, so the earlier session is asked about
        // FIRST, before anything is stamped: if it was paid, paying again would charge twice; if the
        // gateway cannot say yet, nothing new is opened and the hold is kept. Asking before stamping
        // also means a guest pressing the button again does not reset PaymentOpenedUtc, the clock the
        // reconciliation job and its staff alert run on.
        var state = await _deposits.GetPaymentStateAsync(bookingRef);
        if (state is { PaymentOpenedUtc: not null, Status: "Pending", GatewayPaid: false })
        {
            var earlier = await _gateway.RetrieveOrderAsync(bookingRef, cancellationToken);
            var decision = PaymentDecisionTable.Decide(earlier, state.DepositDue, state.CurrencyCode);

            if (decision.Outcome == PaymentOutcome.Paid)
            {
                var recorded = await RecordPaidAsync(bookingRef, earlier, state.CurrencyCode);
                return new PaymentOpening(PayOpenResult.AlreadyPaid, bookingRef, Changed: recorded.Changed);
            }

            if (decision.Outcome != PaymentOutcome.Failed && earlier.Kind != MpgsLookupKind.NotFound)
            {
                await _deposits.PaymentCheckedAsync(bookingRef, keepHold: true);
                _log.LogWarning("Deposit {Ref}: not reopened, the earlier session is unconfirmed ({Reason}).", bookingRef, decision.Reason);
                return new PaymentOpening(PayOpenResult.PreviousUnconfirmed, bookingRef);
            }
        }

        // Validates (not found, not pending, hold expired, already paid, nothing due — refusals travel
        // as SqlException 50000) and stamps the hold and PaymentOpenedUtc in one transaction.
        var started = await _deposits.StartPaymentAsync(bookingRef);
        if (started is null)
            return new PaymentOpening(PayOpenResult.UnknownBooking, bookingRef);

        string sessionId;
        try
        {
            sessionId = await _gateway.InitiateCheckoutAsync(
                bookingRef, started.DepositDue, started.CurrencyCode, Description(started),
                Gateway.VerifyUrl(bookingRef), Gateway.CancelledUrl(), Gateway.UnconfirmedUrl(bookingRef),
                cancellationToken);
        }
        catch (MpgsException)
        {
            // The hold and PaymentOpenedUtc stay stamped: the job asks the gateway later (it will find
            // no order) and releases it once GiveUpAfterMinutes have passed.
            return new PaymentOpening(PayOpenResult.GatewayError, bookingRef);
        }

        try
        {
            await _deposits.SetPaymentSessionAsync(bookingRef, sessionId);
        }
        catch (Exception ex)
        {
            _log.LogWarning(ex, "Deposit {Ref}: the session id could not be stored (audit only).", bookingRef);
        }

        return new PaymentOpening(PayOpenResult.Opened, bookingRef, sessionId, started.DepositDue, started.CurrencyCode, started.HoldExpiresUtc);
    }

    /// <summary>"Room deposit: Studio, 2026-10-01, 2h (total USD 40.00)" — what the guest sees on the gateway's page.</summary>
    public static string Description(PaymentStarted booking)
        => string.Create(CultureInfo.InvariantCulture,
            $"Room deposit: {booking.RoomName}, {booking.BookDate:yyyy-MM-dd}, {booking.Hours:0.##}h (total {booking.CurrencyCode} {booking.TotalAmount:0.00})");

    /* ---- settling -------------------------------------------------------------------------- */

    public async Task<Settlement> SettleAsync(string bookingRef, SettleTrigger trigger, CancellationToken cancellationToken = default)
    {
        var state = await _deposits.GetPaymentStateAsync(bookingRef);
        if (state is null)
            return new Settlement(SettlementResult.UnknownBooking, bookingRef, false, null, "no such booking");

        // Already on the books: a refresh of the return page, a double return, the job after /verify.
        // Nothing is asked and nothing is written.
        if (state.GatewayPaid)
            return new Settlement(state.Status is "Confirmed" or "Completed" ? SettlementResult.Paid : SettlementResult.PaidNeedsStaff,
                bookingRef, false, state.Status, "already recorded");

        if (trigger == SettleTrigger.Reconciliation && state.Status != "Pending")
            return new Settlement(SettlementResult.NotApplicable, bookingRef, false, state.Status, "no longer pending");

        if (state.PaymentOpenedUtc is null)
        {
            // A guest walking away from a booking that never reached the gateway: the old release, unchanged.
            if (trigger == SettleTrigger.GuestRelease)
                return await ReleaseAsync(state, "no payment was opened", ifNotReleased: SettlementResult.NotApplicable);

            // No session was ever opened for it, so nothing can have been charged and there is nothing to
            // ask. Above all NOTHING IS WRITTEN: "keeping the hold" here would put an expiry on a booking
            // that has none — a step-1 request — and hand it to the expiry sweep. The reference is the
            // only credential /verify needs, so this is what an anonymous caller could otherwise do.
            return new Settlement(SettlementResult.NotApplicable, bookingRef, false, state.Status, "no payment was opened");
        }

        var order = await _gateway.RetrieveOrderAsync(bookingRef, cancellationToken);
        var decision = PaymentDecisionTable.Decide(order, state.DepositDue, state.CurrencyCode);
        var age = state.PaymentOpenedUtc is { } opened ? _clock.GetUtcNow().UtcDateTime - opened : TimeSpan.MaxValue;
        var patienceOver = age >= TimeSpan.FromMinutes(_timing.GiveUpAfterMinutes);

        _log.LogInformation("Deposit {Ref} ({Trigger}): {Outcome}, {Reason}.", bookingRef, trigger, decision.Outcome, decision.Reason);

        switch (decision.Outcome)
        {
            case PaymentOutcome.Paid:
                return (await RecordPaidAsync(bookingRef, order, state.CurrencyCode)).Settlement;

            case PaymentOutcome.Failed when trigger != SettleTrigger.Reconciliation || patienceOver:
                return await ReleaseAsync(state, decision.Reason, ifNotReleased: SettlementResult.Failed, markChecked: true);

            case PaymentOutcome.Unconfirmed when order.Kind == MpgsLookupKind.NotFound
                                                && (trigger == SettleTrigger.GuestRelease || (trigger == SettleTrigger.Reconciliation && patienceOver)):
                // Nothing was ever attempted on the order: nothing can have been charged.
                return await ReleaseAsync(state, "abandoned: " + decision.Reason, ifNotReleased: SettlementResult.Failed, markChecked: true);
        }

        // Unconfirmed (or failed, with the guest possibly still retrying on the gateway's page):
        // the slot stays held and the booking stays Pending.
        await _deposits.PaymentCheckedAsync(bookingRef, keepHold: true);

        if (trigger == SettleTrigger.Reconciliation && patienceOver && decision.Outcome == PaymentOutcome.Unconfirmed)
        {
            var queued = await _deposits.QueuePaymentAlertAsync(state.BookingId, AlertUnconfirmed,
                $"Gateway check after {(int)age.TotalMinutes} minutes: {decision.Reason}.");
            if (queued)
                _log.LogWarning("Deposit {Ref}: still unconfirmed after {Minutes} minutes ({Reason}); staff alerted.",
                    bookingRef, (int)age.TotalMinutes, decision.Reason);
        }

        return new Settlement(SettlementResult.Unconfirmed, bookingRef, false, state.Status, decision.Reason);
    }

    private async Task<(Settlement Settlement, bool Changed)> RecordPaidAsync(string bookingRef, MpgsOrderLookup order, string currency)
    {
        var recorded = await _deposits.ConfirmOnlinePaymentAsync(bookingRef, order.Amount!.Value, currency, bookingRef, order.TransactionId)
                       ?? throw new InvalidOperationException($"Recording the deposit of {bookingRef} returned nothing.");

        var changed = recorded.Outcome != OnlinePaymentRecorded.Replay;
        var result = recorded.Outcome is OnlinePaymentRecorded.PaidButClosed or OnlinePaymentRecorded.SlotClash
            ? SettlementResult.PaidNeedsStaff
            : SettlementResult.Paid;

        if (result == SettlementResult.PaidNeedsStaff)
            _log.LogWarning("Deposit {Ref}: paid but {Outcome}; recorded, staff alerted.", bookingRef, recorded.Outcome);

        return (new Settlement(result, bookingRef, changed, recorded.Status, recorded.Outcome), changed);
    }

    /// <summary>Through the existing release path (usp_Booking_ReleaseHold): a Pending website hold with no money against it, nothing else.</summary>
    private async Task<Settlement> ReleaseAsync(PaymentState state, string reason, SettlementResult ifNotReleased, bool markChecked = false)
    {
        if (markChecked)
            await _deposits.PaymentCheckedAsync(state.BookingRef, keepHold: false);

        var released = await _bookings.ReleaseHoldAsync(state.BookingRef);
        var nowCancelled = released?.Status == "Cancelled" && state.Status == "Pending";

        if (nowCancelled)
            return new Settlement(SettlementResult.Released, state.BookingRef, true, released!.Status, reason);

        return new Settlement(ifNotReleased, state.BookingRef, false, released?.Status ?? state.Status, reason);
    }
}
