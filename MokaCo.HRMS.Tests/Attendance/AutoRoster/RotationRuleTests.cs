using System.Collections.Frozen;
using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Services.Attendance.AutoRoster;

namespace MokaCo.HRMS.Tests.Attendance.AutoRoster;

/// <summary>
/// THE FIXED ROTATION is the owner's spreadsheet rule. <see cref="Sheet"/> below was produced by an independent
/// reading of the Excel formula (INT floors, MOD is never negative, WEEKDAY(d,3) is Monday = 0, COUNTIF over the cells
/// above, ROW() = the sheet row): ten weeks, seven people, starting two weeks BEFORE the rotation's start date. The
/// rule must give the same cell everywhere; then the planner must give the same again on a month nobody has touched,
/// and must leave alone what the sheet never knew about (a hand edit, a leave, a holiday).
/// </summary>
public class RotationRuleTests
{
    private static readonly DateOnly Start = new(2026, 11, 30);   // a Monday: week 0

    //                                                  B  C  D  E
    private static readonly (int Group, int Single, int Pair, string? Lead)[] People =
    [
        (0, 0, 5, "L1"), (1, 3, 1, "L2"), (0, 2, 3, null), (1, 6, 0, null), (0, 4, 6, null), (1, 1, 2, null), (0, 5, 4, null),
    ];

    private static readonly string[] Sheet =
    [
        "2026-11-16 M E M E M E M",
        "2026-11-17 M OFF OFF E E M E",
        "2026-11-18 M E OFF E M E OFF",
        "2026-11-19 OFF E M M E M OFF",
        "2026-11-20 OFF E M OFF OFF E M",
        "2026-11-21 M E E M OFF M E",
        "2026-11-22 M E M E M OFF E",
        "2026-11-23 E OFF OFF M E OFF M",
        "2026-11-24 E M M E M OFF E",
        "2026-11-25 E M E M OFF M E",
        "2026-11-26 E M M E M E OFF",
        "2026-11-27 E M E M E M E",
        "2026-11-28 OFF M E OFF M E M",
        "2026-11-29 E OFF M OFF E M E",
        "2026-11-30 M E M E OFF E M",
        "2026-12-01 M E E M E OFF M",
        "2026-12-02 M E M E M E M",
        "2026-12-03 M OFF OFF E E M E",
        "2026-12-04 M E OFF E M E OFF",
        "2026-12-05 OFF E M M E M OFF",
        "2026-12-06 OFF E M OFF OFF E M",
        "2026-12-07 OFF M E OFF E M E",
        "2026-12-08 E OFF M OFF M E M",
        "2026-12-09 E OFF OFF M E OFF M",
        "2026-12-10 E M M E M OFF E",
        "2026-12-11 E M E M OFF M E",
        "2026-12-12 E M M E M E OFF",
        "2026-12-13 E M E M E M E",
        "2026-12-14 OFF E M E M E OFF",
        "2026-12-15 OFF E M OFF OFF M E",
        "2026-12-16 M E M E OFF E M",
        "2026-12-17 M E E M E OFF M",
        "2026-12-18 M E M E M E M",
        "2026-12-19 M OFF OFF E E M E",
        "2026-12-20 M E OFF E M E OFF",
        "2026-12-21 E M E M E M OFF",
        "2026-12-22 E M M E M E M",
        "2026-12-23 OFF M E OFF E M E",
        "2026-12-24 E OFF M OFF M E M",
        "2026-12-25 E OFF OFF M E OFF M",
        "2026-12-26 E M M E M OFF E",
        "2026-12-27 E M E M OFF M E",
        "2026-12-28 M OFF OFF E M E M",
        "2026-12-29 M E OFF M E M OFF",
        "2026-12-30 OFF E M E M E OFF",
        "2026-12-31 OFF E M OFF OFF M E",
        "2027-01-01 M E M E OFF E M",
        "2027-01-02 M E E M E OFF M",
        "2027-01-03 M E M E M E M",
        "2027-01-04 E M E M E OFF M",
        "2027-01-05 E M M E OFF E M",
        "2027-01-06 E M E M E M OFF",
        "2027-01-07 E M M E M E M",
        "2027-01-08 OFF M E OFF E M E",
        "2027-01-09 E OFF M OFF M E M",
        "2027-01-10 E OFF OFF M E OFF M",
        "2027-01-11 M E M E M OFF E",
        "2027-01-12 M E E M E M E",
        "2027-01-13 M OFF OFF E M E M",
        "2027-01-14 M E OFF M E M OFF",
        "2027-01-15 OFF E M E M E OFF",
        "2027-01-16 OFF E M OFF OFF M E",
        "2027-01-17 M E M E OFF E M",
        "2027-01-18 E OFF M OFF E M E",
        "2027-01-19 E OFF OFF M M OFF E",
        "2027-01-20 E M E M E OFF M",
        "2027-01-21 E M M E OFF E M",
        "2027-01-22 E M E M E M OFF",
        "2027-01-23 E M M E M E M",
        "2027-01-24 OFF M E OFF E M E",
    ];

    private static IEnumerable<(DateOnly Date, string[] Cells)> SheetRows()
        => Sheet.Select(line => line.Split(' ')).Select(p => (DateOnly.Parse(p[0]), p[1..]));

    private static RotationSetup Setup()
        => new(Start, RosterWorld.Morning, RosterWorld.Evening,
            People.Select((p, i) => new RotationMember(i + 1, p.Group, p.Single, p.Pair, p.Lead, i + 1)).ToFrozenDictionary(m => m.EmployeeId));

    private static RosterRotationDto Stored() => new()
    {
        BranchId = RosterWorld.Branch,
        StartDate = Start,
        MorningShiftId = RosterWorld.Morning,
        EveningShiftId = RosterWorld.Evening,
        Members = People.Select((p, i) => new RosterRotationMemberDto
        {
            EmployeeId = i + 1, Group = p.Group, SingleRestDay = p.Single, PairRestDay = p.Pair, LeadSlot = p.Lead, SortOrder = i + 1,
        }).ToList(),
    };

    [Fact]
    public void The_rule_gives_the_spreadsheets_cell_everywhere()
    {
        var setup = Setup();
        var ordered = RotationRule.Ordered(setup, Enumerable.Range(1, People.Length));
        foreach (var (date, cells) in SheetRows())
            Assert.Equal(cells, RotationRule.Column(setup, ordered, date));
    }

    [Fact]
    public void Days_off_alternate_two_and_one_and_move_two_weekdays_every_two_weeks()
    {
        var setup = Setup();
        var lead = setup.Members[1];   // group 0, single Monday, pair Saturday+Sunday
        int Off(DateOnly weekStart) => Enumerable.Range(0, 7).Count(i => RotationRule.IsOff(setup, lead, weekStart.AddDays(i)));
        Assert.Equal([2, 1, 2, 1], Enumerable.Range(0, 4).Select(w => Off(Start.AddDays(7 * w))));

        // Weeks 0-1: Saturday+Sunday, then Monday. Weeks 2-3: two weekdays later - Monday+Tuesday, then Wednesday.
        Assert.True(RotationRule.IsOff(setup, lead, Start.AddDays(5)) && RotationRule.IsOff(setup, lead, Start.AddDays(6)));
        Assert.True(RotationRule.IsOff(setup, lead, Start.AddDays(7)));
        Assert.True(RotationRule.IsOff(setup, lead, Start.AddDays(14)) && RotationRule.IsOff(setup, lead, Start.AddDays(15)));
        Assert.True(RotationRule.IsOff(setup, lead, Start.AddDays(21 + 2)));
        // After 14 weeks the days off are back where they started.
        for (var i = 0; i < 14; i++)
            Assert.Equal(RotationRule.IsOff(setup, lead, Start.AddDays(i)), RotationRule.IsOff(setup, lead, Start.AddDays(i + 98)));
    }

    [Fact]
    public void The_planner_writes_the_spreadsheet_on_a_month_nobody_has_touched()
    {
        var world = new RosterWorld { Today = new DateOnly(2026, 11, 1), Rotation = Stored() }.WithStaff(People.Length);
        var run = world.Plan(new DateOnly(2026, 12, 1), configure: r => r.Method = "Rotation");

        var cells = run.Preview.Cells.ToDictionary(c => (c.EmployeeId, c.WorkDate));
        foreach (var (date, expected) in SheetRows().Where(r => r.Date.Month == 12))
        {
            for (var i = 0; i < People.Length; i++)
            {
                var cell = cells[(i + 1, date)];
                var got = cell.State == "rest" ? "OFF" : cell.ShiftId == RosterWorld.Morning ? "M" : cell.ShiftId == RosterWorld.Evening ? "E" : cell.State;
                Assert.True(expected[i] == got, $"{date:yyyy-MM-dd}, person {i + 1}: the sheet says {expected[i]}, the planner {got}");
            }
        }

        // The 6/5 it implies is saved in the auto-roster's own terms: group 0 starts on a 5-day week, group 1 on a 6-day week.
        Assert.Equal(5, run.Plan.Rhythms[1].WorkDaysIn(Start));
        Assert.Equal(6, run.Plan.Rhythms[2].WorkDaysIn(Start));
        Assert.DoesNotContain(run.Preview.Issues, i => i.Severity == RosterPlanValidator.Error);
    }

    [Fact]
    public void A_long_run_of_the_rule_is_shown_not_refused_and_the_plan_can_be_saved()
    {
        // Person 1: Monday off in the one-day week, Saturday+Sunday in the two-day week - eleven working days between them.
        var world = new RosterWorld { Today = new DateOnly(2026, 11, 1), Rotation = Stored() }.WithStaff(People.Length);
        var (run, commitIssues) = world.PlanAndCommit(new DateOnly(2026, 12, 1), configure: r => r.Method = "Rotation");

        Assert.Contains(run.Preview.Issues, i => i.Code == RosterPlanValidator.ConsecutiveCap && i.Severity == RosterPlanValidator.Warning);
        Assert.False(RosterPlanValidator.HasErrors(commitIssues));
    }

    [Fact]
    public void What_the_sheet_never_knew_wins_a_hand_edit_a_leave_a_holiday()
    {
        var day = new DateOnly(2026, 12, 2);   // the sheet: M E M E M E M
        var world = new RosterWorld { Today = new DateOnly(2026, 11, 1), Rotation = Stored() }.WithStaff(People.Length);
        world.Rest(3, day);                                   // a hand edit: person 3 is off that day
        world.Leave(5, day, day);                             // person 5 is on leave
        world.Holiday(new DateOnly(2026, 12, 25));            // a closed public holiday

        var run = world.Plan(new DateOnly(2026, 12, 1), configure: r => r.Method = "Rotation");
        var cells = run.Preview.Cells.ToDictionary(c => (c.EmployeeId, c.WorkDate));

        Assert.Equal("rest", cells[(3, day)].State);
        Assert.Equal("kept", cells[(3, day)].Change);
        // The people below balance against who is REALLY there: 1 M, 2 E, 3 off, so 4 breaks the tie by its row
        // (w 0 + Wednesday 2 + row 7 is odd: evening), 5 is on leave and counts for neither shift, and 6 then
        // fills the morning - where the sheet, which had 3 and 5 at work, had put 6 on the evening.
        Assert.Equal(RosterWorld.Evening, cells[(4, day)].ShiftId);
        Assert.Equal("work", cells[(5, day)].State);          // a leave day keeps a working row (the leave is priced on it)
        Assert.Equal(RosterWorld.Morning, cells[(6, day)].ShiftId);
        // The holiday is a day off for everybody: no row, whatever the rule says.
        Assert.All(Enumerable.Range(1, People.Length), e => Assert.Equal("none", cells[(e, new DateOnly(2026, 12, 25))].State));
    }

    [Fact]
    public void Somebody_on_rotation_without_a_line_is_named_and_left_as_they_stand()
    {
        var stored = Stored();
        stored.Members.RemoveAll(m => m.EmployeeId == 7);
        var world = new RosterWorld { Today = new DateOnly(2026, 11, 1), Rotation = stored }.WithStaff(People.Length);

        var run = world.Plan(new DateOnly(2026, 12, 1), configure: r => r.Method = "Rotation");
        Assert.Contains(run.Preview.Issues, i => i.Code == RosterPlanValidator.RotationNotSet && i.EmployeeId == 7);
        Assert.DoesNotContain(run.Preview.Cells, c => c.EmployeeId == 7 && c.Change is "insert" or "update" or "delete");
    }

    [Fact]
    public void The_shifts_a_day_must_have_somebody_on_are_the_rotations_two()
    {
        // The branch worked the Day shift for months: the fair method would ask for it every day. The rotation does not.
        var world = new RosterWorld { Today = new DateOnly(2026, 11, 1), Rotation = Stored() }.WithStaff(People.Length);
        for (var d = new DateOnly(2026, 9, 1); d < new DateOnly(2026, 11, 1); d = d.AddDays(1))
            for (var e = 1; e <= 4; e++)
                world.Work(e, d, RosterWorld.Day);

        var run = world.Plan(new DateOnly(2026, 12, 1), configure: r => r.Method = "Rotation");
        Assert.Equal([RosterWorld.Morning, RosterWorld.Evening], run.Input.ShiftCover.Select(r => r.ShiftId!.Value));
        Assert.DoesNotContain(run.Preview.Issues, i => i.Code == RosterPlanValidator.ShiftUncovered);
    }

    /* ---- two shift leaders never share a shift ---- */

    private static IEnumerable<DateOnly> December => Enumerable.Range(1, 31).Select(d => new DateOnly(2026, 12, d));

    private static int? ShiftOf(AutoRosterPreview preview, int employee, DateOnly day)
        => preview.Cells.Single(c => c.EmployeeId == employee && c.WorkDate == day) is { State: "work" } cell ? cell.ShiftId : null;

    [Fact]
    public void A_lead_keeps_off_the_shift_the_other_lead_was_put_on_by_hand()
    {
        // Wednesday 2 December, week 0: the rule has Lead 1 on the morning and Lead 2 on the evening. Somebody put
        // Lead 2 on the MORNING by hand: Lead 1 takes the evening, so each shift still has a lead.
        var day = new DateOnly(2026, 12, 2);
        var world = new RosterWorld { Today = new DateOnly(2026, 11, 1), Rotation = Stored() }.WithStaff(People.Length);
        world.Work(2, day, RosterWorld.Morning);

        var run = world.Plan(new DateOnly(2026, 12, 1), configure: r => r.Method = "Rotation");

        Assert.Equal(RosterWorld.Morning, ShiftOf(run.Preview, 2, day));
        Assert.Equal(RosterWorld.Evening, ShiftOf(run.Preview, 1, day));
        Assert.DoesNotContain(run.Preview.Issues, i => i.Code == RosterPlanValidator.LeadsSameShift);
        // Every other day of the month the two leads are apart as the rule has them.
        Assert.All(December, d =>
        {
            if (ShiftOf(run.Preview, 1, d) is { } a && ShiftOf(run.Preview, 2, d) is { } b)
                Assert.NotEqual(a, b);
        });
    }

    [Fact]
    public void Two_leads_put_on_one_shift_by_hand_are_reported_not_changed()
    {
        var day = new DateOnly(2026, 12, 2);
        var world = new RosterWorld { Today = new DateOnly(2026, 11, 1), Rotation = Stored() }.WithStaff(People.Length);
        world.Work(1, day, RosterWorld.Evening);
        world.Work(2, day, RosterWorld.Evening);

        var run = world.Plan(new DateOnly(2026, 12, 1), configure: r => r.Method = "Rotation");

        Assert.Equal(RosterWorld.Evening, ShiftOf(run.Preview, 1, day));
        Assert.Equal(RosterWorld.Evening, ShiftOf(run.Preview, 2, day));
        var issue = Assert.Single(run.Preview.Issues, i => i.Code == RosterPlanValidator.LeadsSameShift);
        Assert.Equal((day, "warning", (int?)RosterWorld.Evening), (issue.Date!.Value, issue.Severity, issue.ShiftId));
    }

    [Fact]
    public void The_fair_method_keeps_the_two_leads_on_different_shifts()
    {
        // Everybody's own shift is the morning (the last two months), and the day must cover a morning and an evening:
        // left alone, both leads would stay on the morning whenever the cover moves somebody else.
        var world = new RosterWorld { Today = new DateOnly(2026, 11, 1), Rotation = Stored() }.WithStaff(People.Length);
        for (var d = new DateOnly(2026, 10, 1); d < new DateOnly(2026, 12, 1); d = d.AddDays(1))
            for (var e = 1; e <= People.Length; e++)
                world.Work(e, d, RosterWorld.Morning);
        world.Min(2, shiftId: RosterWorld.Morning);
        world.Min(2, shiftId: RosterWorld.Evening);

        var run = world.Plan(new DateOnly(2026, 12, 1));

        Assert.Equal([1, 2], run.Input.ShiftLeads.Order());
        var together = December.Count(d => ShiftOf(run.Preview, 1, d) is { } a && ShiftOf(run.Preview, 2, d) is { } b && a == b);
        Assert.Equal(0, together);
        Assert.Contains(December, d => ShiftOf(run.Preview, 1, d) is not null && ShiftOf(run.Preview, 2, d) is not null);
        Assert.DoesNotContain(run.Preview.Issues, i => i.Code == RosterPlanValidator.LeadsSameShift);
        // The cover is as good as without leads: moving a lead changes places with somebody, it does not thin a shift.
        var noLeads = Stored();
        noLeads.Members.ForEach(m => m.LeadSlot = null);
        world.Rotation = noLeads;
        var plain = world.Plan(new DateOnly(2026, 12, 1));
        static IEnumerable<(DateOnly?, int?, string)> Cover(AutoRosterPreview p) => p.Issues
            .Where(i => i.Code is RosterPlanValidator.ShiftUncovered or RosterPlanValidator.ShortStaffed)
            .Select(i => (i.Date, i.ShiftId, i.Message));
        Assert.Equal(Cover(plain.Preview), Cover(run.Preview));
    }

    [Fact]
    public void Without_leads_the_fair_method_plans_as_before()
    {
        RosterWorld World(RosterRotationDto? rotation)
        {
            var world = new RosterWorld { Today = new DateOnly(2026, 11, 1), Rotation = rotation }.WithStaff(People.Length);
            world.Min(2, shiftId: RosterWorld.Morning);
            world.Min(2, shiftId: RosterWorld.Evening);
            return world;
        }
        var noLeads = Stored();
        noLeads.Members.ForEach(m => m.LeadSlot = null);

        var plain = World(null).Plan(new DateOnly(2026, 12, 1));
        var listed = World(noLeads).Plan(new DateOnly(2026, 12, 1));

        Assert.Empty(listed.Input.ShiftLeads);
        Assert.Equal(
            plain.Preview.Cells.Select(c => (c.EmployeeId, c.WorkDate, c.State, c.ShiftId)),
            listed.Preview.Cells.Select(c => (c.EmployeeId, c.WorkDate, c.State, c.ShiftId)));
    }

    /* ---- R6: a new hire's weeks are 6-day weeks in the fixed rotation too ---- */

    [Fact]
    public void In_a_new_hires_first_months_a_two_days_off_week_keeps_only_its_first_day_off()
    {
        // Person 3 (group 0, pair from Thursday): week 0 is a two-days-off week, Thursday 3 and Friday 4 December on the
        // sheet. Hired on 1 November, they are in their first three months: only the Thursday stays a day off.
        var world = new RosterWorld { Today = new DateOnly(2026, 11, 1), Rotation = Stored() }.WithStaff(People.Length);
        world.People[3].Hire = new DateOnly(2026, 11, 1);
        var run = world.Plan(new DateOnly(2026, 12, 1), configure: r => r.Method = "Rotation");
        var p = run.Preview;

        Assert.Equal("rest", p.Cell(3, new DateOnly(2026, 12, 3)).State);
        Assert.Equal("work", p.Cell(3, new DateOnly(2026, 12, 4)).State);
        Assert.All(p.PerEmployee.Single(e => e.EmployeeId == 3).Weeks, w =>
        {
            Assert.Equal(6, w.WorkDays);
            Assert.True(w.Ok, $"week of {w.WeekStart}: {w.Rests} rests for {w.Quota}");
        });
        Assert.DoesNotContain(p.Issues, i => i.EmployeeId == 3 && i.Code is "RHYTHM_SHORT" or "RHYTHM_OVER");

        // Everybody else follows the sheet, and person 3's one-day-off weeks are the sheet's too.
        Assert.Equal("OFF", RotationRule.Column(Setup(), RotationRule.Ordered(Setup(), Enumerable.Range(1, 7)), new DateOnly(2026, 12, 4))[2]);
        Assert.True(RotationRule.IsOff(Setup(), Setup().Members[3], new DateOnly(2026, 12, 4)));
        Assert.False(RotationRule.IsOff(Setup(), Setup().Members[3], new DateOnly(2026, 12, 4), new DateOnly(2027, 2, 1)));
        Assert.True(RotationRule.IsOff(Setup(), Setup().Members[3], new DateOnly(2026, 12, 3), new DateOnly(2027, 2, 1)));

        // The commit judges those weeks the same way.
        var issues = world.Commit(run);
        Assert.DoesNotContain(issues, i => i.EmployeeId == 3 && i.Code is "RHYTHM_SHORT" or "RHYTHM_OVER");
    }

    /* ---- R4: the branch's stored leaders in the fixed rotation ---- */

    [Fact]
    public void A_stored_leader_who_is_not_lead_1_or_2_keeps_off_a_shift_that_has_a_leader_when_the_other_has_none()
    {
        // Thursday 3 December on the sheet: Lead 1 and person 6 on the morning, Lead 2 off, the evening without a leader.
        // With person 6 a stored leader, they change places with the first person of the list on the evening (person 4).
        var world = new RosterWorld { Today = new DateOnly(2026, 11, 1), Rotation = Stored() }.WithStaff(People.Length);
        world.ShiftLeaders.Add(6);
        var p = world.Plan(new DateOnly(2026, 12, 1), configure: r => r.Method = "Rotation").Preview;

        var thursday = new DateOnly(2026, 12, 3);
        Assert.Equal(RosterWorld.Morning, ShiftOf(p, 1, thursday));
        Assert.Equal(RosterWorld.Evening, ShiftOf(p, 6, thursday));
        Assert.Equal(RosterWorld.Morning, ShiftOf(p, 4, thursday));
        Assert.Equal(RosterPlanner.ReasonLeadApart, p.Cell(6, thursday).ReasonCode);

        foreach (var d in December)
        {
            var shifts = new[] { 1, 2, 6 }.Select(e => ShiftOf(p, e, d)).Where(s => s is not null).ToList();
            if (shifts.GroupBy(s => s).Any(g => g.Count() >= 2))
                Assert.Equal(2, shifts.Distinct().Count());   // only when all three work: both shifts keep a leader
        }

        // Without stored leaders the rotation is the sheet, untouched.
        var plain = new RosterWorld { Today = new DateOnly(2026, 11, 1), Rotation = Stored() }.WithStaff(People.Length)
            .Plan(new DateOnly(2026, 12, 1), configure: r => r.Method = "Rotation").Preview;
        Assert.DoesNotContain(plain.Cells, c => c.ReasonCode == RosterPlanner.ReasonLeadApart);
    }

    [Fact]
    public void The_rotation_must_be_set_up_before_it_can_plan()
    {
        var world = new RosterWorld { Today = new DateOnly(2026, 11, 1) }.WithStaff(3);
        var ex = Assert.Throws<ArgumentException>(() => world.Plan(new DateOnly(2026, 12, 1), configure: r => r.Method = "Rotation"));
        Assert.Contains("Set up the rotation first", ex.Message);
        Assert.Equal("The method is Fair or Rotation.", AutoRosterInputFactory.Problem(new AutoRosterRequest { BranchId = 1, Month = "2026-12", Method = "Magic" }));
    }

    [Fact]
    public void The_fair_method_is_untouched_when_no_method_is_named()
    {
        var world = new RosterWorld { Today = new DateOnly(2026, 11, 1), Rotation = Stored() }.WithStaff(People.Length);
        var run = world.Plan(new DateOnly(2026, 12, 1));
        Assert.Null(run.Input.Rotation);
        Assert.DoesNotContain(run.Preview.Cells, c => c.ReasonCode is RotationRule.ReasonRest or RotationRule.ReasonBalance or RotationRule.ReasonLead);
    }
}
