using System.Collections.Concurrent;
using System.Globalization;
using System.Text.Json;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Logging;
using MokaCo.HRMS.Model.Booking;
using MokaCo.HRMS.Repository.Booking;

namespace MokaCo.HRMS.Services.Booking.Payments;

/// <summary>What "Ask the gateway now" and "Refund" answer with: a sentence, what the gateway said, and the payment re-read.</summary>
/// <param name="Changed">The booking changed (confirmed, released, refunded): the calendars should be told.</param>
public sealed record PaymentDeskResult(bool Ok, string Message, bool Changed = false, IReadOnlyList<GatewayFact>? Facts = null, PaymentDetail? Payment = null);

/// <summary>
/// THE PAYMENTS PAGE (Bookings > Payments, script 119): every booking an online payment was opened or recorded for -
/// Bank of Beirut cards and Whish alike - with its log, and the two things staff may do about one:
///
///   ASK THE GATEWAY NOW  what the gateway holds is read and shown; a payment not yet on the books is then settled
///                        through THE SAME path as the job and the guest's return (a paid one is recorded and the
///                        booking confirmed, an abandoned one released once its hold is over, one the gateway cannot
///                        tell about keeps its hold). Asking twice changes nothing twice.
///   REFUND ON WHISH      the whole Whish payment goes back to the payer, and the refund is put on the booking's
///                        books by the procedure staff refunds already use. Only on a cancelled booking (that is
///                        where a refund is recorded), only once, only when the booking's rules say AT LEAST that
///                        much is owed back (Whish cannot return a part), and only while nothing of it was refunded
///                        by hand. One at a time per booking; an aborted request never leaves it half done.
///                        A card payment is refunded in the bank's portal and recorded on the booking, as before.
/// </summary>
public interface IPaymentDeskService
{
    /// <param name="from">First Beirut day of the period (payments by the day they were paid, or opened).</param>
    /// <param name="to">Last Beirut day, inclusive.</param>
    Task<IReadOnlyList<PaymentRow>> ListAsync(DateTime from, DateTime to, string? gateway, string? state, string? search);

    Task<PaymentDetail?> GetAsync(int bookingId);

    Task<PaymentDeskResult?> CheckAsync(int bookingId, int userId, CancellationToken cancellationToken = default);

    Task<PaymentDeskResult?> RefundAsync(int bookingId, string? reason, int userId, CancellationToken cancellationToken = default);
}

public sealed class PaymentDeskService : IPaymentDeskService
{
    public static readonly string[] States = ["Paid", "RefundDue", "Refunded", "NeedsStaff", "Open", "Unconfirmed", "NotPaid"];

    /// <summary>One refund at a time per booking, in this API (it runs as one process): a double press waits, then finds the refund made.</summary>
    private static readonly ConcurrentDictionary<int, SemaphoreSlim> RefundLocks = new();

    private readonly IPaymentGatewayRepository _repository;
    private readonly IPaymentGateways _gateways;
    private readonly IOnlineDepositService _deposits;
    private readonly IBookingService _bookings;
    private readonly IPaymentEventLog _events;
    private readonly OnlineDepositOptions _timing;
    private readonly ILogger<PaymentDeskService> _log;
    private readonly IRoomService? _rooms;

    public PaymentDeskService(IPaymentGatewayRepository repository, IPaymentGateways gateways, IOnlineDepositService deposits,
        IBookingService bookings, IPaymentEventLog events, OnlineDepositOptions timing, ILogger<PaymentDeskService> log, IRoomService? rooms = null)
    {
        _repository = repository;
        _gateways = gateways;
        _deposits = deposits;
        _bookings = bookings;
        _events = events;
        _timing = timing;
        _log = log;
        _rooms = rooms;
    }

    public Task<IReadOnlyList<PaymentRow>> ListAsync(DateTime from, DateTime to, string? gateway, string? state, string? search)
        => _repository.ListPaymentsAsync(
            BeirutTime.At(from.Date).UtcDateTime, BeirutTime.At(to.Date.AddDays(1)).UtcDateTime,
            GatewayNames.Parse(gateway), States.FirstOrDefault(s => string.Equals(s, state?.Trim(), StringComparison.OrdinalIgnoreCase)),
            search, _timing.GiveUpAfterMinutes);

    public Task<PaymentDetail?> GetAsync(int bookingId) => _repository.GetPaymentAsync(bookingId, _timing.GiveUpAfterMinutes);

    /* ---- ask the gateway now ---------------------------------------------------------------- */

    public async Task<PaymentDeskResult?> CheckAsync(int bookingId, int userId, CancellationToken cancellationToken = default)
    {
        var detail = await GetAsync(bookingId);
        if (detail is null) return null;

        var payment = detail.Payment;
        var orderId = payment.GatewayOrderId ?? payment.BookingRef;
        List<GatewayFact> facts;
        string said;
        bool answered;

        // 1. What the gateway holds, read and shown. Nothing is changed by this.
        if (payment.Gateway == GatewayNames.Whish)
        {
            var options = await _gateways.WhishAsync(payment.Mode);
            if (!options.IsConfigured)
                return new PaymentDeskResult(false, options.Problem ?? "Whish is not configured, so it cannot be asked.", Payment: detail);

            var lookup = await _gateways.WhishClient(options).GetStatusAsync(orderId, payment.CurrencyCode, cancellationToken);
            said = OnlineDepositService.Said(lookup);
            answered = lookup.Kind != WhishLookupKind.Error;
            facts = [new GatewayFact("Asked about", orderId), new GatewayFact("Whish says", said)];
            if (lookup.PayerPhoneNumber is { } phone) facts.Add(new GatewayFact("Paid from", phone));
        }
        else
        {
            var options = await _gateways.CardAsync(payment.Mode);
            if (!options.IsConfigured)
                return new PaymentDeskResult(false, options.Problem ?? "The card gateway is not configured, so it cannot be asked.", Payment: detail);

            var order = await _gateways.CardClient(options).RetrieveOrderAsync(payment.BookingRef, cancellationToken);
            said = OnlineDepositService.Said(order);
            answered = order.Kind != MpgsLookupKind.Error;
            facts = [new GatewayFact("Asked about", payment.BookingRef), .. GatewayAdminService.CardFacts(order)];
        }

        // 2. Already on the books (or no payment was ever opened): asking was all there is to do.
        if (payment.PaymentId is not null || payment.PaymentOpenedUtc is null)
        {
            await _events.WriteAsync(new PaymentEventEntry(payment.Gateway, PaymentEvents.Checked, PaymentEvents.FromStaff, BookingRef: payment.BookingRef,
                Mode: payment.Mode, GatewayOrderId: orderId, Outcome: "NoChange", GatewayStatus: said,
                Detail: payment.PaymentId is not null ? "Asked by staff; the payment is already recorded" : "Asked by staff", UserId: userId));

            return new PaymentDeskResult(answered,
                !answered ? "The gateway did not give a usable answer. Try again in a minute."
                : payment.PaymentId is not null ? "The gateway was asked. This payment is already recorded; nothing changed."
                : "The gateway was asked. Nothing changed.",
                Facts: facts, Payment: await GetAsync(bookingId));
        }

        // 3. Not on the books yet: settled through the one path, exactly as the job would (and logged under this user).
        var settled = await _deposits.StaffCheckAsync(payment.BookingRef, userId, cancellationToken);
        var message = settled.Result switch
        {
            SettlementResult.Paid => "Paid. The payment is now recorded and the booking is confirmed.",
            SettlementResult.PaidNeedsStaff => "Paid, and recorded. But the booking could not simply be confirmed (it was closed, or its slot was taken): decide it on the booking.",
            SettlementResult.Released => "Not paid. The slot was released and the booking cancelled.",
            SettlementResult.Failed => "Not paid. Nothing was taken from the guest.",
            SettlementResult.NotApplicable => "Not paid. The booking was already decided, so nothing changed.",
            SettlementResult.NotPaid => "Not paid.",
            _ => "The gateway cannot say yet whether this was paid. The slot stays held; ask again in a few minutes.",
        };

        return new PaymentDeskResult(settled.Result != SettlementResult.Unconfirmed || answered, message, settled.Changed, facts, await GetAsync(bookingId));
    }

    /* ---- refund on Whish -------------------------------------------------------------------- */

    public async Task<PaymentDeskResult?> RefundAsync(int bookingId, string? reason, int userId, CancellationToken cancellationToken = default)
    {
        // ONE AT A TIME PER BOOKING. A second press waits here and then reads a payment that is already refunded.
        var gate = RefundLocks.GetOrAdd(bookingId, _ => new SemaphoreSlim(1, 1));
        await gate.WaitAsync(cancellationToken);
        try
        {
            // FROM HERE THE REQUEST'S OWN CANCELLATION IS NOT FOLLOWED: a browser that goes away between Whish giving
            // the money back and the refund reaching the books must not leave the one without the other.
            return await RefundLockedAsync(bookingId, reason, userId);
        }
        finally
        {
            gate.Release();
        }
    }

    private async Task<PaymentDeskResult?> RefundLockedAsync(int bookingId, string? reason, int userId)
    {
        var detail = await GetAsync(bookingId);
        if (detail is null) return null;

        var payment = detail.Payment;
        if (RefundRefusal(detail) is { } refusal)
            return new PaymentDeskResult(false, refusal, Payment: detail);

        // Everything that could stop the refund reaching the books is checked BEFORE any money moves.
        if (_rooms is not null && !(await _rooms.GetActivePaymentMethodsAsync()).Any(m => string.Equals(m.Name, PaymentMethods.WhishLineName, StringComparison.OrdinalIgnoreCase)))
            return new PaymentDeskResult(false, "The payment method \"Whish\" is switched off or missing, so the refund could not be recorded. Switch it on, then refund.", Payment: detail);

        var externalId = payment.GatewayOrderId!;
        var amount = payment.PaidAmount!.Value;
        var options = await _gateways.WhishAsync(payment.Mode);
        if (!options.IsConfigured)
            return new PaymentDeskResult(false, options.Problem ?? "Whish is not configured, so it cannot refund.", Payment: detail);

        var why = string.IsNullOrWhiteSpace(reason) ? $"Booking {payment.BookingRef} cancelled" : reason.Trim();
        var refund = await _gateways.WhishClient(options).RefundAsync(externalId, payment.CurrencyCode, why, CancellationToken.None);
        if (!refund.Refunded)
        {
            // No answer is not a refusal: the money may have gone back. Said as what it is, and asking again is safe.
            var problem = refund.Unknown
                ? "Whish did not answer, so it is NOT known whether the refund went through. Press Refund again in a minute: Whish never refunds the same payment twice, and the refund is recorded here once Whish confirms it."
                : "Whish did not refund it. " + GatewayAdminService.WhishProblem(refund.Code, refund.Problem) + " Nothing was changed.";
            await _events.WriteAsync(new PaymentEventEntry(GatewayNames.Whish, PaymentEvents.RefundFailed, PaymentEvents.FromStaff, BookingRef: payment.BookingRef,
                Mode: payment.Mode, GatewayOrderId: externalId, Outcome: refund.Unknown ? "Unknown" : "Failed", GatewayStatus: refund.Code, Detail: problem,
                Amount: amount, CurrencyCode: payment.CurrencyCode, UserId: userId));
            return new PaymentDeskResult(false, problem, Payment: await GetAsync(bookingId));
        }

        // The money is back with the payer. The books come first, then the log line that says "refunded": a refund
        // that could not be recorded stays visibly unfinished, and pressing Refund again records it (Whish answers
        // a second request for the same payment as the refund it already made).
        string? notRecorded = null;
        try
        {
            var recorded = await _bookings.AddRefundAsync(bookingId, new BookingRefundRequest
            {
                Amount = amount,
                Method = JsonSerializer.SerializeToElement(PaymentMethods.WhishLineName),
                Reference = RefundReference(externalId),
            }, userId);
            notRecorded = recorded.Error ?? (recorded.Added is null ? "the booking was not found" : null);
        }
        catch (SqlException ex) when (ex.Number == 50000)
        {
            notRecorded = ex.Message;
        }

        if (notRecorded is not null)
        {
            _log.LogError("Refund {Ref}: Whish refunded {ExternalId} but the refund line was not written ({Why}).", payment.BookingRef, externalId, notRecorded);
            var unrecorded = string.Create(CultureInfo.InvariantCulture,
                $"Whish gave the money back ({payment.CurrencyCode} {amount:0.00}), but HRMS could not record it: {notRecorded} Record this refund by hand on the booking.");
            await _events.WriteAsync(new PaymentEventEntry(GatewayNames.Whish, PaymentEvents.RefundFailed, PaymentEvents.FromStaff, BookingRef: payment.BookingRef,
                Mode: payment.Mode, GatewayOrderId: externalId, Outcome: "NotRecorded", Detail: unrecorded, Amount: amount, CurrencyCode: payment.CurrencyCode, UserId: userId));
            return new PaymentDeskResult(false, unrecorded, Changed: true, Payment: await GetAsync(bookingId));
        }

        await _events.WriteAsync(new PaymentEventEntry(GatewayNames.Whish, PaymentEvents.Refunded, PaymentEvents.FromStaff, BookingRef: payment.BookingRef,
            Mode: payment.Mode, GatewayOrderId: externalId, Outcome: refund.AlreadyDone ? "AlreadyRefunded" : "Refunded",
            Detail: "Refunded on Whish: " + why, Amount: amount, CurrencyCode: payment.CurrencyCode, UserId: userId));

        return new PaymentDeskResult(true,
            string.Create(CultureInfo.InvariantCulture, $"Refunded. Whish gave {payment.CurrencyCode} {amount:0.00} back to the payer, and the refund is recorded on the booking."),
            Changed: true, Payment: await GetAsync(bookingId));
    }

    /// <summary>The reference a refund made on Whish is recorded under: how it is recognised later.</summary>
    public static string RefundReference(string externalId) => "Whish refund " + externalId;

    /// <summary>Why this payment cannot be refunded on Whish from here, or null when it can. One rule, read by the API and shown by the page.</summary>
    public static string? RefundRefusal(PaymentDetail detail)
    {
        var payment = detail.Payment;
        if (payment.Gateway != GatewayNames.Whish)
            return "A card payment is refunded in the bank's merchant portal, then recorded on the booking (Bookings > the booking > Refund).";
        if (payment.PaymentId is null || payment.PaidAmount is not { } paid || paid <= 0 || string.IsNullOrEmpty(payment.GatewayOrderId))
            return "Nothing was paid on Whish for this booking, so there is nothing to refund.";
        if (payment.GatewayRefunded || detail.Lines.Any(l => l.IsRefund && l.Reference is { } reference && reference.StartsWith(RefundReference(payment.GatewayOrderId), StringComparison.OrdinalIgnoreCase)))
            return "This Whish payment was already refunded.";
        if (payment.BookingStatus != "Cancelled")
            return "Cancel the booking first: a refund is recorded on a cancelled booking only.";
        // Whish gives back the whole payment, never a part of it.
        if (detail.Lines.Sum(l => l.Amount) < paid)
            return "Part of this booking's money was already refunded by hand. Whish can only give back the whole payment, so refund the rest by hand.";
        // And only what the booking's own rules say is owed back (a guest who cancels keeps no claim on the deposit
        // unless the settings say so): the button never gives back more than is due.
        var owed = Math.Max(0, payment.RefundAmount - payment.RefundedAmount);
        if (owed <= 0)
            return "Nothing is owed back on this booking under its cancellation rules, so there is nothing to refund here.";
        if (owed < paid)
            return string.Create(CultureInfo.InvariantCulture,
                $"Only {payment.CurrencyCode} {owed:0.00} is owed back on this booking, and Whish can only give back the whole payment ({payment.CurrencyCode} {paid:0.00}). Refund the amount owed by hand.");
        return null;
    }
}
