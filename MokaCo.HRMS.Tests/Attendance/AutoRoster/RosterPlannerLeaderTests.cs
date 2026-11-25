using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Services.Attendance.AutoRoster;

namespace MokaCo.HRMS.Tests.Attendance.AutoRoster;

/// <summary>
/// R4, "never put 2 shift leaders in the same shift": the leaders (the rotation list's Lead 1 and Lead 2 and the branch's
/// stored leaders, any number) are placed first on each day, one per shift; two share a shift only when more of them work
/// than the day has shifts (a warning names the day); a leader move never takes a shift below its minimum; and the rest days
/// avoid days with no leader at all.
/// </summary>
public class RosterPlannerLeaderTests
{
    private static readonly DateOnly Dec = new(2026, 12, 1);
    private static readonly DateOnly WindowFrom = new(2026, 11, 30);

    /// <summary>Eight weeks on one shift, Sundays off.</summary>
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

    private static int? ShiftOf(AutoRosterPreview p, int employee, DateOnly day)
        => p.CellOrNull(employee, day) is { State: "work" } cell ? cell.ShiftId : null;

    private static IEnumerable<DateOnly> December => Enumerable.Range(1, 31).Select(d => new DateOnly(2026, 12, d));

    /// <summary>Everybody's own shift is the morning; the branch covers a morning and an evening.</summary>
    private static RosterWorld AllMornings(int size, params int[] leaders)
    {
        var world = new RosterWorld { Today = new DateOnly(2026, 11, 1) }.WithStaff(size);
        for (var e = 1; e <= size; e++)
            History(world, e, RosterWorld.Morning);
        world.Min(1, shiftId: RosterWorld.Morning);
        world.Min(1, shiftId: RosterWorld.Evening);
        world.ShiftLeaders.AddRange(leaders);
        return world;
    }

    [Fact]
    public void The_branchs_stored_leaders_join_the_rotation_lists_leads()
    {
        var world = new RosterWorld().WithStaff(6);
        world.Rotation = new RosterRotationDto
        {
            BranchId = RosterWorld.Branch,
            StartDate = WindowFrom,
            MorningShiftId = RosterWorld.Morning,
            EveningShiftId = RosterWorld.Evening,
            Members =
            [
                new RosterRotationMemberDto { EmployeeId = 1, LeadSlot = "L1", SortOrder = 1 },
                new RosterRotationMemberDto { EmployeeId = 2, LeadSlot = "L2", SortOrder = 2 },
                new RosterRotationMemberDto { EmployeeId = 3, SortOrder = 3 },
            ],
        };
        world.ShiftLeaders.AddRange([5, 2]);

        Assert.Equal([1, 2, 5], world.Plan(Dec).Input.ShiftLeads.Order());

        world.Rotation = null;   // a branch that never saved a rotation still has its leaders
        Assert.Equal([2, 5], world.Plan(Dec).Input.ShiftLeads.Order());
    }

    [Fact]
    public void Two_working_leaders_are_placed_one_per_shift()
    {
        var p = AllMornings(7, 1, 2).Plan(Dec).Preview;

        var both = December.Where(d => ShiftOf(p, 1, d) is not null && ShiftOf(p, 2, d) is not null).ToList();
        Assert.NotEmpty(both);
        Assert.All(both, d => Assert.NotEqual(ShiftOf(p, 1, d), ShiftOf(p, 2, d)));
        Assert.DoesNotContain(p.Issues, i => i.Code == RosterPlanValidator.LeadsSameShift);
        Assert.Contains(p.Cells, c => c.ReasonCode == RosterPlanner.ReasonLeadApart);
    }

    /// <summary>
    /// Two leaders share a shift when all three work, and otherwise only when keeping them apart would itself break the
    /// rest rule: both worked the evening before (the three-leader day put the pair there), and the morning starts 8 hours
    /// after it ends - the minimum is 11. The planner never makes a turnaround to keep leaders apart (it did before the
    /// review of the shift-roster work: on those days one leader went from an evening to a morning).
    /// </summary>
    [Fact]
    public void Three_leaders_on_two_shifts_share_only_when_all_three_work_or_a_move_would_be_a_turnaround()
    {
        var p = AllMornings(8, 1, 2, 3).Plan(Dec).Preview;
        int[] leaders = [1, 2, 3];

        var forced = 0;
        var threeWork = 0;
        foreach (var d in December)
        {
            var working = leaders.Where(l => ShiftOf(p, l, d) is not null).ToList();
            var shared = working.GroupBy(l => ShiftOf(p, l, d)).Any(g => g.Count() >= 2);
            if (working.Count == 3)
            {
                // Both shifts keep a leader; two of the three share one. Not a warning per day: one for the month says
                // that more leaders work than there are shifts (LEADS_TOO_FEW_SHIFTS, below).
                Assert.Equal(2, working.Select(l => ShiftOf(p, l, d)).Distinct().Count());
                Assert.DoesNotContain(p.Issues, i => i.Code == RosterPlanValidator.LeadsSameShift && i.Date == d);
                threeWork++;
            }
            else if (shared)
            {
                forced++;
                Assert.All(working, l => Assert.Equal(RosterWorld.Evening, ShiftOf(p, l, d)));
                Assert.All(working, l => Assert.Equal(RosterWorld.Evening, ShiftOf(p, l, d.AddDays(-1))));
                Assert.Single(p.Issues, i => i.Code == RosterPlanValidator.LeadsSameShift && i.Date == d);
            }
            else
            {
                Assert.DoesNotContain(p.Issues, i => i.Code == RosterPlanValidator.LeadsSameShift && i.Date == d);
            }
        }

        Assert.True(forced <= 3, $"{forced} days with two of three leaders together");
        // The days all three work are said ONCE, on the first of them.
        if (threeWork > 0)
        {
            var month = Assert.Single(p.Issues, i => i.Code == RosterPlanValidator.LeadsTooFewShifts);
            Assert.Equal("warning", month.Severity);
            Assert.Contains($"On {threeWork} day(s)", month.Message);
        }
        Assert.DoesNotContain(p.Issues, i => i.Code == RosterPlanValidator.Turnaround && i.EmployeeId is 1 or 2 or 3);
    }

    /// <summary>Saturdays and Sundays off per person over the months planned and saved one after the other.</summary>
    private static Dictionary<int, int> WeekendsOff(RosterWorld world, int size, params DateOnly[] months)
    {
        foreach (var month in months)
            world.PlanAndCommit(month);
        var to = RosterCalendar.MonthEnd(months[^1]);
        return Enumerable.Range(1, size).ToDictionary(
            e => e,
            e => RosterCalendar.Days(months[0], to).Count(d => RosterCalendar.IsWeekend(d) && world.IsRest(e, d)));
    }

    /// <summary>
    /// The rest days keep a leader on duty only where another leader's day can make room: with ONE leader working (one leader
    /// in the branch, a rotation list naming only Lead 1, or the other leader on leave for two months) the leader is never held
    /// back from a weekend day off, and nobody else loses one either - every person's Saturdays and Sundays off are those of
    /// the same branch without leaders.
    /// </summary>
    [Theory]
    [InlineData("one stored leader")]
    [InlineData("rotation list with Lead 1 only")]
    [InlineData("two leaders, one on leave")]
    public void One_working_leader_costs_nobody_a_weekend_day_off(string setup)
    {
        DateOnly[] months = [Dec, new(2027, 1, 1), new(2027, 2, 1)];
        var withLeave = setup == "two leaders, one on leave";
        if (withLeave)
            months = [Dec, new(2027, 1, 1)];

        RosterWorld World(bool leaders)
        {
            var world = AllMornings(7);
            if (withLeave)
                world.Leave(2, Dec, new DateOnly(2027, 1, 31));
            if (!leaders)
                return world;
            switch (setup)
            {
                case "one stored leader":
                    world.ShiftLeaders.Add(1);
                    break;
                case "rotation list with Lead 1 only":
                    world.Rotation = new RosterRotationDto
                    {
                        BranchId = RosterWorld.Branch,
                        StartDate = WindowFrom,
                        MorningShiftId = RosterWorld.Morning,
                        EveningShiftId = RosterWorld.Evening,
                        Members = [new RosterRotationMemberDto { EmployeeId = 1, LeadSlot = "L1", SortOrder = 1 }],
                    };
                    break;
                default:
                    world.ShiftLeaders.AddRange([1, 2]);
                    break;
            }
            return world;
        }

        var baseline = WeekendsOff(World(leaders: false), 7, months);
        var led = WeekendsOff(World(leaders: true), 7, months);

        Assert.True(led[1] > 0, $"{setup}: the leader got no weekend day off");
        Assert.Equal(baseline.Values.Sum(), led.Values.Sum());
        Assert.All(baseline, kv => Assert.InRange(led[kv.Key], kv.Value - 1, kv.Value + 1));
    }

    /// <summary>
    /// The branch covers only the morning; one person works nights (22:00-06:00), a shift nobody has to cover. Two leaders on
    /// the morning may be kept apart over the shifts the day uses, but never by a night that the leader's own morning follows
    /// (one hour of rest), nor by any move that breaks a rest rule: nobody is kept on a shift that is not covered the next day.
    /// The same with the evening stored at minimum 0 and worked by others.
    /// </summary>
    [Theory]
    [InlineData(RosterWorld.Night)]
    [InlineData(RosterWorld.Evening)]
    public void A_leader_is_never_moved_onto_a_shift_nobody_covers_into_a_turnaround(int other)
    {
        var world = new RosterWorld { Today = new DateOnly(2026, 11, 1) }.WithStaff(7);
        for (var e = 1; e <= 5; e++)
            History(world, e, RosterWorld.Morning);
        History(world, 6, other == RosterWorld.Night ? RosterWorld.Morning : other);
        History(world, 7, other);
        world.Min(1, shiftId: RosterWorld.Morning);
        if (other == RosterWorld.Evening)
            world.Min(0, shiftId: RosterWorld.Evening);
        world.ShiftLeaders.AddRange([1, 2]);

        var p = world.Plan(Dec).Preview;
        Assert.DoesNotContain(p.Issues, i => i.Code is RosterPlanValidator.Turnaround or RosterPlanValidator.WeeklyRestHours);
        Assert.Empty(p.Errors());
    }

    [Fact]
    public void With_every_shift_stored_at_minimum_zero_nobody_is_moved()
    {
        // The manager's "no shift needs covering": the planner moves nobody, leaders included; the warning still names the days.
        var world = new RosterWorld { Today = new DateOnly(2026, 11, 1) }.WithStaff(7);
        for (var e = 1; e <= 6; e++)
            History(world, e, RosterWorld.Morning);
        History(world, 7, RosterWorld.Night);
        foreach (var shift in new[] { RosterWorld.Day, RosterWorld.Morning, RosterWorld.Evening, RosterWorld.Night })
            world.Min(0, shiftId: shift);
        world.ShiftLeaders.AddRange([1, 2]);

        var p = world.Plan(Dec).Preview;
        foreach (var d in December)
        {
            for (var e = 1; e <= 7; e++)
                if (ShiftOf(p, e, d) is { } shift)
                    Assert.Equal(e == 7 ? RosterWorld.Night : RosterWorld.Morning, shift);
        }
        Assert.DoesNotContain(p.Cells, c => c.ReasonCode is RosterPlanner.ReasonLeadApart or RosterPlanner.ReasonShiftCover or RosterPlanner.ReasonShiftBalance);
        Assert.Contains(p.Issues, i => i.Code == RosterPlanValidator.LeadsSameShift);
    }

    /// <summary>
    /// Wednesday 9 December: Lead 1 is on the morning by a saved row, Lead 2's day is the planner's (Monday's saved rest
    /// fills the week's quota, so Wednesday is a working day; Tuesday's saved morning keeps the day before plain) and the
    /// morning needs two people. A worker on the evening is saved there too; employee 4, whose own shift is the evening,
    /// is the planner's when <paramref name="withPartner"/>.
    /// </summary>
    private static RosterWorld LeadersSharingAMorning(bool withPartner)
    {
        var world = new RosterWorld { Today = new DateOnly(2026, 11, 1) }.WithStaff(withPartner ? 4 : 3);
        History(world, 1, RosterWorld.Morning);
        History(world, 2, RosterWorld.Morning);
        History(world, 3, RosterWorld.Evening);
        world.Min(2, shiftId: RosterWorld.Morning);
        world.Min(1, shiftId: RosterWorld.Evening);
        world.ShiftLeaders.AddRange([1, 2]);

        var wednesday = new DateOnly(2026, 12, 9);
        world.Work(1, wednesday, RosterWorld.Morning);
        world.Work(3, wednesday, RosterWorld.Evening);
        world.Anchor(2, new DateOnly(2026, 12, 7), 6);
        world.Rest(2, new DateOnly(2026, 12, 7));
        world.Work(2, new DateOnly(2026, 12, 8), RosterWorld.Morning);
        if (withPartner)
        {
            History(world, 4, RosterWorld.Evening);
            world.Anchor(4, new DateOnly(2026, 12, 7), 6);
            world.Rest(4, new DateOnly(2026, 12, 8));   // no evening the night before a morning
        }
        return world;
    }

    [Fact]
    public void A_leader_changes_places_so_the_shift_it_leaves_keeps_its_minimum()
    {
        var wednesday = new DateOnly(2026, 12, 9);
        var p = LeadersSharingAMorning(withPartner: true).Plan(Dec).Preview;

        Assert.Equal(RosterWorld.Morning, ShiftOf(p, 1, wednesday));
        Assert.Equal(RosterWorld.Evening, ShiftOf(p, 2, wednesday));
        Assert.Equal(RosterWorld.Morning, ShiftOf(p, 4, wednesday));
        Assert.Equal(RosterPlanner.ReasonLeadApart, p.Cell(2, wednesday).ReasonCode);
        Assert.Equal(RosterPlanner.ReasonLeadApart, p.Cell(4, wednesday).ReasonCode);
        Assert.DoesNotContain(p.Issues, i => i.Date == wednesday && i.Code is RosterPlanValidator.LeadsSameShift or RosterPlanValidator.ShortStaffed);
    }

    [Fact]
    public void Without_anybody_to_change_places_with_a_leader_never_takes_a_shift_below_its_minimum()
    {
        var wednesday = new DateOnly(2026, 12, 9);
        var p = LeadersSharingAMorning(withPartner: false).Plan(Dec).Preview;

        // Moving Lead 2 to the evening would leave one person on a morning that needs two: they stay together, reported.
        Assert.Equal(RosterWorld.Morning, ShiftOf(p, 1, wednesday));
        Assert.Equal(RosterWorld.Morning, ShiftOf(p, 2, wednesday));
        Assert.DoesNotContain(p.Issues, i => i.Date == wednesday && i.Code == RosterPlanValidator.ShortStaffed);
        var issue = Assert.Single(p.Issues, i => i.Date == wednesday && i.Code == RosterPlanValidator.LeadsSameShift);
        Assert.Equal(RosterWorld.Morning, issue.ShiftId);
    }

    [Fact]
    public void With_one_shift_to_cover_two_leaders_are_still_kept_apart_over_the_shifts_the_day_uses()
    {
        // Only the evening is stored as a shift to cover; the mornings are worked anyway. Both leaders' own shift is the morning.
        var world = new RosterWorld { Today = new DateOnly(2026, 11, 1) }.WithStaff(6);
        for (var e = 1; e <= 4; e++)
            History(world, e, RosterWorld.Morning);
        History(world, 5, RosterWorld.Evening);
        History(world, 6, RosterWorld.Evening);
        world.Min(1, shiftId: RosterWorld.Evening);
        world.ShiftLeaders.AddRange([1, 2]);

        var p = world.Plan(Dec).Preview;
        var both = December.Where(d => ShiftOf(p, 1, d) is not null && ShiftOf(p, 2, d) is not null).ToList();
        Assert.NotEmpty(both);
        Assert.All(both, d => Assert.NotEqual(ShiftOf(p, 1, d), ShiftOf(p, 2, d)));
        Assert.DoesNotContain(p.Issues, i => i.Code == RosterPlanValidator.LeadsSameShift);
    }

    [Fact]
    public void The_rest_days_keep_a_leader_on_duty_every_day()
    {
        var world = AllMornings(7, 1, 2);
        var p = world.Plan(Dec).Preview;
        var leaderless = December.Where(d => ShiftOf(p, 1, d) is null && ShiftOf(p, 2, d) is null).ToList();
        Assert.Empty(leaderless);
        Assert.All(p.PerEmployee, e => Assert.All(e.Weeks, w => Assert.True(w.Ok)));   // nobody lost a rest day for it

        // Regenerating the saved plan moves nobody.
        world.PlanAndCommit(Dec);
        Assert.Equal(0, world.Plan(Dec, "ReplanAuto").Preview.Changes());
    }
}
