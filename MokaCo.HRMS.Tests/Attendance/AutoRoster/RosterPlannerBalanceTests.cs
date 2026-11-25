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

    /* ---- R5 over several months: a move holds the person, and the home shift does not drift ---- */

    /// <summary>Eight weeks before the window of <paramref name="month"/> on one shift, 6- and 5-day weeks taking turns, the rest days moving through the week.</summary>
    private static void History(RosterWorld world, int id, int shift, DateOnly month)
    {
        var (from, _) = RosterCalendar.Window(month);
        var start = from.AddDays(-56);
        for (var k = 0; k < 8; k++)
        {
            var ws = start.AddDays(7 * k);
            var first = (id * 3 + k * 2) % 7;
            var fiveDays = (k + id) % 2 == 1;
            for (var i = 0; i < 7; i++)
            {
                if (i == first || (fiveDays && i == (first + 1) % 7))
                    world.Rest(id, ws.AddDays(i));
                else
                    world.Work(id, ws.AddDays(i), shift);
            }
        }
    }

    [Fact]
    public void An_evenly_split_branch_stays_even_over_three_months()
    {
        // Four people on the morning, four on the evening, a minimum of one on each, no leaders; December, January and
        // February planned and saved one after the other. A balancing move holds the person on the evening (going back the
        // next morning, or after one day off, is too short a rest): the planner counts that hold, so the evening does not
        // fill up with people nobody may move back, and the home shifts are the same in February as in December.
        var world = new RosterWorld { Today = new DateOnly(2026, 11, 25) };
        for (var id = 1; id <= 8; id++)
        {
            world.Add(id);
            History(world, id, id % 2 == 1 ? RosterWorld.Morning : RosterWorld.Evening, Dec);
        }
        world.Min(1, shiftId: RosterWorld.Morning);
        world.Min(1, shiftId: RosterWorld.Evening);

        var months = new[] { Dec, new DateOnly(2027, 1, 1), new DateOnly(2027, 2, 1) };
        foreach (var month in months)
        {
            var (run, issues) = world.PlanAndCommit(month);
            Assert.False(RosterPlanValidator.HasErrors(issues));
            Assert.DoesNotContain(run.Preview.Issues, i => i.Code is "TURNAROUND" or "WEEKLY_REST_HOURS" or "SHIFT_UNCOVERED");
        }

        var days = RosterCalendar.Days(Dec, new DateOnly(2027, 2, 28)).ToList();
        int On(DateOnly d, int shift) => Enumerable.Range(1, 8).Count(e => world.RowAt(e, d) is { IsWork: true } r && r.ShiftId == shift);
        var apart = days.Select(d => Math.Abs(On(d, RosterWorld.Morning) - On(d, RosterWorld.Evening))).ToList();
        Assert.True(apart.Max() <= 2, $"a day {apart.Max()} apart");
        Assert.True(apart.Count(a => a <= 1) >= 85, $"within one on {apart.Count(a => a <= 1)} of {days.Count} days");

        // Each person still works their own shift on most of their days in February.
        var february = RosterCalendar.Days(months[2], new DateOnly(2027, 2, 28)).ToList();
        Assert.All(Enumerable.Range(1, 8), e =>
        {
            var own = e % 2 == 1 ? RosterWorld.Morning : RosterWorld.Evening;
            var worked = february.Where(d => world.IsWork(e, d)).ToList();
            Assert.True(worked.Count(d => world.RowAt(e, d)!.Value.ShiftId == own) * 2 > worked.Count, $"employee {e}");
        });
    }

    [Fact]
    public void A_new_hire_with_nothing_to_go_by_starts_on_a_shift_the_branch_covers()
    {
        // Seven people on the morning and the evening; two new hires with no rows and no weekly pattern, and no default shift
        // in the drawer. The lowest-numbered active shift (Day) is one the branch never runs: they start on a shift it covers,
        // so the balancing spreads them, and January learns a real shift for them.
        var world = new RosterWorld { Today = new DateOnly(2026, 11, 25) };
        for (var id = 1; id <= 7; id++)
        {
            world.Add(id);
            History(world, id, id % 2 == 1 ? RosterWorld.Morning : RosterWorld.Evening, Dec);
        }
        world.Add(8, hire: new DateOnly(2026, 12, 9));
        world.Add(9, hire: new DateOnly(2026, 12, 14));
        world.Min(1, shiftId: RosterWorld.Morning);
        world.Min(1, shiftId: RosterWorld.Evening);

        world.PlanAndCommit(Dec);
        world.PlanAndCommit(new DateOnly(2027, 1, 1));

        var days = RosterCalendar.Days(Dec, new DateOnly(2027, 1, 31)).ToList();
        var shifts = new[] { 8, 9 }.SelectMany(e => days.Where(d => world.IsWork(e, d)).Select(d => world.RowAt(e, d)!.Value.ShiftId)).ToList();
        Assert.NotEmpty(shifts);
        Assert.All(shifts, s => Assert.True(s is RosterWorld.Morning or RosterWorld.Evening, $"shift {s}"));
        Assert.Contains(RosterWorld.Morning, shifts);
        Assert.Contains(RosterWorld.Evening, shifts);
    }

    [Fact]
    public void A_new_hire_with_nothing_to_go_by_keeps_one_shift_when_the_cover_changes_with_the_weekday()
    {
        // The evening is covered every day, the morning only Monday to Friday. Two new hires with no rows, no weekly pattern
        // and no default shift start on the shift covered on the most days - the evening - every day: a start shift that
        // followed each day's cover would put them on the evening on Sunday and the morning on Monday, 8 hours apart.
        var world = new RosterWorld { Today = new DateOnly(2026, 11, 25) };
        for (var id = 1; id <= 8; id++)
        {
            world.Add(id);
            History(world, id, id % 2 == 1 ? RosterWorld.Morning : RosterWorld.Evening, Dec);
        }
        world.Add(9, hire: new DateOnly(2026, 11, 30));
        world.Add(10, hire: new DateOnly(2026, 11, 30));
        world.Min(1, shiftId: RosterWorld.Evening);
        for (var weekday = 1; weekday <= 5; weekday++)
            world.Min(1, dayOfWeek: weekday, shiftId: RosterWorld.Morning);

        var p = world.Plan(Dec).Preview;

        Assert.DoesNotContain(p.Issues, i => i.Code == "TURNAROUND" && i.EmployeeId is 9 or 10);
        var worked = p.Cells.Where(c => c.EmployeeId is 9 or 10 && c.WorkDate.Month == 12 && c.State == "work").ToList();
        Assert.NotEmpty(worked);
        Assert.All(worked, c => Assert.True(c.ShiftId is RosterWorld.Morning or RosterWorld.Evening, $"{c.WorkDate}: shift {c.ShiftId}"));
    }

    [Theory]
    [InlineData(RosterWorld.Day, true)]        // 09:00-17:00 at the weekend: no turnaround either side, so they take it
    [InlineData(RosterWorld.Evening, false)]   // 15:00-23:00 on Sunday, then Monday's 07:00: they keep the morning
    public void On_days_the_guessed_shift_is_not_covered_a_new_hire_takes_the_shift_covered_only_without_a_turnaround(int weekendShift, bool takesIt)
    {
        // The morning is covered Monday to Friday, another shift only at the weekend (two people work it already). A new hire
        // with nothing to go by starts on the morning (covered on the most days); at the weekend on the shift covered then,
        // unless Sunday's shift would end too close to Monday's morning: then on the morning, unless the weekend's minimum
        // needs them there.
        var world = new RosterWorld { Today = new DateOnly(2026, 11, 25) };
        for (var id = 1; id <= 6; id++)
        {
            world.Add(id);
            History(world, id, id <= 4 ? RosterWorld.Morning : weekendShift, Dec);
        }
        world.Add(9, hire: new DateOnly(2026, 11, 30));
        for (var weekday = 1; weekday <= 5; weekday++)
            world.Min(1, dayOfWeek: weekday, shiftId: RosterWorld.Morning);
        world.Min(1, dayOfWeek: 6, shiftId: weekendShift);
        world.Min(1, dayOfWeek: 7, shiftId: weekendShift);

        var p = world.Plan(Dec).Preview;

        Assert.DoesNotContain(p.Issues, i => i.Code == "TURNAROUND" && i.EmployeeId == 9);
        var days = p.Cells.Where(c => c.EmployeeId == 9 && c.WorkDate.Month == 12 && c.State == "work").ToList();
        var weekend = days.Where(c => c.WorkDate.DayOfWeek is DayOfWeek.Saturday or DayOfWeek.Sunday).ToList();
        Assert.NotEmpty(weekend);
        Assert.All(days.Except(weekend), c => Assert.Equal(RosterWorld.Morning, c.ShiftId));
        if (takesIt)
        {
            Assert.All(weekend, c => Assert.Equal(weekendShift, c.ShiftId));
        }
        else
        {
            Assert.Contains(weekend, c => c.ShiftId == RosterWorld.Morning);
            Assert.All(weekend.Where(c => c.ShiftId != RosterWorld.Morning), c => Assert.Equal(RosterPlanner.ReasonShiftCover, c.ReasonCode));
        }
    }

    [Fact]
    public void Somebody_held_on_the_evening_by_last_months_last_day_is_counted_there_when_the_rest_days_are_placed()
    {
        // Five people (1, 3 and 5 on the morning, 2 and 4 on the evening), a minimum of one on each - a small branch.
        // Employees 1 and 3 covered the evening on the last three days of January (saved). On Monday 1 February the morning
        // would be too soon after Sunday's evening, so whoever of them works that day stays on the evening. The rest days are
        // placed before any shift is chosen: counted on their own shift, they could leave the morning with nobody but them,
        // and the shift cover would have to send one back - an 8-hour turnaround across the month's end.
        var feb = new DateOnly(2027, 2, 1);
        var world = new RosterWorld { Today = new DateOnly(2027, 1, 25) };
        var (from, _) = RosterCalendar.Window(feb);
        for (var id = 1; id <= 5; id++)
        {
            world.Add(id);
            var rng = new Random(id * 7919 + 6 * 104729);
            for (var k = 0; k < 8; k++)
            {
                var ws = from.AddDays(-56 + 7 * k);
                var first = rng.Next(7);
                var fiveDays = (k + id + 6) % 2 == 1;
                for (var i = 0; i < 7; i++)
                {
                    if (i == first || (fiveDays && i == (first + 1) % 7))
                        world.Rest(id, ws.AddDays(i));
                    else
                        world.Work(id, ws.AddDays(i), id % 2 == 1 ? RosterWorld.Morning : RosterWorld.Evening);
                }
            }
        }
        foreach (var id in new[] { 1, 3 })
            foreach (var d in new[] { new DateOnly(2027, 1, 29), new DateOnly(2027, 1, 30), new DateOnly(2027, 1, 31) })
                world.Work(id, d, RosterWorld.Evening);
        world.Min(1, shiftId: RosterWorld.Morning);
        world.Min(1, shiftId: RosterWorld.Evening);

        var p = world.Plan(feb).Preview;

        foreach (var id in new[] { 1, 3 })
        {
            var monday = p.Cell(id, feb);
            Assert.True(monday.State != "work" || monday.ShiftId == RosterWorld.Evening, $"employee {id}: {monday.State} {monday.ShiftId}");
        }
        Assert.DoesNotContain(p.Issues, i => i.Code == "TURNAROUND" && i.Date == feb);
        Assert.DoesNotContain(p.Issues, i => i.Code == "SHIFT_UNCOVERED" && i.Date == feb);
    }

    [Fact]
    public void A_rest_on_the_first_day_of_the_month_reads_the_shift_saved_the_day_before()
    {
        // Employee 1, a morning person, covered the evening on the last three days of January (saved rows) and rests on
        // Monday 1 February, the only rest of a 6-day week. Back on the morning on Tuesday would be 32 hours after the Sunday
        // evening - the week's longest rest, under the minimum of 36: the planner keeps him on the evening, as it would in
        // the middle of the month.
        var feb = new DateOnly(2027, 2, 1);
        var world = new RosterWorld { Today = new DateOnly(2027, 1, 25) };
        for (var id = 1; id <= 8; id++)
        {
            world.Add(id);
            History(world, id, id % 2 == 1 ? RosterWorld.Morning : RosterWorld.Evening, feb);
        }
        world.Min(1, shiftId: RosterWorld.Morning);
        world.Min(1, shiftId: RosterWorld.Evening);
        foreach (var d in new[] { new DateOnly(2027, 1, 29), new DateOnly(2027, 1, 30), new DateOnly(2027, 1, 31) })
            world.Work(1, d, RosterWorld.Evening);
        world.Rest(1, feb);
        world.Anchor(1, feb, 6);

        var p = world.Plan(feb).Preview;

        var tuesday = p.Cell(1, feb.AddDays(1));
        Assert.Equal(("work", RosterWorld.Evening), (tuesday.State, tuesday.ShiftId));
        Assert.Equal(RosterPlanner.ReasonShiftCover, tuesday.ReasonCode);
        Assert.DoesNotContain(p.Issues, i => i.Code == "WEEKLY_REST_HOURS" && i.EmployeeId == 1);
    }
}
