using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Services.Attendance.AutoRoster;

namespace MokaCo.HRMS.Tests.Attendance.AutoRoster;

/// <summary>D4 / §2.4 public holidays and D5 leave.</summary>
public class RosterPlannerHolidayLeaveTests
{
    private static readonly DateOnly Dec = new(2026, 12, 1);
    private static readonly DateOnly Christmas = new(2026, 12, 25);   // a Friday
    private static readonly DateOnly Week21 = new(2026, 12, 21);

    /* ---- holidays ---- */

    [Fact]
    public void A_closed_holiday_has_no_row_is_never_a_rest_and_is_an_extra_day_off()
    {
        var world = new RosterWorld().WithStaff(5);
        world.Holiday(Christmas, "Christmas");
        world.Min(3);
        var p = world.Plan(Dec).Preview;

        Assert.All(Enumerable.Range(1, 5), e =>
        {
            var cell = p.Cell(e, Christmas);
            Assert.Equal("none", cell.State);
            Assert.Equal("holiday", cell.Origin);
            Assert.Equal("HOLIDAY_OFF", cell.ReasonCode);
            Assert.Equal("unchanged", cell.Change);

            // The holiday does not use up the week's rest days (RosterHolidayCountsAsRest = 0).
            var week = p.Week(e, Week21);
            Assert.Equal(7 - week.WorkDays, week.Quota);
            Assert.Equal(week.Quota, week.Rests);
        });

        Assert.Empty(p.Issues.WithCode("REST_ON_HOLIDAY"));
        // A closed holiday is closed, not short-staffed: its minimum is the cover asked for (0).
        Assert.DoesNotContain(p.Issues, i => i.Code == "SHORT_STAFFED" && i.Date == Christmas);
        Assert.Equal(0, p.PerDay.Single(d => d.Date == Christmas).Min);
    }

    [Fact]
    public void Holiday_cover_goes_to_the_people_who_worked_the_fewest_holidays()
    {
        var world = new RosterWorld().WithStaff(6);
        var labour = new DateOnly(2026, 5, 1);
        var assumption = new DateOnly(2026, 8, 15);
        world.Holiday(labour, "Labour Day");
        world.Holiday(assumption, "Assumption");
        foreach (var e in new[] { 1, 2 }) { world.Work(e, labour); world.Rest(e, assumption); }
        foreach (var e in new[] { 4, 6 }) { world.Work(e, labour); world.Work(e, assumption); }
        foreach (var e in new[] { 3, 5 }) { world.Rest(e, labour); world.Rest(e, assumption); }

        world.Holiday(Christmas, "Christmas");
        world.Holiday(new DateOnly(2026, 12, 31), "New Year's Eve");
        var p = world.Plan(Dec, "FillEmpty", r =>
        {
            r.HolidayCover.Add(new HolidayCoverDto { Date = Christmas, Count = 2 });
            r.HolidayCover.Add(new HolidayCoverDto { Date = new DateOnly(2026, 12, 31), Count = 2 });
        }).Preview;

        var christmas = p.Cells.Where(c => c.WorkDate == Christmas && c.State == "work").Select(c => c.EmployeeId).Order().ToList();
        Assert.Equal(new[] { 3, 5 }, christmas);
        Assert.All(p.Cells.Where(c => c.WorkDate == Christmas && c.State == "work"), c =>
        {
            Assert.Equal("WORK_HOLIDAY_COVER", c.ReasonCode);
            Assert.Equal(RosterWorld.Day, c.ShiftId);
        });

        // After Christmas, 1, 2, 3 and 5 have each worked one; 4 and 6 (two each) are not asked again.
        var eve = p.Cells.Where(c => c.WorkDate == new DateOnly(2026, 12, 31) && c.State == "work").Select(c => c.EmployeeId).ToList();
        Assert.Equal(2, eve.Count);
        Assert.All(eve, e => Assert.Contains(e, new[] { 1, 2, 3, 5 }));
        Assert.Empty(p.Errors());
    }

    /// <summary>
    /// Employee 1 has worked the fewest holidays, but Mon 7 – Sun 13 Dec are pinned working days:
    /// covering Monday 14 would make eight in a row.
    /// </summary>
    private static RosterWorld PinnedWeekBeforeAHoliday(out DateOnly holiday)
    {
        var world = new RosterWorld { Today = new DateOnly(2026, 11, 1) }.WithStaff(3);
        var assumption = new DateOnly(2026, 8, 15);
        world.Holiday(assumption, "Assumption");
        world.Work(2, assumption);
        world.Work(3, assumption);
        foreach (var d in RosterCalendar.Days(new DateOnly(2026, 12, 7), new DateOnly(2026, 12, 13)))
        {
            world.Work(1, d);
            world.Pin(1, d);
        }
        holiday = new DateOnly(2026, 12, 14);
        world.Holiday(holiday, "Declared holiday");
        return world;
    }

    [Fact]
    public void Holiday_cover_passes_over_someone_it_would_push_past_the_cap()
    {
        var world = PinnedWeekBeforeAHoliday(out var holiday);
        var p = world.Plan(Dec, "FillEmpty", r => r.HolidayCover.Add(new HolidayCoverDto { Date = holiday, Count = 1 })).Preview;

        Assert.Equal("none", p.Cell(1, holiday).State);
        var cover = Assert.Single(p.Cells, c => c.WorkDate == holiday && c.State == "work");
        Assert.Contains(cover.EmployeeId, new[] { 2, 3 });
        Assert.Empty(p.Errors());
    }

    [Fact]
    public void When_nobody_else_is_left_the_cover_is_still_given_and_the_cap_error_says_so()
    {
        var world = PinnedWeekBeforeAHoliday(out var holiday);
        var p = world.Plan(Dec, "FillEmpty", r => r.HolidayCover.Add(new HolidayCoverDto { Date = holiday, Count = 3 })).Preview;

        Assert.All(Enumerable.Range(1, 3), e => Assert.Equal("work", p.Cell(e, holiday).State));
        var issue = Assert.Single(p.Errors());
        Assert.Equal(("CONSECUTIVE_CAP", (int?)1), (issue.Code, issue.EmployeeId));
    }

    [Fact]
    public void Working_facts_on_a_holiday_count_as_its_cover()
    {
        var world = new RosterWorld().WithStaff(4);
        world.Holiday(Christmas, "Christmas");
        world.Work(2, Christmas);   // FillEmpty: a fact
        var p = world.Plan(Dec, "FillEmpty", r => r.HolidayCover.Add(new HolidayCoverDto { Date = Christmas, Count = 1 })).Preview;

        Assert.Equal(new[] { 2 }, p.Cells.Where(c => c.WorkDate == Christmas && c.State == "work").Select(c => c.EmployeeId));
        Assert.Equal("kept", p.Cell(2, Christmas).Change);
    }

    [Fact]
    public void A_holiday_added_after_a_save_deletes_that_days_rows_and_moves_the_rest_day()
    {
        var world = new RosterWorld().WithStaff(5);
        world.PlanAndCommit(Dec);

        // Pick a weekday rest someone was given in the week of 14 Dec, and declare that day a holiday.
        var ws = new DateOnly(2026, 12, 14);
        var (who, day) = Enumerable.Range(1, 5)
            .SelectMany(e => Enumerable.Range(0, 5).Select(i => (e, d: ws.AddDays(i))))
            .First(x => world.IsRest(x.e, x.d));
        var quota = world.RestsInWeek(who, ws);
        world.Holiday(day, "Declared holiday");

        var run = world.Plan(Dec, "ReplanAuto");
        var p = run.Preview;
        Assert.All(Enumerable.Range(1, 5), e =>
        {
            var cell = p.Cell(e, day);
            Assert.Equal("none", cell.State);
            Assert.Equal("delete", cell.Change);
        });
        Assert.Equal(5, p.Summary.Deletes);
        Assert.Empty(p.Errors());

        var issues = world.Commit(run);
        Assert.DoesNotContain(issues, i => i.Severity == "error");
        Assert.All(Enumerable.Range(1, 5), e => Assert.Null(world.RowAt(e, day)));
        Assert.Equal(quota, world.RestsInWeek(who, ws));   // the rest moved to another day of the week
    }

    [Fact]
    public void When_holidays_count_as_rest_two_holidays_empty_a_6_day_weeks_quota_without_a_false_RHYTHM_OVER()
    {
        var world = new RosterWorld().WithStaff(2);
        world.Settings["RosterHolidayCountsAsRest"] = "1";
        world.Anchor(1, Week21, 6);
        world.Anchor(2, Week21, 6);
        world.Holiday(new DateOnly(2026, 12, 24), "Christmas Eve");
        world.Holiday(Christmas, "Christmas");
        var p = world.Plan(Dec).Preview;

        Assert.All(new[] { 1, 2 }, e =>
        {
            var week = p.Week(e, Week21);
            Assert.Equal(0, week.Quota);
            Assert.Equal(0, week.Rests);
            Assert.True(week.Ok);
        });
        Assert.DoesNotContain(p.Issues, i => i.Code is "RHYTHM_OVER" or "RHYTHM_SHORT" && i.Date >= Week21 && i.Date <= Week21.AddDays(6));
    }

    [Fact]
    public void A_rest_fact_on_a_holiday_hides_the_holiday_and_is_reported()
    {
        var world = new RosterWorld().WithStaff(3);
        world.Holiday(Christmas, "Christmas");
        world.Rest(1, Christmas);   // written by an older generator; a fact in FillEmpty
        var p = world.Plan(Dec).Preview;

        Assert.Equal("kept", p.Cell(1, Christmas).Change);
        var issue = Assert.Single(p.Issues.WithCode("HOLIDAY_HIDDEN_BY_REST"));
        Assert.Equal("warning", issue.Severity);
        Assert.Equal(1, issue.EmployeeId);
        Assert.Equal(Christmas, issue.Date);
    }

    [Fact]
    public void In_ReplanAll_a_hand_written_rest_on_a_holiday_is_deleted_like_any_other_row()
    {
        var world = new RosterWorld().WithStaff(3);
        world.Holiday(Christmas, "Christmas");
        world.Rest(1, Christmas);
        var p = world.Plan(Dec, "ReplanAll").Preview;

        Assert.Equal("delete", p.Cell(1, Christmas).Change);
        Assert.Empty(p.Issues.WithCode("HOLIDAY_HIDDEN_BY_REST"));
    }

    [Fact]
    public void An_empty_leave_day_that_is_also_a_holiday_stays_a_holiday_off()
    {
        var world = new RosterWorld().WithStaff(3);
        world.Holiday(Christmas, "Christmas");
        world.Leave(1, new DateOnly(2026, 12, 23), new DateOnly(2026, 12, 28));
        var p = world.Plan(Dec, "FillEmpty", r => r.HolidayCover.Add(new HolidayCoverDto { Date = Christmas, Count = 3 })).Preview;

        // Never a working row on a holiday for someone on leave, and never chosen to cover it.
        Assert.Equal("none", p.Cell(1, Christmas).State);
        Assert.Equal("work", p.Cell(2, Christmas).State);
        Assert.Equal("work", p.Cell(3, Christmas).State);
    }

    /* ---- leave ---- */

    [Fact]
    public void Empty_leave_days_get_working_rows_and_the_weeks_rest_goes_outside_the_leave()
    {
        var world = new RosterWorld().WithStaff(5);
        world.Leave(1, new DateOnly(2026, 12, 9), new DateOnly(2026, 12, 11));
        var p = world.Plan(Dec).Preview;

        foreach (var d in RosterCalendar.Days(new DateOnly(2026, 12, 9), new DateOnly(2026, 12, 11)))
        {
            var cell = p.Cell(1, d);
            Assert.Equal("work", cell.State);
            Assert.Equal("leave", cell.Origin);
            Assert.Equal("insert", cell.Change);
            Assert.Equal(RosterWorld.Day, cell.ShiftId);
        }

        var week = p.Week(1, new DateOnly(2026, 12, 7));
        Assert.Equal(week.Quota, week.Rests);
        Assert.Empty(p.Errors());
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void A_whole_week_of_leave_never_gets_a_rest_inside_and_the_absorbed_rest_is_reported(bool paid)
    {
        var world = new RosterWorld().WithStaff(4);
        var ws = new DateOnly(2026, 12, 14);
        world.Leave(1, ws, ws.AddDays(6), paid: paid);
        var p = world.Plan(Dec).Preview;

        Assert.All(Enumerable.Range(0, 7), i => Assert.Equal("work", p.Cell(1, ws.AddDays(i)).State));
        var week = p.Week(1, ws);
        Assert.Equal(0, week.Rests);
        Assert.True(week.Ok);   // absorbed by the leave, not broken

        var absorbed = Assert.Single(p.Issues.WithCode("REST_ABSORBED_BY_LEAVE"), i => i.EmployeeId == 1);
        Assert.Equal("info", absorbed.Severity);
        Assert.DoesNotContain(p.Issues, i => i.EmployeeId == 1 && i.Code == "RHYTHM_SHORT");

        // The leave breaks the run: no CONSECUTIVE_CAP although 7 working rows sit under it.
        Assert.DoesNotContain(p.Issues, i => i.EmployeeId == 1 && i.Code == "CONSECUTIVE_CAP");
    }

    [Fact]
    public void A_half_day_leave_is_a_working_day_never_a_rest()
    {
        var world = new RosterWorld().WithStaff(1);
        var ws = new DateOnly(2026, 12, 7);
        for (var i = 0; i < 7; i++)
            world.Leave(1, ws.AddDays(i), ws.AddDays(i), halfDay: "AM");
        var p = world.Plan(Dec).Preview;

        Assert.All(Enumerable.Range(0, 7), i => Assert.Equal("work", p.Cell(1, ws.AddDays(i)).State));
        Assert.Contains(p.Issues, i => i.EmployeeId == 1 && i.Code == "REST_ABSORBED_BY_LEAVE");
    }

    [Theory]
    [InlineData("FillEmpty")]
    [InlineData("ReplanAuto")]
    [InlineData("ReplanAll")]
    public void Rows_inside_a_leave_are_never_changed_in_any_mode(string mode)
    {
        var world = new RosterWorld().WithStaff(2);
        var thu = new DateOnly(2026, 12, 10);
        var fri = new DateOnly(2026, 12, 11);
        world.Leave(1, thu, fri);
        world.Rest(1, thu);
        world.Work(1, fri, RosterWorld.Evening);
        world.MarkAuto(1, thu);
        world.MarkAuto(1, fri);
        var p = world.Plan(Dec, mode).Preview;

        Assert.Equal(("rest", "leave", "kept"), (p.Cell(1, thu).State, p.Cell(1, thu).Origin, p.Cell(1, thu).Change));
        Assert.Equal(("work", "leave", "kept"), (p.Cell(1, fri).State, p.Cell(1, fri).Origin, p.Cell(1, fri).Change));
    }

    [Fact]
    public void A_rest_row_on_a_leave_day_counts_neither_as_rest_nor_in_the_weekend_ledger()
    {
        var world = new RosterWorld().WithStaff(3);
        var saturday = new DateOnly(2026, 11, 14);
        world.Leave(1, saturday, saturday);
        world.Rest(1, saturday);
        world.Work(2, saturday);
        world.Work(3, saturday);
        world.Rest(2, saturday.AddDays(1));
        world.Work(1, saturday.AddDays(1));
        world.Work(3, saturday.AddDays(1));

        var input = AutoRosterInputFactory.Create(world.Context(Dec), world.Request(Dec));
        var ledger = WeekendLedger.FromHistory(input, [1, 2, 3]);

        // Saturday: 1 is on leave → out of the pool; nobody else rested → no shares, no debits.
        Assert.Equal(0, ledger.Owed(1, DayOfWeek.Saturday), 6);
        Assert.Equal(0, ledger.Owed(2, DayOfWeek.Saturday), 6);
        // Sunday: 2 rested in a pool of 3 → everyone earns 1/3, 2 is debited 1.
        Assert.Equal(1 / 3.0, ledger.Owed(1, DayOfWeek.Sunday), 6);
        Assert.Equal(1 / 3.0 - 1, ledger.Owed(2, DayOfWeek.Sunday), 6);
    }
}
