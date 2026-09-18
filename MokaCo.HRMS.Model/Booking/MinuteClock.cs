namespace MokaCo.HRMS.Model.Booking;

/// <summary>
/// The one conversion between the website's MINUTES FROM MIDNIGHT and the two TIME(0) parameters
/// booking.usp_Booking_Create still takes.
///
/// BUG-22 LIVES HERE. A 22:00–01:00 booking is startMin 1320, endMin 1500. The procedure wants
/// @StartTime = 22:00 and @EndTime = 01:00, and works out for itself that an end at or before the
/// start means "the next morning" (it adds 1440). So the end is reduced MODULO 1440 for the wire
/// and NEVER compared with the start as a clock time — the "end must be after start" check is made
/// on the minutes, where 1500 &gt; 1320 is simply true.
/// </summary>
public static class MinuteClock
{
    /// <summary>The latest an end may be: 30 hours from midnight, matching usp_Booking_Validate's own bound.</summary>
    public const int MaxEndMin = 1800;

    public static TimeSpan StartTime(int startMin) => TimeSpan.FromMinutes(startMin);

    /// <summary>1500 → 01:00. The procedure re-adds the day when the end is not after the start.</summary>
    public static TimeSpan EndTime(int endMin) => TimeSpan.FromMinutes(endMin % 1440);

    /// <summary>The reverse, for rows that only carry the two TIMEs: an end at or before the start is the next day.</summary>
    public static int EndMinOf(TimeSpan startTime, TimeSpan endTime)
        => (endTime <= startTime ? 1440 : 0) + (int)endTime.TotalMinutes;
}
