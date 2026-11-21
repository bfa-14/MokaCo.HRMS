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
    /// Whish's server called our callback address (GET /whish/callback): an attempt was processed. Only a SIGNAL -
    /// the answer is still Whish's status call - and judged exactly like the guest's return trip.
    /// </summary>
    GatewayCallback,

    /// <summary>
    /// The Quartz job. An abandoned payment (nothing attempted on the order) is released once the hold
    /// has run out; a failed one after GiveUpAfterMinutes; one it cannot tell about keeps its hold and
    /// is reported to staff once, after GiveUpAfterMinutes. A booking staff already decided (confirmed,
    /// cancelled, no-show) is asked about too, for 72 hours (QA3 BKG-4): a captured deposit is
    /// recorded, nothing else is ever done to it.
    /// </summary>
    Reconciliation,

    /// <summary>
    /// POST /{ref}/release — the guest walked away. Released only if a payment was opened on the
    /// booking and the gateway says nothing was paid (a request taken without a deposit is never
    /// released this way — QA3 BKG-1).
    /// </summary>
    GuestRelease,

    /// <summary>
    /// POST /{ref}/pay again for a booking whose payment was already opened: the earlier session on the
    /// same order is settled before a new one may be opened. Paid is recorded exactly as /verify records
    /// it; failed or nothing attempted is <see cref="SettlementResult.NotPaid"/> and NOTHING is written
    /// (a new checkout follows at once, so the hold is not released).
    /// </summary>
    PayAgain,

    /// <summary>
    /// A member of staff pressed "Ask the gateway now" on the Payments page (script 119). Judged EXACTLY like
    /// <see cref="Reconciliation"/> - a paid payment is recorded, an abandoned one released once its hold has run
    /// out, one that cannot be told about keeps its hold - only without the staff e-mail, and logged under their name.
    /// </summary>
    StaffCheck,
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

/// <param name="Method">"card" or "whish": which gateway the payment was opened on.</param>
/// <param name="SessionId">Card: the checkout session the site hands to the gateway's page.</param>
/// <param name="CollectUrl">Whish: its hosted payment link, where the site sends the guest.</param>
public sealed record PaymentOpening(
    PayOpenResult Result,
    string BookingRef,
    string? SessionId = null,
    decimal Deposit = 0,
    string Currency = "",
    DateTime? HoldExpiresUtc = null,
    bool Changed = false,
    string Method = PaymentMethods.Card,
    string? CollectUrl = null);

/// <summary>The ways a deposit is paid online. A booking's current one is read off its gateway order id.</summary>
public static class PaymentMethods
{
    public const string Card = "card";
    public const string Whish = "whish";

    /// <summary>The name on the payment line (booking.PAYMENT_METHOD).</summary>
    public const string WhishLineName = "Whish";

    /// <summary>"card" for nothing or "card"; "whish"; null for anything else.</summary>
    public static string? Parse(string? method) => (method ?? string.Empty).Trim().ToLowerInvariant() switch
    {
        "" or Card => Card,
        Whish => Whish,
        _ => null,
    };
}

/// <summary>
/// Online deposits end to end: opening a checkout session for a booking, and SETTLING it — one code
/// path (<see cref="SettleAsync"/>) shared by the gateway's return trip (/verify), a second /pay, the
/// reconciliation job and the guest's release, so that a payment is judged, and a paid one recorded,
/// the same way whoever asks. The SQL expiry sweep never settles: it leaves every booking whose payment
/// was opened to the reconciliation job.
///
/// TWO GATEWAYS, ONE PIPELINE. The card (MPGS) and Whish differ only in who is asked - which gateway
/// opens the payment, and which one says what became of it (each through its own decision table). What
/// follows the answer - recording, releasing, keeping the hold, alerting staff - is the same code. Which
/// gateway a booking is on is read off its gateway order id: the bare reference is a card order,
/// reference-A&lt;n&gt; a Whish attempt (<see cref="WhishOptions.IsAttemptId"/>).
/// </summary>
public interface IOnlineDepositService
{
    /// <summary>The card gateway as it is configured right now (the mode in use), for the redirect targets.</summary>
    Task<MpgsOptions> GatewayAsync();

    /// <summary>Whish as it is configured right now (the mode in use): its redirect targets and the callback token.</summary>
    Task<WhishOptions> WhishAsync();

    /// <summary>The methods a guest may pay with right now: "card" when its keys are set, "whish" when its keys are set AND its switch is on.</summary>
    Task<IReadOnlyList<string>> MethodsAsync();

    /// <summary>POST /{ref}/pay with a method: "card" (as <see cref="OpenAsync(string, CancellationToken)"/>) or "whish".</summary>
    Task<PaymentOpening> OpenAsync(string bookingRef, string method, CancellationToken cancellationToken = default);

    /// <summary>
    /// POST /{ref}/pay. The procedure's refusals (not found, not pending, hold expired, already paid,
    /// nothing due) propagate as SqlException 50000 for the controller's error filter.
    /// </summary>
    Task<PaymentOpening> OpenAsync(string bookingRef, CancellationToken cancellationToken = default);

    Task<Settlement> SettleAsync(string bookingRef, SettleTrigger trigger, CancellationToken cancellationToken = default);

    /// <summary>"Ask the gateway now", pressed by a member of staff (<see cref="SettleTrigger.StaffCheck"/>); logged under their name.</summary>
    Task<Settlement> StaffCheckAsync(string bookingRef, int userId, CancellationToken cancellationToken = default);
}

public sealed class OnlineDepositService : IOnlineDepositService
{
    public const string AlertUnconfirmed = "PayUnconfirmed";

    /// <summary>How many earlier Whish attempts of a booking the reconciliation job asks about again.</summary>
    public const int EarlierAttemptsChecked = 5;

    private readonly IOnlineDepositRepository _deposits;
    private readonly IBookingRepository _bookings;
    private readonly IPaymentGateways _gateways;
    private readonly IPaymentEventLog? _events;
    private readonly OnlineDepositOptions _timing;
    private readonly TimeProvider _clock;
    private readonly ILogger<OnlineDepositService> _log;

    /// <summary>
    /// What the API runs: the gateways as they are configured RIGHT NOW (script 119: their keys and mode can be
    /// changed in HRMS while the API is running), asked for at every call, and the payment log.
    /// </summary>
    public OnlineDepositService(IOnlineDepositRepository deposits, IBookingRepository bookings, IPaymentGateways gateways,
        OnlineDepositOptions timing, ILogger<OnlineDepositService> log, TimeProvider? clock = null, IPaymentEventLog? events = null)
    {
        _deposits = deposits;
        _bookings = bookings;
        _gateways = gateways;
        _timing = timing;
        _log = log;
        _clock = clock ?? TimeProvider.System;
        _events = events;
    }

    /// <summary>Fixed gateways: one card client, optionally one Whish client. What the tests build it on.</summary>
    public OnlineDepositService(IOnlineDepositRepository deposits, IBookingRepository bookings, IMpgsClient gateway,
        MpgsOptions options, OnlineDepositOptions timing, ILogger<OnlineDepositService> log, TimeProvider? clock = null,
        IWhishClient? whish = null, WhishOptions? whishOptions = null, IPaymentEventLog? events = null)
        : this(deposits, bookings, new FixedPaymentGateways(options, gateway, whishOptions, whish), timing, log, clock, events)
    {
    }

    public Task<MpgsOptions> GatewayAsync() => _gateways.CardAsync();

    public Task<WhishOptions> WhishAsync() => _gateways.WhishAsync();

    public async Task<IReadOnlyList<string>> MethodsAsync()
    {
        var methods = new List<string>(2);
        if ((await _gateways.CardAsync()).IsConfigured) methods.Add(PaymentMethods.Card);
        if ((await _gateways.WhishAsync()).IsConfigured && await _deposits.IsWhishEnabledAsync()) methods.Add(PaymentMethods.Whish);
        return methods;
    }

    private Task WriteAsync(PaymentEventEntry entry) => _events is null ? Task.CompletedTask : _events.WriteAsync(entry);

    /* ---- opening --------------------------------------------------------------------------- */

    public Task<PaymentOpening> OpenAsync(string bookingRef, string method, CancellationToken cancellationToken = default)
        => PaymentMethods.Parse(method) == PaymentMethods.Whish
            ? OpenWhishAsync(bookingRef, cancellationToken)
            : OpenAsync(bookingRef, cancellationToken);

    /// <summary>
    /// A WHISH ATTEMPT: the same steps as a card session - settle whatever was opened before, let the procedure
    /// decide and stamp the hold, ask the gateway - with Whish's two differences: every attempt has an id of its own
    /// (a payment link allows ONE attempt and lives five minutes; a retry is a new payment), and what comes back is
    /// a link the guest is sent to, where Whish shows the QR code and the six-digit code itself.
    /// </summary>
    private async Task<PaymentOpening> OpenWhishAsync(string bookingRef, CancellationToken cancellationToken)
    {
        // Not configured, or switched off: like a gateway that did not open a payment, before anything is stamped.
        var whish = await _gateways.WhishAsync();
        if (!whish.IsConfigured || !await _deposits.IsWhishEnabledAsync())
            return new PaymentOpening(PayOpenResult.GatewayError, bookingRef, Method: PaymentMethods.Whish);

        // Whatever was opened before - a card session or an earlier Whish attempt - is settled FIRST, through the
        // one path. Paid: recorded, no new payment. An attempt whose link can still be paid: no second payment
        // beside it (a guest with two open links could pay twice). Settled as not paid: a fresh id and link.
        var earlier = await SettleAsync(bookingRef, SettleTrigger.PayAgain, cancellationToken);
        switch (earlier.Result)
        {
            case SettlementResult.Paid or SettlementResult.PaidNeedsStaff:
                return new PaymentOpening(PayOpenResult.AlreadyPaid, bookingRef, Changed: earlier.Changed, Method: PaymentMethods.Whish);

            case SettlementResult.Unconfirmed:
                _log.LogWarning("Deposit {Ref}: no new Whish attempt, the earlier payment is unconfirmed ({Reason}).", bookingRef, earlier.Reason);
                return new PaymentOpening(PayOpenResult.PreviousUnconfirmed, bookingRef, Method: PaymentMethods.Whish);

            case SettlementResult.UnknownBooking:
                return new PaymentOpening(PayOpenResult.UnknownBooking, bookingRef, Method: PaymentMethods.Whish);
        }

        // The same procedure as the card: validates (refusals travel as SqlException 50000) and stamps the hold.
        var started = await _deposits.StartPaymentAsync(bookingRef);
        if (started is null)
            return new PaymentOpening(PayOpenResult.UnknownBooking, bookingRef, Method: PaymentMethods.Whish);

        var attempt = await _deposits.StartWhishAttemptAsync(bookingRef);
        if (attempt is null)
            return new PaymentOpening(PayOpenResult.UnknownBooking, bookingRef, Method: PaymentMethods.Whish);

        // The mode this attempt is opened in: it is settled, and refunded, with the keys of this mode whatever
        // mode is in use by then (script 119).
        await _deposits.SetPaymentModeAsync(bookingRef, whish.Mode);

        string collectUrl;
        try
        {
            // Both callbacks and both redirects carry the reference and lead to the same two places: each only
            // makes us ASK Whish what happened, so which one fired never decides anything.
            collectUrl = await _gateways.WhishClient(whish).CreateCollectAsync(
                attempt.ExternalId, started.DepositDue, started.CurrencyCode, WhishInvoice(started),
                whish.CallbackUrl(bookingRef), whish.CallbackUrl(bookingRef), whish.ReturnUrl(bookingRef), whish.ReturnUrl(bookingRef),
                cancellationToken);
        }
        catch (WhishException ex)
        {
            await WriteAsync(new PaymentEventEntry(GatewayNames.Whish, PaymentEvents.OpenFailed, PaymentEvents.FromWebsite, BookingRef: bookingRef,
                Mode: whish.Mode, GatewayOrderId: attempt.ExternalId, Outcome: "GatewayError", Detail: ex.Message,
                Amount: started.DepositDue, CurrencyCode: started.CurrencyCode));

            // The hold and the attempt id stay: the job asks Whish later, finds no such payment (or one never
            // paid) and releases the booking; the guest may press pay again at once (the attempt settles as not paid).
            return new PaymentOpening(PayOpenResult.GatewayError, bookingRef, Method: PaymentMethods.Whish, Changed: true);
        }

        await WriteAsync(new PaymentEventEntry(GatewayNames.Whish, PaymentEvents.Opened, PaymentEvents.FromWebsite, BookingRef: bookingRef,
            Mode: whish.Mode, GatewayOrderId: attempt.ExternalId, Outcome: "Opened", Detail: $"Whish payment link created (attempt {attempt.Attempt})",
            Amount: started.DepositDue, CurrencyCode: started.CurrencyCode));

        return new PaymentOpening(PayOpenResult.Opened, bookingRef, Deposit: started.DepositDue, Currency: started.CurrencyCode,
            HoldExpiresUtc: started.HoldExpiresUtc, Changed: true, Method: PaymentMethods.Whish, CollectUrl: collectUrl);
    }

    /// <summary>"MOKA&amp;CO room deposit MC-K7Q2M9PW: Studio, 2026-10-01, 2h" - what the guest reads on Whish's page.</summary>
    public static string WhishInvoice(PaymentStarted booking)
        => string.Create(CultureInfo.InvariantCulture,
            $"MOKA&CO room deposit {booking.BookingRef}: {booking.RoomName}, {booking.BookDate:yyyy-MM-dd}, {booking.Hours:0.##}h");

    public async Task<PaymentOpening> OpenAsync(string bookingRef, CancellationToken cancellationToken = default)
    {
        // NO GATEWAY CONFIGURED: answered like a gateway that did not open a session, but before anything
        // is stamped. A hold here would expire a booking that no session can ever pay; left without one
        // it stays a Pending request that staff confirm.
        var card = await _gateways.CardAsync();
        if (!card.IsConfigured)
            return new PaymentOpening(PayOpenResult.GatewayError, bookingRef);

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

        // The mode this session is opened in (script 119): it is settled with the keys of this mode.
        await _deposits.SetPaymentModeAsync(bookingRef, card.Mode);

        string sessionId;
        try
        {
            sessionId = await _gateways.CardClient(card).InitiateCheckoutAsync(
                bookingRef, started.DepositDue, started.CurrencyCode, Description(started),
                card.VerifyUrl(bookingRef), card.CancelledUrl(), card.UnconfirmedUrl(bookingRef),
                cancellationToken);
        }
        catch (MpgsException ex)
        {
            await WriteAsync(new PaymentEventEntry(GatewayNames.Card, PaymentEvents.OpenFailed, PaymentEvents.FromWebsite, BookingRef: bookingRef,
                Mode: card.Mode, GatewayOrderId: bookingRef, Outcome: "GatewayError", Detail: ex.Message,
                Amount: started.DepositDue, CurrencyCode: started.CurrencyCode));

            // The hold and PaymentOpenedUtc stay stamped: the job asks the gateway later (it will find
            // no order) and releases it once GiveUpAfterMinutes have passed.
            return new PaymentOpening(PayOpenResult.GatewayError, bookingRef);
        }

        await WriteAsync(new PaymentEventEntry(GatewayNames.Card, PaymentEvents.Opened, PaymentEvents.FromWebsite, BookingRef: bookingRef,
            Mode: card.Mode, GatewayOrderId: bookingRef, Outcome: "Opened", Detail: "Card checkout session opened",
            Amount: started.DepositDue, CurrencyCode: started.CurrencyCode));

        try
        {
            await _deposits.SetPaymentSessionAsync(bookingRef, sessionId);
        }
        catch (Exception ex)
        {
            _log.LogWarning(ex, "Deposit {Ref}: the session id could not be stored (audit only).", bookingRef);
        }

        // Changed: the hold and PaymentOpenedUtc were stamped, so the staff calendar and the guest's
        // page are told (QA3 BKG-14: the hold was never announced).
        return new PaymentOpening(PayOpenResult.Opened, bookingRef, sessionId, started.DepositDue, started.CurrencyCode, started.HoldExpiresUtc,
            Changed: true);
    }

    /// <summary>"Room deposit: Studio, 2026-10-01, 2h (total USD 40.00)" — what the guest sees on the gateway's page.</summary>
    public static string Description(PaymentStarted booking)
        => string.Create(CultureInfo.InvariantCulture,
            $"Room deposit: {booking.RoomName}, {booking.BookDate:yyyy-MM-dd}, {booking.Hours:0.##}h (total {booking.CurrencyCode} {booking.TotalAmount:0.00})");

    /* ---- settling -------------------------------------------------------------------------- */

    public Task<Settlement> SettleAsync(string bookingRef, SettleTrigger trigger, CancellationToken cancellationToken = default)
        => SettleAsync(bookingRef, trigger, userId: null, cancellationToken);

    public Task<Settlement> StaffCheckAsync(string bookingRef, int userId, CancellationToken cancellationToken = default)
        => SettleAsync(bookingRef, SettleTrigger.StaffCheck, userId, cancellationToken);

    /// <summary>The job, and a member of staff asking by hand: nobody is waiting on a gateway's page for the answer.</summary>
    private static bool IsBackground(SettleTrigger trigger) => trigger is SettleTrigger.Reconciliation or SettleTrigger.StaffCheck;

    private async Task<Settlement> SettleAsync(string bookingRef, SettleTrigger trigger, int? userId, CancellationToken cancellationToken)
    {
        var state = await _deposits.GetPaymentStateAsync(bookingRef);
        if (state is null)
            return new Settlement(SettlementResult.UnknownBooking, bookingRef, false, null, "no such booking");

        // Already on the books: a refresh of the return page, a double return, the job after /verify.
        // Nothing is asked and nothing is written.
        if (state.GatewayPaid)
            return new Settlement(state.Status is "Confirmed" or "Completed" ? SettlementResult.Paid : SettlementResult.PaidNeedsStaff,
                bookingRef, false, state.Status, "already recorded");

        if (trigger is SettleTrigger.PayAgain && state.Status != "Pending")
            return new Settlement(SettlementResult.NotApplicable, bookingRef, false, state.Status, "no longer pending");

        if (state.PaymentOpenedUtc is null)
        {
            // No session was ever opened for it, so nothing can have been charged and there is nothing to
            // ask. Above all NOTHING IS WRITTEN, whoever asks: "keeping the hold" would put an expiry on a
            // booking that has none — a step-1 request — and hand it to the expiry sweep, and RELEASING it
            // (POST /release) would cancel it. The reference is the only credential /verify and /release
            // need, so that is what an anonymous caller could otherwise do (QA3 BKG-1). A hold is only
            // ever stamped by /pay, which stamps PaymentOpenedUtc with it.
            return new Settlement(SettlementResult.NotApplicable, bookingRef, false, state.Status, "no payment was opened");
        }

        // WHICH GATEWAY: read off the booking's order id. The bare reference is a card order; reference-A<n> is a
        // Whish attempt. Each is asked in its own way and answers through its own decision table; from the
        // decision on, there is one path.
        // WHICH KEYS (script 119): those of the mode the payment was OPENED in - a gateway switched to test since
        // must still be able to find a live payment in flight. Unknown (an older payment) = the mode in use.
        var whishAttempt = WhishOptions.AttemptNumber(state.GatewayOrderId, bookingRef);
        var openedIn = await _deposits.GetPaymentModeAsync(bookingRef);
        var now = _clock.GetUtcNow().UtcDateTime;
        var source = PaymentEvents.SourceOf(trigger);
        PaymentDecision decision;
        Func<Task<(Settlement Settlement, bool Changed)>> recordPaid;
        string gatewayName, modeName, orderId, gatewaySaid;

        if (whishAttempt is { } attemptNumber)
        {
            var whish = await _gateways.WhishAsync(openedIn);
            gatewayName = GatewayNames.Whish;
            modeName = openedIn ?? whish.Mode;
            orderId = state.GatewayOrderId!;

            // Its keys have gone since the attempt was opened: nobody can be asked, nothing is judged or written.
            if (!whish.IsConfigured)
            {
                await WriteAsync(new PaymentEventEntry(gatewayName, PaymentEvents.Checked, source, BookingRef: bookingRef, Mode: openedIn,
                    GatewayOrderId: orderId, Outcome: nameof(SettlementResult.Unconfirmed), Detail: "Whish is not configured: nobody could be asked", UserId: userId));
                return new Settlement(SettlementResult.Unconfirmed, bookingRef, false, state.Status, "Whish is not configured");
            }

            var whishClient = _gateways.WhishClient(whish);
            var externalId = orderId;
            var lookup = await whishClient.GetStatusAsync(externalId, state.CurrencyCode, cancellationToken);
            var linkOver = state.PaymentOpenedUtc is { } linkOpened && now >= linkOpened + WhishOptions.LinkLifetime + WhishOptions.LinkGrace;
            decision = WhishDecisionTable.Decide(lookup, linkOver);
            gatewaySaid = Said(lookup);
            recordPaid = () => RecordWhishPaidAsync(bookingRef, externalId, lookup.PayerPhoneNumber, state.DepositDue, state.CurrencyCode);

            // AN EARLIER ATTEMPT PAID LATE. A new attempt replaces the id the booking is asked about, so a guest who
            // paid attempt 1 in its last second - while it still read "pending" and attempt 2 was being opened -
            // would never be found. The job asks about the attempts before the current one too; the first that
            // Whish says was paid is recorded, exactly as the current one would be.
            if (IsBackground(trigger) && decision.Outcome != PaymentOutcome.Paid && attemptNumber > 1)
            {
                for (var earlier = attemptNumber - 1; earlier >= Math.Max(1, attemptNumber - EarlierAttemptsChecked); earlier--)
                {
                    var earlierId = WhishOptions.AttemptId(bookingRef, earlier);
                    var earlierLookup = await whishClient.GetStatusAsync(earlierId, state.CurrencyCode, cancellationToken);
                    if (earlierLookup is not { Kind: WhishLookupKind.Found, CollectStatus: "success" }) continue;

                    _log.LogWarning("Deposit {Ref}: Whish attempt {Earlier} was paid after attempt {Current} was opened; recorded.", bookingRef, earlier, attemptNumber);
                    var late = (await RecordWhishPaidAsync(bookingRef, earlierId, earlierLookup.PayerPhoneNumber, state.DepositDue, state.CurrencyCode)).Settlement;
                    await WriteAsync(new PaymentEventEntry(gatewayName, PaymentEvents.Paid, source, BookingRef: bookingRef, Mode: modeName,
                        GatewayOrderId: earlierId, Outcome: late.Reason, GatewayStatus: Said(earlierLookup),
                        Detail: $"paid on Whish on attempt {earlier}, after attempt {attemptNumber} was opened",
                        Amount: state.DepositDue, CurrencyCode: state.CurrencyCode, UserId: userId));
                    return late;
                }
            }
        }
        else
        {
            var card = await _gateways.CardAsync(openedIn);
            gatewayName = GatewayNames.Card;
            modeName = openedIn ?? card.Mode;
            orderId = bookingRef;

            // A session was opened while the gateway was configured, and its keys have since gone: nobody
            // can be asked, so nothing is judged or written (the hold stays as it is).
            if (!card.IsConfigured)
            {
                await WriteAsync(new PaymentEventEntry(gatewayName, PaymentEvents.Checked, source, BookingRef: bookingRef, Mode: openedIn,
                    GatewayOrderId: orderId, Outcome: nameof(SettlementResult.Unconfirmed), Detail: "The card gateway is not configured: nobody could be asked", UserId: userId));
                return new Settlement(SettlementResult.Unconfirmed, bookingRef, false, state.Status, "online deposits are not configured");
            }

            var order = await _gateways.CardClient(card).RetrieveOrderAsync(bookingRef, cancellationToken);
            decision = PaymentDecisionTable.Decide(order, state.DepositDue, state.CurrencyCode);
            gatewaySaid = Said(order);
            recordPaid = () => RecordPaidAsync(bookingRef, order, state.CurrencyCode);
        }

        var settlement = await ActAsync();

        // THE LOG (script 119): what was asked, what the gateway said, what was done about it.
        var paidNow = settlement.Result is SettlementResult.Paid or SettlementResult.PaidNeedsStaff;
        await WriteAsync(new PaymentEventEntry(gatewayName,
            paidNow && settlement.Changed ? PaymentEvents.Paid : settlement.Result == SettlementResult.Released ? PaymentEvents.Released : PaymentEvents.Checked,
            source, BookingRef: bookingRef, Mode: modeName, GatewayOrderId: orderId,
            Outcome: paidNow ? settlement.Reason : settlement.Result == SettlementResult.NotApplicable ? "NoChange" : settlement.Result.ToString(),
            GatewayStatus: gatewaySaid,
            Detail: paidNow ? decision.Reason : settlement.Reason,
            Amount: paidNow ? state.DepositDue : null, CurrencyCode: paidNow ? state.CurrencyCode : null, UserId: userId));

        return settlement;

        async Task<Settlement> ActAsync()
        {
            // QA3 BKG-4: staff decided the booking while the guest was on the gateway's page. Money the gateway
            // captured is recorded (usp_Booking_ConfirmOnlinePayment: 'Recorded' on a confirmed booking,
            // 'PaidButClosed' + Refund Due on a cancelled one, staff alerted either way); anything else is
            // only noted as checked — a decided booking has no hold to keep and nothing to release.
            if (IsBackground(trigger) && state.Status != "Pending")
            {
                _log.LogInformation("Deposit {Ref} ({Trigger}, {Status}): {Outcome}, {Reason}.", bookingRef, trigger, state.Status, decision.Outcome, decision.Reason);

                if (decision.Outcome == PaymentOutcome.Paid)
                    return (await recordPaid()).Settlement;

                await _deposits.PaymentCheckedAsync(bookingRef, keepHold: false);
                return new Settlement(SettlementResult.NotApplicable, bookingRef, false, state.Status, "no longer pending: " + decision.Reason);
            }

            var age = state.PaymentOpenedUtc is { } opened ? now - opened : TimeSpan.MaxValue;
            var patienceOver = age >= TimeSpan.FromMinutes(_timing.GiveUpAfterMinutes);
            var holdOver = state.HoldExpiresUtc is not { } holdUntil || holdUntil <= now;

            _log.LogInformation("Deposit {Ref} ({Trigger}): {Outcome}, {Reason}.", bookingRef, trigger, decision.Outcome, decision.Reason);

            switch (decision.Outcome)
            {
                case PaymentOutcome.Paid:
                    return (await recordPaid()).Settlement;

                // No money was taken on the order and a new checkout is about to be opened on it: nothing is
                // written, and above all the hold is not released under the guest who is paying again.
                case PaymentOutcome.Failed when trigger == SettleTrigger.PayAgain:
                case PaymentOutcome.Unconfirmed when decision.NothingAttempted && trigger == SettleTrigger.PayAgain:
                    return new Settlement(SettlementResult.NotPaid, bookingRef, false, state.Status, decision.Reason);

                case PaymentOutcome.Failed when !IsBackground(trigger) || patienceOver || decision.Final:
                    return await ReleaseAsync(state, decision.Reason, ifNotReleased: SettlementResult.Failed, markChecked: true);

                // ABANDONED: the gateway answered and nothing was ever attempted on the order, so nothing can
                // have been charged. The guest walking away releases it at once; the job releases it once the
                // hold has run out (the guest had the whole hold to pay).
                case PaymentOutcome.Unconfirmed when decision.NothingAttempted
                                                    && (trigger == SettleTrigger.GuestRelease || (IsBackground(trigger) && holdOver)):
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
                {
                    _log.LogWarning("Deposit {Ref}: still unconfirmed after {Minutes} minutes ({Reason}); staff alerted.",
                        bookingRef, (int)age.TotalMinutes, decision.Reason);
                    await WriteAsync(new PaymentEventEntry(gatewayName, PaymentEvents.Alerted, source, BookingRef: bookingRef, Mode: modeName,
                        GatewayOrderId: orderId, Outcome: "StaffEmailed",
                        Detail: $"Still not confirmed after {(int)age.TotalMinutes} minutes: staff were e-mailed"));
                }
            }

            return new Settlement(SettlementResult.Unconfirmed, bookingRef, false, state.Status, decision.Reason);
        }
    }

    /// <summary>What the card gateway said, in its own words, for the log.</summary>
    public static string Said(MpgsOrderLookup order) => order.Kind switch
    {
        MpgsLookupKind.Found => $"{order.Result ?? "-"} / {order.Status ?? "-"}",
        MpgsLookupKind.NotFound => "order not found",
        _ => "no answer (" + (order.Problem ?? "?") + ")",
    };

    /// <summary>What Whish said, in its own words, for the log.</summary>
    public static string Said(WhishCollectLookup lookup) => lookup.Kind switch
    {
        WhishLookupKind.Found => lookup.CollectStatus ?? "-",
        WhishLookupKind.NotFound => "no such payment",
        _ => "no answer (" + (lookup.Problem ?? "?") + ")",
    };

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

    /// <summary>
    /// A paid Whish attempt, recorded by the SAME procedure as a card payment (so: Confirmed, the payment line, the
    /// guest's messages, the staff alert, the same five outcomes), under the attempt's own id and the method name
    /// "Whish". The amount is the booking's deposit: the payment was created with it, and Whish reports none.
    /// </summary>
    private async Task<(Settlement Settlement, bool Changed)> RecordWhishPaidAsync(string bookingRef, string externalId, string? payerPhone, decimal deposit, string currency)
    {
        var recorded = await _deposits.ConfirmOnlinePaymentAsync(bookingRef, deposit, currency, externalId, payerPhone, PaymentMethods.WhishLineName)
                       ?? throw new InvalidOperationException($"Recording the Whish deposit of {bookingRef} returned nothing.");

        var changed = recorded.Outcome != OnlinePaymentRecorded.Replay;
        var result = recorded.Outcome is OnlinePaymentRecorded.PaidButClosed or OnlinePaymentRecorded.SlotClash
            ? SettlementResult.PaidNeedsStaff
            : SettlementResult.Paid;

        if (changed)
        {
            try
            {
                await _deposits.SetWhishPayerAsync(bookingRef, externalId, payerPhone);
            }
            catch (Exception ex)
            {
                _log.LogWarning(ex, "Deposit {Ref}: the Whish payer could not be noted (the payment itself is recorded).", bookingRef);
            }
        }

        if (result == SettlementResult.PaidNeedsStaff)
            _log.LogWarning("Deposit {Ref}: paid on Whish but {Outcome}; recorded, staff alerted.", bookingRef, recorded.Outcome);

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
