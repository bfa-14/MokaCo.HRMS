using MokaCo.HRMS.Model.Booking;

namespace MokaCo.HRMS.Repository.Booking;

/// <summary>
/// The bookings themselves: taking one, listing them, deciding them, taking money against them,
/// printing them and reporting on them — all through the booking.usp_* procedures.
///
/// EVERY REFUSAL IN THIS AREA IS THE DATABASE'S and travels untouched as SqlException 50000. That is
/// load-bearing for the public endpoint in a way it is not elsewhere: "That time was just taken —
/// pick another slot" and "Mokha takes 2 to 8 persons" are written to be read by a guest, and the
/// API's job is to pass them through as the 400's text, not to summarise them.
/// </summary>
public interface IBookingRepository
{
    /// <summary>
    /// Takes a booking (booking.usp_Booking_Create) and returns id, price, deposit, currency and the
    /// status it landed in.
    ///
    /// THE OVERLAP CHECK IS INSIDE THE PROCEDURE'S TRANSACTION, under UPDLOCK/HOLDLOCK. Two guests
    /// submitting the same slot at the same moment is the ordinary case this is built for, and the
    /// loser gets a refusal rather than a double booking. Nothing here may pre-check availability
    /// and then create: that race is exactly what the lock exists to close.
    ///
    /// <paramref name="source"/> is 'Website' or 'Manual' and decides which rules apply — the
    /// lead-time settings gate the website only.
    /// </summary>
    Task<BookingCreated?> CreateAsync(BookingCreateRequest request, string source, int? createdByUserId);

    /// <summary>
    /// Bookings and staff blocks over a date range (booking.usp_Booking_GetForRange), optionally
    /// narrowed to one room or one status. Both result sets, always — see <see cref="BookingRange"/>.
    /// </summary>
    Task<BookingRange> GetForRangeAsync(DateTime fromDate, DateTime toDate, int? roomId, string? status);

    /// <summary>
    /// Moves a booking to Confirmed, Completed, Cancelled or NoShow (booking.usp_Booking_SetStatus).
    ///
    /// THE PROCEDURE OWNS THE TRANSITIONS: it refuses an unknown status, refuses to touch a booking
    /// that is already closed, and refuses a cancellation with no reason. None of that is re-checked
    /// here.
    /// </summary>
    Task<BookingStatusChanged?> SetStatusAsync(int bookingId, string newStatus, int actedByUserId, string? reason);

    /// <summary>
    /// Records a payment (booking.usp_Payment_Add) and returns the resulting money position.
    /// Refuses an unknown or retired method, a closed booking, and any amount that would take the
    /// booking past its total — naming what remains.
    /// </summary>
    Task<PaymentAdded?> AddPaymentAsync(int bookingId, BookingPaymentRequest request, int receivedByUserId);

    /// <summary>All three result sets behind a printed receipt. Header is null when the id is unknown.</summary>
    Task<BookingReceipt> GetReceiptAsync(int bookingId);

    /// <summary>
    /// Holds a room back (booking.usp_Block_Create). REFUSES to cover live bookings — a block is not
    /// a way to evict guests, and the procedure says so.
    /// </summary>
    Task<BlockCreated?> CreateBlockAsync(BlockCreateRequest request, int createdByUserId);

    /// <summary>Removes a block. RAISERRORs when the id is unknown, so a deleted-twice block is a 400 rather than a silent success.</summary>
    Task DeleteBlockAsync(int blockId);

    /// <summary>The bookings report, bucketed by 'day', 'week' or 'month', plus the per-room totals for the range.</summary>
    Task<BookingReport> GetReportAsync(DateTime fromDate, DateTime toDate, string groupBy);

    /// <summary>
    /// Queues the guest's copy of what just happened (booking.usp_Booking_QueueEmail).
    ///
    /// IT WRITES TO core.EMAIL_OUTBOX AND SENDS NOTHING — EmailWorker drains that once a minute. A
    /// guest with no email address is a NO-OP, not a refusal: the address is optional on the public
    /// form, and a booking that succeeded must not fail on the way to telling somebody about it.
    /// </summary>
    Task QueueEmailAsync(int bookingId);
}
