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
