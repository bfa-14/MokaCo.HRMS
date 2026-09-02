using Microsoft.Data.SqlClient;
using MokaCo.HRMS.Model.Booking;
using MokaCo.HRMS.Repository.Booking;

namespace MokaCo.HRMS.Services.Booking;

/// <summary>
/// Bookings. Almost every rule lives in the procedures; what lives here is the ORDER of two calls
/// and the decision about what happens when the second one fails.
/// </summary>
public class BookingService : IBookingService
{
    /// <summary>
    /// The two outcomes worth an email. Completed and NoShow are back-office bookkeeping — a guest
    /// who has already left does not need to be told they arrived, and telling someone they were
    /// marked a no-show is a conversation, not a notification.
    /// </summary>
    private static readonly HashSet<string> EmailedStatuses =
        new(StringComparer.OrdinalIgnoreCase) { "Confirmed", "Cancelled" };

    private readonly IBookingRepository _bookings;
    public BookingService(IBookingRepository bookings) => _bookings = bookings;

    public async Task<BookingCreated?> CreateFromWebsiteAsync(BookingCreateRequest request)
    {
        var created = await _bookings.CreateAsync(request, source: "Website", createdByUserId: null);
        await QueueEmailQuietlyAsync(created?.BookingId);
        return created;
    }

    public async Task<BookingCreated?> CreateManuallyAsync(BookingCreateRequest request, int createdByUserId)
    {
        var created = await _bookings.CreateAsync(request, source: "Manual", createdByUserId);
        await QueueEmailQuietlyAsync(created?.BookingId);
        return created;
    }

    public Task<BookingRange> GetForRangeAsync(DateTime fromDate, DateTime toDate, int? roomId, string? status)
        => _bookings.GetForRangeAsync(fromDate, toDate, roomId, status);

    public async Task<BookingStatusChanged?> SetStatusAsync(int bookingId, BookingStatusRequest request, int actedByUserId)
    {
        var changed = await _bookings.SetStatusAsync(bookingId, request.Status, actedByUserId, request.Reason);

        // Read from the RESULT, not from the request: the procedure is the thing that decided where
        // the booking landed, and a status it refused never reaches this line anyway.
        if (changed is not null && EmailedStatuses.Contains(changed.Status))
            await QueueEmailQuietlyAsync(changed.BookingId);

        return changed;
    }

    public Task<PaymentAdded?> AddPaymentAsync(int bookingId, BookingPaymentRequest request, int receivedByUserId)
        => _bookings.AddPaymentAsync(bookingId, request, receivedByUserId);

    public Task<BookingReceipt> GetReceiptAsync(int bookingId)
        => _bookings.GetReceiptAsync(bookingId);

    public Task<BlockCreated?> CreateBlockAsync(BlockCreateRequest request, int createdByUserId)
        => _bookings.CreateBlockAsync(request, createdByUserId);

    public Task DeleteBlockAsync(int blockId)
        => _bookings.DeleteBlockAsync(blockId);

    public Task<BookingReport> GetReportAsync(DateTime fromDate, DateTime toDate, string groupBy)
        => _bookings.GetReportAsync(fromDate, toDate, groupBy);

    /// <summary>
    /// Queues the guest's copy, and REFUSES TO LET THAT FAILURE MATTER.
    ///
    /// This is the same judgement LiveNotifier makes about a broadcast, for the same reason. The
    /// booking has been taken: the slot is held, the room's calendar shows it, the guest is standing
    /// there having been told a price. If writing an outbox row then fails, the correct outcome is a
    /// guest who does not receive an email — not a 500 on an operation that already committed, and
    /// certainly not a guest who re-submits and is told their own slot was just taken.
    ///
    /// Only SqlException 50000 is swallowed — the procedure's own refusals, of which there is
    /// exactly one it can raise here ("Booking not found.", unreachable on an id we just created).
    /// A connection failure or a deadlock is NOT caught: those are real faults, they are not specific
    /// to the email, and a 500 that says so is better than silence.
    ///
    /// A guest with no address is not a failure at all — the procedure returns quietly, by design.
    /// </summary>
    private async Task QueueEmailQuietlyAsync(int? bookingId)
    {
        if (bookingId is not { } id)
            return;

        try
        {
            await _bookings.QueueEmailAsync(id);
        }
        catch (SqlException ex) when (ex.Number == 50000)
        {
            // Nothing to do and nowhere useful to say it: the booking stands, which is the part
            // that matters. The row's absence from core.EMAIL_OUTBOX is the record that it did not
            // go out.
        }
    }
}
