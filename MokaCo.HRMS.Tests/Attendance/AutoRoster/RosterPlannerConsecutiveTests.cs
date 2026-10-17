using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Services.Attendance.AutoRoster;

namespace MokaCo.HRMS.Tests.Attendance.AutoRoster;

/// <summary>D7: the hard cap on consecutive working days, across weeks and months, and the joint weekend case.</summary>
public class RosterPlannerConsecutiveTests
{
    private static readonly DateOnly Nov = new(2026, 11, 1);
    private static readonly DateOnly Dec = new(2026, 12, 1);

    [Fact]
    public void Two_months_in_sequence_never_exceed_the_cap()
    {
        var world = new RosterWorld().WithStaff(7);
        foreach (var month in new[] { Nov, Dec })
        {
            var (run, _) = world.PlanAndCommit(month);
            Assert.Empty(run.Preview.Issues.WithCode("CONSECUTIVE_CAP"));
        }

        Assert.All(Enumerable.Range(1, 7), e => Assert.True(world.LongestRun(e, Nov, new DateOnly(2026, 12, 31)) <= 7));
    }

    [Fact]
    public void A_run_carried_in_from_the_previous_month_forces_an_early_rest()
    {
        var world = new RosterWorld().WithStaff(3);
        // 1: rested Mon 26 Oct, then worked Tue–Sat (rows already saved; Sun 1 Nov is the November run's).
        world.Rest(1, new DateOnly(2026, 10, 26));
        foreach (var d in RosterCalendar.Days(new DateOnly(2026, 10, 27), new DateOnly(2026, 10, 31)))
            world.Work(1, d);

        var (run, _) = world.PlanAndCommit(Nov);
        var p = run.Preview;

        // The 26 Oct week already has its rest, so Sun 1 Nov is a working day: the run is 6 going
        // into the 2 Nov week, which must rest on its Monday or Tuesday.
        Assert.Equal("work", p.Cell(1, Nov).State);
        Assert.True(world.IsRest(1, new DateOnly(2026, 11, 2)) || world.IsRest(1, new DateOnly(2026, 11, 3)));
        Assert.True(world.LongestRun(1, new DateOnly(2026, 10, 27), new DateOnly(2026, 11, 30)) <= 7);
        Assert.Empty(p.Issues.WithCode("CONSECUTIVE_CAP"));
    }

    [Fact]
    public void A_month_planned_after_the_month_that_follows_it_ends_short_enough_for_that_months_opening_run()
    {
        // February first, then January: February read January as empty and may open with several working
        // days; January now reads them (past its window) and ends early enough for the join to hold.
        var world = new RosterWorld { Today = new DateOnly(2026, 11, 1) }.WithStaff(3);
        var jan = new DateOnly(2027, 1, 1);
        var feb = new DateOnly(2027, 2, 1);
        world.PlanAndCommit(feb);
        var (run, commitIssues) = world.PlanAndCommit(jan);

        Assert.Empty(run.Preview.Issues.WithCode("CONSECUTIVE_CAP"));
        Assert.DoesNotContain(commitIssues, i => i.Severity == "error");
        Assert.All(Enumerable.Range(1, 3), e => Assert.True(world.LongestRun(e, new DateOnly(2027, 1, 18), new DateOnly(2027, 2, 14)) <= 7, $"employee {e}"));
    }

    public static IEnumerable<object[]> Orders()
    {
        foreach (var start in new[] { "Aligned", "Staggered" })
        {
            yield return [3, "2027-02 2027-01", start];
            yield return [4, "2027-04 2027-03 2027-02 2027-01", start];
            yield return [5, "2026-11 2026-09 2026-12 2026-10", start];
            yield return [6, "2027-02 2027-01", start];
            yield return [8, "2027-04 2027-03 2027-02 2027-01", start];
            yield return [8, "2027-02 2027-04 2027-01 2027-03", start];
        }
    }

    [Theory]
    [MemberData(nameof(Orders))]
    public void Months_generated_in_any_order_keep_the_cap_and_the_6_5_rhythm_across_every_join(int size, string order, string start)
    {
        var world = new RosterWorld { Today = new DateOnly(2026, 8, 1) }.WithStaff(size);
        var months = order.Split(' ').Select(m => DateOnly.ParseExact(m + "-01", "yyyy-MM-dd")).ToList();
        foreach (var month in months)
        {
            var (run, commitIssues) = world.PlanAndCommit(month, "FillEmpty", r => r.RhythmStart = start);
            Assert.DoesNotContain(run.Preview.Issues, i => i.Code is "CONSECUTIVE_CAP" or "RHYTHM_OVER" or "RHYTHM_SHORT");
            Assert.DoesNotContain(commitIssues, i => i.Severity == "error");
        }

        var from = months.Min();
        var to = RosterCalendar.MonthEnd(months.Max());
        Assert.All(Enumerable.Range(1, size), e => Assert.True(world.LongestRun(e, from, to) <= 7, $"employee {e}"));
    }

    [Fact]
    public void The_check_follows_a_run_into_the_following_months_saved_rows()
    {
        // February was saved first and opens with five working days. A January draft working its last
        // four days makes nine in a row across the join: January's preview says so, as an error.
        var world = new RosterWorld().WithStaff(2);
        foreach (var d in RosterCalendar.Days(new DateOnly(2027, 2, 1), new DateOnly(2027, 2, 5)))
            world.Work(1, d);
        var p = world.Plan(new DateOnly(2027, 1, 1), "FillEmpty", r =>
        {
            foreach (var d in RosterCalendar.Days(new DateOnly(2027, 1, 28), new DateOnly(2027, 1, 31)))
                r.DraftCells.Add(new DraftCellDto { EmployeeId = 1, WorkDate = d, ShiftId = RosterWorld.Day });
        }).Preview;

        var issue = Assert.Single(p.Issues.WithCode("CONSECUTIVE_CAP"), i => i.EmployeeId == 1);
        Assert.Equal("error", issue.Severity);
        Assert.Contains("2027-02-05", issue.Message);
    }

    public static IEnumerable<object[]> PinnedWeekendsOff()
    {
        foreach (var size in Enumerable.Range(1, 6))
            foreach (var day in new[] { 14, 21, 28 })
                foreach (var mondayPattern in new[] { false, true })
                    yield return [size, day, mondayPattern];
    }

    [Theory]
    [MemberData(nameof(PinnedWeekendsOff))]
    public void A_pinned_weekend_off_two_weeks_ahead_is_planned_for_without_an_extra_rest(int size, int day, bool mondayPattern)
    {
        // Employee 1's Saturday and Sunday of a 5-day week C are pinned rests: C's quota is met, so its
        // Monday–Friday are working days and the run into them can be at most 2. The week before C (a
        // 6-day week, one rest) must then rest on Friday or later — so the week before THAT must leave
        // at most 3 at its Sunday. Looking one week ahead only, the first week rested early and the next
        // needed a second rest (RHYTHM_OVER) to hold the cap. A Monday pattern rest pulls the early way.
        var c = new DateOnly(2026, 12, day);
        var world = new RosterWorld { Today = new DateOnly(2026, 10, 20) }.WithStaff(size);
        for (var e = 1; e <= size; e++)
            world.Anchor(e, c, 5);
        foreach (var d in new[] { c.AddDays(5), c.AddDays(6) })
        {
            world.Rest(1, d);
            world.Pin(1, d);
        }
        if (mondayPattern)
            world.Patterns.Add(new AutoRosterPatternRow { EmployeeId = 1, DayOfWeek = 1, IsRestDay = true });

        var p = world.Plan(Dec).Preview;
        Assert.DoesNotContain(p.Issues, i => i.Code is "CONSECUTIVE_CAP" or "RHYTHM_OVER" or "RHYTHM_SHORT");
        Assert.All(p.PerEmployee.Single(x => x.EmployeeId == 1).Weeks, w => Assert.True(w.Ok, $"week {w.WeekStart}: {w.Rests} rests for {w.Quota}"));
    }

    [Fact]
    public void A_6_day_cap_holds_too()
    {
        var world = new RosterWorld().WithStaff(6);
        world.Settings["RosterMaxConsecutiveWorkDays"] = "6";
        world.Settings["RosterPreferredMaxConsecutiveWorkDays"] = "5";
        foreach (var month in new[] { Nov, Dec })
            world.PlanAndCommit(month);

        Assert.All(Enumerable.Range(1, 6), e => Assert.True(world.LongestRun(e, Nov, new DateOnly(2026, 12, 31)) <= 6, $"employee {e}"));
    }

    [Fact]
    public void A_pinned_Monday_rest_never_lets_the_most_owed_take_both_weekend_days_past_the_cap()
    {
        // Maya (1) rested on Monday 7 Dec (pinned), her 7 Dec week is a 6-day week (that rest is all
        // of it), and 14–20 Dec is her 5-day week. Tue 8 → Mon 14 is already 7 days, so one of her two
        // rests must be Mon 14 or Tue 15. She is the most owed for both Saturday and Sunday: given
        // both, she would work Tue 8 – Fri 18, eleven days.
        var world = new RosterWorld().WithStaff(8);
        var mon7 = new DateOnly(2026, 12, 7);
        for (var e = 1; e <= 8; e++)
            world.Anchor(e, mon7, e == 1 ? 6 : 5);
        world.Rest(1, mon7);
        world.Pin(1, mon7);

        // History: 2–8 took turns on the weekends; Maya worked them all.
        for (var d = new DateOnly(2026, 10, 5); d < new DateOnly(2026, 11, 30); d = d.AddDays(1))
        {
            var turn = RosterCalendar.Mod(RosterCalendar.WeekIndex(d), 7) + 2;
            foreach (var e in Enumerable.Range(1, 8))
            {
                var rest = e != 1 && (RosterCalendar.IsWeekend(d) ? e == turn : d.DayOfWeek == DayOfWeek.Wednesday && e != turn)
                           || e == 1 && d.DayOfWeek == DayOfWeek.Wednesday;
                if (rest) world.Rest(e, d); else world.Work(e, d);
            }
        }

        var p = world.Plan(Dec).Preview;
        var mid = new DateOnly(2026, 12, 14);

        Assert.Equal("pinned", p.Cell(1, mon7).Origin);
        Assert.False(p.Cell(1, mid.AddDays(5)).State == "rest" && p.Cell(1, mid.AddDays(6)).State == "rest");
        Assert.True(p.Cell(1, mid).State == "rest" || p.Cell(1, mid.AddDays(1)).State == "rest");
        Assert.Equal(2, p.Week(1, mid).Rests);
        Assert.Empty(p.Issues.WithCode("CONSECUTIVE_CAP"));

        // And she does get one of the two weekend days: she is the most owed.
        Assert.True(p.Cell(1, mid.AddDays(5)).State == "rest" || p.Cell(1, mid.AddDays(6)).State == "rest");
    }

    [Fact]
    public void A_breach_made_only_of_facts_is_a_warning_and_the_planner_rests_right_after_it()
    {
        var world = new RosterWorld().WithStaff(2);
        foreach (var d in RosterCalendar.Days(new DateOnly(2026, 12, 7), new DateOnly(2026, 12, 15)))
            world.Work(1, d);   // nine working days written by hand; FillEmpty keeps them
        var p = world.Plan(Dec).Preview;

        var issue = Assert.Single(p.Issues.WithCode("CONSECUTIVE_CAP"), i => i.EmployeeId == 1);
        Assert.Equal("warning", issue.Severity);
        Assert.Equal("rest", p.Cell(1, new DateOnly(2026, 12, 16)).State);
    }

    [Fact]
    public void A_breach_the_manager_draws_in_the_draft_is_an_error()
    {
        var world = new RosterWorld().WithStaff(2);
        var p = world.Plan(Dec, "FillEmpty", r =>
        {
            foreach (var d in RosterCalendar.Days(new DateOnly(2026, 12, 7), new DateOnly(2026, 12, 14)))
                r.DraftCells.Add(new DraftCellDto { EmployeeId = 1, WorkDate = d, ShiftId = RosterWorld.Day });
        }).Preview;

        var issue = Assert.Single(p.Issues.WithCode("CONSECUTIVE_CAP"), i => i.EmployeeId == 1);
        Assert.Equal("error", issue.Severity);
        Assert.Contains("8 working days in a row", issue.Message);
    }

    [Fact]
    public void A_run_past_the_preferred_maximum_is_reported_as_info()
    {
        var world = new RosterWorld().WithStaff(2);
        var p = world.Plan(Dec, "FillEmpty", r =>
        {
            foreach (var d in RosterCalendar.Days(new DateOnly(2026, 12, 7), new DateOnly(2026, 12, 13)))
                r.DraftCells.Add(new DraftCellDto { EmployeeId = 1, WorkDate = d, ShiftId = RosterWorld.Day });
        }).Preview;

        var issue = Assert.Single(p.Issues.WithCode("LONG_RUN"), i => i.EmployeeId == 1);
        Assert.Equal("info", issue.Severity);
        Assert.Empty(p.Issues.WithCode("CONSECUTIVE_CAP"));
    }

    [Fact]
    public void When_the_quota_is_met_but_the_cap_still_needs_a_break_one_more_rest_is_given_and_reported_as_info()
    {
        // A 6-day cap, and Saturday is an "unavailable" pattern day: that fixed rest is the whole of
        // the 6-day week's quota, yet Monday–Friday on top of the weekend just worked is 7 days.
        var world = new RosterWorld().WithStaff(1);
        world.Settings["RosterMaxConsecutiveWorkDays"] = "6";
        world.Settings["RosterPreferredMaxConsecutiveWorkDays"] = "6";
        world.Settings["RosterPatternRestDays"] = "Unavailable";
        world.Patterns.Add(new AutoRosterPatternRow { EmployeeId = 1, DayOfWeek = 6, IsRestDay = true });
        var mon = new DateOnly(2026, 12, 14);
        world.Anchor(1, mon, 6);
        world.Work(1, mon.AddDays(-2));
        world.Work(1, mon.AddDays(-1));   // FillEmpty: Sat 12 and Sun 13 are worked facts

        var p = world.Plan(Dec).Preview;

        Assert.Empty(p.Issues.WithCode("CONSECUTIVE_CAP"));
        Assert.Equal(2, p.Week(1, mon).Rests);
        Assert.Contains(p.Issues, i => i.Code == "RHYTHM_OVER" && i.Severity == "info" && i.Date == mon);
        var extra = p.Cells.Single(c => c.EmployeeId == 1 && c.WorkDate >= mon && c.WorkDate < mon.AddDays(5) && c.State == "rest");
        Assert.Equal("REST_CONSECUTIVE", extra.ReasonCode);
    }

    [Fact]
    public void A_last_partial_week_before_a_termination_still_gets_a_break_when_the_cap_needs_one()
    {
        // Quota 0 (Mon–Thu employed, a 5-day week) but the run from the last rest would reach 9 days.
        var world = new RosterWorld().WithStaff(2);
        world.Add(9, termination: new DateOnly(2026, 12, 17));
        world.Anchor(9, new DateOnly(2026, 12, 7), 6);
        world.Rest(9, new DateOnly(2026, 12, 7));   // the 7 Dec week's only rest, on its Monday

        var (run, _) = world.PlanAndCommit(Dec);
        var p = run.Preview;
        Assert.Equal(0, p.Week(9, new DateOnly(2026, 12, 14)).Quota);
        Assert.Empty(p.Issues.WithCode("CONSECUTIVE_CAP"));
        Assert.True(world.LongestRun(9, new DateOnly(2026, 12, 7), new DateOnly(2026, 12, 17)) <= 7);
        Assert.Contains(p.Issues, i => i.EmployeeId == 9 && i.Code == "RHYTHM_OVER");   // the extra rest is said, not hidden
    }
}

