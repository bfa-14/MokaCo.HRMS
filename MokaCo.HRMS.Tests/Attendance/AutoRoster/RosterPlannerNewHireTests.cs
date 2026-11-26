using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Services.Attendance.AutoRoster;

namespace MokaCo.HRMS.Tests.Attendance.AutoRoster;

/// <summary>
/// R6, the owner's words: "in the first 3 months 6 days working, and after 3 months of employment one week 6 days working
/// and the next week 5 days working and so on". A Monday-Sunday week that starts before W0 (the first Monday on or after
/// the hire date + RosterNewHireSixDayMonths months) is a 6-day week whatever any anchor says; from W0 the person alternates
/// 6, 5, 6, 5 with W0 a 6-day week, unless a stored anchor or the drawer chose otherwise there.
/// </summary>
public class RosterPlannerNewHireTests
{
    private static readonly DateOnly Dec = new(2026, 12, 1);

    /// <summary>Rest rows of a week as saved (leave days excluded): 1 for a 6-day week, 2 for a 5-day week.</summary>
    private static int Rests(RosterWorld world, int id, DateOnly weekStart) => world.RestsInWeek(id, weekStart);

    [Fact]
    public void A_new_hire_works_6_days_every_week_for_three_months_then_6_5_6_5_starting_with_6()
    {
        // Hired Wednesday 9 September 2026: three months end on Wednesday 9 December, so W0 is Monday 14 December.
        var world = new RosterWorld().WithStaff(3);
        world.Add(9, hire: new DateOnly(2026, 9, 9));
        foreach (var month in new[] { new DateOnly(2026, 10, 1), new DateOnly(2026, 11, 1), Dec, new DateOnly(2027, 1, 1) })
        {
            var (run, issues) = world.PlanAndCommit(month);
            Assert.Empty(run.Preview.Errors());
            Assert.DoesNotContain(issues, i => i.EmployeeId == 9 && i.Code is "RHYTHM_SHORT" or "RHYTHM_OVER");
            Assert.Equal(new DateOnly(2026, 12, 14), run.Input.AlternateFrom(9));
        }

        for (var ws = new DateOnly(2026, 9, 28); ws < new DateOnly(2026, 12, 14); ws = ws.AddDays(7))
            Assert.True(Rests(world, 9, ws) == 1, $"week of {ws}: {Rests(world, 9, ws)} rests in the first three months");
        Assert.Equal(1, Rests(world, 9, new DateOnly(2026, 12, 14)));   // W0: a 6-day week
        Assert.Equal(2, Rests(world, 9, new DateOnly(2026, 12, 21)));
        Assert.Equal(1, Rests(world, 9, new DateOnly(2026, 12, 28)));
        Assert.Equal(2, Rests(world, 9, new DateOnly(2027, 1, 4)));
        Assert.Equal(1, Rests(world, 9, new DateOnly(2027, 1, 11)));

        // The saved anchor is W0 as a 6-day week: next month's run carries the same alternation on.
        var stored = world.Rhythms[9];
        Assert.Equal((new DateOnly(2026, 12, 14), 6), (RosterWorld.D(stored.AnchorWeekStart), (int)stored.AnchorWorkDays));

        // The others were never new: 6, 5, 6, 5 from their first planned week.
        Assert.Equal(1, Rests(world, 1, new DateOnly(2026, 9, 28)));
        Assert.Equal(2, Rests(world, 1, new DateOnly(2026, 10, 5)));
    }

    [Fact]
    public void Without_a_hire_date_the_alternation_starts_as_before()
    {
        var world = new RosterWorld().WithStaff(2);
        world.Add(9, hire: new DateOnly(2026, 11, 2));
        var request = world.Request(Dec);

        var recent = RosterPlanner.Plan(AutoRosterInputFactory.Create(world.Context(Dec), request)).Preview;
        Assert.All(recent.PerEmployee.Single(e => e.EmployeeId == 9).Weeks, w => Assert.Equal(6, w.WorkDays));

        var context = world.Context(Dec);
        context.Staff.Single(s => s.EmployeeId == 9).HireDate = null;
        var input = AutoRosterInputFactory.Create(context, request);
        Assert.Null(input.AlternateFrom(9));
        var unknown = RosterPlanner.Plan(input).Preview;
        Assert.Equal(new[] { 6, 5, 6, 5, 6 }, unknown.PerEmployee.Single(e => e.EmployeeId == 9).Weeks.Select(w => w.WorkDays));
        var rhythm = unknown.Rhythm.Single(r => r.EmployeeId == 9);
        Assert.Equal((new DateOnly(2026, 11, 30), 6), (rhythm.AnchorWeekStart, rhythm.AnchorWorkDays));
    }

    [Fact]
    public void A_stored_anchor_decides_the_weeks_from_W0_on_but_never_the_weeks_before()
    {
        var world = new RosterWorld().WithStaff(2);

        // Past the new-hire period (W0 = 23 Nov): the stored anchor's alternation, a 5-day week on 30 November.
        world.Add(8, hire: new DateOnly(2026, 8, 20));
        world.Anchor(8, new DateOnly(2026, 11, 30), 5);

        // Still in it (W0 = 4 Jan 2027): an anchor stored for a week before W0 does not apply before W0.
        world.Add(9, hire: new DateOnly(2026, 10, 1));
        world.Anchor(9, new DateOnly(2026, 11, 30), 5);

        var p = world.Plan(Dec).Preview;
        Assert.Equal(new[] { 5, 6, 5, 6, 5 }, p.PerEmployee.Single(e => e.EmployeeId == 8).Weeks.Select(w => w.WorkDays));
        Assert.Equal(new[] { 6, 6, 6, 6, 6 }, p.PerEmployee.Single(e => e.EmployeeId == 9).Weeks.Select(w => w.WorkDays));
        Assert.All(p.Rhythm.Where(r => r.EmployeeId is 8 or 9), r => Assert.False(r.IsNew));
        Assert.All(p.PerEmployee.Where(e => e.EmployeeId is 8 or 9), e => Assert.All(e.Weeks, w => Assert.True(w.Ok)));

        // From W0 on the stored alternation applies: 4 January 2027 is five weeks after the 5-day week of 30 November.
        var jan = world.Plan(new DateOnly(2027, 1, 1)).Preview;
        Assert.Equal(6, jan.Week(9, new DateOnly(2027, 1, 4)).WorkDays);
        Assert.Equal(5, jan.Week(9, new DateOnly(2027, 1, 11)).WorkDays);
    }

    [Fact]
    public void The_drawers_override_applies_from_W0_on()
    {
        // W0 = 14 December. The manager makes the week of 14 December a 5-day week: it is, and the weeks before stay 6.
        var world = new RosterWorld().WithStaff(2);
        world.Add(9, hire: new DateOnly(2026, 9, 9));
        var p = world.Plan(Dec, "FillEmpty", r => r.RhythmOverrides.Add(new RhythmOverrideDto { EmployeeId = 9, WeekStart = new DateOnly(2026, 12, 14), WorkDays = 5 })).Preview;

        Assert.Equal(new[] { 6, 6, 5, 6, 5 }, p.PerEmployee.Single(e => e.EmployeeId == 9).Weeks.Select(w => w.WorkDays));
        var rhythm = p.Rhythm.Single(r => r.EmployeeId == 9);
        Assert.Equal((new DateOnly(2026, 12, 14), 5, true), (rhythm.AnchorWeekStart, rhythm.AnchorWorkDays, rhythm.IsNew));
    }

    [Theory]
    [InlineData(5)]
    [InlineData(6)]
    public void A_first_week_override_for_a_week_of_the_new_hire_period_is_ignored_and_W0_starts_the_alternation(int workDays)
    {
        // W0 = 14 December. An old draft (or another API caller) still sends a 6/5 choice for the first week, 30 November, which
        // is a week of the new-hire period: the drawer no longer offers it there. It changes nothing before W0, and it must not
        // decide W0's parity either: W0 is a 6-day week, and the anchor the preview returns - the one the commit saves - is W0.
        var world = new RosterWorld().WithStaff(2);
        world.Add(9, hire: new DateOnly(2026, 9, 9));
        var p = world.Plan(Dec, "FillEmpty", r => r.RhythmOverrides.Add(new RhythmOverrideDto { EmployeeId = 9, WeekStart = new DateOnly(2026, 12, 2), WorkDays = workDays })).Preview;

        Assert.Equal(new[] { 6, 6, 6, 5, 6 }, p.PerEmployee.Single(e => e.EmployeeId == 9).Weeks.Select(w => w.WorkDays));
        var rhythm = p.Rhythm.Single(r => r.EmployeeId == 9);
        Assert.Equal((new DateOnly(2026, 12, 14), 6), (rhythm.AnchorWeekStart, rhythm.AnchorWorkDays));

        // The commit saves what the planner resolves for an anchor sent for a week before W0, whatever the client sends; a row
        // for W0 or later, and a row taking somebody off the rotation, are saved as sent.
        var run = world.Plan(Dec);
        var sent = new List<AutoRosterCommitRhythm>
        {
            new() { EmployeeId = 9, AnchorWeekStart = new DateOnly(2026, 11, 30), AnchorWorkDays = 5 },
            new() { EmployeeId = 1, AnchorWeekStart = new DateOnly(2026, 11, 30), AnchorWorkDays = 5 },
            new() { EmployeeId = 2, AnchorWeekStart = new DateOnly(2026, 11, 30), AnchorWorkDays = 6, OnRotation = false },
        };
        var saved = RosterPlanValidator.RhythmToSave(run.Input, sent);
        Assert.Equal((new DateOnly(2026, 12, 14), 6, true), (saved[0].AnchorWeekStart, saved[0].AnchorWorkDays, saved[0].OnRotation));
        Assert.Same(sent[1], saved[1]);
        Assert.Same(sent[2], saved[2]);
    }

    [Fact]
    public void The_commit_judges_a_new_hire_week_as_a_6_day_week_whatever_anchor_the_client_sends()
    {
        var world = new RosterWorld().WithStaff(2);
        world.Add(9, hire: new DateOnly(2026, 11, 2));
        var run = world.Plan(Dec);
        var commit = RosterWorld.CommitRequestFor(run.Request, run.Preview);

        // The client claims the week of 7 December is a 5-day week (two rests due). It is a week of the new-hire
        // period: one rest is due, and the plan's one rest is right.
        commit.Rhythm.RemoveAll(r => r.EmployeeId == 9);
        commit.Rhythm.Add(new AutoRosterCommitRhythm { EmployeeId = 9, AnchorWeekStart = new DateOnly(2026, 12, 7), AnchorWorkDays = 5 });
        var issues = RosterPlanValidator.ValidateSubmission(run.Input, commit.Cells, commit.Rhythm);
        Assert.DoesNotContain(issues, i => i.EmployeeId == 9 && i.Code is "RHYTHM_SHORT" or "RHYTHM_OVER");

        // A second rest in that week is one more than due.
        var work = commit.Cells.First(c => c.EmployeeId == 9 && !c.IsRestDay && c.WorkDate >= new DateOnly(2026, 12, 7) && c.WorkDate <= new DateOnly(2026, 12, 13));
        work.IsRestDay = true;
        work.ShiftId = null;
        issues = RosterPlanValidator.ValidateSubmission(run.Input, commit.Cells, commit.Rhythm);
        var over = Assert.Single(issues, i => i.EmployeeId == 9 && i.Code == "RHYTHM_OVER");
        Assert.Contains("6-day week", over.Message);
    }

    [Theory]
    [InlineData(null, 3)]
    [InlineData("1", 1)]
    [InlineData("6", 6)]
    [InlineData("0", 3)]
    [InlineData("-2", 3)]
    [InlineData("three", 3)]
    public void The_number_of_months_comes_from_the_setting(string? value, int months)
    {
        var world = new RosterWorld().WithStaff(1);
        world.Add(9, hire: new DateOnly(2026, 9, 9));
        if (value is not null)
            world.Settings["RosterNewHireSixDayMonths"] = value;

        var input = world.Plan(Dec).Input;
        Assert.Equal(months, input.Settings.NewHireSixDayMonths);
        var end = new DateOnly(2026, 9, 9).AddMonths(months);
        var w0 = input.AlternateFrom(9)!.Value;
        Assert.Equal(DayOfWeek.Monday, w0.DayOfWeek);
        Assert.True(w0 >= end && w0 < end.AddDays(7));
        if (months == 3)
            Assert.Equal(new DateOnly(2024, 4, 1), input.AlternateFrom(1));   // hired Monday 1 January 2024: W0 is Monday 1 April
    }
}
