using System.Globalization;

namespace MokaCo.HRMS.Services.Attendance.AutoRoster;

/// <summary>
/// The calendar arithmetic the auto-roster agrees on with the database (D1): Monday–Sunday weeks,
/// ISO weekday 1 = Monday .. 7 = Sunday (EMPLOYEE_SHIFT_PATTERN.DayOfWeek and every Monday-first
/// mask), and a week index counted from 1900-01-01 — a Monday, and the date the SQL side uses in
/// DATEDIFF(DAY,'19000101',d)/7 — so the index never resets at a month or year end and the 6/5
/// parity carries on across months.
/// </summary>
public static class RosterCalendar
{
    /// <summary>1900-01-01, a Monday: week 0.</summary>
    public static readonly DateOnly Epoch = new(1900, 1, 1);

    /// <summary>W(d) = (d − 1900-01-01) div 7, floored so a date before the epoch is not folded into week 0.</summary>
    public static int WeekIndex(DateOnly date) => FloorDiv(date.DayNumber - Epoch.DayNumber, 7);

    public static DateOnly WeekStartOf(int weekIndex) => Epoch.AddDays(weekIndex * 7);

    /// <summary>1 = Monday .. 7 = Sunday, whatever the culture says the first day is.</summary>
    public static int IsoDayOfWeek(DateOnly date) => date.DayOfWeek == DayOfWeek.Sunday ? 7 : (int)date.DayOfWeek;

    /// <summary>The Monday on or before the date.</summary>
    public static DateOnly WeekStart(DateOnly date) => date.AddDays(1 - IsoDayOfWeek(date));

    public static bool IsSaturday(DateOnly date) => date.DayOfWeek == DayOfWeek.Saturday;
    public static bool IsSunday(DateOnly date) => date.DayOfWeek == DayOfWeek.Sunday;
    public static bool IsWeekend(DateOnly date) => IsSaturday(date) || IsSunday(date);

    public static DateOnly MonthStart(DateOnly date) => new(date.Year, date.Month, 1);
    public static DateOnly MonthEnd(DateOnly monthStart) => MonthStart(monthStart).AddMonths(1).AddDays(-1);

    /// <summary>
    /// The planning window of a month: the Monday on/before the 1st to the Sunday on/after the last
    /// day. November 2026 starts on a Sunday, so its window opens on Monday 26 October.
    /// </summary>
    public static (DateOnly From, DateOnly To) Window(DateOnly anyDayOfMonth)
    {
        var first = MonthStart(anyDayOfMonth);
        var last = MonthEnd(first);
        return (WeekStart(first), WeekStart(last).AddDays(6));
    }

    /// <summary>
    /// The 6/5 type of a week: the anchor's own type in weeks an even distance from the anchor, the
    /// other one (11 − type) otherwise. The distance may be negative — a month planned before the
    /// stored anchor — so the parity is taken with a non-negative modulo; C#'s -1 % 2 is -1.
    /// </summary>
    public static int WorkDaysInWeek(int anchorWeekIndex, int anchorWorkDays, int weekIndex)
        => Mod(weekIndex - anchorWeekIndex, 2) == 0 ? anchorWorkDays : 11 - anchorWorkDays;

    /// <summary>"2026-12" (or a full "2026-12-01") → the 1st of that month.</summary>
    public static bool TryParseMonth(string? text, out DateOnly monthStart)
    {
        monthStart = default;
        if (string.IsNullOrWhiteSpace(text))
            return false;

        var s = text.Trim();
        if (DateOnly.TryParseExact(s, "yyyy-MM", CultureInfo.InvariantCulture, DateTimeStyles.None, out var month)
            || DateOnly.TryParseExact(s, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out month))
        {
            monthStart = MonthStart(month);
            return true;
        }

        return false;
    }

    /// <summary>Every date from..to inclusive, in calendar order.</summary>
    public static IEnumerable<DateOnly> Days(DateOnly from, DateOnly to)
    {
        for (var d = from; d <= to; d = d.AddDays(1))
            yield return d;
    }

    /// <summary>A modulo that is never negative.</summary>
    public static int Mod(int value, int modulus) => ((value % modulus) + modulus) % modulus;

    private static int FloorDiv(int a, int b) => a >= 0 ? a / b : -((-a + b - 1) / b);
}
