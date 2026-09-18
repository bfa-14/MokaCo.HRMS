using System.Data;
using Dapper;
using MokaCo.HRMS.Model.Booking;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.Booking;

/// <summary>
/// Dapper access to the room catalogue and the availability feed, entirely through the
/// booking.usp_Room_* / booking.usp_Availability_* / booking.usp_Public_* procedures.
///
/// NOT ONE LINE OF SQL IS WRITTEN HERE. Every rule these calls are subject to lives in the procedure
/// and reaches the caller as SqlException 50000 with its own wording intact.
/// </summary>
public class RoomRepository : IRoomRepository
{
    private readonly IDbConnectionFactory _factory;
    public RoomRepository(IDbConnectionFactory factory) => _factory = factory;

    public async Task<RoomCatalog> GetCatalogAsync(bool includeInactive)
    {
        using var db = _factory.Create();
        using var multi = await db.QueryMultipleAsync(
            "booking.usp_Room_GetAll",
            new { IncludeInactive = includeInactive },
            commandType: CommandType.StoredProcedure);

        return new RoomCatalog
        {
            Rooms = (await multi.ReadAsync<Room>()).ToList(),
            Hours = (await multi.ReadAsync<RoomHours>()).ToList(),
            Addons = (await multi.ReadAsync<RoomAddon>()).ToList(),
        };
    }

    /// <summary>
    /// Six result sets, read in the order the procedure writes them (a GridReader has no way back).
    /// ReadSingle on the rules — there is exactly one row and its absence would be a broken
    /// procedure, not a case to handle.
    /// </summary>
    public async Task<PublicCatalogSets> GetPublicCatalogSetsAsync()
    {
        using var db = _factory.Create();
        using var multi = await db.QueryMultipleAsync(
            "booking.usp_Public_GetCatalog",
            commandType: CommandType.StoredProcedure);

        return new PublicCatalogSets
        {
            Rooms = (await multi.ReadAsync<PublicRoom>()).ToList(),
            Hours = (await multi.ReadAsync<PublicRoomHours>()).ToList(),
            Addons = (await multi.ReadAsync<PublicRoomAddon>()).ToList(),
            Tiers = (await multi.ReadAsync<DepositTier>()).ToList(),
            Rules = await multi.ReadSingleAsync<BookingRules>(),
            Discounts = (await multi.ReadAsync<CatalogRoomDiscount>()).ToList(),
        };
    }

    /// <summary>
    /// QuerySingleOrDefault, not QuerySingle: on a refusal the procedure RAISERRORs and RETURNs
    /// without producing a result set, and QuerySingle would raise "sequence contains no elements"
    /// over the top of the message that is the whole value of the failure.
    /// </summary>
    public async Task<Room?> UpsertRoomAsync(int? roomId, RoomUpsertRequest request)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<Room>(
            "booking.usp_Room_Upsert",
            new
            {
                RoomId = roomId,
                request.Code,
                request.Name,
                request.NameAr,
                request.Seats,
                request.MinPersons,
                request.PricePerHour,
                request.CurrencyCode,
                request.DepositPercent,
                request.MinHours,
                request.MaxHours,
                request.Description,
                request.Features,
                request.PolicyText,
                request.PhotoKey,
                request.SortOrder,
                request.IsActive,
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task SetHoursAsync(int roomId, RoomHoursRequest request)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "booking.usp_Room_SetHours",
            new
            {
                RoomId = roomId,
                request.DayOfWeek,
                request.OpenTime,
                request.CloseTime,
                request.IsClosed,
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task UpsertAddonAsync(int? addonId, int roomId, RoomAddonUpsertRequest request)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "booking.usp_RoomAddon_Upsert",
            new
            {
                AddonId = addonId,
                RoomId = roomId,
                request.Name,
                request.PriceType,
                request.Price,
                request.IsActive,
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<PaymentMethod>> GetPaymentMethodsAsync()
    {
        using var db = _factory.Create();
        return await db.QueryAsync<PaymentMethod>(
            "booking.usp_PaymentMethod_GetAll",
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>
    /// Two result sets: the frame (RoomId, RoomCode, OnDate, IsClosed, OpenMin, CloseMin, the rules
    /// and LocalNow — Dapper maps them by name onto <see cref="DayAvailability"/>) and the taken
    /// ranges as StartMin/EndMin. The frame is EMPTY for an unknown room code, hence the null.
    /// </summary>
    public async Task<DayAvailability?> GetDayAsync(string roomCode, DateTime onDate)
    {
        using var db = _factory.Create();
        using var multi = await db.QueryMultipleAsync(
            "booking.usp_Availability_GetDay",
            new { RoomId = (int?)null, RoomCode = roomCode, OnDate = onDate.Date },
            commandType: CommandType.StoredProcedure);

        var day = await multi.ReadFirstOrDefaultAsync<DayAvailability>();
        if (day is null)
            return null;

        day.Taken = (await multi.ReadAsync<TakenRange>()).ToList();
        return day;
    }

    public async Task<IEnumerable<MonthDayAvailability>> GetMonthAsync(string roomCode, DateTime monthDate)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<MonthDayAvailability>(
            "booking.usp_Availability_GetMonth",
            new { RoomId = (int?)null, RoomCode = roomCode, MonthDate = monthDate.Date },
            commandType: CommandType.StoredProcedure);
    }
}
