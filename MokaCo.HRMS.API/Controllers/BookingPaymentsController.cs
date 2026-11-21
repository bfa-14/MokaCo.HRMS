using System.Globalization;
using Microsoft.AspNetCore.Mvc;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Api.Hubs;
using MokaCo.HRMS.Model.Booking;
using MokaCo.HRMS.Services.Booking;
using MokaCo.HRMS.Services.Booking.Payments;

namespace MokaCo.HRMS.Api.Controllers;

/// <summary>
/// THE PAYMENTS PAGE (Bookings > Payments, script 119): every booking an online payment was opened or recorded for,
/// by Bank of Beirut card or by Whish, with its log - and what staff may do about one.
///
///   GET  /api/booking-payments?from=&amp;to=&amp;gateway=&amp;state=&amp;q=   BOOKING_PAYMENTS          the list and its totals
///   GET  /api/booking-payments/{bookingId}                    BOOKING_PAYMENTS          one payment, its log, the money lines
///   POST /api/booking-payments/{bookingId}/check              BOOKING_PAYMENTS_MANAGE   ask the gateway now (and settle)
///   POST /api/booking-payments/{bookingId}/refund             BOOKING_PAYMENTS_MANAGE   refund the whole payment on Whish
///
/// from/to are Beirut days ('2026-11-21'), by the day a payment was paid - or opened, when it was never paid. A search
/// (q) looks at every date. Every instant in an answer is UTC with its Z; timeZone names the café's zone.
/// </summary>
[ApiController]
[Route("api/booking-payments")]
public class BookingPaymentsController : ControllerBase
{
    private const string View = "BOOKING_PAYMENTS";
    private const string Manage = "BOOKING_PAYMENTS_MANAGE";

    /// <summary>The longest period one list covers: a year and a day.</summary>
    public const int MaxDays = 367;

    private readonly IPaymentDeskService _payments;
    private readonly IBookingLivePublisher _live;

    public BookingPaymentsController(IPaymentDeskService payments, IBookingLivePublisher live)
    {
        _payments = payments;
        _live = live;
    }

    [HttpGet]
    [HasPermission(View)]
    public async Task<IActionResult> GetList([FromQuery] string? from, [FromQuery] string? to, [FromQuery] string? gateway,
        [FromQuery] string? state, [FromQuery] string? q)
    {
        var today = BeirutTime.Now.Date;
        var first = today.AddDays(-29);
        var last = today;
        if (!string.IsNullOrWhiteSpace(from) && !TryDate(from, out first)) return BadRequest(new { error = "from must look like '2026-11-21'." });
        if (!string.IsNullOrWhiteSpace(to) && !TryDate(to, out last)) return BadRequest(new { error = "to must look like '2026-11-21'." });
        if (last < first) return BadRequest(new { error = "The 'to' date cannot be before the 'from' date." });
        if ((last - first).TotalDays > MaxDays) return BadRequest(new { error = "Choose a period of a year or less." });

        var rows = await _payments.ListAsync(first, last, gateway, state, q);

        return Ok(new
        {
            timeZone = BeirutTime.IanaId,
            from = first.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
            to = last.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
            totals = Totals(rows),
            payments = rows.Select(Shape),
        });
    }

    [HttpGet("{bookingId:int}")]
    [HasPermission(View)]
    public async Task<IActionResult> GetOne(int bookingId)
    {
        var detail = await _payments.GetAsync(bookingId);
        return detail is null ? NotFound() : Ok(Shape(detail));
    }

    [HttpPost("{bookingId:int}/check")]
    [HasPermission(Manage)]
    public async Task<IActionResult> Check(int bookingId, CancellationToken cancellationToken)
    {
        var result = await _payments.CheckAsync(bookingId, User.UserId(), cancellationToken);
        if (result is null) return NotFound();

        if (result.Changed && result.Payment is not null) await _live.PublishAsync(result.Payment.Payment.BookingRef);
        return Ok(Shape(result));
    }

    public sealed class RefundRequest
    {
        public string? Reason { get; set; }
    }

    [HttpPost("{bookingId:int}/refund")]
    [HasPermission(Manage)]
    public async Task<IActionResult> Refund(int bookingId, [FromBody] RefundRequest? request, CancellationToken cancellationToken)
    {
        var result = await _payments.RefundAsync(bookingId, request?.Reason, User.UserId(), cancellationToken);
        if (result is null) return NotFound();

        if (result.Changed && result.Payment is not null) await _live.PublishAsync(result.Payment.Payment.BookingRef);
        return Ok(Shape(result));
    }

    /* ---- shapes ----------------------------------------------------------------------------- */

    private static object Shape(PaymentDeskResult result) => new
    {
        ok = result.Ok,
        message = result.Message,
        changed = result.Changed,
        facts = PaymentGatewaysController.Facts(result.Facts),
        payment = result.Payment is null ? null : Shape(result.Payment),
    };

    private static object Shape(PaymentDetail detail) => new
    {
        timeZone = BeirutTime.IanaId,
        payment = Shape(detail.Payment),
        // Why "Refund on Whish" is not offered, in a sentence; null when it is.
        refundRefusal = PaymentDeskService.RefundRefusal(detail),
        events = detail.Events.Select(Shape),
        lines = detail.Lines.Select(l => new
        {
            paymentId = l.PaymentId,
            amount = l.Amount,
            isRefund = l.IsRefund,
            method = l.MethodName,
            reference = l.Reference,
            paidAt = Utc(l.PaidUtc),
            receivedBy = l.ReceivedBy,
            gatewayOrderId = l.GatewayOrderId,
            transactionId = l.TransactionId,
        }),
    };

    private static object Shape(PaymentRow p) => new
    {
        bookingId = p.BookingId,
        @ref = p.BookingRef,
        guestName = p.GuestName,
        guestPhone = p.GuestPhone,
        roomName = p.RoomName,
        date = p.BookDate.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
        startMin = p.StartMin,
        endMin = p.EndMin,
        bookingStatus = p.BookingStatus,
        gateway = p.Gateway,
        mode = p.Mode,
        state = p.PayState,
        deposit = p.DepositDue,
        total = p.TotalAmount,
        currency = p.CurrencyCode,
        paidAmount = p.PaidAmount,
        paidAt = Utc(p.PaidUtc),
        openedAt = Utc(p.PaymentOpenedUtc),
        checkedAt = Utc(p.PaymentCheckedUtc),
        activityAt = Utc(p.ActivityUtc),
        holdExpiresAt = Utc(p.HoldExpiresUtc),
        attempts = p.Attempts,
        payerPhone = p.PayerPhone,
        gatewayOrderId = p.GatewayOrderId,
        transactionId = p.TransactionId,
        refundDue = p.RefundAmount,
        refundStatus = p.RefundStatus,
        refundedAmount = p.RefundedAmount,
        refundedAt = Utc(p.RefundedUtc),
        gatewayRefunded = p.GatewayRefunded,
        lastEvent = p.LastEventType is null ? null : new { type = p.LastEventType, outcome = p.LastOutcome, detail = p.LastDetail, at = Utc(p.LastEventUtc) },
    };

    internal static object Shape(PaymentEventRow e) => new
    {
        id = e.PaymentEventId,
        gateway = e.Gateway,
        mode = e.Mode,
        gatewayOrderId = e.GatewayOrderId,
        type = e.EventType,
        source = e.Source,
        outcome = e.Outcome,
        gatewayStatus = e.GatewayStatus,
        detail = e.Detail,
        amount = e.Amount,
        currency = e.CurrencyCode,
        repeats = e.Repeats,
        at = Utc(e.CreatedAtUtc),
        lastAt = Utc(e.LastAtUtc),
        by = e.UserName,
    };

    /// <summary>
    /// What the period came to, per currency: money received online (by gateway), money given back, and how many
    /// payments are waiting on somebody. TEST payments are counted apart and never added to the money.
    /// </summary>
    private static object Totals(IReadOnlyList<PaymentRow> rows)
    {
        static bool Received(PaymentRow p) => p.PaymentId is not null;
        static bool Real(PaymentRow p) => p.Mode != GatewayModes.Test;

        return new
        {
            count = rows.Count,
            waiting = rows.Count(p => p.PayState == "Open"),
            needAttention = rows.Count(p => p.PayState is "Unconfirmed" or "NeedsStaff" or "RefundDue"),
            notPaid = rows.Count(p => p.PayState == "NotPaid"),
            testPayments = rows.Count(p => Received(p) && !Real(p)),
            money = rows.Where(p => Received(p) && Real(p)).GroupBy(p => p.CurrencyCode).OrderBy(g => g.Key).Select(g => new
            {
                currency = g.Key,
                received = g.Sum(p => p.PaidAmount ?? 0),
                card = g.Where(p => p.Gateway == GatewayNames.Card).Sum(p => p.PaidAmount ?? 0),
                whish = g.Where(p => p.Gateway == GatewayNames.Whish).Sum(p => p.PaidAmount ?? 0),
                refunded = g.Sum(p => p.RefundedAmount),
                refundDue = g.Where(p => p.PayState == "RefundDue").Sum(p => Math.Max(0, p.RefundAmount - p.RefundedAmount)),
                payments = g.Count(),
            }),
        };
    }

    private static DateTime? Utc(DateTime? value) => value is { } at ? DateTime.SpecifyKind(at, DateTimeKind.Utc) : null;

    private static bool TryDate(string? value, out DateTime date)
        => DateTime.TryParseExact(value?.Trim(), "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out date);
}
