using MokaCo.HRMS.Model.Booking;

namespace MokaCo.HRMS.Repository.Booking;

/// <summary>
/// The rooms themselves — the catalogue, its opening hours and its price list — plus the
/// availability the public site paints its calendar from.
///
/// AVAILABILITY LIVES HERE RATHER THAN WITH THE BOOKINGS because it is a property of a ROOM: it is
/// the room's opening hours with the taken time punched out of it, and the caller asking for it is
/// asking about a room on a date, not about anybody's booking.
/// </summary>
public interface IRoomRepository
{
    /// <summary>
    /// The whole catalogue in one call (booking.usp_Room_GetAll): rooms, then every room's hours,
    /// then every room's add-ons.
    ///
    /// HOURS AND ADD-ONS ARE NOT FILTERED BY <paramref name="includeInactive"/> — the procedure
    /// returns all of them whatever the flag says. Trimming them to the rooms actually returned is
    /// the service's job, and the public feed does exactly that.
    /// </summary>
    Task<RoomCatalog> GetCatalogAsync(bool includeInactive);

    /// <summary>
    /// Inserts (roomId null) or updates a room, and returns the row AS STORED.
    ///
    /// A NEW ROOM IS BORN WITH SEVEN 09:00–22:00 DAYS, which the procedure inserts — so a room is
    /// bookable the moment it exists rather than being invisible until somebody notices its week is
    /// empty. Refusals (bad seats/price/deposit, a duplicate code) arrive as SqlException 50000.
    /// </summary>
    Task<Room?> UpsertRoomAsync(int? roomId, RoomUpsertRequest request);

    /// <summary>
    /// MERGEs one weekday's hours (booking.usp_Room_SetHours). Refuses a close time at or before the
    /// open time unless the day is marked closed.
    /// </summary>
    Task SetHoursAsync(int roomId, RoomHoursRequest request);

    /// <summary>Inserts (addonId null) or updates one add-on. Refuses a PriceType that is not PerHour or Fixed.</summary>
    Task UpsertAddonAsync(int? addonId, int roomId, RoomAddonUpsertRequest request);

    /// <summary>Every payment method, active or not — the caller filters, because a receipt must still name a method that has since been retired.</summary>
    Task<IEnumerable<PaymentMethod>> GetPaymentMethodsAsync();

    /// <summary>
    /// One room on one date: the day's hours and every stretch already taken
    /// (booking.usp_Availability_GetDay).
    ///
    /// Never null. A room with no hours row for that weekday comes back closed with nothing busy,
    /// which is the truthful answer rather than an error.
    /// </summary>
    Task<DayAvailability> GetDayAsync(int roomId, DateTime onDate);

    /// <summary>
    /// One room across the month containing <paramref name="monthDate"/>: open minutes against taken
    /// minutes, per day (booking.usp_Availability_GetMonth). Any date in the month will do.
    /// </summary>
    Task<IEnumerable<MonthDayAvailability>> GetMonthAsync(int roomId, DateTime monthDate);
}
