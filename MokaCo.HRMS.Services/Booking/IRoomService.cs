using MokaCo.HRMS.Model.Booking;

namespace MokaCo.HRMS.Services.Booking;

/// <summary>The room catalogue and the availability feed, for both the public site and the back office.</summary>
public interface IRoomService
{
    /// <summary>
    /// What an anonymous visitor may see: active rooms with their week, their ACTIVE add-ons and
    /// their resolved discount ladder, the deposit tiers, and the rules — one object, one call.
    /// </summary>
    Task<PublicCatalog> GetPublicCatalogAsync();

    /// <summary>The back-office catalogue: everything, retired rooms and inactive add-ons included.</summary>
    Task<RoomCatalog> GetCatalogAsync(bool includeInactive);

    Task<Room?> UpsertRoomAsync(int? roomId, RoomUpsertRequest request);

    /// <summary>Applies a whole week (or any subset) a day at a time, in DayOfWeek order. NOT a transaction — see the implementation.</summary>
    Task SetHoursAsync(int roomId, IEnumerable<RoomHoursRequest> hours);

    Task UpsertAddonAsync(int? addonId, int roomId, RoomAddonUpsertRequest request);

    /// <summary>Active payment methods only — the list is for CHOOSING one.</summary>
    Task<IEnumerable<PaymentMethod>> GetActivePaymentMethodsAsync();

    /// <summary>
    /// One room (by code) on one date: the frame in minutes, the taken ranges, the FREE ranges and
    /// the earliest start the lead time allows. Null for an unknown room code.
    /// </summary>
    Task<DayAvailability?> GetPublicDayAsync(string roomCode, DateTime onDate);

    /// <summary>One room's month reduced to one word per day. Null for an unknown room code.</summary>
    Task<MonthAvailability?> GetPublicMonthAsync(string roomCode, DateTime monthDate);
}
