using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Services.Attendance.AutoRoster;

namespace MokaCo.HRMS.Tests.Attendance.AutoRoster;

/// <summary>
/// R5, "divide the employees to all shifts": after the leaders, the minimums and the targets, each day's people are spread
/// over its shifts within one (or by the stored targets' proportions), preferring yesterday's shift, never into a short rest,
/// never moving somebody off a shift that is not to be covered. R3, "cover daily all the shifts": the rest days keep every
/// shift's minimum reachable on weekends too, even when the rows the planner cannot move all sit on one shift. R1: the
/// turnaround and weekly-rest maths read the hours in force on each date.
/// </summary>
public class RosterPlannerBalanceTests
{
    private static readonly DateOnly Dec = new(2026, 12, 1);
    private static readonly DateOnly WindowFrom = new(2026, 11, 30);

    private static void History(RosterWorld world, int id, int shift)
    {
        for (var d = WindowFrom.AddDays(-ShiftCoverDetector.LookbackDays); d < WindowFrom; d = d.AddDays(1))
        {
            if (d.DayOfWeek == DayOfWeek.Sunday)
                world.Rest(id, d);
            else
                world.Work(id, d, shift);
        }
    }

    private static RosterWorld Mornings(int size, Action<RosterWorld>? cover = null)
    {
        var world = new RosterWorld { Today = new DateOnly(2026, 11, 1) }.WithStaff(size);
        for (var e = 1; e <= size; e++)
            History(world, e, RosterWorld.Morning);
        if (cover is null)
        {
            world.Min(1, shiftId: RosterWorld.Morning);
            world.Min(1, shiftId: RosterWorld.Evening);
        }
        else
        {
            cover(world);
        }
        return world;
    }

    private static int On(AutoRosterPreview p, DateOnly d, int shift)
        => p.Cells.Count(c => c.WorkDate == d && c.State == "work" && c.ShiftId == shift);

    private static IEnumerable<DateOnly> December => Enumerable.Range(1, 31).Select(d => new DateOnly(2026, 12, d));

    [Fact]
    public void The_people_of_each_day_are_spread_over_its_shifts()
    {
        // Eight people whose own shift is the morning (left alone: seven mornings and one evening). Within one on almost
        // every day; a day further apart is one where everybody on the fuller shift is held there by the rest rules
        // (an evening yesterday, or an evening before one day off, then a morning).
        var p = Mornings(8).Plan(Dec).Preview;

        var within = 0;
        foreach (var d in December)
        {
            var (morning, evening) = (On(p, d, RosterWorld.Morning), On(p, d, RosterWorld.Evening));
            Assert.True(Math.Abs(morning - evening) <= 2 && Math.Min(morning, evening) >= 2, $"{d}: {morning} mornings, {evening} evenings");
            if (Math.Abs(morning - evening) <= 1)
                within++;
        }
        Assert.True(within >= 26, $"within one on {within} of 31 days");
        Assert.Contains(p.Cells, c => c.ReasonCode == RosterPlanner.ReasonShiftBalance && c.ReasonArgs!.Contains("Evening"));
        Assert.DoesNotContain(p.Issues, i => i.Code is "TURNAROUND" or "SHIFT_UNCOVERED");
        Assert.All(p.PerEmployee, e => Assert.All(e.Weeks, w => Assert.True(w.Ok)));   // spreading never costs a rest day
    }

    [Fact]
    public void A_moved_person_keeps_the_shift_of_the_day_before_and_the_evenings_are_shared()
    {
        var p = Mornings(8).Plan(Dec).Preview;

        // Whoever was on the evening yesterday and works today is on the evening again, unless a rest day came between.
        var kept = 0;
        var changed = 0;
        foreach (var e in Enumerable.Range(1, 8))
            foreach (var d in December.Skip(1))
            {
                if (p.Cell(e, d.AddDays(-1)) is not { State: "work", ShiftId: RosterWorld.Evening } || p.Cell(e, d).State != "work")
                    continue;
                if (p.Cell(e, d).ShiftId == RosterWorld.Evening) kept++; else changed++;
            }
        Assert.Equal(0, changed);
        Assert.True(kept > 0);

        // Over the month the evenings are not always the same people's.
        var evenings = p.Cells.Where(c => c.WorkDate.Month == 12 && c.State == "work" && c.ShiftId == RosterWorld.Evening)
            .GroupBy(c => c.EmployeeId).ToDictionary(g => g.Key, g => g.Count());
        Assert.True(evenings.Count >= 6, $"evenings by person: {string.Join(", ", evenings)}");
    }

    [Fact]
    public void With_targets_the_shifts_follow_the_targets_proportions()
    {
        var p = Mornings(9, w =>
        {
            w.Min(1, shiftId: RosterWorld.Morning, target: 4);
            w.Min(1, shiftId: RosterWorld.Evening, target: 2);
        }).Plan(Dec).Preview;

        foreach (var d in December)
        {
            var (morning, evening) = (On(p, d, RosterWorld.Morning), On(p, d, RosterWorld.Evening));
            var people = morning + evening;
            // Two thirds on the morning, one third on the evening, within one person.
            Assert.True(Math.Abs(morning - 2.0 * people / 3) <= 1 + 1e-9, $"{d}: {morning} mornings, {evening} evenings");
            Assert.True(morning > evening, $"{d}: {morning} mornings, {evening} evenings");
            Assert.True(evening >= 2, $"{d}: the evening's target");
        }
    }

    [Fact]
    public void Somebody_on_a_shift_that_is_not_covered_stays_there()
    {
        var world = Mornings(8);
        History(world, 8, RosterWorld.Night);   // the night is worked, but not a shift the branch must cover
        var p = world.Plan(Dec).Preview;

        var nights = p.Cells.Where(c => c.EmployeeId == 8 && c.WorkDate.Month == 12 && c.State == "work").ToList();
        Assert.NotEmpty(nights);
        Assert.All(nights, c => Assert.Equal(RosterWorld.Night, c.ShiftId));
        Assert.All(nights, c => Assert.Null(c.ReasonCode));
        // The others are still spread over the morning and the evening (one apart on average at most).
        var gap = December.Average(d => Math.Abs(On(p, d, RosterWorld.Morning) - On(p, d, RosterWorld.Evening)));
        Assert.True(gap <= 1, $"{gap:0.00} apart on average");
    }

    [Fact]
    public void Regenerating_a_balanced_plan_moves_nobody()
    {
        var world = Mornings(8);
        var (run, issues) = world.PlanAndCommit(Dec);
        Assert.False(RosterPlanValidator.HasErrors(issues));
        Assert.Contains(run.Preview.Cells, c => c.ReasonCode == RosterPlanner.ReasonShiftBalance);

        Assert.Equal(0, world.Plan(Dec, "ReplanAuto").Preview.Changes());
        Assert.Equal(0, world.Plan(Dec, "ReplanAll").Preview.Changes());
    }

    /* ---- R3: every shift covered, weekends included ---- */

    /// <summary>
    /// Two people's mornings are saved on every day of December (the planner cannot move them); two others, whose own
    /// shift is the evening, are the planner's. Only they can hold the evening, so they must never rest on the same day.
    /// </summary>
    private static RosterWorld FixedMornings()
    {
        var world = new RosterWorld { Today = new DateOnly(2026, 11, 1) }.WithStaff(4);
        foreach (var e in new[] { 1, 2 })
        {
            History(world, e, RosterWorld.Morning);
            foreach (var d in December)
            {
                if (e == 1 ? d.DayOfWeek == DayOfWeek.Monday : d.DayOfWeek == DayOfWeek.Tuesday)
                    world.Rest(e, d);
                else
                    world.Work(e, d, RosterWorld.Morning);
            }
        }
        History(world, 3, RosterWorld.Evening);
        History(world, 4, RosterWorld.Evening);
        world.Min(1, shiftId: RosterWorld.Morning);
        world.Min(1, shiftId: RosterWorld.Evening);
        return world;
    }

    [Fact]
    public void The_rest_days_keep_every_shift_covered_on_weekends_too_when_the_fixed_rows_sit_on_one_shift()
    {
        var p = FixedMornings().Plan(Dec).Preview;

        Assert.All(December, d => Assert.True(On(p, d, RosterWorld.Evening) >= 1, $"{d}: nobody on the evening"));
        Assert.DoesNotContain(p.Issues, i => i.Code is "SHIFT_UNCOVERED" or "SHORT_STAFFED");
        var weekends = December.Where(RosterCalendar.IsWeekend).ToList();
        Assert.Contains(weekends, d => p.Cell(3, d).State == "rest" || p.Cell(4, d).State == "rest");   // weekends are still shared out
        Assert.All(new[] { 3, 4 }, e => Assert.All(p.PerEmployee.Single(x => x.EmployeeId == e).Weeks, w => Assert.True(w.Ok)));
    }

    [Fact]
    public void When_people_are_simply_too_few_the_rest_days_stay_and_the_plan_says_so()
    {
        // One person for two shifts: every rest day is kept (the 6/5 rule is hard) and the empty shift is a warning.
        var world = new RosterWorld { Today = new DateOnly(2026, 11, 1) }.WithStaff(1);
        History(world, 1, RosterWorld.Evening);
        world.Min(1, shiftId: RosterWorld.Morning);
        world.Min(1, shiftId: RosterWorld.Evening);
        var p = world.Plan(Dec).Preview;

        Assert.All(p.PerEmployee, e => Assert.All(e.Weeks, w => Assert.True(w.Ok)));
        Assert.All(December, d => Assert.Contains(p.Issues, i => i.Date == d && i.Code == "SHIFT_UNCOVERED" && i.Severity == "warning"));
    }

    [Fact]
    public void A_branch_with_nothing_to_read_its_shifts_from_covers_every_active_shift()
    {
        var world = new RosterWorld { Today = new DateOnly(2026, 11, 1) }.WithStaff(8);
        var p = world.Plan(Dec).Preview;

        foreach (var d in December)
        {
            foreach (var shift in new[] { RosterWorld.Day, RosterWorld.Morning, RosterWorld.Evening, RosterWorld.Night })
                Assert.True(On(p, d, shift) >= 1, $"{d}: nobody on shift {shift}");
            Assert.Equal(0, On(p, d, RosterWorld.Retired));
        }
        Assert.DoesNotContain(p.Issues, i => i.Code is "SHIFT_UNCOVERED" or "TURNAROUND");
    }

    /* ---- R1: the hours in force on each date ---- */

    [Fact]
    public void The_planner_moves_people_by_the_hours_in_force_that_day()
    {
        // The evening person's days off are covered from the mornings; the next morning would be a turnaround with the
        // 07:00 start, so whoever covers stays on the evening. From 1 December the morning starts at 11:00: twelve hours
        // after an evening, so nobody needs to stay and the cover goes back to the morning the next day.
        static RosterWorld World(bool lateMornings)
        {
            var world = new RosterWorld { Today = new DateOnly(2026, 11, 1) }.WithStaff(6);
            for (var e = 1; e <= 5; e++)
                History(world, e, RosterWorld.Morning);
            History(world, 6, RosterWorld.Evening);
            world.Min(1, shiftId: RosterWorld.Morning, target: 5);   // five to one: the evening keeps one person
            world.Min(1, shiftId: RosterWorld.Evening, target: 1);
            if (lateMornings)
            {
                world.Hours(RosterWorld.Morning, new DateOnly(2000, 1, 1), 7, 15);
                world.Hours(RosterWorld.Morning, WindowFrom, 11, 19);
            }
            return world;
        }

        static int Stays(AutoRosterPreview p) => p.Cells.Count(c =>
            c.WorkDate.Month == 12 && c.EmployeeId != 6 && c.State == "work" && c.ShiftId == RosterWorld.Evening
            && p.CellOrNull(c.EmployeeId, c.WorkDate.AddDays(-1)) is { State: "work", ShiftId: RosterWorld.Evening });

        var early = World(lateMornings: false).Plan(Dec).Preview;
        var late = World(lateMornings: true).Plan(Dec).Preview;
        Assert.True(Stays(early) > 0);
        Assert.True(Stays(late) < Stays(early), $"{Stays(late)} stays with 11:00 mornings, {Stays(early)} with 07:00 mornings");
        Assert.DoesNotContain(early.Issues, i => i.Code == "TURNAROUND");
        Assert.DoesNotContain(late.Issues, i => i.Code == "TURNAROUND");
    }
}
