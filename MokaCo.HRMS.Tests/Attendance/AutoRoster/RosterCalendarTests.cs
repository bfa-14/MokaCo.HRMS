using MokaCo.HRMS.Services.Attendance.AutoRoster;

namespace MokaCo.HRMS.Tests.Attendance.AutoRoster;

/// <summary>D1: Monday–Sunday weeks numbered from 1900-01-01 (a Monday), ISO weekdays, the month window.</summary>
public class RosterCalendarTests
{
    [Fact]
    public void Week_zero_is_the_week_of_1900_01_01_a_Monday()
    {
        Assert.Equal(DayOfWeek.Monday, RosterCalendar.Epoch.DayOfWeek);
        Assert.Equal(0, RosterCalendar.WeekIndex(new DateOnly(1900, 1, 1)));
        Assert.Equal(0, RosterCalendar.WeekIndex(new DateOnly(1900, 1, 7)));
        Assert.Equal(1, RosterCalendar.WeekIndex(new DateOnly(1900, 1, 8)));
        Assert.Equal(-1, RosterCalendar.WeekIndex(new DateOnly(1899, 12, 31)));
    }

    [Fact]
    public void The_week_index_matches_the_SQL_datediff_div_7_and_never_resets_at_a_year_end()
    {
        // DATEDIFF(DAY,'19000101','2026-12-28')/7 — the Monday of the week holding New Year 2027.
        var monday = new DateOnly(2026, 12, 28);
        Assert.Equal((monday.DayNumber - new DateOnly(1900, 1, 1).DayNumber) / 7, RosterCalendar.WeekIndex(monday));
        Assert.Equal(RosterCalendar.WeekIndex(monday), RosterCalendar.WeekIndex(new DateOnly(2027, 1, 3)));
        Assert.Equal(RosterCalendar.WeekIndex(monday) + 1, RosterCalendar.WeekIndex(new DateOnly(2027, 1, 4)));
    }

    [Theory]
    [InlineData("2026-10-26", 1)]
    [InlineData("2026-10-31", 6)]
    [InlineData("2026-11-01", 7)]
    public void Iso_weekday_runs_Monday_1_to_Sunday_7(string date, int expected)
        => Assert.Equal(expected, RosterCalendar.IsoDayOfWeek(DateOnly.Parse(date)));

    [Theory]
    [InlineData("2026-11", "2026-10-26", "2026-12-06")]   // starts on a Sunday: a one-day first week
    [InlineData("2026-06", "2026-06-01", "2026-07-05")]   // starts on a Monday
    [InlineData("2026-02", "2026-01-26", "2026-03-01")]   // February 2026 starts on a Sunday too
    [InlineData("2026-12", "2026-11-30", "2027-01-03")]
    public void The_window_is_whole_weeks_around_the_month(string month, string from, string to)
    {
        Assert.True(RosterCalendar.TryParseMonth(month, out var start));
        var (f, t) = RosterCalendar.Window(start);
        Assert.Equal(DateOnly.Parse(from), f);
        Assert.Equal(DateOnly.Parse(to), t);
        Assert.Equal(DayOfWeek.Monday, f.DayOfWeek);
        Assert.Equal(DayOfWeek.Sunday, t.DayOfWeek);
    }

    [Fact]
    public void The_6_5_type_alternates_from_the_anchor_in_both_directions()
    {
        var anchor = RosterCalendar.WeekIndex(new DateOnly(2026, 12, 7));
        Assert.Equal(6, RosterCalendar.WorkDaysInWeek(anchor, 6, anchor));
        Assert.Equal(5, RosterCalendar.WorkDaysInWeek(anchor, 6, anchor + 1));
        Assert.Equal(6, RosterCalendar.WorkDaysInWeek(anchor, 6, anchor + 2));

        // A week BEFORE the anchor (a month planned before the stored anchor): -1 % 2 is -1 in C#,
        // and a naive parity test would call this a 6-day week.
        Assert.Equal(5, RosterCalendar.WorkDaysInWeek(anchor, 6, anchor - 1));
        Assert.Equal(6, RosterCalendar.WorkDaysInWeek(anchor, 6, anchor - 2));
        Assert.Equal(6, RosterCalendar.WorkDaysInWeek(anchor, 5, anchor - 3));
    }

    [Theory]
    [InlineData("2026-12", true)]
    [InlineData("2026-12-01", true)]
    [InlineData("12/2026", false)]
    [InlineData("", false)]
    [InlineData(null, false)]
    public void Months_parse_as_yyyy_MM(string? text, bool ok)
    {
        Assert.Equal(ok, RosterCalendar.TryParseMonth(text, out var month));
        if (ok)
            Assert.Equal(new DateOnly(2026, 12, 1), month);
    }

    [Fact]
    public void Mod_is_never_negative()
    {
        Assert.Equal(1, RosterCalendar.Mod(-1, 2));
        Assert.Equal(0, RosterCalendar.Mod(-4, 2));
        Assert.Equal(3, RosterCalendar.Mod(-4, 7));
    }
}
