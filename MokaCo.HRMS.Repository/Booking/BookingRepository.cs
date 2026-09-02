using System.Data;
using Dapper;
using MokaCo.HRMS.Model.Booking;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.Booking;

/// <summary>
/// Dapper access to the bookings, entirely through the booking.usp_* procedures — no inline SQL.
///
/// THE PROCEDURES ARE THE RULES. Overlap, opening hours, lead times, person counts, deposit
/// arithmetic, status transitions, payment ceilings: all of it is enforced in SQL, inside the
/// transaction that also writes the row. This class carries parameters in and result sets out, and
/// deliberately re-checks nothing — a pre-flight check in C# would either duplicate a rule or,
/// worse, run outside the lock and answer a question that is already stale by the time the INSERT
/// runs.
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

    public async Task<BookingStatusChanged?> SetStatusAsync(int bookingId, string newStatus, int actedByUserId, string? reason)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<BookingStatusChanged>(
            "booking.usp_Booking_SetStatus",
            new
            {
                BookingId = bookingId,
                NewStatus = newStatus,
                ActedByUserId = actedByUserId,
                Reason = reason,
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

    /// <summary>
    /// ReadFirstOrDefault on the header, so an unknown booking id comes back as a receipt with no
    /// header rather than throwing — the controller turns that into a 404, which is the honest
    /// answer to "print booking 9999".
    /// </summary>
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

    public async Task QueueEmailAsync(int bookingId)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "booking.usp_Booking_QueueEmail",
            new { BookingId = bookingId },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>
    /// The list-to-string join the procedure's STRING_SPLIT needs, kept in the one place that knows
    /// the procedure exists.
    ///
    /// EMPTY BECOMES NULL, not "". The procedure tests `IS NOT NULL AND LTRIM(@AddonIds) &lt;&gt; ''`
    /// so both work today — but null is what "no add-ons" means, and passing an empty string relies
    /// on the second half of that test staying there.
    /// </summary>
    private static string? JoinAddonIds(List<int>? addonIds)
        => addonIds is null || addonIds.Count == 0
            ? null
            : string.Join(',', addonIds.Distinct());
}
