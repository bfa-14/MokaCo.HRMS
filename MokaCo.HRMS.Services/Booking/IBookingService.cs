using MokaCo.HRMS.Model.Booking;

namespace MokaCo.HRMS.Services.Booking;

/// <summary>
/// Bookings: taking them, pricing them, listing them, deciding them, collecting against them,
/// refunding them and reporting on them.
///
/// NO NOTIFICATION IS QUEUED FROM THIS LAYER. The database trigger booking.trg_Booking_Notify
/// writes the guest's request/confirmation/cancellation and the staff alert, and
/// trg_Payment_RefundNotify the refund mail, inside the transaction that changed the row.
/// </summary>
public interface IBookingService
{
    /* ---- public (website) ---- */

    /// <summary>A booking taken by an anonymous visitor — Source='Website', lead-time rules apply, opens Pending unless BookingAutoConfirm.</summary>
    Task<BookingCreated?> CreateFromWebsiteAsync(PublicBookingRequest request);

    Task<BookingQuote?> QuoteAsync(PublicQuoteRequest request);

    /// <summary>The recap behind an MC- reference, PROJECTED for an anonymous holder: no phone, no email, no note, the name cut to "First L.".</summary>
    Task<PublicBookingRecap?> GetPublicRecapAsync(string bookingRef);

    Task<BookingHoldReleased?> ReleaseHoldAsync(string bookingRef);

    /// <summary>The guest cancels, proving the phone number. Refusals are the procedure's (SqlException 50000). Returns the recap after the cancellation.</summary>
    Task<PublicBookingRecap?> CancelByGuestAsync(string bookingRef, string phone);

    /// <summary>Cancels expired unpaid holds; returns the references it cancelled, so each can be announced live. Called by the five-minute job.</summary>
    Task<IReadOnlyList<string>> ExpireHoldsAsync();

    /// <summary>core.SETTING BookingDepositRequired — whether the website must collect the deposit online (step 2).</summary>
    Task<bool> IsDepositRequiredAsync();

    /* ---- staff ---- */

    /// <summary>A booking typed in by staff — Source='Manual', opens Confirmed, exempt from the lead-time settings.</summary>
    Task<BookingCreated?> CreateManuallyAsync(BookingCreateRequest request, int createdByUserId);

    Task<BookingRange> GetForRangeAsync(DateTime fromDate, DateTime toDate, int? roomId, string? status);

    /// <summary>One booking with its money lines, for the back office. Null when the id is unknown.</summary>
    Task<BookingStaffDetail?> GetStaffDetailAsync(int bookingId);

    /// <summary>Moves the booking; a cancellation carries who asked for it (<see cref="BookingStatusRequest.CancelledBy"/>) and gets its refund figured.</summary>
    Task<BookingStatusChanged?> SetStatusAsync(int bookingId, BookingStatusRequest request, int actedByUserId);

    Task<PaymentAdded?> AddPaymentAsync(int bookingId, BookingPaymentRequest request, int receivedByUserId);

    /// <summary>Records a refund. The method may be an id or a name; the outcome says which was used, or why it was refused.</summary>
    Task<RefundOutcome> AddRefundAsync(int bookingId, BookingRefundRequest request, int receivedByUserId);

    Task<BookingReceipt> GetReceiptAsync(int bookingId);

    Task<BlockCreated?> CreateBlockAsync(BlockCreateRequest request, int createdByUserId);
    Task DeleteBlockAsync(int blockId);

    Task<BookingReport> GetReportAsync(DateTime fromDate, DateTime toDate, string groupBy);
}

/// <summary>
/// What recording a refund produced. <see cref="Error"/> is set when the payment method could not
/// be resolved (nothing was written); otherwise <see cref="Added"/> is the procedure's answer and
/// <see cref="Method"/> the method it was recorded against, resolved by <see cref="ResolvedBy"/>
/// ("id" or "name").
/// </summary>
public sealed class RefundOutcome
{
    public RefundAdded? Added { get; init; }
    public PaymentMethod? Method { get; init; }
    public string ResolvedBy { get; init; } = string.Empty;
    public string? Error { get; init; }
}
