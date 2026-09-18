using MokaCo.HRMS.Model.Booking;

namespace MokaCo.HRMS.Repository.Booking;

/// <summary>
/// The bookings themselves: taking one, pricing one, listing them, deciding them, taking money
/// against them and giving it back, printing them and reporting on them — all through the
/// booking.usp_* procedures.
///
/// EVERY REFUSAL IN THIS AREA IS THE DATABASE'S and travels untouched as SqlException 50000. That is
/// load-bearing for the public endpoint: "That time was just taken — pick another slot" is written
/// to be read by a guest, and the API's job is to pass it through and put a machine code beside it.
///
/// NOTHING HERE QUEUES A NOTIFICATION. booking.trg_Booking_Notify and trg_Payment_RefundNotify write
/// the outbox rows inside the transaction that changed the row; an explicit call would double-send.
/// </summary>
public interface IBookingRepository
{
    /// <summary>
    /// A staff booking (booking.usp_Booking_Create by @RoomId, Source 'Manual'). THE OVERLAP CHECK
    /// IS INSIDE THE PROCEDURE'S TRANSACTION, under UPDLOCK/HOLDLOCK; nothing here may pre-check.
    /// </summary>
    Task<BookingCreated?> CreateAsync(BookingCreateRequest request, string source, int? createdByUserId);

    /// <summary>
    /// The website's booking (booking.usp_Booking_Create by @RoomCode, Source nailed to 'Website',
    /// no CreatedByUserId). Minutes become the two TIME parameters through <see cref="MinuteClock"/>.
    /// </summary>
    Task<BookingCreated?> CreateFromWebsiteAsync(PublicBookingRequest request);

    /// <summary>Prices a slot without taking it (booking.usp_Booking_Quote, Source 'Website' so the website's rules apply).</summary>
    Task<BookingQuote?> QuoteAsync(PublicQuoteRequest request);

    /// <summary>The full row behind an MC- reference (booking.usp_Booking_GetByRef), addons included. Null when unknown.</summary>
    Task<BookingRefDetail?> GetByRefAsync(string bookingRef);

    /// <summary>Frees an unpaid payment hold (booking.usp_Booking_ReleaseHold). A no-op on anything it may not touch; echoes the status either way.</summary>
    Task<BookingHoldReleased?> ReleaseHoldAsync(string bookingRef);

    /// <summary>Cancels every Pending hold whose clock ran out with no money against it (booking.usp_Booking_ExpireHolds). Returns how many.</summary>
    Task<int> ExpireHoldsAsync();

    /// <summary>
    /// The guest cancels their own booking (booking.usp_Booking_CancelByGuest, SQL 79): the last 8
    /// digits of <paramref name="phone"/> must match the booking's, the booking must be live and
    /// inside BookingCancelHours. Returns the recap re-read after the cancellation.
    /// </summary>
    Task<BookingRefDetail?> CancelByGuestAsync(string bookingRef, string phone);

    Task<BookingRange> GetForRangeAsync(DateTime fromDate, DateTime toDate, int? roomId, string? status);

    /// <summary>
    /// Confirmed, Completed, Cancelled or NoShow (booking.usp_Booking_SetStatus). THE PROCEDURE OWNS
    /// THE TRANSITIONS and the refund arithmetic: <paramref name="cancelledBy"/> 'Guest' refunds
    /// what was paid minus the deposit, 'Staff' refunds everything.
    /// </summary>
    Task<BookingStatusChanged?> SetStatusAsync(int bookingId, string newStatus, int actedByUserId, string? note, string cancelledBy);

    Task<PaymentAdded?> AddPaymentAsync(int bookingId, BookingPaymentRequest request, int receivedByUserId);

    /// <summary>Records money going back (booking.usp_Refund_Add): a negative BOOKING_PAYMENT line, IsRefund = 1 (SQL 74 lets it in).</summary>
    Task<RefundAdded?> AddRefundAsync(int bookingId, decimal amount, int paymentMethodId, string? reference, int receivedByUserId);

    /// <summary>All three result sets behind a printed receipt. Header is null when the id is unknown.</summary>
    Task<BookingReceipt> GetReceiptAsync(int bookingId);

    Task<BlockCreated?> CreateBlockAsync(BlockCreateRequest request, int createdByUserId);
    Task DeleteBlockAsync(int blockId);

    Task<BookingReport> GetReportAsync(DateTime fromDate, DateTime toDate, string groupBy);
}
