using System.Text.Json;
using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Services.Attendance.AutoRoster;

namespace MokaCo.HRMS.Tests.Attendance.AutoRoster;

/// <summary>D10/D11: what each mode may touch, pins, locks, drafts, off rotation, stability, determinism, transfers, shifts.</summary>
public class RosterPlannerModesTests
{
    private static readonly DateOnly Dec = new(2026, 12, 1);
    private static readonly DateOnly Tue8 = new(2026, 12, 8);
    private static readonly DateOnly Wed9 = new(2026, 12, 9);

    /* ---- modes ---- */

    [Fact]
    public void FillEmpty_fills_only_the_empty_days()
    {
        var world = new RosterWorld().WithStaff(3);
        world.Work(1, Tue8, RosterWorld.Evening);   // a hand-written row
        world.Rest(2, Wed9);
        var p = world.Plan(Dec).Preview;

        Assert.Equal(("work", "fact", "kept", (int?)RosterWorld.Evening), (p.Cell(1, Tue8).State, p.Cell(1, Tue8).Origin, p.Cell(1, Tue8).Change, p.Cell(1, Tue8).ShiftId));
        Assert.Equal(("rest", "kept"), (p.Cell(2, Wed9).State, p.Cell(2, Wed9).Change));
        Assert.All(p.Cells.Where(c => c.WorkDate.Month == 12 && !(c.EmployeeId == 1 && c.WorkDate == Tue8) && !(c.EmployeeId == 2 && c.WorkDate == Wed9)),
            c => Assert.Equal("insert", c.Change));
        Assert.Equal(2, p.Summary.Kept);
        Assert.Equal(3 * 31 - 2, p.Summary.Inserts);
    }

    [Fact]
    public void ReplanAuto_replans_the_generators_rows_and_keeps_hand_edits()
    {
        var world = new RosterWorld().WithStaff(3);
        world.PlanAndCommit(Dec);

        // A hand edit after the save: employee 1's Tuesday becomes an Evening shift. Upsert does not
        // touch ROSTER_CELL, so the row no longer equals its AUTO value — it is manual now.
        var before = world.RowAt(1, Tue8);
        world.Work(1, Tue8, RosterWorld.Evening);
        var p = world.Plan(Dec, "ReplanAuto").Preview;

        Assert.Equal(("fact", "kept", (int?)RosterWorld.Evening), (p.Cell(1, Tue8).Origin, p.Cell(1, Tue8).Change, p.Cell(1, Tue8).ShiftId));
        Assert.All(p.Cells.Where(c => c.WorkDate.Month == 12 && !(c.EmployeeId == 1 && c.WorkDate == Tue8)), c => Assert.Equal("planned", c.Origin));
        Assert.NotEqual(before, world.RowAt(1, Tue8));
    }

    [Fact]
    public void ReplanAll_replans_hand_edits_too_but_never_pinned_locked_or_leave_days()
    {
        var world = new RosterWorld().WithStaff(3);
        world.PlanAndCommit(Dec);
        world.Work(1, Tue8, RosterWorld.Evening);                      // manual
        world.Work(2, Wed9, RosterWorld.Evening); world.Pin(2, Wed9);  // pinned
        world.Locks[new EmpDay(3, Wed9)] = "Paid";                     // paid
        var thu = new DateOnly(2026, 12, 10);
        world.Leave(3, thu, thu);                                      // a row inside a leave

        var p = world.Plan(Dec, "ReplanAll").Preview;
        Assert.Equal("planned", p.Cell(1, Tue8).Origin);
        Assert.Equal(("pinned", "kept"), (p.Cell(2, Wed9).Origin, p.Cell(2, Wed9).Change));
        Assert.Equal(("locked", "kept"), (p.Cell(3, Wed9).Origin, p.Cell(3, Wed9).Change));
        Assert.Equal(("leave", "kept"), (p.Cell(3, thu).Origin, p.Cell(3, thu).Change));
    }

    [Fact]
    public void After_a_preference_changes_ReplanAuto_keeps_the_saved_rests_and_ReplanAll_plans_afresh()
    {
        // Saved; then three people say they would rather rest on Wednesdays (a weekly pattern, a
        // preference). Every saved week still fits, so ReplanAuto moves nothing. ReplanAll is the way to
        // apply it: it plans exactly what the month would get if it were empty.
        static void Wednesdays(RosterWorld w)
        {
            for (var e = 1; e <= 3; e++)
                w.Patterns.Add(new AutoRosterPatternRow { EmployeeId = e, DayOfWeek = 3, IsRestDay = true });
        }

        var world = new RosterWorld().WithStaff(5);
        world.PlanAndCommit(Dec);
        Wednesdays(world);

        Assert.Equal(0, world.Plan(Dec, "ReplanAuto").Preview.Changes());

        var all = world.Plan(Dec, "ReplanAll").Preview;
        var empty = new RosterWorld().WithStaff(5);
        Wednesdays(empty);
        foreach (var r in world.Rhythms.Values)
            empty.Rhythms[r.EmployeeId] = r;
        var fresh = empty.Plan(Dec).Preview;
        Assert.True(all.Changes() > 0);
        Assert.Equal(fresh.Cells.Select(c => (c.EmployeeId, c.WorkDate, c.State)), all.Cells.Select(c => (c.EmployeeId, c.WorkDate, c.State)));
    }

    [Fact]
    public void A_pin_with_no_row_pins_nothing()
    {
        var world = new RosterWorld().WithStaff(1);
        world.Pin(1, Tue8);
        var p = world.Plan(Dec).Preview;
        Assert.Equal("planned", p.Cell(1, Tue8).Origin);
    }

    /* ---- locks ---- */

    [Theory]
    [InlineData("FillEmpty")]
    [InlineData("ReplanAuto")]
    [InlineData("ReplanAll")]
    public void Days_before_today_are_locked_in_a_draft_month_too(string mode)
    {
        var world = new RosterWorld().WithStaff(4);
        world.PlanAndCommit(Dec);
        world.Today = new DateOnly(2026, 12, 10);   // the month is still a Draft (no approval at all)

        var p = world.Plan(Dec, mode).Preview;
        Assert.All(p.Cells.Where(c => c.WorkDate >= Dec && c.WorkDate < world.Today), c =>
        {
            Assert.Equal("locked", c.Origin);
            Assert.Equal("kept", c.Change);
        });
        // From today on, the mode decides as usual (FillEmpty finds every day already filled).
        var fromToday = p.Cells.Where(c => c.WorkDate >= world.Today && c.WorkDate.Month == 12).ToList();
        Assert.All(fromToday, c => Assert.Equal(mode == "FillEmpty" ? "fact" : "planned", c.Origin));
        Assert.Empty(p.Errors());
    }

    [Fact]
    public void Days_before_today_are_locked_by_the_planner_itself_even_without_the_Past_lock_rows()
    {
        var world = new RosterWorld().WithStaff(2);
        world.Today = new DateOnly(2026, 12, 10);
        var context = world.Context(Dec);
        context.Locks.RemoveAll(l => l.Reason == "Past");
        var p = RosterPlanner.Preview(AutoRosterInputFactory.Create(context, world.Request(Dec, "ReplanAll")));

        Assert.All(p.Cells.Where(c => c.WorkDate >= Dec && c.WorkDate < world.Today), c => Assert.Equal(("locked", "kept"), (c.Origin, c.Change)));
    }

    [Fact]
    public void Locked_past_days_count_as_facts_for_the_weeks_rest()
    {
        var world = new RosterWorld { Today = new DateOnly(2026, 12, 10) }.WithStaff(1);
        world.Anchor(1, new DateOnly(2026, 12, 7), 5);
        world.Rest(1, Tue8);   // in the past: locked, and one of this week's two rests
        var p = world.Plan(Dec).Preview;

        var week = p.Week(1, new DateOnly(2026, 12, 7));
        Assert.Equal(2, week.Rests);
        Assert.Equal(1, Enumerable.Range(10, 4).Count(day => p.Cell(1, new DateOnly(2026, 12, day)).State == "rest"));
    }

    [Fact]
    public void Recorded_and_paid_days_are_locked()
    {
        var world = new RosterWorld().WithStaff(1);
        world.Locks[new EmpDay(1, Tue8)] = "Recorded";
        world.Locks[new EmpDay(1, Wed9)] = "Paid";
        var p = world.Plan(Dec).Preview;
        Assert.Equal(("locked", "none", "kept"), (p.Cell(1, Tue8).Origin, p.Cell(1, Tue8).State, p.Cell(1, Tue8).Change));
        Assert.Equal("locked", p.Cell(1, Wed9).Origin);
    }

    [Fact]
    public void A_roster_approval_waiting_locks_the_whole_month()
    {
        var world = new RosterWorld { OpenRequestId = 77 }.WithStaff(2);
        var p = world.Plan(Dec).Preview;

        var issue = Assert.Single(p.Errors());
        Assert.Equal("MONTH_LOCKED", issue.Code);
        Assert.All(p.Cells.Where(c => c.WorkDate.Month == 12), c => Assert.Equal("kept", c.Change));
        Assert.Equal(0, p.Changes());
    }

    /* ---- drafts ---- */

    [Fact]
    public void Draft_edits_are_fixed_as_sent_and_the_week_is_replanned_around_them()
    {
        var world = new RosterWorld().WithStaff(3);
        world.Anchor(1, new DateOnly(2026, 12, 7), 6);
        var p = world.Plan(Dec, "FillEmpty", r =>
        {
            r.DraftCells.Add(new DraftCellDto { EmployeeId = 1, WorkDate = Wed9, IsRestDay = true });
            r.DraftCells.Add(new DraftCellDto { EmployeeId = 1, WorkDate = Tue8, ShiftId = RosterWorld.Evening, IsPinned = true });
        }).Preview;

        Assert.Equal(("rest", "draft", "insert"), (p.Cell(1, Wed9).State, p.Cell(1, Wed9).Origin, p.Cell(1, Wed9).Change));
        Assert.Equal(("work", "draft", (int?)RosterWorld.Evening), (p.Cell(1, Tue8).State, p.Cell(1, Tue8).Origin, p.Cell(1, Tue8).ShiftId));
        // The 6-day week's one rest is the drafted Wednesday: no other rest was added around it.
        Assert.Equal(1, p.Week(1, new DateOnly(2026, 12, 7)).Rests);

        // The commit marks the draft as the manager's (not AUTO) and saves the pin.
        var commit = RosterWorld.CommitRequestFor(world.Request(Dec), p);
        var tue = commit.Cells.Single(c => c.EmployeeId == 1 && c.WorkDate == Tue8);
        Assert.False(tue.IsAuto);
    }

    [Fact]
    public void A_draft_on_a_holiday_chooses_who_covers_it()
    {
        var world = new RosterWorld().WithStaff(3);
        var christmas = new DateOnly(2026, 12, 25);
        world.Holiday(christmas, "Christmas");
        var p = world.Plan(Dec, "FillEmpty", r =>
        {
            r.HolidayCover.Add(new HolidayCoverDto { Date = christmas, Count = 1 });
            r.DraftCells.Add(new DraftCellDto { EmployeeId = 3, WorkDate = christmas, ShiftId = RosterWorld.Day });
        }).Preview;

        Assert.Equal(new[] { 3 }, p.Cells.Where(c => c.WorkDate == christmas && c.State == "work").Select(c => c.EmployeeId));
    }

    /* ---- off rotation ---- */

    [Fact]
    public void Off_rotation_staff_are_shown_as_their_rows_stand_and_never_planned()
    {
        var world = new RosterWorld().WithStaff(3);
        world.Work(3, Tue8);
        var p = world.Plan(Dec, "FillEmpty", r => r.OffRotationEmployeeIds = [3]).Preview;

        Assert.All(p.Cells.Where(c => c.EmployeeId == 3), c => Assert.Equal("kept", c.Change));
        Assert.Equal("work", p.Cell(3, Tue8).State);
        Assert.Equal("none", p.Cell(3, Wed9).State);
        Assert.DoesNotContain(p.Rhythm, r => r.EmployeeId == 3);
        Assert.Empty(p.PerEmployee.Single(e => e.EmployeeId == 3).Weeks);
        // Still on duty when working: the footer counts people, not rotations.
        Assert.Equal(p.Cells.Count(c => c.WorkDate == Tue8 && c.State == "work"), p.PerDay.Single(d => d.Date == Tue8).OnDuty);
        Assert.Equal(p.Cells.Count(c => c.WorkDate == Wed9 && c.State == "work"), p.PerDay.Single(d => d.Date == Wed9).OnDuty);
    }

    [Fact]
    public void Off_rotation_null_uses_the_stored_flag_and_a_list_overrides_it()
    {
        var world = new RosterWorld().WithStaff(2);
        world.Anchor(2, new DateOnly(2026, 11, 30), 6, onRotation: false);

        Assert.DoesNotContain(world.Plan(Dec).Preview.Rhythm, r => r.EmployeeId == 2);
        Assert.Contains(world.Plan(Dec, "FillEmpty", r => r.OffRotationEmployeeIds = []).Preview.Rhythm, r => r.EmployeeId == 2);
    }

    /* ---- stability ---- */

    public static IEnumerable<object[]> Worlds()
    {
        yield return ["plain", (Action<RosterWorld>)(_ => { })];
        yield return ["holidays with cover", (Action<RosterWorld>)(w =>
        {
            w.Holiday(new DateOnly(2026, 12, 25), "Christmas");
            w.Holiday(new DateOnly(2026, 12, 8), "Immaculate Conception");
        })];
        yield return ["leave and a hire", (Action<RosterWorld>)(w =>
        {
            w.Leave(2, new DateOnly(2026, 12, 9), new DateOnly(2026, 12, 18));
            w.Add(9, hire: new DateOnly(2026, 12, 17));
        })];
        yield return ["staffing that forces repairs", (Action<RosterWorld>)(w => { w.Min(5); w.Min(6, dayOfWeek: 6); })];
        yield return ["patterns and pairs", (Action<RosterWorld>)(w =>
        {
            for (var e = 1; e <= 3; e++)
                w.Patterns.Add(new AutoRosterPatternRow { EmployeeId = e, DayOfWeek = (byte)(e + 1), IsRestDay = true });
        })];
        yield return ["a transfer", (Action<RosterWorld>)(w => w.Move(4, new DateOnly(2026, 12, 17), RosterWorld.OtherBranch))];
    }

    [Theory]
    [MemberData(nameof(Worlds))]
    public void Regenerating_a_saved_plan_with_nothing_changed_changes_nothing(string name, Action<RosterWorld> setup)
    {
        foreach (var start in new[] { "Aligned", "Staggered" })
        {
            var world = new RosterWorld().WithStaff(7);
            setup(world);
            void Configure(AutoRosterRequest r)
            {
                r.RhythmStart = start;
                r.HolidayCover.Add(new HolidayCoverDto { Date = new DateOnly(2026, 12, 25), Count = 2 });
            }

            var (first, _) = world.PlanAndCommit(Dec, "FillEmpty", Configure);
            Assert.True(first.Preview.Changes() > 0, name);

            var again = world.Plan(Dec, "ReplanAuto", Configure).Preview;
            Assert.True(again.Changes() == 0, $"{name}/{start}: {again.Summary.Inserts} inserts, {again.Summary.Updates} updates, {again.Summary.Deletes} deletes");
        }
    }

    [Fact]
    public void After_a_change_is_saved_regenerating_again_changes_nothing()
    {
        var world = new RosterWorld().WithStaff(7);
        world.Min(5);
        world.PlanAndCommit(Dec);

        world.Leave(3, new DateOnly(2026, 12, 14), new DateOnly(2026, 12, 16));
        world.Holiday(new DateOnly(2026, 12, 22), "Declared holiday");
        var (changed, _) = world.PlanAndCommit(Dec, "ReplanAuto");
        Assert.True(changed.Preview.Changes() > 0);

        Assert.Equal(0, world.Plan(Dec, "ReplanAuto").Preview.Changes());
    }

    [Theory]
    [InlineData(4, "Aligned")]
    [InlineData(6, "Aligned")]
    [InlineData(8, "Aligned")]
    [InlineData(6, "Staggered")]
    [InlineData(8, "Staggered")]
    public void Regenerating_while_today_moves_through_the_months_changes_nothing(int size, string start)
    {
        // November and December saved together in October; then the manager opens the drawer again day
        // after day. Each morning more days are in the past — facts now, no longer plannable — and what
        // was saved still fits, so nothing moves: no rest swapped between people, no weekend handed on.
        // (From 2 November: on the 1st, 26–31 October — planned as ghosts, never saved — pass; that is
        // the next test.)
        var world = new RosterWorld { Today = new DateOnly(2026, 10, 20) }.WithStaff(size);
        world.Holiday(new DateOnly(2026, 11, 23), "Declared holiday");
        world.Leave(2, new DateOnly(2026, 12, 9), new DateOnly(2026, 12, 11));
        world.Min(size / 2);
        void Configure(AutoRosterRequest r)
        {
            r.RhythmStart = start;
            r.HolidayCover.Add(new HolidayCoverDto { Date = new DateOnly(2026, 11, 23), Count = 1 });
        }
        var nov = new DateOnly(2026, 11, 1);
        world.PlanAndCommit(nov, "FillEmpty", Configure);
        world.PlanAndCommit(Dec, "FillEmpty", Configure);

        for (var today = new DateOnly(2026, 11, 2); today <= new DateOnly(2026, 12, 31); today = today.AddDays(1))
        {
            world.Today = today;
            foreach (var month in new[] { nov, Dec }.Where(m => RosterCalendar.MonthEnd(m) >= today))
            {
                var p = world.Plan(month, "ReplanAuto", Configure).Preview;
                Assert.True(p.Changes() == 0, $"today {today:yyyy-MM-dd}: {month:yyyy-MM} has {p.Changes()} changes");
            }
        }
    }

    [Fact]
    public void When_today_passes_a_ghost_day_only_that_week_finds_its_rest_again()
    {
        // December saved in October with November never rostered: Mon 30 Nov was a ghost, and the rest of
        // that first week sat on it for some — planned, never saved. Once 30 Nov is past (no row: not a
        // rest), each of them needs that rest inside 1–6 December. Nothing else moves.
        var world = new RosterWorld { Today = new DateOnly(2026, 10, 20) }.WithStaff(8);
        var (first, _) = world.PlanAndCommit(Dec);
        var mon30 = new DateOnly(2026, 11, 30);
        var lost = first.Preview.Cells.Where(c => c.WorkDate == mon30 && c.State == "rest").Select(c => c.EmployeeId).ToList();
        Assert.NotEmpty(lost);

        world.Today = new DateOnly(2026, 12, 1);
        var p = world.Plan(Dec, "ReplanAuto").Preview;
        var changed = p.Cells.Where(c => c.Change is "insert" or "update" or "delete").ToList();

        Assert.Equal(lost.Order(), changed.Select(c => c.EmployeeId).Order());   // one day each, only theirs
        Assert.All(changed, c => Assert.Equal(("rest", true), (c.State, c.WorkDate <= new DateOnly(2026, 12, 6))));
        Assert.All(lost, e => Assert.True(p.Week(e, mon30).Ok));
    }

    [Fact]
    public void A_small_change_keeps_most_of_the_generated_rests_where_they_were()
    {
        var world = new RosterWorld().WithStaff(7);
        world.PlanAndCommit(Dec);
        var before = world.Rows.Where(r => r.Key.Date.Month == 12 && r.Value.IsRestDay).Select(r => r.Key).ToHashSet();

        world.Leave(3, new DateOnly(2026, 12, 22), new DateOnly(2026, 12, 22));
        var p = world.Plan(Dec, "ReplanAuto").Preview;
        var after = p.Cells.Where(c => c.WorkDate.Month == 12 && c.State == "rest").Select(c => new EmpDay(c.EmployeeId, c.WorkDate)).ToHashSet();

        Assert.True(before.Intersect(after).Count() >= before.Count - 6, $"{before.Count - before.Intersect(after).Count()} rests moved");
    }

    /* ---- determinism ---- */

    [Fact]
    public void Shuffling_every_input_list_gives_the_same_preview()
    {
        var world = new RosterWorld().WithStaff(8);
        world.Holiday(new DateOnly(2026, 12, 25), "Christmas");
        world.Leave(2, new DateOnly(2026, 12, 9), new DateOnly(2026, 12, 12));
        world.Min(5);
        world.Move(5, new DateOnly(2026, 12, 17), RosterWorld.OtherBranch);
        for (var d = new DateOnly(2026, 10, 1); d < new DateOnly(2026, 11, 30); d = d.AddDays(1))
            foreach (var e in world.People.Keys)
                if ((d.DayNumber + e) % 6 == 0) world.Rest(e, d); else world.Work(e, d);

        var request = world.Request(Dec);
        request.HolidayCover.Add(new HolidayCoverDto { Date = new DateOnly(2026, 12, 25), Count = 1 });
        var context = world.Context(Dec);
        var expected = JsonSerializer.Serialize(RosterPlanner.Preview(AutoRosterInputFactory.Create(context, request)));

        for (var seed = 1; seed <= 5; seed++)
        {
            var rng = new Random(seed);
            var shuffled = new AutoRosterContext
            {
                Header = context.Header,
                Settings = Shuffle(context.Settings, rng),
                Staff = Shuffle(context.Staff, rng),
                StaffDays = Shuffle(context.StaffDays, rng),
                Rows = Shuffle(context.Rows, rng),
                Locks = Shuffle(context.Locks, rng),
                Holidays = Shuffle(context.Holidays, rng),
                HolidaysWorked = Shuffle(context.HolidaysWorked, rng),
                Leaves = Shuffle(context.Leaves, rng),
                Shifts = Shuffle(context.Shifts, rng),
                Patterns = Shuffle(context.Patterns, rng),
                Rhythm = Shuffle(context.Rhythm, rng),
                Cells = Shuffle(context.Cells, rng),
                Staffing = Shuffle(context.Staffing, rng),
                LastRun = context.LastRun,
            };
            Assert.Equal(expected, JsonSerializer.Serialize(RosterPlanner.Preview(AutoRosterInputFactory.Create(shuffled, request))));
        }
    }

    private static List<T> Shuffle<T>(List<T> list, Random rng) => list.OrderBy(_ => rng.Next()).ToList();

    /* ---- transfers ---- */

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public void A_transfer_mid_week_gives_that_week_its_quota_in_either_generation_order(bool newBranchFirst)
    {
        var world = new RosterWorld();
        world.Add(1, branch: RosterWorld.OtherBranch);
        world.Add(2, branch: RosterWorld.OtherBranch);
        world.Add(3, branch: RosterWorld.Branch);
        world.Move(1, new DateOnly(2026, 12, 17), RosterWorld.Branch);   // Ali: Mon–Wed in branch 2, Thu–Sun in branch 1

        var order = newBranchFirst ? new[] { RosterWorld.Branch, RosterWorld.OtherBranch } : new[] { RosterWorld.OtherBranch, RosterWorld.Branch };
        foreach (var branch in order)
        {
            var (run, issues) = world.PlanAndCommit(Dec, branch: branch);
            Assert.Empty(run.Preview.Errors());
            // Each branch writes only its own days of Ali's week.
            Assert.All(run.Preview.Cells.Where(c => c.EmployeeId == 1 && c.WorkDate >= new DateOnly(2026, 12, 14) && c.WorkDate <= new DateOnly(2026, 12, 20)),
                c => Assert.Equal(branch == RosterWorld.Branch, c.WorkDate >= new DateOnly(2026, 12, 17)));
        }

        var ws = new DateOnly(2026, 12, 14);
        var rhythm = world.Rhythms[1];
        var expected = 7 - RosterCalendar.WorkDaysInWeek(RosterCalendar.WeekIndex(RosterWorld.D(rhythm.AnchorWeekStart)), rhythm.AnchorWorkDays, RosterCalendar.WeekIndex(ws));
        Assert.Equal(expected, world.RestsInWeek(1, ws));
        Assert.All(Enumerable.Range(0, 7), i => Assert.NotNull(world.RowAt(1, ws.AddDays(i))));
    }

    /* ---- shifts (§2.6) ---- */

    [Fact]
    public void A_working_day_takes_the_pattern_shift_then_the_usual_shift_then_the_default_then_the_first_active()
    {
        var world = new RosterWorld();
        world.Add(1); world.Add(2); world.Add(3); world.Add(4);
        world.Patterns.Add(new AutoRosterPatternRow { EmployeeId = 1, DayOfWeek = 2, ShiftId = RosterWorld.Night });     // Tuesdays
        world.Patterns.Add(new AutoRosterPatternRow { EmployeeId = 1, DayOfWeek = 3, ShiftId = RosterWorld.Retired });   // inactive: ignored
        for (var d = new DateOnly(2026, 11, 2); d < new DateOnly(2026, 11, 30); d = d.AddDays(1))
            world.Work(2, d, d.DayOfWeek == DayOfWeek.Monday ? RosterWorld.Morning : RosterWorld.Evening);

        var p = world.Plan(Dec, "FillEmpty", r => r.DefaultShiftId = RosterWorld.Morning).Preview;
        var tue = p.Cells.First(c => c.EmployeeId == 1 && c.WorkDate.DayOfWeek == DayOfWeek.Tuesday && c.State == "work" && c.WorkDate.Month == 12);
        Assert.Equal(RosterWorld.Night, tue.ShiftId);
        var wed = p.Cells.First(c => c.EmployeeId == 1 && c.WorkDate.DayOfWeek == DayOfWeek.Wednesday && c.State == "work" && c.WorkDate.Month == 12);
        Assert.Equal(RosterWorld.Morning, wed.ShiftId);   // pattern shift inactive → (no history) → the default
        Assert.All(p.Cells.Where(c => c.EmployeeId == 2 && c.State == "work"), c => Assert.Equal(RosterWorld.Evening, c.ShiftId));
        Assert.All(p.Cells.Where(c => c.EmployeeId == 3 && c.State == "work"), c => Assert.Equal(RosterWorld.Morning, c.ShiftId));

        var noDefault = world.Plan(Dec).Preview;
        Assert.All(noDefault.Cells.Where(c => c.EmployeeId == 3 && c.State == "work"), c => Assert.Equal(RosterWorld.Day, c.ShiftId));   // the first active
        Assert.DoesNotContain(noDefault.Cells, c => c.State == "work" && c.ShiftId == RosterWorld.Retired);
        Assert.All(noDefault.Cells.Where(c => c.State != "work"), c => Assert.Null(c.ShiftId));
    }

    [Fact]
    public void With_no_active_shift_a_working_day_is_an_error()
    {
        var world = new RosterWorld().WithStaff(1);
        world.Shifts.ForEach(s => s.IsActive = false);
        var p = world.Plan(Dec).Preview;
        Assert.Contains(p.Errors(), i => i.Code == "WORK_WITHOUT_SHIFT");
    }

    /* ---- the preview's own consistency ---- */

    [Fact]
    public void The_summary_counts_the_month_cells_and_ghosts_are_never_sent()
    {
        var world = new RosterWorld().WithStaff(4);
        world.Work(1, Tue8);
        var run = world.Plan(Dec);
        var p = run.Preview;
        var month = p.Cells.Where(c => c.WorkDate.Month == 12 && c.WorkDate.Year == 2026).ToList();

        Assert.Equal(month.Count(c => c.Change == "insert"), p.Summary.Inserts);
        Assert.Equal(month.Count(c => c.Change == "kept"), p.Summary.Kept);
        Assert.Equal(month.Count, p.Summary.Inserts + p.Summary.Updates + p.Summary.Deletes + p.Summary.Unchanged + p.Summary.Kept);
        Assert.All(p.Cells.Where(c => c.WorkDate.Month != 12), c => Assert.Equal("kept", c.Change));
        Assert.All(RosterWorld.CommitRequestFor(run.Request, p).Cells, c => Assert.Equal(12, c.WorkDate.Month));
        Assert.Equal(31, p.PerDay.Count);
        Assert.DoesNotContain(p.Cells, c => c.State == "work" && c.ShiftId is null);
    }
}
