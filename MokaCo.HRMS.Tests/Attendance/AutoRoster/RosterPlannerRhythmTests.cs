using MokaCo.HRMS.Services.Attendance.AutoRoster;

namespace MokaCo.HRMS.Tests.Attendance.AutoRoster;

/// <summary>
/// §2.2–2.3: the 6/5 rhythm from the anchor, continuously across months and in either generation
/// order; the straddling weeks (a month starting on a Sunday, on a Monday, February); partial weeks.
/// </summary>
public class RosterPlannerRhythmTests
{
    private static readonly DateOnly Oct = new(2026, 10, 1);
    private static readonly DateOnly Nov = new(2026, 11, 1);
    private static readonly DateOnly Dec = new(2026, 12, 1);

    /// <summary>Every complete week Oct 5 – Dec 27 alternates 1 and 2 rest days (a 6-day week, then a 5-day week).</summary>
    private static void AssertAlternates(RosterWorld world, IEnumerable<int> staff)
    {
        foreach (var e in staff)
        {
            var anchor = world.Rhythms[e];
            var rhythm = new ResolvedRhythm(e, RosterWorld.D(anchor.AnchorWeekStart), anchor.AnchorWorkDays, false);
            int? previous = null;
            for (var ws = new DateOnly(2026, 10, 5); ws <= new DateOnly(2026, 12, 21); ws = ws.AddDays(7))
            {
                var rests = world.RestsInWeek(e, ws);
                Assert.True(rests == 7 - rhythm.WorkDaysIn(ws), $"employee {e}, week {ws}: {rests} rests, rhythm {rhythm.WorkDaysIn(ws)}");
                if (previous is { } p)
                    Assert.Equal(3, p + rests);   // never two 6-day (or two 5-day) weeks in a row
                previous = rests;
            }
        }
    }

    [Fact]
    public void Oct_Nov_Dec_generated_in_order_alternate_6_and_5_without_restarting_at_month_ends()
    {
        var world = new RosterWorld().WithStaff(5);
        foreach (var month in new[] { Oct, Nov, Dec })
        {
            var (run, commitIssues) = world.PlanAndCommit(month, "FillEmpty");
            Assert.Empty(run.Preview.Errors());
            Assert.DoesNotContain(commitIssues, i => i.Severity == "error");
        }

        AssertAlternates(world, Enumerable.Range(1, 5));

        // The first planned week was a 6-day week (Aligned), anchored on the window's first Monday.
        Assert.All(world.Rhythms.Values, r =>
        {
            Assert.Equal(new DateOnly(2026, 9, 28), RosterWorld.D(r.AnchorWeekStart));
            Assert.Equal(6, r.AnchorWorkDays);
        });

        // Ghost days are never saved: 28–30 Sep and 1–3 Jan were planned only to make their weeks work.
        Assert.All(Enumerable.Range(1, 5), e =>
        {
            Assert.Null(world.RowAt(e, new DateOnly(2026, 9, 30)));
            Assert.Null(world.RowAt(e, new DateOnly(2027, 1, 1)));
        });
    }

    [Fact]
    public void Dec_then_Nov_then_Oct_gives_the_same_alternation_and_completes_the_straddling_weeks()
    {
        var world = new RosterWorld().WithStaff(5);
        foreach (var month in new[] { Dec, Nov, Oct })
        {
            var (run, commitIssues) = world.PlanAndCommit(month, "FillEmpty");
            Assert.Empty(run.Preview.Errors());
            Assert.DoesNotContain(commitIssues, i => i.Severity == "error");
        }

        AssertAlternates(world, Enumerable.Range(1, 5));

        // The rhythm was anchored on December's first week (the first run) and the earlier months
        // follow it backwards — the negative parity case.
        Assert.All(world.Rhythms.Values, r => Assert.Equal(new DateOnly(2026, 11, 30), RosterWorld.D(r.AnchorWeekStart)));
    }

    [Fact]
    public void November_2026_starts_on_a_Sunday_and_its_empty_October_days_are_ghosts_not_a_pile_of_Sunday_rests()
    {
        var world = new RosterWorld().WithStaff(7);
        var run = world.Plan(Nov);
        var p = run.Preview;

        Assert.Equal(new DateOnly(2026, 10, 26), p.WindowFrom);
        Assert.Empty(p.Errors());

        // 26–31 Oct are empty and in the future: planned as ghosts, never part of the commit.
        var ghosts = p.Cells.Where(c => c.WorkDate < Nov).ToList();
        Assert.NotEmpty(ghosts);
        Assert.All(ghosts, c => { Assert.Equal("ghost", c.Origin); Assert.Equal("kept", c.Change); });
        Assert.DoesNotContain(RosterWorld.CommitRequestFor(run.Request, p).Cells, c => c.WorkDate < Nov);

        // The week's 7 rests (one each, a 6-day week) are spread over its 7 days, not all on Sun 1 Nov.
        var sundayRests = p.Cells.Count(c => c.WorkDate == Nov && c.State == "rest");
        Assert.True(sundayRests <= 1, $"{sundayRests} people rest on Sun 1 Nov");
        Assert.All(Enumerable.Range(1, 7), e => Assert.Equal(1, p.RestsInWeek(e, new DateOnly(2026, 10, 26))));
    }

    [Fact]
    public void November_after_a_saved_October_completes_the_week_from_the_October_facts()
    {
        var world = new RosterWorld().WithStaff(4);
        world.PlanAndCommit(Oct);
        var p = world.Plan(Nov).Preview;

        Assert.Empty(p.Errors());
        foreach (var e in Enumerable.Range(1, 4))
        {
            // Oct 26–31 are facts now; Sun 1 Nov carries exactly what the week still lacks.
            var week = p.Week(e, new DateOnly(2026, 10, 26));
            Assert.Equal(week.Quota, week.Rests);
            Assert.True(week.Ok);
            Assert.All(p.Cells.Where(c => c.EmployeeId == e && c.WorkDate < Nov), c => Assert.Equal("outside", c.Origin));
        }
    }

    [Fact]
    public void June_2026_starts_on_a_Monday_and_every_week_meets_its_quota()
    {
        var world = new RosterWorld { Today = new DateOnly(2026, 5, 1) }.WithStaff(6);
        var p = world.Plan(new DateOnly(2026, 6, 1)).Preview;

        Assert.Equal(new DateOnly(2026, 6, 1), p.WindowFrom);
        Assert.Empty(p.Errors());
        Assert.All(p.PerEmployee, e => Assert.All(e.Weeks, w => Assert.True(w.Ok, $"{e.EmployeeId} {w.WeekStart}")));
        Assert.All(p.PerEmployee, e => Assert.Equal(new[] { 6, 5, 6, 5, 6 }, e.Weeks.Select(w => w.WorkDays)));
    }

    [Fact]
    public void February_is_planned_in_whole_weeks_with_every_week_on_quota()
    {
        var world = new RosterWorld { Today = new DateOnly(2026, 1, 1) }.WithStaff(6);
        var p = world.Plan(new DateOnly(2026, 2, 1)).Preview;

        Assert.Equal(new DateOnly(2026, 1, 26), p.WindowFrom);
        Assert.Equal(new DateOnly(2026, 3, 1), p.WindowTo);
        Assert.Empty(p.Errors());
        Assert.All(p.PerEmployee, e => Assert.All(e.Weeks, w => Assert.True(w.Ok)));
        Assert.Equal(28, p.PerDay.Count);
        // Four weeks 6,5,6,5 inside February plus the straddling ones: ≈ 22 working days in the month.
        Assert.All(p.PerEmployee, e => Assert.InRange(e.WorkDays, 21, 23));
    }

    [Fact]
    public void Someone_hired_on_a_Thursday_works_that_week_without_rest_then_starts_a_5_day_week()
    {
        var world = new RosterWorld().WithStaff(3);
        world.Add(9, hire: new DateOnly(2026, 12, 10));
        var p = world.Plan(Dec).Preview;

        Assert.Null(p.CellOrNull(9, new DateOnly(2026, 12, 9)));
        Assert.Equal("work", p.Cell(9, new DateOnly(2026, 12, 10)).State);

        var hireWeek = p.Week(9, new DateOnly(2026, 12, 7));
        Assert.Equal(0, hireWeek.Quota);   // 4 employed days − 6
        Assert.Equal(0, hireWeek.Rests);
        Assert.Equal(6, hireWeek.WorkDays);

        var next = p.Week(9, new DateOnly(2026, 12, 14));
        Assert.Equal(5, next.WorkDays);
        Assert.Equal(2, next.Rests);

        var rhythm = p.Rhythm.Single(r => r.EmployeeId == 9);
        Assert.Equal(new DateOnly(2026, 12, 7), rhythm.AnchorWeekStart);
        Assert.True(rhythm.IsNew);
    }

    [Fact]
    public void Someone_leaving_mid_week_gets_the_rest_quota_of_the_days_they_are_employed()
    {
        var world = new RosterWorld().WithStaff(3);
        world.Add(9, termination: new DateOnly(2026, 12, 18));   // employed Mon–Fri of the 14 Dec week
        world.Anchor(9, new DateOnly(2026, 12, 14), 5);
        var p = world.Plan(Dec).Preview;

        var week = p.Week(9, new DateOnly(2026, 12, 14));
        Assert.Equal(0, week.Quota);   // 5 employed days − 5
        Assert.Null(p.CellOrNull(9, new DateOnly(2026, 12, 19)));
    }

    [Fact]
    public void Aligned_starts_on_a_5_day_week_when_the_first_weeks_facts_already_hold_two_rests()
    {
        var world = new RosterWorld().WithStaff(2);
        world.Rest(1, new DateOnly(2026, 11, 30));
        world.Rest(1, new DateOnly(2026, 12, 1));   // FillEmpty: both are facts
        var p = world.Plan(Dec).Preview;

        Assert.Equal(5, p.Rhythm.Single(r => r.EmployeeId == 1).AnchorWorkDays);
        Assert.Equal(6, p.Rhythm.Single(r => r.EmployeeId == 2).AnchorWorkDays);
        Assert.DoesNotContain(p.Issues, i => i.EmployeeId == 1 && i.Code == "RHYTHM_OVER");
    }

    [Fact]
    public void A_stored_anchor_after_the_month_still_gives_the_right_types_backwards()
    {
        var world = new RosterWorld().WithStaff(1);
        world.Anchor(1, new DateOnly(2027, 1, 4), 6);   // 4 Jan 2027 is a 6-day week
        var p = world.Plan(Dec).Preview;

        // 28 Dec is one week earlier → 5; 21 Dec → 6; 30 Nov (5 weeks earlier) → 5.
        Assert.Equal(5, p.Week(1, new DateOnly(2026, 12, 28)).WorkDays);
        Assert.Equal(6, p.Week(1, new DateOnly(2026, 12, 21)).WorkDays);
        Assert.Equal(5, p.Week(1, new DateOnly(2026, 11, 30)).WorkDays);
        Assert.False(p.Rhythm.Single().IsNew);
    }

    [Fact]
    public void A_rhythm_override_flips_the_week_and_is_returned_for_saving()
    {
        var world = new RosterWorld().WithStaff(2);
        world.Anchor(1, new DateOnly(2026, 11, 30), 6);
        var run = world.Plan(Dec, "FillEmpty", r => r.RhythmOverrides.Add(new() { EmployeeId = 1, WeekStart = new DateOnly(2026, 12, 2), WorkDays = 5 }));
        var p = run.Preview;

        var rhythm = p.Rhythm.Single(r => r.EmployeeId == 1);
        Assert.True(rhythm.IsNew);
        Assert.Equal(new DateOnly(2026, 11, 30), rhythm.AnchorWeekStart);   // moved back to its Monday
        Assert.Equal(5, rhythm.AnchorWorkDays);
        Assert.Equal(2, p.Week(1, new DateOnly(2026, 11, 30)).Rests);
        Assert.Equal(1, p.Week(1, new DateOnly(2026, 12, 7)).Rests);

        // An override that says what is already stored changes nothing and is not new.
        var same = world.Plan(Dec, "FillEmpty", r => r.RhythmOverrides.Add(new() { EmployeeId = 1, WeekStart = new DateOnly(2026, 12, 7), WorkDays = 5 }));
        Assert.False(same.Preview.Rhythm.Single(r => r.EmployeeId == 1).IsNew);
    }

    [Theory]
    [InlineData(2)]
    [InlineData(3)]
    [InlineData(4)]
    [InlineData(6)]
    public void Staggered_balances_6_and_5_day_first_weeks_across_the_branch_even_with_one_person_per_position(int size)
    {
        var world = new RosterWorld();
        for (var e = 1; e <= size; e++)
            world.Add(e, positionId: e);   // every position has one person: a per-position stagger would collapse to all-6
        var p = world.Plan(Dec, "FillEmpty", r => r.RhythmStart = "Staggered").Preview;

        var first = p.PerEmployee.Select(e => e.Weeks[0].WorkDays).ToList();
        Assert.True(Math.Abs(first.Count(t => t == 6) - first.Count(t => t == 5)) <= 1);
        Assert.True(first.Count(t => t == 6) >= first.Count(t => t == 5));   // ties start on 6
    }

    [Fact]
    public void Staggered_gives_a_new_hire_the_type_under_represented_among_the_stored_rhythms()
    {
        var world = new RosterWorld().WithStaff(3);
        world.Anchor(1, new DateOnly(2026, 11, 30), 6);
        world.Anchor(2, new DateOnly(2026, 11, 30), 6);
        world.Anchor(3, new DateOnly(2026, 11, 30), 5);
        world.Add(4, hire: new DateOnly(2026, 11, 1));
        world.Add(5, hire: new DateOnly(2026, 11, 2));
        var p = world.Plan(Dec, "FillEmpty", r => r.RhythmStart = "Staggered").Preview;

        // 6,6,5 stored → the first new one starts on 5, the next on 6 (tie → 6).
        Assert.Equal(5, p.Week(4, new DateOnly(2026, 11, 30)).WorkDays);
        Assert.Equal(6, p.Week(5, new DateOnly(2026, 11, 30)).WorkDays);
    }
}
