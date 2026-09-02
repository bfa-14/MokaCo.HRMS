namespace MokaCo.HRMS.Model.Booking;

/// <summary>
/// Maps to booking.ROOM — one bookable space, and the price list for it.
///
/// A ROOM CARRIES ITS OWN RULES rather than deferring to global settings, because the rules are
/// genuinely per-room: the podcast booth is not rented in the same minimum block as a meeting room.
/// MinHours/MaxHours are nullable precisely so that "no opinion" is expressible — booking.usp_Booking_Create
/// falls back to core.SETTING BookingMinHours / BookingMaxHours when they are null, and a room that
/// stored a 1 would be indistinguishable from one that wanted the default.
/// </summary>
public class Room
{
    public int RoomId { get; set; }

    /// <summary>The short slug the website uses in a URL. Unique — usp_Room_Upsert refuses a duplicate.</summary>
    public string Code { get; set; } = string.Empty;

    public string Name { get; set; } = string.Empty;

    /// <summary>The Arabic name for the RTL side of the site. Null falls back to <see cref="Name"/>.</summary>
    public string? NameAr { get; set; }

    /// <summary>The upper bound on Persons. A booking for more than this is refused by the procedure.</summary>
    public int Seats { get; set; }

    public int MinPersons { get; set; }

    public decimal PricePerHour { get; set; }
    public string CurrencyCode { get; set; } = string.Empty;

    /// <summary>
    /// What share of the total is due up front, as a percentage. Stored rather than derived because
    /// it differs per room, and it is what DepositDue on a booking was computed from — changing it
    /// later must not retroactively restate what a guest was told to pay.
    /// </summary>
    public decimal DepositPercent { get; set; }

    /// <summary>Null = use core.SETTING BookingMinHours.</summary>
    public int? MinHours { get; set; }

    /// <summary>Null = use core.SETTING BookingMaxHours.</summary>
    public int? MaxHours { get; set; }

    public string? Description { get; set; }

    /// <summary>Free text the site renders as a list — "Whiteboard, 55&quot; screen, coffee".</summary>
    public string? Features { get; set; }

    /// <summary>The cancellation/deposit terms. Printed on the receipt, so it is stored per room, not global.</summary>
    public string? PolicyText { get; set; }

    public string? PhotoKey { get; set; }

    public int SortOrder { get; set; }
    public bool IsActive { get; set; }

    /// <summary>
    /// Live bookings from today onward (usp_Room_GetAll only). This is the number that makes
    /// deactivating a room an informed act rather than a guess — it is not stored on the table, so
    /// it stays 0 on the row usp_Room_Upsert echoes back.
    /// </summary>
    public int FutureBookings { get; set; }
}

/// <summary>
/// One weekday's opening hours for one room (booking.ROOM_HOURS).
///
/// DayOfWeek IS 1=MONDAY..7=SUNDAY, computed in SQL as ((DATEPART(WEEKDAY,d)+@@DATEFIRST-2)%7)+1 so
/// that it does not move with the server's DATEFIRST. It is NOT System.DayOfWeek, where Sunday is 0 —
/// converting between the two is the client's job and getting it wrong silently shifts a whole week.
/// </summary>
public class RoomHours
{
    public int RoomId { get; set; }

    /// <summary>1 = Monday … 7 = Sunday.</summary>
    public byte DayOfWeek { get; set; }

    public TimeSpan OpenTime { get; set; }
    public TimeSpan CloseTime { get; set; }

    /// <summary>Closed all day. The times are still stored, so re-opening a day restores its old hours.</summary>
    public bool IsClosed { get; set; }
}

/// <summary>
/// A paid extra that can be attached to a booking of one room (booking.ROOM_ADDON).
///
/// PriceType is 'PerHour' or 'Fixed', and the difference is settled at booking time: the procedure
/// multiplies a PerHour add-on by the booked duration and COPIES the resulting amount onto
/// booking.BOOKING_ADDON. Re-pricing an add-on therefore never disturbs a booking already taken.
/// </summary>
public class RoomAddon
{
    public int AddonId { get; set; }
    public int RoomId { get; set; }
    public string Name { get; set; } = string.Empty;

    /// <summary>'PerHour' or 'Fixed'.</summary>
    public string PriceType { get; set; } = string.Empty;

    public decimal Price { get; set; }
    public bool IsActive { get; set; }
}

/// <summary>
/// The three result sets of booking.usp_Room_GetAll in one object: the rooms, every room's hours and
/// every room's add-ons.
///
/// THEY TRAVEL TOGETHER BECAUSE THEY ARE USELESS APART. A room with no hours cannot be offered a
/// slot and a room with no add-on list cannot be priced, so a client that fetched only the rooms
/// would immediately have to fetch the rest — which is exactly the round trip the procedure exists
/// to avoid. Hours and Addons are flat lists keyed by RoomId, not nested, because that is the shape
/// the procedure returns and re-shaping it here would only invent a second thing to keep in sync.
/// </summary>
public class RoomCatalog
{
    public List<Room> Rooms { get; set; } = [];
    public List<RoomHours> Hours { get; set; } = [];
    public List<RoomAddon> Addons { get; set; } = [];
}

/// <summary>A way to pay (booking.PAYMENT_METHOD). IsOnline marks the ones the website could collect through.</summary>
public class PaymentMethod
{
    public int PaymentMethodId { get; set; }
    public string Name { get; set; } = string.Empty;
    public bool IsOnline { get; set; }
    public bool IsActive { get; set; }
}
