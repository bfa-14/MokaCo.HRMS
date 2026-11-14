namespace MokaCo.HRMS.Services.Attendance;

/// <summary>
/// A from-to range of days for the actions that work one day at a time (punches, re-process, mark absentees).
/// At most <see cref="MaxDays"/> days: a month at once, never an unbounded read of the raw log.
/// </summary>
public static class DayRange
{
    public const int MaxDays = 31;

    /// <summary>The problem with a range, in a sentence, or null when it is usable.</summary>
    public static string? Problem(DateTime from, DateTime to)
    {
        if (to.Date < from.Date) return "The end of the period must be on or after its start.";
        if ((to.Date - from.Date).TotalDays + 1 > MaxDays) return $"Choose at most {MaxDays} days at a time.";
        return null;
    }

    public static IEnumerable<DateTime> Days(DateTime from, DateTime to)
    {
        for (var d = from.Date; d <= to.Date; d = d.AddDays(1)) yield return d;
    }
}
