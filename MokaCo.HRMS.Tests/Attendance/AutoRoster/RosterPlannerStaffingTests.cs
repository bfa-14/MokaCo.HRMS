using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Services.Attendance.AutoRoster;

namespace MokaCo.HRMS.Tests.Attendance.AutoRoster;

/// <summary>D8: minimum on duty — met when the rests fit, reported (never paid for with a rest day) when they do not.</summary>
public class RosterPlannerStaffingTests
{
    private static readonly DateOnly Dec = new(2026, 12, 1);

    private static int OnDuty(AutoRosterPreview p, DateOnly d) => p.PerDay.Single(x => x.Date == d).OnDuty;

    [Fact]
    public void Without_staffing_rows_the_rests_are_spread_so_on_duty_is_level()
    {
        var world = new RosterWorld().WithStaff(7);
        var p = world.Plan(Dec).Preview;

        // Aligned: 7 rests in a 6-day week, 14 in a 5-day week — one or two off every day.
        foreach (var ws in new[] { new DateOnly(2026, 12, 7), new DateOnly(2026, 12, 14) })
        {
            var duty = Enumerable.Range(0, 7).Select(i => OnDuty(p, ws.AddDays(i))).ToList();
            Assert.True(duty.Max() - duty.Min() <= 1, $"week {ws}: {string.Join(",", duty)}");
        }
    }

    [Fact]
    public void The_minimum_is_met_when_the_rests_fit()
    {
        var world = new RosterWorld().WithStaff(6);
        world.Min(4);
        var p = world.Plan(Dec, "FillEmpty", r => r.RhythmStart = "Staggered").Preview;   // 3×1 + 3×2 = 9 rests a week

        Assert.Empty(p.Issues.WithCode("SHORT_STAFFED"));
        Assert.All(p.PerDay, d => Assert.True(d.OnDuty >= 4, $"{d.Date}: {d.OnDuty}"));
        Assert.All(p.PerEmployee, e => Assert.All(e.Weeks, w => Assert.True(w.Ok)));
    }

    [Fact]
    public void When_the_rests_cannot_fit_the_days_are_short_staffed_and_every_rest_is_kept()
    {
        var world = new RosterWorld().WithStaff(6);
        world.Min(5);
        var p = world.Plan(Dec).Preview;   // aligned: 12 rests in a 5-day week, at most 7 fit one-a-day

        Assert.All(p.PerEmployee, e => Assert.All(e.Weeks, w => Assert.True(w.Ok, $"{e.EmployeeId} {w.WeekStart}")));

        foreach (var ws in new[] { new DateOnly(2026, 12, 7), new DateOnly(2026, 12, 21) })   // 5-day weeks
        {
            var shortDays = Enumerable.Range(0, 7).Select(i => ws.AddDays(i)).Where(d => OnDuty(p, d) < 5).ToList();
            Assert.Equal(5, shortDays.Count);   // 12 − 7: no more short days than the arithmetic forces
            Assert.All(shortDays, d => Assert.Contains(p.Issues, i => i.Code == "SHORT_STAFFED" && i.Date == d && i.Severity == "warning"));
        }

        var sixDayWeek = new DateOnly(2026, 12, 14);
        Assert.All(Enumerable.Range(0, 7), i => Assert.True(OnDuty(p, sixDayWeek.AddDays(i)) >= 5));
    }

    [Fact]
    public void A_weekday_minimum_beats_the_every_day_one_and_keeps_rests_off_that_day()
    {
        var world = new RosterWorld().WithStaff(5);
        world.Min(3);
        world.Min(5, dayOfWeek: 6);   // Saturday: everybody
        var p = world.Plan(Dec).Preview;

        Assert.DoesNotContain(p.Cells, c => c.WorkDate.DayOfWeek == DayOfWeek.Saturday && c.State == "rest" && c.Origin == "planned");
        Assert.DoesNotContain(p.Issues, i => i.Code == "SHORT_STAFFED" && i.Date is { DayOfWeek: DayOfWeek.Saturday });
        Assert.All(p.PerDay.Where(d => d.Date.DayOfWeek == DayOfWeek.Saturday), d => Assert.Equal(5, d.Min));
        Assert.All(p.PerDay.Where(d => d.Date.DayOfWeek == DayOfWeek.Monday), d => Assert.Equal(3, d.Min));
    }

    [Fact]
    public void A_per_shift_minimum_is_checked_on_that_shift()
    {
        var world = new RosterWorld().WithStaff(3);
        foreach (var e in new[] { 1, 2 })
            for (byte dow = 1; dow <= 7; dow++)
                world.Patterns.Add(new AutoRosterPatternRow { EmployeeId = e, DayOfWeek = dow, ShiftId = RosterWorld.Evening });
        world.Min(2, shiftId: RosterWorld.Evening);
        var p = world.Plan(Dec).Preview;

        Assert.All(p.Cells.Where(c => c.EmployeeId <= 2 && c.State == "work" && c.Origin == "planned"), c => Assert.Equal(RosterWorld.Evening, c.ShiftId));
        var dayOff = p.Cells.First(c => c.EmployeeId == 1 && c.State == "rest" && c.WorkDate.Month == 12).WorkDate;
        Assert.Contains(p.Issues, i => i.Code == "SHORT_STAFFED" && i.Date == dayOff && i.Message.Contains("Evening"));
    }

    [Theory]
    [InlineData(2)]
    [InlineData(3)]
    public void Small_branches_keep_all_but_one_on_duty(int size)
    {
        var world = new RosterWorld().WithStaff(size);
        world.Min(size - 1);
        var p = world.Plan(Dec).Preview;

        Assert.Empty(p.Issues.WithCode("SHORT_STAFFED"));
        Assert.All(p.PerDay, d => Assert.True(d.OnDuty >= size - 1));
        Assert.All(p.PerEmployee, e => Assert.All(e.Weeks, w => Assert.True(w.Ok)));
    }

    [Fact]
    public void A_4_person_branch_aligned_is_short_once_in_each_5_day_week_and_staggered_never()
    {
        var aligned = new RosterWorld().WithStaff(4);
        aligned.Min(3);
        var a = aligned.Plan(Dec).Preview;
        Assert.All(a.PerEmployee, e => Assert.All(e.Weeks, w => Assert.True(w.Ok)));   // rest beats staffing
        var shortDays = a.Issues.WithCode("SHORT_STAFFED").Select(i => i.Date!.Value).ToList();
        Assert.Equal(1, shortDays.Count(d => d >= new DateOnly(2026, 12, 7) && d <= new DateOnly(2026, 12, 13)));   // 8 rests on 7 days → exactly one day with two off
        Assert.DoesNotContain(shortDays, d => d >= new DateOnly(2026, 12, 14) && d <= new DateOnly(2026, 12, 20));

        var staggered = new RosterWorld();
        for (var e = 1; e <= 4; e++)
            staggered.Add(e, positionId: e);
        staggered.Min(3);
        var s = staggered.Plan(Dec, "FillEmpty", r => r.RhythmStart = "Staggered").Preview;
        Assert.Empty(s.Issues.WithCode("SHORT_STAFFED"));
        Assert.All(s.PerEmployee, e => Assert.All(e.Weeks, w => Assert.True(w.Ok)));
    }

    [Fact]
    public void Repair_moves_a_rest_off_a_day_below_its_minimum_when_another_day_can_take_it()
    {
        // Two people whose pattern prefers Monday off and a Monday minimum of 2: the pattern pulls
        // both rests to Monday, the minimum pushes one away.
        var world = new RosterWorld().WithStaff(3);
        foreach (var e in new[] { 1, 2 })
            world.Patterns.Add(new AutoRosterPatternRow { EmployeeId = e, DayOfWeek = 1, IsRestDay = true });
        world.Min(2, dayOfWeek: 1);
        var p = world.Plan(Dec).Preview;

        Assert.All(p.PerDay.Where(d => d.Date.DayOfWeek == DayOfWeek.Monday), d => Assert.True(d.OnDuty >= 2, $"{d.Date}: {d.OnDuty}"));
        Assert.Empty(p.Issues.WithCode("SHORT_STAFFED"));
    }
}
