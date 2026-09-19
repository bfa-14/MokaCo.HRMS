using System.Globalization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Data.SqlClient;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Model.Booking;
using MokaCo.HRMS.Services.Booking;

namespace MokaCo.HRMS.Api.Controllers;

/// <summary>
/// The back office for room bookings: the calendar, the decisions, the money, the rooms themselves
/// and the report over all of it.
///
/// TWO PERMISSIONS, AND THE LINE BETWEEN THEM IS "does this change anything". BOOKING_VIEW reads the
/// calendar, one booking, a receipt and the report; BOOKING_MANAGE takes a booking, decides one,
/// collects against one, refunds one, blocks a room and edits the catalogue. A receptionist who may see the day without being able
/// to cancel it is the case that line exists for.
///
/// ONE DELIBERATE DEPARTURE FROM THE OBVIOUS READING: GET rooms is BOOKING_VIEW, not
/// BOOKING_MANAGE, while every write to the catalogue is BOOKING_MANAGE. The calendar draws a column
/// per room and filters by room, so gating the room LIST on the manage permission would leave a
/// view-only user with a calendar that cannot render — and the list reveals nothing they are not
/// already reading off the bookings themselves.
///
/// REFUSALS ARE THE PROCEDURES' AND TRAVEL UNTOUCHED. Every rule here — a booking already closed, a
/// cancellation with no reason, a payment past the total, a block laid over live bookings, a
/// duplicate room code — is enforced in SQL and arrives as SqlException 50000. The catches below
/// turn it into a 400 carrying that exact sentence, because "Amount exceeds the balance — 45.00
/// remains" is a usable answer and "Bad request" is not.
/// </summary>
[ApiController]
[Route("api/bookings")]
public class BookingsController : ControllerBase
{
    private readonly IBookingService _bookings;
    private readonly IRoomService _rooms;

    /// <summary>Tells /hubs/booking after each committed change: the staff calendars and the guest's confirmation page.</summary>
    private readonly IBookingLivePublisher _live;

    public BookingsController(IBookingService bookings, IRoomService rooms, IBookingLivePublisher live)
    {
        _bookings = bookings;
        _rooms = rooms;
        _live = live;
    }

    /* ---- 1. The calendar ---------------------------------------------------------------- */

    /// <summary>
    /// Bookings AND staff blocks over a date range, optionally narrowed to one room or one status.
    ///
    /// Both lists always come back, because a calendar drawn from the bookings alone paints free
    /// time over a room that is shut. The status filter narrows the bookings only — a block has no
    /// status to filter on.
    /// </summary>
    [HttpGet]
    [HasPermission("BOOKING_VIEW")]
    public async Task<IActionResult> GetRange(
        [FromQuery] DateTime from,
        [FromQuery] DateTime to,
        [FromQuery] int? roomId,
        [FromQuery] string? status)
    {
        if (to < from)
            return BadRequest(new { error = "The 'to' date cannot be before the 'from' date." });

        return Ok(await _bookings.GetForRangeAsync(from, to, roomId, status));
    }

    /// <summary>
    /// A booking typed in by staff — Source='Manual', which opens it Confirmed and exempts it from
    /// the lead-time settings that gate the website. Still usp_Booking_Create by @RoomId; the answer
    /// carries the same fields the public create does (ref, hours, discount, deposit percent). The
    /// guest's confirmation is queued by the database trigger, not here.
    ///
    /// AN END AT OR BEFORE THE START MEANS THE NEXT MORNING (22:00–01:00), which the procedure
    /// accepts up to 06:00 — the same rule as the table's CK_BOOKING_Times. Only an end later than
    /// that, or equal to the start, is refused here (BUG-22).
    /// </summary>
    [HttpPost("manual")]
    [HasPermission("BOOKING_MANAGE")]
    public async Task<IActionResult> CreateManual([FromBody] BookingCreateRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.GuestName) || string.IsNullOrWhiteSpace(request.GuestPhone))
            return BadRequest(new { error = "Guest name and phone are required." });

        if (request.EndTime == request.StartTime || (request.EndTime < request.StartTime && request.EndTime > TimeSpan.FromHours(6)))
            return BadRequest(new { error = "The end time must be after the start time (an end up to 06:00 is read as the next morning)." });

        try
        {
            var created = await _bookings.CreateManuallyAsync(request, User.UserId());
            if (created is null)
                return BadRequest(new { error = "The booking could not be taken." });

            await _live.PublishAsync(created.BookingRef);
            return Ok(created);
        }
        catch (SqlException ex) when (ex.Number == 50000)
        {
            return BadRequest(new { error = ex.Message });
        }
    }

    /// <summary>
    /// One booking with its money lines: the row as usp_Booking_GetByRef reads it (refundAmount,
    /// refundStatus, refundedUtc, cancelledBy included) plus every payment line with isRefund.
    /// </summary>
    [HttpGet("{id:int}")]
    [HasPermission("BOOKING_VIEW")]
    public async Task<IActionResult> GetById(int id)
    {
        var detail = await _bookings.GetStaffDetailAsync(id);
        return detail is null ? NotFound() : Ok(StaffShape(detail));
    }

    /// <summary>
    /// Confirm, complete, cancel or mark a no-show. Body { status, cancelledBy: "Staff"|"Guest",
    /// note? } — `reason` is still accepted as the note and cancelledBy defaults to Staff, so the
    /// current web app keeps working until Q6 lands.
    ///
    /// THE TRANSITION RULES AND THE REFUND ARITHMETIC ARE THE PROCEDURE'S (BUG-25): it refuses an
    /// unknown status, a booking already closed, a cancellation with no note; and a cancellation
    /// carries who asked for it — Guest = the guest rang → refund minus the deposit, Staff = the café
    /// cancelled → everything paid goes back. Answers with the booking row as GET {id} does, so the
    /// screen repaints from one shape. The guest's mail is queued by the database trigger.
    /// </summary>
    [HttpPut("{id:int}/status")]
    [HasPermission("BOOKING_MANAGE")]
    public async Task<IActionResult> SetStatus(int id, [FromBody] BookingStatusRequest request)
    {
        var by = string.IsNullOrWhiteSpace(request.CancelledBy) ? "Staff" : request.CancelledBy.Trim();
        if (!string.Equals(by, "Staff", StringComparison.OrdinalIgnoreCase) && !string.Equals(by, "Guest", StringComparison.OrdinalIgnoreCase))
            return BadRequest(new { error = "cancelledBy must be Staff or Guest." });

        request.CancelledBy = char.ToUpperInvariant(by[0]) + by[1..].ToLowerInvariant();

        try
        {
            var changed = await _bookings.SetStatusAsync(id, request, User.UserId());
            if (changed is null)
                return NotFound();

            await _live.PublishAsync(changed.BookingRef);   // confirm / cancel / no-show / completed

            var detail = await _bookings.GetStaffDetailAsync(id);
            return Ok(detail is null
                ? new
                {
                    bookingId = changed.BookingId,
                    bookingRef = changed.BookingRef,
                    status = changed.Status,
                    cancelledBy = changed.CancelledBy,
                    refundAmount = changed.RefundAmount,
                    refundStatus = changed.RefundStatus,
                }
                : StaffShape(detail));
        }
        catch (SqlException ex) when (ex.Number == 50000)
        {
            return BadRequest(new { error = ex.Message });
        }
    }

    /// <summary>
    /// Records money going back on a cancelled booking (booking.usp_Refund_Add — a negative payment
    /// line, which SQL 74 lets through CK_PAY_Amount). Body { amount, method, reference? } where
    /// `method` is a PaymentMethodId or a method name (Cash, Card, Whish, OMT). Answers with every
    /// payment line and where the refund now stands. The refund mail is queued by the database
    /// trigger on BOOKING_PAYMENT.
    /// </summary>
    [HttpPost("{id:int}/refunds")]
    [HasPermission("BOOKING_MANAGE")]
    public async Task<IActionResult> AddRefund(int id, [FromBody] BookingRefundRequest request)
    {
        if (request.Amount <= 0)
            return BadRequest(new { error = "Enter a refund amount greater than zero." });

        try
        {
            var outcome = await _bookings.AddRefundAsync(id, request, User.UserId());
            if (outcome.Error is not null)
                return BadRequest(new { error = outcome.Error });

            if (outcome.Added is null)
                return NotFound();

            var detail = await _bookings.GetStaffDetailAsync(id);
            if (detail is null)
                return NotFound();

            await _live.PublishAsync(detail.Booking.BookingRef);   // refund recorded: refundStatus moved

            return Ok(new
            {
                bookingId = id,
                bookingRef = detail.Booking.BookingRef,
                paymentId = outcome.Added.PaymentId,
                method = outcome.Method!.Name,
                methodResolvedBy = outcome.ResolvedBy,
                payments = Payments(detail),
                refundAmount = detail.Booking.RefundAmount,
                refundedAmount = detail.Booking.RefundedAmount,
                refundStatus = detail.Booking.RefundStatus,
                refundedUtc = detail.Booking.RefundedUtc,
                paidAmount = detail.Booking.PaidAmount,
                balanceDue = detail.Booking.BalanceDue,
            });
        }
        catch (SqlException ex) when (ex.Number == 50000)
        {
            // "Refunds are recorded on cancelled bookings only." / "Refund exceeds what was paid — 20.00 remains refundable."
            return BadRequest(new { error = ex.Message });
        }
    }

    /// <summary>
    /// The staff view of one booking: BookingRow's names (so the calendar's type still fits) plus the
    /// refund, cancellation and money fields, the add-ons and every payment line.
    /// </summary>
    private static object StaffShape(BookingStaffDetail detail)
    {
        var b = detail.Booking;
        return new
        {
            bookingId = b.BookingId,
            bookingRef = b.BookingRef,
            @ref = b.BookingRef,
            roomCode = b.RoomCode,
            roomName = b.RoomName,
            bookDate = b.BookDate,
            date = b.BookDate.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
            startTime = b.StartTime,
            endTime = b.EndTime,
            startMin = b.StartMin,
            endMin = b.EndMin,
            vacateByMin = b.VacateByMin,
            turnaroundMinutes = b.TurnaroundMinutes,
            hours = b.Hours,
            persons = b.Persons,
            guestName = b.GuestName,
            guestPhone = b.GuestPhone,
            guestEmail = b.GuestEmail,
            note = b.Note,
            status = b.Status,
            source = b.Source,
            totalAmount = b.TotalAmount,
            discountPercent = b.DiscountPercent,
            discountAmount = b.DiscountAmount,
            depositDue = b.DepositDue,
            depositPercent = b.DepositPercent,
            currencyCode = b.CurrencyCode,
            paidAmount = b.PaidAmount,
            balanceDue = b.BalanceDue,
            cancelReason = b.CancelReason,
            cancelledBy = b.CancelledBy,
            refundAmount = b.RefundAmount,
            refundedAmount = b.RefundedAmount,
            refundStatus = b.RefundStatus,
            refundedUtc = b.RefundedUtc,
            canCancelOnline = b.CanCancelOnline,
            cancelHours = b.CancelHours,
            holdExpiresUtc = b.HoldExpiresUtc,
            paidConfirmedUtc = b.PaidConfirmedUtc,
            createdUtc = b.CreatedUtc,
            policyText = b.PolicyText,
            addons = b.Addons.Select(a => new { name = a.Name, amount = a.Amount }),
            payments = Payments(detail),
        };
    }

    private static IEnumerable<object> Payments(BookingStaffDetail detail)
        => detail.Payments.Select(p => new
        {
            paymentId = p.PaymentId,
            amount = p.Amount,
            isRefund = p.IsRefund,
            method = p.MethodName,
            reference = p.Reference,
            paidUtc = p.PaidUtc,
            receivedBy = p.ReceivedBy,
        });

    /* ---- 2. Money ----------------------------------------------------------------------- */

    /// <summary>
    /// Records a payment and returns the money position after it — paid total and remaining balance,
    /// both computed by the procedure that also refused to let the total be exceeded.
    /// </summary>
    [HttpPost("{id:int}/payments")]
    [HasPermission("BOOKING_MANAGE")]
    public async Task<IActionResult> AddPayment(int id, [FromBody] BookingPaymentRequest request)
    {
        if (request.Amount <= 0)
            return BadRequest(new { error = "Enter an amount greater than zero." });

        try
        {
            var added = await _bookings.AddPaymentAsync(id, request, User.UserId());
            if (added is null)
                return NotFound();

            // paid and balance moved — the guest's page shows both
            await _live.PublishAsync((await _bookings.GetStaffDetailAsync(id))?.Booking.BookingRef);
            return Ok(added);
        }
        catch (SqlException ex) when (ex.Number == 50000)
        {
            return BadRequest(new { error = ex.Message });
        }
    }

    /// <summary>
    /// Everything a printed receipt needs, in one call: the booking and its money position, the
    /// add-on lines AS CHARGED, and every payment against it.
    /// </summary>
    [HttpGet("{id:int}/receipt")]
    [HasPermission("BOOKING_VIEW")]
    public async Task<IActionResult> GetReceipt(int id)
    {
        var receipt = await _bookings.GetReceiptAsync(id);
        if (receipt.Header is null)
            return NotFound();

        return Ok(receipt);
    }

    /* ---- 3. Blocks ---------------------------------------------------------------------- */

    /// <summary>
    /// Holds a room back — maintenance, a private event, a deep clean.
    ///
    /// The procedure REFUSES to lay a block over live bookings. That is the right answer: a block is
    /// not a way to evict guests, and silently double-holding the room would leave the calendar
    /// showing both.
    /// </summary>
    [HttpPost("blocks")]
    [HasPermission("BOOKING_MANAGE")]
    public async Task<IActionResult> CreateBlock([FromBody] BlockCreateRequest request)
    {
        if (request.EndTime <= request.StartTime)
            return BadRequest(new { error = "The end time must be after the start time." });

        try
        {
            var created = await _bookings.CreateBlockAsync(request, User.UserId());
            if (created is null)
                return BadRequest(new { error = "The block could not be created." });

            return Ok(created);
        }
        catch (SqlException ex) when (ex.Number == 50000)
        {
            return BadRequest(new { error = ex.Message });
        }
    }

    /// <summary>Removes a block. The procedure raises on an unknown id, so deleting one twice says so rather than reporting success.</summary>
    [HttpDelete("blocks/{id:int}")]
    [HasPermission("BOOKING_MANAGE")]
    public async Task<IActionResult> DeleteBlock(int id)
    {
        try
        {
            await _bookings.DeleteBlockAsync(id);
            return NoContent();
        }
        catch (SqlException ex) when (ex.Number == 50000)
        {
            return BadRequest(new { error = ex.Message });
        }
    }

    /* ---- 4. The catalogue: rooms, hours, add-ons ----------------------------------------- */

    /// <summary>
    /// The whole catalogue — rooms, every room's hours, every room's add-ons — retired ones
    /// included by default, because this is the screen on which a retired room is edited back.
    ///
    /// BOOKING_VIEW: see the class remark. The calendar cannot draw a column per room without it.
    /// </summary>
    [HttpGet("rooms")]
    [HasPermission("BOOKING_VIEW")]
    public async Task<IActionResult> GetRooms([FromQuery] bool includeInactive = true)
        => Ok(await _rooms.GetCatalogAsync(includeInactive));

    /// <summary>
    /// Creates a room. It is born with seven 09:00–22:00 days, which the procedure inserts — so a
    /// new room is bookable immediately rather than invisible until somebody notices its week is
    /// empty. Returns the row as stored.
    /// </summary>
    [HttpPost("rooms")]
    [HasPermission("BOOKING_MANAGE")]
    public async Task<IActionResult> CreateRoom([FromBody] RoomUpsertRequest request)
        => await UpsertRoomAsync(null, request);

    /// <summary>
    /// Updates a room. EVERY FIELD IS STORED, including the ones the caller left at their defaults —
    /// the procedure UPDATEs the whole row, so a partial body is a room with a 0% deposit rather than
    /// a room with its deposit left alone.
    /// </summary>
    [HttpPut("rooms/{id:int}")]
    [HasPermission("BOOKING_MANAGE")]
    public async Task<IActionResult> UpdateRoom(int id, [FromBody] RoomUpsertRequest request)
        => await UpsertRoomAsync(id, request);

    private async Task<IActionResult> UpsertRoomAsync(int? roomId, RoomUpsertRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.Code) || string.IsNullOrWhiteSpace(request.Name))
            return BadRequest(new { error = "A room needs a code and a name." });

        try
        {
            var saved = await _rooms.UpsertRoomAsync(roomId, request);
            if (saved is null)
                return roomId is null
                    ? BadRequest(new { error = "The room could not be saved." })
                    : NotFound();

            return Ok(saved);
        }
        catch (SqlException ex) when (ex.Number == 50000)
        {
            // "A room with that code already exists." / "Check seats, price and deposit percent."
            return BadRequest(new { error = ex.Message });
        }
    }

    /// <summary>
    /// Sets the room's week. Takes the WHOLE week (or any subset), because the screen that edits
    /// this is seven rows and saves as one act — seven requests to store one edit would make a
    /// half-saved week the routine result of closing a laptop.
    ///
    /// The days are applied in DayOfWeek order, one procedure call each and NOT in a transaction: a
    /// day the procedure refuses stops the run, leaving the days before it stored. That is why the
    /// refusal names the day it was on.
    /// </summary>
    [HttpPut("rooms/{id:int}/hours")]
    [HasPermission("BOOKING_MANAGE")]
    public async Task<IActionResult> SetHours(int id, [FromBody] List<RoomHoursRequest> hours)
    {
        if (hours is null || hours.Count == 0)
            return BadRequest(new { error = "Send at least one day." });

        if (hours.Any(day => day.DayOfWeek is < 1 or > 7))
            return BadRequest(new { error = "DayOfWeek must be 1 (Monday) to 7 (Sunday)." });

        try
        {
            await _rooms.SetHoursAsync(id, hours);
            return NoContent();
        }
        catch (SqlException ex) when (ex.Number == 50000)
        {
            // "Close time must be after open time."
            return BadRequest(new { error = ex.Message });
        }
    }

    /// <summary>Adds an add-on to a room's price list.</summary>
    [HttpPost("rooms/{id:int}/addons")]
    [HasPermission("BOOKING_MANAGE")]
    public async Task<IActionResult> CreateAddon(int id, [FromBody] RoomAddonUpsertRequest request)
        => await UpsertAddonAsync(null, id, request);

    /// <summary>
    /// Edits one add-on. RE-PRICING IS SAFE: the amount was copied onto every booking that took it,
    /// so nothing already booked moves.
    /// </summary>
    [HttpPut("rooms/{id:int}/addons/{addonId:int}")]
    [HasPermission("BOOKING_MANAGE")]
    public async Task<IActionResult> UpdateAddon(int id, int addonId, [FromBody] RoomAddonUpsertRequest request)
        => await UpsertAddonAsync(addonId, id, request);

    private async Task<IActionResult> UpsertAddonAsync(int? addonId, int roomId, RoomAddonUpsertRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.Name))
            return BadRequest(new { error = "Give the add-on a name." });

        try
        {
            await _rooms.UpsertAddonAsync(addonId, roomId, request);
            return NoContent();
        }
        catch (SqlException ex) when (ex.Number == 50000)
        {
            // "Price type is PerHour or Fixed."
            return BadRequest(new { error = ex.Message });
        }
    }

    /// <summary>
    /// The ways money can be taken. ACTIVE ONLY — this list exists to be chosen from, and a retired
    /// method is not a choice. (A receipt still names a retired method correctly; it reads the name
    /// off the payment, not off this list.)
    /// </summary>
    [HttpGet("payment-methods")]
    [HasPermission("BOOKING_MANAGE")]
    public async Task<IActionResult> GetPaymentMethods()
        => Ok(await _rooms.GetActivePaymentMethodsAsync());

    /* ---- 5. Report ---------------------------------------------------------------------- */

    /// <summary>
    /// The bookings report: a timeline bucketed by day, week or month, plus each room's share of the
    /// whole range.
    ///
    /// REVENUE AND COLLECTED ARE NOT THE SAME POPULATION and the gap between them is the point —
    /// Revenue counts Confirmed and Completed bookings, Collected counts every payment received,
    /// including payments against bookings that were later cancelled.
    /// </summary>
    [HttpGet("report")]
    [HasPermission("BOOKING_VIEW")]
    public async Task<IActionResult> GetReport(
        [FromQuery] DateTime from,
        [FromQuery] DateTime to,
        [FromQuery] string groupBy = "day")
    {
        if (to < from)
            return BadRequest(new { error = "The 'to' date cannot be before the 'from' date." });

        try
        {
            return Ok(await _bookings.GetReportAsync(from, to, groupBy));
        }
        catch (SqlException ex) when (ex.Number == 50000)
        {
            // "GroupBy must be day, week or month."
            return BadRequest(new { error = ex.Message });
        }
    }
}
