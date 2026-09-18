namespace MokaCo.HRMS.Model.Booking;

/// <summary>
/// A busy stretch of one room on one day, from booking.usp_Availability_GetDay.
///
/// MINUTES FROM MIDNIGHT OF THE BOOKING DATE, not clock times (BUG-23: the procedure returns
/// StartMin/EndMin, and the old mapping to StartTime/EndTime read columns that do not exist). A room
/// that closes at 01:00 is open across a date boundary, and TimeSpan-of-day arithmetic on that
/// produces an end BEFORE its start — 23:00–01:00 becomes 1380–60. EndMin simply keeps counting:
/// 01:00 the next morning is 1500. BOOKING.StartMin/EndMin are PERSISTED, so C# never redoes the wrap.
///
/// A REAL BOOKING AND A STAFF BLOCK ARE THE SAME THING HERE, deliberately: the procedure UNIONs them
/// and the public site paints both as unavailable.
/// </summary>
public class TakenRange
{
    /// <summary>Minutes from midnight of the booking date. 0–1439.</summary>
    public int StartMin { get; set; }

    /// <summary>Minutes from midnight of the booking date. MAY EXCEED 1440 — 01:00 next day is 1500.</summary>
    public int EndMin { get; set; }
}

/// <summary>
/// A stretch the site may offer, computed by subtracting the taken ranges (plus the turnaround
/// after each) from the day's opening hours. NOT STORED ANYWHERE and NOT A RESERVATION — the
/// authority on whether a slot is still free is the overlap check inside usp_Booking_Create.
/// </summary>
public class FreeRange
{
    public int StartMin { get; set; }
    public int EndMin { get; set; }
}

/// <summary>
/// What one room looks like on one date: the frame (usp_Availability_GetDay set 1, in MINUTES) and
/// the taken ranges (set 2), plus what the service derives from them.
///
/// <see cref="IsClosed"/> DEFAULTS TO TRUE: a missing hours row means the weekday was never
/// configured, and the safe reading of "we do not know" is "do not offer slots".
/// </summary>
public class DayAvailability
{
    public int RoomId { get; set; }
    public string RoomCode { get; set; } = string.Empty;
    public DateTime OnDate { get; set; }

    /// <summary>True when the day is marked closed, has no hours row, or falls outside the booking window.</summary>
    public bool IsClosed { get; set; } = true;

    /// <summary>Null when the room has no hours row for that weekday.</summary>
    public int? OpenMin { get; set; }

    /// <summary>Null when the room has no hours row for that weekday. May exceed 1440 (a 01:00 close is 1500).</summary>
    public int? CloseMin { get; set; }

    public int SlotMinutes { get; set; }
    public int MinHours { get; set; }
    public int MaxHours { get; set; }
    public int LeadMinHours { get; set; }
    public int LeadMaxDays { get; set; }

    /// <summary>core.SETTING BookingTurnaroundMinutes — not returned by the procedure; the service fills it in.</summary>
    public int TurnaroundMinutes { get; set; }

    /// <summary>Café-local wall clock, from booking.fn_LocalNow(). NOT the visitor's clock and not the server's.</summary>
    public DateTime LocalNow { get; set; }

    /// <summary>
    /// The first minute the site may offer: opening time on any other day, and on today the lead
    /// time added to <see cref="LocalNow"/> and rounded UP to the next slot.
    /// </summary>
    public int EarliestStartMin { get; set; }

    public List<TakenRange> Taken { get; set; } = [];

    /// <summary>[OpenMin, CloseMin) minus Taken (+ turnaround after each), trimmed to EarliestStartMin, pieces shorter than MinHours × 60 dropped.</summary>
    public List<FreeRange> Free { get; set; } = [];
}

/// <summary>One day of the month heat map (booking.usp_Availability_GetMonth), exactly as the procedure returns it. MINUTES, NOT A PERCENTAGE.</summary>
public class MonthDayAvailability
{
    public DateTime OnDate { get; set; }

    /// <summary>Closed, or never configured for that weekday. OpenMinutes is 0 in both cases.</summary>
    public bool IsClosed { get; set; }

    public int OpenMinutes { get; set; }

    /// <summary>Minutes already held by live bookings plus staff blocks. Expired payment holds do not count.</summary>
    public int TakenMinutes { get; set; }

    /// <summary>The longest uninterrupted free stretch. Below MinHours × 60 the day is full whatever the totals say.</summary>
    public int MaxFreeRun { get; set; }
}

/// <summary>One day as the website's calendar paints it: past | unavailable | closed | full | partial | open, decided server-side.</summary>
public class MonthDayStatus
{
    public DateTime Date { get; set; }
    public string Status { get; set; } = string.Empty;
}

/// <summary>A room's month, ready to paint. <see cref="Month"/> is 'YYYY-MM', echoed back so a late response cannot be applied to the wrong month.</summary>
public class MonthAvailability
{
    public string RoomCode { get; set; } = string.Empty;
    public string Month { get; set; } = string.Empty;
    public List<MonthDayStatus> Days { get; set; } = [];
}
