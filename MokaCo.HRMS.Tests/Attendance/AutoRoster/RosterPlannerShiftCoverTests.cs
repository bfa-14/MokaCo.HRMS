using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Services.Attendance.AutoRoster;

namespace MokaCo.HRMS.Tests.Attendance.AutoRoster;

/// <summary>
/// D16: every shift the branch must cover — the ones it runs, found from its roster, or the ones the
/// manager set — has its people every day. Rest days are spread so each day holds enough people for
/// all its shifts, someone is moved onto a shift that would be short, and what cannot be covered is
/// reported by shift.
/// </summary>
public class RosterPlannerShiftCoverTests
{
    private static readonly DateOnly Dec = new(2026, 12, 1);
    private static readonly DateOnly WindowFrom = new(2026, 11, 30);
    private static readonly DateOnly HistoryFrom = WindowFrom.AddDays(-ShiftCoverDetector.LookbackDays);

    /// <summary>Eight weeks on one shift, Sundays off.</summary>
    private static void History(RosterWorld world, int id, int shift)
    {
        for (var d = HistoryFrom; d < WindowFrom; d = d.AddDays(1))
        {
            if (d.DayOfWeek == DayOfWeek.Sunday)
                world.Rest(id, d);
            else
                world.Work(id, d, shift);
        }
    }

    /// <summary>Five people on mornings, one on evenings: the evening has nobody else on that person's days off.</summary>
    private static RosterWorld MorningsAndOneEvening()
    {
        var world = new RosterWorld().WithStaff(6);
        for (var e = 1; e <= 5; e++)
            History(world, e, RosterWorld.Morning);
        History(world, 6, RosterWorld.Evening);
        return world;
    }

    private static AutoRosterShiftCounter On(AutoRosterPreview p, DateOnly date, int shiftId)
        => p.PerDay.Single(d => d.Date == date).Shifts.Single(s => s.ShiftId == shiftId);

    /* ---- which shifts ---- */

    [Fact]
    public void The_shifts_the_branch_runs_are_found_from_its_last_eight_weeks()
    {
        var world = MorningsAndOneEvening();
        world.Work(1, new DateOnly(2026, 11, 2), RosterWorld.Night);   // one inventory night is not a shift the branch runs
        world.Work(2, new DateOnly(2026, 11, 9), RosterWorld.Night);

        var input = world.Plan(Dec).Input;
        Assert.True(input.ShiftCoverDetected);
        Assert.Equal([RosterWorld.Morning, RosterWorld.Evening], input.ShiftCover.Select(r => r.ShiftId!.Value));
        Assert.All(input.ShiftCover, r => Assert.Equal((null, 1, null), (r.DayOfWeek, r.MinOnDuty, r.TargetOnDuty)));

        var setup = AutoRosterSetupFactory.Create(world.Context(Dec), Dec);
        Assert.True(setup.ShiftCoverDetected);
        Assert.Equal([RosterWorld.Morning, RosterWorld.Evening], setup.ShiftCover.Select(r => r.ShiftId!.Value));
    }

    [Fact]
    public void A_shift_worked_now_and_then_is_still_one_the_branch_runs()
    {
        // Evenings were short-handed: worked on only a third of the days. It is still the branch's
        // evening shift, and covering it every day is exactly what was missing.
        var world = new RosterWorld().WithStaff(4);
        for (var e = 1; e <= 4; e++)
            History(world, e, RosterWorld.Morning);
        for (var d = HistoryFrom; d < WindowFrom; d = d.AddDays(3))
            world.Work(4, d, RosterWorld.Evening);

        Assert.Equal([RosterWorld.Morning, RosterWorld.Evening], world.Plan(Dec).Input.ShiftCover.Select(r => r.ShiftId!.Value));
    }

    [Fact]
    public void A_new_branch_is_read_from_its_weekly_patterns()
    {
        var world = new RosterWorld().WithStaff(3);
        for (byte dow = 1; dow <= 5; dow++)
            world.Patterns.Add(new AutoRosterPatternRow { EmployeeId = 1, DayOfWeek = dow, ShiftId = RosterWorld.Morning });
        foreach (byte dow in new byte[] { 1, 2 })
            world.Patterns.Add(new AutoRosterPatternRow { EmployeeId = 2, DayOfWeek = dow, ShiftId = RosterWorld.Evening });
        world.Patterns.Add(new AutoRosterPatternRow { EmployeeId = 3, DayOfWeek = 3, ShiftId = RosterWorld.Night });   // one weekday only

        Assert.Equal([RosterWorld.Morning, RosterWorld.Evening], world.Plan(Dec).Input.ShiftCover.Select(r => r.ShiftId!.Value));
    }

    [Fact]
    public void With_no_roster_and_no_pattern_no_shift_is_covered()
    {
        var world = new RosterWorld().WithStaff(3);
        var run = world.Plan(Dec);

        Assert.True(run.Input.ShiftCoverDetected);
        Assert.Empty(run.Input.ShiftCover);
        Assert.All(run.Preview.PerDay, d => Assert.Empty(d.Shifts));
        Assert.Empty(run.Preview.Issues.WithCode("SHIFT_UNCOVERED"));
        Assert.DoesNotContain(run.Preview.Cells, c => c.ReasonCode == "WORK_SHIFT_COVER");
    }

    [Fact]
    public void Stored_shift_rows_replace_what_was_found_and_a_zero_minimum_covers_nothing()
    {
        var world = MorningsAndOneEvening();
        world.Min(0, shiftId: RosterWorld.Evening);
        var run = world.Plan(Dec);

        Assert.False(run.Input.ShiftCoverDetected);
        Assert.Empty(run.Input.CoverRulesFor(new DateOnly(2026, 12, 8)));
        Assert.DoesNotContain(run.Preview.Cells, c => c.ReasonCode == "WORK_SHIFT_COVER");

        var onlyMornings = MorningsAndOneEvening();
        onlyMornings.Min(2, shiftId: RosterWorld.Morning);
        var rules = onlyMornings.Plan(Dec).Input.CoverRulesFor(new DateOnly(2026, 12, 8));
        Assert.Equal([(RosterWorld.Morning, 2)], rules.Select(r => (r.ShiftId!.Value, r.MinOnDuty)));
    }

    /* ---- covering them ---- */

    [Fact]
    public void On_the_evening_persons_days_off_a_morning_person_covers_the_evening()
    {
        var world = MorningsAndOneEvening();
        var p = world.Plan(Dec).Preview;

        foreach (var day in p.PerDay)
        {
            Assert.True(On(p, day.Date, RosterWorld.Morning).OnDuty >= 1, $"{day.Date}: no morning");
            Assert.True(On(p, day.Date, RosterWorld.Evening).OnDuty >= 1, $"{day.Date}: no evening");
        }

        var eveningOff = p.Cells.Where(c => c.EmployeeId == 6 && c.State == "rest" && c.WorkDate.Month == 12).Select(c => c.WorkDate).ToList();
        Assert.NotEmpty(eveningOff);
        foreach (var d in eveningOff)
        {
            var cover = p.Cells.Where(c => c.WorkDate == d && c.EmployeeId != 6 && c.State == "work" && c.ShiftId == RosterWorld.Evening).ToList();
            Assert.NotEmpty(cover);
            Assert.All(cover, c => Assert.Equal("WORK_SHIFT_COVER", c.ReasonCode));
            Assert.All(cover, c => Assert.Contains("Evening", c.ReasonArgs));
        }

        Assert.Empty(p.Issues.WithCode("SHIFT_UNCOVERED"));
        Assert.Empty(p.Issues.WithCode("SHORT_STAFFED"));
        Assert.Empty(p.Issues.WithCode("TURNAROUND"));   // whoever covers an evening does not start at seven the next morning
        Assert.All(p.PerEmployee, e => Assert.All(e.Weeks, w => Assert.True(w.Ok)));   // nobody lost a rest day for it
    }

    [Fact]
    public void Covering_is_shared_out_instead_of_falling_on_one_person()
    {
        var world = MorningsAndOneEvening();
        var p = world.Plan(Dec).Preview;

        var covers = p.Cells.Where(c => c.ReasonCode == "WORK_SHIFT_COVER" && c.WorkDate.Month == 12)
            .GroupBy(c => c.EmployeeId)
            .ToDictionary(g => g.Key, g => g.Count());
        Assert.True(covers.Count >= 2, $"one person covered every evening: {string.Join(", ", covers)}");
    }

    [Fact]
    public void Rest_days_are_spread_so_every_day_has_enough_people_for_its_shifts()
    {
        // Four people, two shifts with two each: four on duty every day would leave no rest at all, so
        // what the planner can promise is that no day falls below what the rests allow — and that every
        // shortage is reported by shift.
        var world = new RosterWorld().WithStaff(6);
        for (var e = 1; e <= 3; e++)
            History(world, e, RosterWorld.Morning);
        for (var e = 4; e <= 6; e++)
            History(world, e, RosterWorld.Evening);
        world.Min(2, shiftId: RosterWorld.Morning);
        world.Min(2, shiftId: RosterWorld.Evening);
        var p = world.Plan(Dec, "FillEmpty", r => r.RhythmStart = "Staggered").Preview;   // 3×1 + 3×2 = 9 rests a week

        Assert.All(p.PerDay, d => Assert.True(d.OnDuty >= 4, $"{d.Date}: {d.OnDuty} on duty"));
        Assert.All(p.PerDay, d => Assert.All(d.Shifts, s => Assert.True(s.OnDuty >= 2, $"{d.Date}: {s.OnDuty} on shift {s.ShiftId}")));
        Assert.Empty(p.Issues.WithCode("SHIFT_UNCOVERED"));
        Assert.All(p.PerEmployee, e => Assert.All(e.Weeks, w => Assert.True(w.Ok)));
    }

    [Fact]
    public void A_shift_nobody_can_cover_is_reported_and_no_rest_day_is_taken_for_it()
    {
        var world = new RosterWorld().WithStaff(1);
        History(world, 1, RosterWorld.Morning);
        world.Min(1, shiftId: RosterWorld.Morning);
        world.Min(1, shiftId: RosterWorld.Evening);
        var p = world.Plan(Dec).Preview;

        // One person, two shifts: one shift is empty on every working day, both on every day off.
        var uncovered = p.Issues.WithCode("SHIFT_UNCOVERED").ToList();
        foreach (var day in p.PerDay)
            Assert.Equal(p.Cell(1, day.Date).State == "work" ? 1 : 2, uncovered.Count(i => i.Date == day.Date));
        Assert.All(uncovered, i => Assert.Equal("warning", i.Severity));
        Assert.Contains(uncovered, i => i.Message.Contains("Evening"));
        Assert.All(p.PerEmployee, e => Assert.All(e.Weeks, w => Assert.True(w.Ok)));
    }

    [Fact]
    public void A_target_per_shift_moves_people_only_from_a_shift_above_its_own()
    {
        var world = MorningsAndOneEvening();
        world.Min(1, shiftId: RosterWorld.Morning, target: 2);
        world.Min(1, shiftId: RosterWorld.Evening, target: 2);
        var p = world.Plan(Dec).Preview;

        foreach (var day in p.PerDay)
        {
            var morning = On(p, day.Date, RosterWorld.Morning).OnDuty;
            var evening = On(p, day.Date, RosterWorld.Evening).OnDuty;
            Assert.True(evening >= 2 || morning <= 2, $"{day.Date}: {morning} mornings left {evening} evenings under target");
            Assert.True(morning >= 1 && evening >= 1, $"{day.Date}: {morning}/{evening}");
        }
    }

    [Fact]
    public void An_open_holiday_covers_its_shifts_with_the_cover_asked_for()
    {
        var world = MorningsAndOneEvening();
        var holiday = new DateOnly(2026, 12, 9);
        world.Holiday(holiday, "Feast");

        var two = world.Plan(Dec, "FillEmpty", r => r.HolidayCover = [new HolidayCoverDto { Date = holiday, Count = 2 }]).Preview;
        Assert.Equal(1, On(two, holiday, RosterWorld.Morning).OnDuty);
        Assert.Equal(1, On(two, holiday, RosterWorld.Evening).OnDuty);
        Assert.DoesNotContain(two.Issues, i => i.Date == holiday && i.Code == "SHIFT_UNCOVERED");

        var one = world.Plan(Dec, "FillEmpty", r => r.HolidayCover = [new HolidayCoverDto { Date = holiday, Count = 1 }]).Preview;
        var note = Assert.Single(one.Issues, i => i.Date == holiday && i.Code == "SHIFT_UNCOVERED");
        Assert.Equal("info", note.Severity);   // the manager chose one person for the day

        var closed = world.Plan(Dec).Preview;
        Assert.Empty(closed.PerDay.Single(d => d.Date == holiday).Shifts);
        Assert.DoesNotContain(closed.Issues, i => i.Date == holiday && i.Code == "SHIFT_UNCOVERED");
    }

    [Fact]
    public void A_draft_edit_is_never_moved_to_cover_a_shift()
    {
        var world = MorningsAndOneEvening();
        var first = world.Plan(Dec).Preview;
        var day = first.Cells.First(c => c.EmployeeId == 6 && c.State == "rest" && c.WorkDate.Month == 12).WorkDate;
        var drafts = Enumerable.Range(1, 5)
            .Select(e => new DraftCellDto { EmployeeId = e, WorkDate = day, ShiftId = RosterWorld.Morning })
            .ToList();

        var p = world.Plan(Dec, "FillEmpty", r => r.DraftCells = drafts).Preview;
        Assert.All(Enumerable.Range(1, 5), e => Assert.Equal(RosterWorld.Morning, p.Cell(e, day).ShiftId));
        Assert.Contains(p.Issues, i => i.Date == day && i.Code == "SHIFT_UNCOVERED" && i.Message.Contains("Evening"));
    }

    /* ---- the commit, and running it again ---- */

    [Fact]
    public void Saving_an_edit_that_empties_a_shift_is_reported_by_the_commit()
    {
        var world = MorningsAndOneEvening();
        var run = world.Plan(Dec);
        var commit = RosterWorld.CommitRequestFor(run.Request, run.Preview);
        var day = run.Preview.Cells.First(c => c.EmployeeId == 6 && c.State == "work" && c.WorkDate.Month == 12).WorkDate;
        foreach (var cell in commit.Cells.Where(c => c.WorkDate == day && c.ShiftId == RosterWorld.Evening))
            cell.ShiftId = RosterWorld.Morning;

        var issues = RosterPlanValidator.ValidateSubmission(run.Input, commit.Cells, commit.Rhythm);
        Assert.Contains(issues, i => i.Date == day && i.Code == "SHIFT_UNCOVERED" && i.Severity == "warning");
        Assert.False(RosterPlanValidator.HasErrors(issues.Where(i => i.Code == "SHIFT_UNCOVERED")));
    }

    [Fact]
    public void Regenerating_a_saved_plan_moves_nobody_else()
    {
        var world = MorningsAndOneEvening();
        var (run, issues) = world.PlanAndCommit(Dec);
        Assert.False(RosterPlanValidator.HasErrors(issues));
        Assert.Contains(run.Preview.Cells, c => c.ReasonCode == "WORK_SHIFT_COVER");

        var again = world.Plan(Dec, "ReplanAuto").Preview;
        Assert.Equal(0, again.Changes());
        var all = world.Plan(Dec, "ReplanAll").Preview;
        Assert.Equal(0, all.Changes());
    }
}
