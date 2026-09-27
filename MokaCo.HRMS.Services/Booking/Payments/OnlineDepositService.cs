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

    /// <summary>
    /// The Quartz job. An abandoned payment (nothing attempted on the order) is released once the hold
    /// has run out; a failed one after GiveUpAfterMinutes; one it cannot tell about keeps its hold and
    /// is reported to staff once, after GiveUpAfterMinutes.
    /// </summary>
    Reconciliation,

    /// <summary>POST /{ref}/release — the guest walked away. Released only if the gateway says nothing was paid.</summary>
    GuestRelease,

    /// <summary>
    /// POST /{ref}/pay again for a booking whose payment was already opened: the earlier session on the
    /// same order is settled before a new one may be opened. Paid is recorded exactly as /verify records
    /// it; failed or nothing attempted is <see cref="SettlementResult.NotPaid"/> and NOTHING is written
    /// (a new checkout follows at once, so the hold is not released).
    /// </summary>
    PayAgain,
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

    /// <summary>
    /// <see cref="SettleTrigger.PayAgain"/> only: the gateway says no money was taken on the order (it
    /// failed, or nothing was attempted). Nothing was written; a new checkout may be opened on it.
    /// </summary>
    NotPaid,
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
/// path (<see cref="SettleAsync"/>) shared by the gateway's return trip (/verify), a second /pay, the
/// reconciliation job and the guest's release, so that a payment is judged, and a paid one recorded,
/// the same way whoever asks. The SQL expiry sweep never settles: it leaves every booking whose payment
/// was opened to the reconciliation job.
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
        // A SECOND /pay FOR THE SAME BOOKING reuses the order id, so the earlier session is SETTLED
        // FIRST, before anything is stamped — through SettleAsync, the path /verify takes, so a paid
        // session has exactly the same effects whoever finds it (Confirmed, the payment line, the
        // messages; the caller tells the hub). Paid: paying again would charge twice. Cannot tell yet:
        // nothing new is opened and the hold is kept. Settling before stamping also means a second press
        // does not reset PaymentOpenedUtc, the clock the reconciliation job and its staff alert run on.
        var earlier = await SettleAsync(bookingRef, SettleTrigger.PayAgain, cancellationToken);
        switch (earlier.Result)
        {
            case SettlementResult.Paid or SettlementResult.PaidNeedsStaff:
                return new PaymentOpening(PayOpenResult.AlreadyPaid, bookingRef, Changed: earlier.Changed);

            case SettlementResult.Unconfirmed:
                _log.LogWarning("Deposit {Ref}: not reopened, the earlier session is unconfirmed ({Reason}).", bookingRef, earlier.Reason);
                return new PaymentOpening(PayOpenResult.PreviousUnconfirmed, bookingRef);

            case SettlementResult.UnknownBooking:
                return new PaymentOpening(PayOpenResult.UnknownBooking, bookingRef);

            // NotPaid (failed, or nothing attempted on the order) and NotApplicable (no payment opened
            // yet, or not Pending — the procedure below refuses that with its own code): go on.
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

        if (trigger is SettleTrigger.Reconciliation or SettleTrigger.PayAgain && state.Status != "Pending")
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
        var now = _clock.GetUtcNow().UtcDateTime;
        var age = state.PaymentOpenedUtc is { } opened ? now - opened : TimeSpan.MaxValue;
        var patienceOver = age >= TimeSpan.FromMinutes(_timing.GiveUpAfterMinutes);
        var holdOver = state.HoldExpiresUtc is not { } holdUntil || holdUntil <= now;

        _log.LogInformation("Deposit {Ref} ({Trigger}): {Outcome}, {Reason}.", bookingRef, trigger, decision.Outcome, decision.Reason);

        switch (decision.Outcome)
        {
            case PaymentOutcome.Paid:
                return (await RecordPaidAsync(bookingRef, order, state.CurrencyCode)).Settlement;

            // No money was taken on the order and a new checkout is about to be opened on it: nothing is
            // written, and above all the hold is not released under the guest who is paying again.
            case PaymentOutcome.Failed when trigger == SettleTrigger.PayAgain:
            case PaymentOutcome.Unconfirmed when decision.NothingAttempted && trigger == SettleTrigger.PayAgain:
                return new Settlement(SettlementResult.NotPaid, bookingRef, false, state.Status, decision.Reason);

            case PaymentOutcome.Failed when trigger != SettleTrigger.Reconciliation || patienceOver:
                return await ReleaseAsync(state, decision.Reason, ifNotReleased: SettlementResult.Failed, markChecked: true);

            // ABANDONED: the gateway answered and nothing was ever attempted on the order, so nothing can
            // have been charged. The guest walking away releases it at once; the job releases it once the
            // hold has run out (the guest had the whole hold to pay).
            case PaymentOutcome.Unconfirmed when decision.NothingAttempted
                                                && (trigger == SettleTrigger.GuestRelease || (trigger == SettleTrigger.Reconciliation && holdOver)):
                return await ReleaseAsync(state, "abandoned: " + decision.Reason, ifNotReleased: SettlementResult.Failed, markChecked: true);

            // Abandoned, but the hold is still running: the guest may still be on the gateway's page. The
            // hold is left as it is — NOT extended, since there is no payment in flight to protect — and
            // the next run looks again.
            case PaymentOutcome.Unconfirmed when decision.NothingAttempted:
                await _deposits.PaymentCheckedAsync(bookingRef, keepHold: false);
                return new Settlement(SettlementResult.Unconfirmed, bookingRef, false, state.Status, decision.Reason);
        }

        // Cannot tell — a transaction the gateway has not settled, or no answer at all (a network error
        // or a timeout is NEVER abandonment) — or failed, with the guest possibly still retrying on the
        // gateway's page: the slot stays held, the booking stays Pending, the next run asks again.
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
