namespace MokaCo.HRMS.Model.Booking;

/// <summary>
/// A busy stretch of one room on one day, from booking.usp_Availability_GetDay.
///
/// A REAL BOOKING AND A STAFF BLOCK ARE THE SAME THING HERE, deliberately: the procedure UNIONs them
/// and the public site paints both as unavailable. Telling an anonymous visitor which is which would
/// leak who booked what and when the room is merely being held back, and neither is any of their
/// business — the manager's calendar (usp_Booking_GetForRange) is where the two are distinguished.
/// </summary>
public class BusyInterval
{
    public TimeSpan StartTime { get; set; }
    public TimeSpan EndTime { get; set; }
}

/// <summary>
/// What one room looks like on one date: when it is open, and what is already taken inside that.
///
/// FLATTENED FROM TWO RESULT SETS. The procedure returns the day's ROOM_HOURS row — which may not
/// exist at all — and then the busy intervals. A missing hours row means the room has never had that
/// weekday configured, which for booking purposes is identical to being closed, so
/// <see cref="IsClosed"/> DEFAULTS TO TRUE: the safe reading of "we do not know" is "do not offer
/// slots", never "open all day".
/// </summary>
public class DayAvailability
{
    /// <summary>Null when the room has no hours row for that weekday — see <see cref="IsClosed"/>.</summary>
    public TimeSpan? OpenTime { get; set; }

    /// <summary>Null when the room has no hours row for that weekday.</summary>
    public TimeSpan? CloseTime { get; set; }

    /// <summary>True when the day is marked closed OR has no hours row at all.</summary>
    public bool IsClosed { get; set; } = true;

    public List<BusyInterval> Busy { get; set; } = [];
}

/// <summary>
/// One day of the month heat map (booking.usp_Availability_GetMonth).
///
/// MINUTES, NOT A PERCENTAGE. The procedure hands over the two raw numbers and leaves the ratio to
/// the caller, because the interesting cases are the ones a percentage erases: OpenMinutes = 0 is a
/// closed day, not a 0% busy one, and TakenMinutes can reach OpenMinutes exactly — "full" — which
/// the site colours differently from "busy".
/// </summary>
public class MonthDayAvailability
{
    public DateTime OnDate { get; set; }

    /// <summary>Closed, or never configured for that weekday. OpenMinutes is 0 in both cases.</summary>
    public bool IsClosed { get; set; }

    public int OpenMinutes { get; set; }

    /// <summary>Minutes already held by bookings (Pending or Confirmed) plus staff blocks.</summary>
    public int TakenMinutes { get; set; }
}
