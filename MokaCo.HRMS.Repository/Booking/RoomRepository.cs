using System.Data;
using Dapper;
using MokaCo.HRMS.Model.Booking;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.Booking;

/// <summary>
/// Dapper access to the room catalogue and the availability feed, entirely through the
/// booking.usp_Room_* / booking.usp_Availability_* procedures.
///
/// NOT ONE LINE OF SQL IS WRITTEN HERE. Every rule these calls are subject to — a duplicate room
/// code, a close time before an open time, a price type that is not PerHour or Fixed — lives in the
/// procedure and reaches the caller as SqlException 50000 with its own wording intact. A validation
/// re-implemented in C# would be a second opinion that drifts.
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
    /// QuerySingleOrDefault, not QuerySingle: on a refusal the procedure RAISERRORs and RETURNs
    /// without producing a result set at all. Both forms surface the SqlException, but QuerySingle
    /// would be able to raise "sequence contains no elements" over the top of it, and the
    /// procedure's message is the whole value of the failure.
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
    /// Two result sets flattened into one answer. The FIRST MAY BE EMPTY — a room that has never had
    /// that weekday configured has no ROOM_HOURS row — and an empty first set means closed, which is
    /// what <see cref="DayAvailability"/> already defaults to. Reading it with ReadFirstOrDefault is
    /// what makes the missing row an ordinary case instead of an exception.
    /// </summary>
    public async Task<DayAvailability> GetDayAsync(int roomId, DateTime onDate)
    {
        using var db = _factory.Create();
        using var multi = await db.QueryMultipleAsync(
            "booking.usp_Availability_GetDay",
            new { RoomId = roomId, OnDate = onDate.Date },
            commandType: CommandType.StoredProcedure);

        var hours = await multi.ReadFirstOrDefaultAsync<DayHoursRow>();
        var busy = (await multi.ReadAsync<BusyInterval>()).ToList();

        return new DayAvailability
        {
            OpenTime = hours?.OpenTime,
            CloseTime = hours?.CloseTime,
            IsClosed = hours is null || hours.IsClosed,
            Busy = busy,
        };
    }

    public async Task<IEnumerable<MonthDayAvailability>> GetMonthAsync(int roomId, DateTime monthDate)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<MonthDayAvailability>(
            "booking.usp_Availability_GetMonth",
            new { RoomId = roomId, MonthDate = monthDate.Date },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>
    /// The shape of usp_Availability_GetDay's first result set, and nothing else — which is why it is
    /// private to this file rather than a model. The public answer is the flattened
    /// <see cref="DayAvailability"/>; a caller has no use for a hours-row-that-might-not-exist.
    /// </summary>
    private sealed class DayHoursRow
    {
        public TimeSpan OpenTime { get; set; }
        public TimeSpan CloseTime { get; set; }
        public bool IsClosed { get; set; }
    }
}
