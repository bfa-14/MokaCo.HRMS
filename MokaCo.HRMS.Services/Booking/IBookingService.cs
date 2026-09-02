using MokaCo.HRMS.Model.Booking;

namespace MokaCo.HRMS.Services.Booking;

/// <summary>
/// Bookings: taking them, listing them, deciding them, collecting against them and reporting on them.
///
/// THE ONE PIECE OF ORCHESTRATION IN THIS LAYER is "create, then queue the guest's copy" and
/// "decide, then queue the guest's copy". Both are two procedure calls that the controller must not
/// be trusted to remember in the right order, and both are deliberately NOT atomic — see the
/// implementation for why a failure to queue must never undo a booking that exists.
/// </summary>
public interface IBookingService
{
    /// <summary>
    /// A booking taken by an anonymous visitor — Source='Website', so the lead-time settings apply
    /// and the row opens Pending unless core.SETTING BookingAutoConfirm says otherwise.
    /// </summary>
    Task<BookingCreated?> CreateFromWebsiteAsync(BookingCreateRequest request);

    /// <summary>
    /// A booking typed in by staff — Source='Manual', which skips the lead-time rules (staff may
    /// book this afternoon) and opens Confirmed, and is attributed to the user who took it.
    /// </summary>
    Task<BookingCreated?> CreateManuallyAsync(BookingCreateRequest request, int createdByUserId);

    Task<BookingRange> GetForRangeAsync(DateTime fromDate, DateTime toDate, int? roomId, string? status);

    /// <summary>
    /// Moves the booking and, for the two outcomes a guest needs to hear about, queues their copy.
    /// Returns null when the procedure produced no row, which it does not do on success.
    /// </summary>
    Task<BookingStatusChanged?> SetStatusAsync(int bookingId, BookingStatusRequest request, int actedByUserId);

    Task<PaymentAdded?> AddPaymentAsync(int bookingId, BookingPaymentRequest request, int receivedByUserId);

    Task<BookingReceipt> GetReceiptAsync(int bookingId);

    Task<BlockCreated?> CreateBlockAsync(BlockCreateRequest request, int createdByUserId);
    Task DeleteBlockAsync(int blockId);

    Task<BookingReport> GetReportAsync(DateTime fromDate, DateTime toDate, string groupBy);
}
