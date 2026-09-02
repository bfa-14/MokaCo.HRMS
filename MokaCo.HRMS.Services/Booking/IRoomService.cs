using MokaCo.HRMS.Model.Booking;

namespace MokaCo.HRMS.Services.Booking;

/// <summary>The room catalogue and the availability feed, for both the public site and the back office.</summary>
public interface IRoomService
{
    /// <summary>
    /// What an anonymous visitor may see: active rooms, their hours, and their ACTIVE add-ons only.
    ///
    /// The procedure returns every room's hours and add-ons whatever it was asked for, so the
    /// trimming happens here — otherwise the public feed would list add-ons that have been retired
    /// and hours belonging to rooms it did not return.
    /// </summary>
    Task<RoomCatalog> GetPublicCatalogAsync();

    /// <summary>The back-office catalogue: everything, retired rooms and inactive add-ons included.</summary>
    Task<RoomCatalog> GetCatalogAsync(bool includeInactive);

    Task<Room?> UpsertRoomAsync(int? roomId, RoomUpsertRequest request);

    /// <summary>
    /// Applies a whole week (or any subset of it) a day at a time, in DayOfWeek order.
    ///
    /// NOT A TRANSACTION, because usp_Room_SetHours is a per-day MERGE and there is no procedure that
    /// takes a week. A day that is refused therefore stops the run with the days before it already
    /// stored. Ordering by DayOfWeek is what makes that partial result comprehensible rather than
    /// arbitrary — the caller is told which day failed, and the days after it are the ones untouched.
    /// </summary>
    Task SetHoursAsync(int roomId, IEnumerable<RoomHoursRequest> hours);

    Task UpsertAddonAsync(int? addonId, int roomId, RoomAddonUpsertRequest request);

    /// <summary>Active payment methods only — the list is for CHOOSING one, and a retired method is not a choice.</summary>
    Task<IEnumerable<PaymentMethod>> GetActivePaymentMethodsAsync();

    Task<DayAvailability> GetDayAsync(int roomId, DateTime onDate);
    Task<IEnumerable<MonthDayAvailability>> GetMonthAsync(int roomId, DateTime monthDate);
}
