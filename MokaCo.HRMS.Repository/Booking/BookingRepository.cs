using System.Data;
using Dapper;
using MokaCo.HRMS.Model.Booking;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.Booking;

/// <summary>
/// Dapper access to the bookings, entirely through the booking.usp_* procedures — no inline SQL.
///
/// THE PROCEDURES ARE THE RULES. Overlap, opening hours, lead times, person counts, deposit
/// arithmetic, status transitions, payment ceilings, refund ceilings: all of it is enforced in SQL,
/// inside the transaction that also writes the row. This class carries parameters in and result
/// sets out, and deliberately re-checks nothing.
/// </summary>
public class BookingRepository : IBookingRepository
{
    private readonly IDbConnectionFactory _factory;
    public BookingRepository(IDbConnectionFactory factory) => _factory = factory;

    public async Task<BookingCreated?> CreateAsync(BookingCreateRequest request, string source, int? createdByUserId)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<BookingCreated>(
            "booking.usp_Booking_Create",
            new
            {
                request.RoomId,
                BookDate = request.BookDate.Date,
                request.StartTime,
                request.EndTime,
                request.Persons,
                request.GuestName,
                request.GuestPhone,
                request.GuestEmail,
                request.Note,
                AddonIds = JoinAddonIds(request.AddonIds),
                Source = source,
                CreatedByUserId = createdByUserId,
            },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>
    /// Source is 'Website' HERE, not taken from the body, so a caller cannot post 'Manual' and skip
    /// the lead-time rules; CreatedByUserId is null, so nothing is attributed to staff who never
    /// touched it. Price, deposit and status are computed by the procedure and never accepted.
    /// </summary>
    public async Task<BookingCreated?> CreateFromWebsiteAsync(PublicBookingRequest request)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<BookingCreated>(
            "booking.usp_Booking_Create",
            new
            {
                RoomId = (int?)null,
                request.RoomCode,
                BookDate = request.Date.Date,
                StartTime = MinuteClock.StartTime(request.StartMin),
                EndTime = MinuteClock.EndTime(request.EndMin),
                request.Persons,
                GuestName = request.Name,
                GuestPhone = request.Phone,
                GuestEmail = request.Email,
                Note = request.Notes,
                AddonIds = JoinAddonIds(request.AddonIds),
                Source = "Website",
                CreatedByUserId = (int?)null,
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<BookingQuote?> QuoteAsync(PublicQuoteRequest request)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<BookingQuote>(
            "booking.usp_Booking_Quote",
            new
            {
                request.RoomCode,
                RoomId = (int?)null,
                BookDate = request.Date.Date,
                request.StartMin,
                request.EndMin,
                AddonIds = JoinAddonIds(request.AddonIds),
                Source = "Website",
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<BookingRefDetail?> GetByRefAsync(string bookingRef)
    {
        using var db = _factory.Create();
        using var multi = await db.QueryMultipleAsync(
            "booking.usp_Booking_GetByRef",
            new { Ref = bookingRef },
            commandType: CommandType.StoredProcedure);

        return await ReadRefDetailAsync(multi);
    }

    public async Task<BookingHoldReleased?> ReleaseHoldAsync(string bookingRef)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<BookingHoldReleased>(
            "booking.usp_Booking_ReleaseHold",
            new { Ref = bookingRef },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>@ReturnRows = 1 (SQL 80): one row per hold this call cancelled, so each can be announced on the hub.</summary>
    public async Task<IReadOnlyList<string>> ExpireHoldsAsync()
    {
        using var db = _factory.Create();
        var expired = await db.QueryAsync<(int BookingId, string? BookingRef)>(
            "booking.usp_Booking_ExpireHolds",
            new { ReturnRows = true },
            commandType: CommandType.StoredProcedure);
        return expired.Where(row => !string.IsNullOrEmpty(row.BookingRef)).Select(row => row.BookingRef!).ToList();
    }

    /// <summary>The procedure ends with EXEC usp_Booking_GetByRef, so the same two result sets come back and are read the same way.</summary>
    public async Task<BookingRefDetail?> CancelByGuestAsync(string bookingRef, string phone)
    {
        using var db = _factory.Create();
        using var multi = await db.QueryMultipleAsync(
            "booking.usp_Booking_CancelByGuest",
            new { Ref = bookingRef, Phone = phone },
            commandType: CommandType.StoredProcedure);

        return await ReadRefDetailAsync(multi);
    }

    private static async Task<BookingRefDetail?> ReadRefDetailAsync(SqlMapper.GridReader multi)
    {
        var booking = await multi.ReadFirstOrDefaultAsync<BookingRefDetail>();
        if (booking is null)
            return null;

        booking.Addons = (await multi.ReadAsync<BookingRefAddon>()).ToList();
        return booking;
    }

    public async Task<BookingRange> GetForRangeAsync(DateTime fromDate, DateTime toDate, int? roomId, string? status)
    {
        using var db = _factory.Create();
        using var multi = await db.QueryMultipleAsync(
            "booking.usp_Booking_GetForRange",
            new
            {
                FromDate = fromDate.Date,
                ToDate = toDate.Date,
                RoomId = roomId,
                Status = status,
            },
            commandType: CommandType.StoredProcedure);

        return new BookingRange
        {
            Bookings = (await multi.ReadAsync<BookingRow>()).ToList(),
            Blocks = (await multi.ReadAsync<BookingBlock>()).ToList(),
        };
    }

    public async Task<BookingStatusChanged?> SetStatusAsync(int bookingId, string newStatus, int actedByUserId, string? note, string cancelledBy)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<BookingStatusChanged>(
            "booking.usp_Booking_SetStatus",
            new
            {
                BookingId = bookingId,
                NewStatus = newStatus,
                ActedByUserId = actedByUserId,
                Reason = note,
                CancelledBy = cancelledBy,
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<PaymentAdded?> AddPaymentAsync(int bookingId, BookingPaymentRequest request, int receivedByUserId)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<PaymentAdded>(
            "booking.usp_Payment_Add",
            new
            {
                BookingId = bookingId,
                request.PaymentMethodId,
                request.Amount,
                request.Reference,
                ReceivedByUserId = receivedByUserId,
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<RefundAdded?> AddRefundAsync(int bookingId, decimal amount, int paymentMethodId, string? reference, int receivedByUserId)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<RefundAdded>(
            "booking.usp_Refund_Add",
            new
            {
                BookingId = bookingId,
                Amount = amount,
                PaymentMethodId = paymentMethodId,
                Reference = reference,
                ReceivedByUserId = receivedByUserId,
            },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>ReadFirstOrDefault on the header, so an unknown booking id comes back as a receipt with no header rather than throwing.</summary>
    public async Task<BookingReceipt> GetReceiptAsync(int bookingId)
    {
        using var db = _factory.Create();
        using var multi = await db.QueryMultipleAsync(
            "booking.usp_Booking_GetReceipt",
            new { BookingId = bookingId },
            commandType: CommandType.StoredProcedure);

        return new BookingReceipt
        {
            Header = await multi.ReadFirstOrDefaultAsync<ReceiptHeader>(),
            Addons = (await multi.ReadAsync<ReceiptAddon>()).ToList(),
            Payments = (await multi.ReadAsync<ReceiptPayment>()).ToList(),
        };
    }

    public async Task<BlockCreated?> CreateBlockAsync(BlockCreateRequest request, int createdByUserId)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<BlockCreated>(
            "booking.usp_Block_Create",
            new
            {
                request.RoomId,
                BlockDate = request.BlockDate.Date,
                request.StartTime,
                request.EndTime,
                request.Reason,
                CreatedByUserId = createdByUserId,
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task DeleteBlockAsync(int blockId)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "booking.usp_Block_Delete",
            new { BlockId = blockId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<BookingReport> GetReportAsync(DateTime fromDate, DateTime toDate, string groupBy)
    {
        using var db = _factory.Create();
        using var multi = await db.QueryMultipleAsync(
            "booking.usp_Report_Bookings",
            new
            {
                FromDate = fromDate.Date,
                ToDate = toDate.Date,
                GroupBy = groupBy,
            },
            commandType: CommandType.StoredProcedure);

        return new BookingReport
        {
            Buckets = (await multi.ReadAsync<BookingReportBucket>()).ToList(),
            Rooms = (await multi.ReadAsync<BookingReportRoom>()).ToList(),
        };
    }

    /// <summary>The list-to-string join the procedure's STRING_SPLIT needs. EMPTY BECOMES NULL — null is what "no add-ons" means to the procedure.</summary>
    private static string? JoinAddonIds(List<int>? addonIds)
        => addonIds is null || addonIds.Count == 0
            ? null
            : string.Join(',', addonIds.Distinct());
}
