using MokaCo.HRMS.Model.Booking;

namespace MokaCo.HRMS.Repository.Booking;

/// <summary>
/// The rooms themselves — the catalogue, its opening hours and its price list — plus the
/// availability the public site paints its calendar from.
///
/// AVAILABILITY LIVES HERE RATHER THAN WITH THE BOOKINGS because it is a property of a ROOM: it is
/// the room's opening hours with the taken time punched out of it.
///
/// EVERY TIME COLUMN THE AVAILABILITY PROCEDURES RETURN IS MINUTES FROM MIDNIGHT — OpenMin,
/// CloseMin, StartMin, EndMin. BUG-23 was a mapping to OpenTime/StartTime columns that do not exist.
/// </summary>
public interface IRoomRepository
{
    /// <summary>The back-office catalogue (booking.usp_Room_GetAll): rooms, then every room's hours, then every room's add-ons.</summary>
    Task<RoomCatalog> GetCatalogAsync(bool includeInactive);

    /// <summary>The six result sets of booking.usp_Public_GetCatalog: rooms, hours, add-ons, deposit tiers, rules, discounts. Active rooms only.</summary>
    Task<PublicCatalogSets> GetPublicCatalogSetsAsync();

    Task<Room?> UpsertRoomAsync(int? roomId, RoomUpsertRequest request);
    Task SetHoursAsync(int roomId, RoomHoursRequest request);
    Task UpsertAddonAsync(int? addonId, int roomId, RoomAddonUpsertRequest request);

    /// <summary>Every payment method, active or not — the caller filters.</summary>
    Task<IEnumerable<PaymentMethod>> GetPaymentMethodsAsync();

    /// <summary>
    /// One room on one date (booking.usp_Availability_GetDay by room CODE): the day's frame with the
    /// rules, and every stretch already taken. NULL FOR AN UNKNOWN CODE — the procedure selects no
    /// frame row — which the caller turns into a 404. A room that exists but has no hours row for
    /// that weekday DOES produce a frame, closed.
    /// </summary>
    Task<DayAvailability?> GetDayAsync(string roomCode, DateTime onDate);

    /// <summary>One room across the month containing <paramref name="monthDate"/> (booking.usp_Availability_GetMonth by room code).</summary>
    Task<IEnumerable<MonthDayAvailability>> GetMonthAsync(string roomCode, DateTime monthDate);
}
