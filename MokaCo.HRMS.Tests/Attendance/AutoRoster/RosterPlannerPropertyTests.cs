using System.Text.Json;
using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Services.Attendance.AutoRoster;

namespace MokaCo.HRMS.Tests.Attendance.AutoRoster;

/// <summary>
/// The seeded property loop: 320 random branches (System.Random with fixed seeds, so a failure names
/// a seed that reproduces it) with history, existing rows, auto markers, pins, holidays and cover,
/// leave and half days, locks, transfers, hires and leavers, staffing rows, patterns, drafts, stored
/// rhythms, overrides, off-rotation staff and every mode. Each plan is held to the hard rules by an
/// INDEPENDENT reading of the spec (not by the validator): every rule holds, or the preview reports it.
/// Then: the same input plans the same way, the commit validates without new errors, regenerating
/// the saved plan changes nothing, and regenerating it again after today has moved on changes nothing
/// either — except in a week whose planned rest sat on a ghost day that is now in the past (it was
/// never saved, so that week has to find it again).
/// </summary>
public class RosterPlannerPropertyTests
{
    public static IEnumerable<object[]> Seeds() => Enumerable.Range(1, 320).Select(s => new object[] { s });

    [Theory]
    [MemberData(nameof(Seeds))]
    public void Every_hard_rule_holds_or_is_reported(int seed)
    {
        var rng = new Random(seed);
        var scenario = Scenario.Random(rng);
        var world = scenario.World;
        var run = world.Plan(scenario.Month, scenario.Mode, scenario.Configure);

        new Checker(run).All();

        // Determinism: the same input again, and the same input with every list shuffled.
        Assert.Equal(Json(run.Preview), Json(world.Plan(scenario.Month, scenario.Mode, scenario.Configure).Preview));
        if (seed % 8 == 0)
        {
            var context = world.Context(scenario.Month);
            var shuffled = Shuffled(context, new Random(seed * 31));
            Assert.Equal(Json(run.Preview), Json(RosterPlanner.Preview(AutoRosterInputFactory.Create(shuffled, run.Request))));
        }

        // The commit of the unedited preview: its server-side check finds no error the preview did not show.
        var commitIssues = world.Commit(run);
        var previewErrors = run.Preview.Errors().Select(i => (i.Code, i.EmployeeId)).ToHashSet();
        Assert.All(commitIssues.Where(i => i.Severity == "error"), i => Assert.Contains((i.Code, i.EmployeeId), previewErrors));

        // Stability: regenerating what was just saved changes nothing.
        var regenerateMode = scenario.Mode == "FillEmpty" ? "FillEmpty" : "ReplanAuto";
        var again = world.Plan(scenario.Month, regenerateMode, scenario.Configure).Preview;
        Assert.True(again.Changes() == 0,
            $"seed {seed}: regenerate gave {again.Summary.Inserts} inserts, {again.Summary.Updates} updates, {again.Summary.Deletes} deletes: "
            + string.Join("; ", again.Cells.Where(c => c.Change is "insert" or "update" or "delete")
                .Select(c => $"{c.EmployeeId} {c.WorkDate:yyyy-MM-dd} {c.Change} {(c.Expected.IsRestDay == true ? "rest" : c.Expected.ShiftId?.ToString() ?? "none")}->{(c.State == "work" ? c.ShiftId?.ToString() : c.State)} {c.Origin} {c.ReasonCode} {c.ReasonArgs}")));

        // And once today has moved on: the days before it become facts, everything saved still fits.
        var lostGhostWeeks = run.Preview.Cells
            .Where(c => c.Origin == "ghost")
            .Select(c => (c.WorkDate, Week: RosterCalendar.WeekStart(c.WorkDate)))
            .ToList();
        world.Today = world.Today.AddDays(1 + new Random(seed * 17).Next(21));
        var later = world.Plan(scenario.Month, regenerateMode, scenario.Configure).Preview;
        // A shift that only changed because the day before did follows that change (D16: who covers a
        // shift depends on the shifts worked the day before — someone who covered a night stays on
        // nights while going back would be a turnaround, and the next cover is chosen around them).
        var changedDays = new HashSet<DateOnly>();
        foreach (var c in later.Cells.Where(c => c.Change is "insert" or "update" or "delete").OrderBy(c => c.WorkDate))
        {
            var week = RosterCalendar.WeekStart(c.WorkDate);
            var shiftOnly = c.Change == "update" && c.State == "work" && c.Expected.IsRestDay == false;
            var followsDayBefore = shiftOnly && changedDays.Contains(c.WorkDate.AddDays(-1));
            changedDays.Add(c.WorkDate);
            Assert.True(followsDayBefore || lostGhostWeeks.Any(g => g.Week == week && g.WorkDate < world.Today),
                $"seed {seed}: {c.EmployeeId} {c.WorkDate:yyyy-MM-dd} {c.Change} "
                + $"{(c.Expected.IsRestDay == true ? "rest" : c.Expected.ShiftId?.ToString() ?? "none")}->{(c.State == "work" ? c.ShiftId?.ToString() : c.State)} "
                + $"{c.Origin} {c.ReasonCode} {c.ReasonArgs} after today moved to {world.Today:yyyy-MM-dd}");
        }
    }

    private static string Json(AutoRosterPreview p) => JsonSerializer.Serialize(p);

    private static AutoRosterContext Shuffled(AutoRosterContext c, Random rng)
    {
        List<T> S<T>(List<T> list) => list.OrderBy(_ => rng.Next()).ToList();
        return new AutoRosterContext
        {
            Header = c.Header, Settings = S(c.Settings), Staff = S(c.Staff), StaffDays = S(c.StaffDays), Rows = S(c.Rows),
            Locks = S(c.Locks), Holidays = S(c.Holidays), HolidaysWorked = S(c.HolidaysWorked), Leaves = S(c.Leaves),
            Shifts = S(c.Shifts), Patterns = S(c.Patterns), Rhythm = S(c.Rhythm), Cells = S(c.Cells), Staffing = S(c.Staffing),
            LastRun = c.LastRun,
        };
    }

    /* ==================================================================================
     * Random scenarios
     * ================================================================================ */

    private sealed record Scenario(RosterWorld World, DateOnly Month, string Mode, Action<AutoRosterRequest> Configure)
    {
        private static readonly int[] WorkShifts = [RosterWorld.Day, RosterWorld.Morning, RosterWorld.Evening, RosterWorld.Night];

        public static Scenario Random(Random rng)
        {
            var month = new DateOnly(2026, 6, 1).AddMonths(rng.Next(10));
            var (from, to) = RosterCalendar.Window(month);
            var monthEnd = RosterCalendar.MonthEnd(month);
            var world = new RosterWorld { Today = month.AddDays(rng.Next(-40, 16)) };
            if (rng.Next(25) == 0)
                world.OpenRequestId = 500 + rng.Next(100);

            // Settings
            var cap = rng.Next(5) == 0 ? 6 : 7;
            world.Settings["RosterMaxConsecutiveWorkDays"] = cap.ToString();
            world.Settings["RosterPreferredMaxConsecutiveWorkDays"] = (cap - rng.Next(2)).ToString();
            if (rng.Next(5) == 0) world.Settings["RosterHolidayCountsAsRest"] = "1";
            if (rng.Next(5) == 0) world.Settings["RosterPairRestDays"] = "0";
            if (rng.Next(5) == 0) world.Settings["RosterPatternRestDays"] = "Unavailable";
            if (rng.Next(4) == 0) world.LookbackWeeks = rng.Next(4, 27);

            // Staff: hires, leavers, transfers in and out
            var size = rng.Next(1, 10);
            for (var e = 1; e <= size; e++)
            {
                var hire = rng.Next(7) == 0 ? from.AddDays(rng.Next(0, 40)) : new DateOnly(2024, 1, 1);
                DateOnly? leave = rng.Next(10) == 0 ? from.AddDays(rng.Next(3, 42)) : null;
                if (leave is { } l && l < hire) leave = hire.AddDays(3);
                var startsElsewhere = rng.Next(7) == 0;
                world.Add(e, startsElsewhere ? RosterWorld.OtherBranch : RosterWorld.Branch, hire, leave, positionId: rng.Next(1, 4));
                if (startsElsewhere)
                    world.Move(e, from.AddDays(rng.Next(1, 40)), RosterWorld.Branch);
                else if (rng.Next(10) == 0)
                    world.Move(e, from.AddDays(rng.Next(1, 40)), RosterWorld.OtherBranch);
            }

            // History rows (all branches), with a holiday someone worked
            foreach (var e in world.People.Keys)
            {
                if (rng.Next(10) < 3) continue;
                for (var d = from.AddDays(-42); d < from; d = d.AddDays(1))
                {
                    if (world.BranchOn(e, d) is null || rng.Next(10) == 0) continue;
                    if (rng.Next(6) == 0) world.Rest(e, d); else world.Work(e, d, WorkShifts[rng.Next(WorkShifts.Length)]);
                }
            }
            var pastHoliday = from.AddDays(-rng.Next(20, 300));
            world.Holiday(pastHoliday, "Past holiday");
            foreach (var e in world.People.Keys.Where(_ => rng.Next(2) == 0))
                world.Work(e, pastHoliday);

            // Existing rows in the window, some generated (auto), some by hand, some pinned
            foreach (var e in world.People.Keys)
            {
                foreach (var d in RosterCalendar.Days(from, to))
                {
                    if (world.BranchOn(e, d) is null || rng.Next(4) != 0) continue;
                    var roll = rng.Next(30);
                    if (roll < 6) world.Rest(e, d);
                    else world.Work(e, d, roll == 6 ? RosterWorld.Retired : WorkShifts[rng.Next(WorkShifts.Length)]);
                    var marker = rng.Next(20);
                    if (marker < 12) world.MarkAuto(e, d);
                    else if (marker == 12)
                        world.Cells[new EmpDay(e, d)] = new AutoRosterCellRow { EmployeeId = e, WorkDate = RosterWorld.T(d), AutoState = "work", AutoShiftId = RosterWorld.Morning };
                    if (rng.Next(25) == 0) world.Pin(e, d);
                }
            }

            // Holidays in (and around) the month
            var holidays = new List<DateOnly>();
            for (var i = rng.Next(0, 3); i > 0; i--)
            {
                var d = month.AddDays(rng.Next(0, monthEnd.Day));
                if (holidays.Contains(d)) continue;
                holidays.Add(d);
                world.Holiday(d, $"Holiday {d:MM-dd}", paid: rng.Next(3) > 0, branch: rng.Next(4) == 0 ? RosterWorld.Branch : null);
            }
            if (rng.Next(4) == 0)
                world.Holiday(to.AddDays(-rng.Next(0, 3)), "Ghost-week holiday");
            if (rng.Next(6) == 0)
                world.Holiday(month.AddDays(3), "Other branch's holiday", branch: RosterWorld.OtherBranch);

            // Leave
            foreach (var e in world.People.Keys)
            {
                if (rng.Next(10) < 3)
                {
                    var start = from.AddDays(rng.Next(-5, 40));
                    world.Leave(e, start, start.AddDays(rng.Next(0, 9)), paid: rng.Next(2) == 0, status: rng.Next(4) == 0 ? "Pending" : "Approved");
                }
                if (rng.Next(6) == 0)
                {
                    var day = from.AddDays(rng.Next(0, 42));
                    world.Leave(e, day, day, halfDay: rng.Next(2) == 0 ? "AM" : "PM");
                }
            }

            // Locks
            foreach (var e in world.People.Keys)
                foreach (var d in RosterCalendar.Days(month, monthEnd))
                    if (rng.Next(35) == 0)
                        world.Locks[new EmpDay(e, d)] = rng.Next(2) == 0 ? "Paid" : "Recorded";

            // Staffing
            switch (rng.Next(6))
            {
                case 0: case 1: world.Min(rng.Next(0, size + 1)); break;
                case 2: world.Min(rng.Next(0, size)); world.Min(rng.Next(0, size + 1), dayOfWeek: rng.Next(1, 8), target: size); break;
                case 3: world.Min(rng.Next(0, 3), shiftId: WorkShifts[rng.Next(WorkShifts.Length)]); break;
            }

            // Weekly patterns
            foreach (var e in world.People.Keys.Where(_ => rng.Next(10) < 3))
            {
                world.Patterns.Add(new AutoRosterPatternRow { EmployeeId = e, DayOfWeek = (byte)rng.Next(1, 8), IsRestDay = true });
                var dow = (byte)rng.Next(1, 8);
                if (world.Patterns.All(p => p.EmployeeId != e || p.DayOfWeek != dow))
                    world.Patterns.Add(new AutoRosterPatternRow { EmployeeId = e, DayOfWeek = dow, ShiftId = rng.Next(5) == 0 ? RosterWorld.Retired : WorkShifts[rng.Next(WorkShifts.Length)] });
            }

            // Stored rhythms (some off rotation)
            foreach (var e in world.People.Keys.Where(_ => rng.Next(10) < 3))
                world.Anchor(e, RosterCalendar.WeekStart(from.AddDays(rng.Next(-60, 60))), rng.Next(2) == 0 ? 5 : 6, onRotation: rng.Next(8) != 0);

            // The request
            var mode = AutoRosterInputFactory.Modes[rng.Next(3)];
            var rhythmStart = rng.Next(3) switch { 0 => "Staggered", 1 => "Aligned", _ => (string?)null };
            int? defaultShift = rng.Next(3) switch { 0 => RosterWorld.Evening, 1 => RosterWorld.Retired, _ => null };
            var cover = holidays.Select(h => new HolidayCoverDto { Date = h, Count = rng.Next(0, 3) }).ToList();
            var off = rng.Next(3) == 0 ? world.People.Keys.Where(_ => rng.Next(8) == 0).ToList() : null;
            var overrides = world.People.Keys.Where(_ => rng.Next(10) == 0)
                .Select(e => new RhythmOverrideDto { EmployeeId = e, WeekStart = from.AddDays(rng.Next(0, 35)), WorkDays = rng.Next(2) == 0 ? 5 : 6 }).ToList();
            var drafts = new List<DraftCellDto>();
            foreach (var e in world.People.Keys)
                foreach (var d in RosterCalendar.Days(month, monthEnd))
                {
                    if (rng.Next(20) != 0) continue;
                    var roll = rng.Next(20);
                    drafts.Add(roll < 9
                        ? new DraftCellDto { EmployeeId = e, WorkDate = d, IsRestDay = true, IsPinned = rng.Next(4) == 0 }
                        : new DraftCellDto { EmployeeId = e, WorkDate = d, ShiftId = WorkShifts[rng.Next(WorkShifts.Length)], IsPinned = rng.Next(4) == 0 });
                }

            // The following month saved first, for some: rows past the window that its last run joins.
            foreach (var e in world.People.Keys)
            {
                if (rng.Next(10) >= 3) continue;
                var opening = rng.Next(0, cap + 2);
                for (var i = 1; i <= cap + 3; i++)
                {
                    var d = to.AddDays(i);
                    if (world.BranchOn(e, d) is null) continue;
                    if (i <= opening || rng.Next(4) != 0) world.Work(e, d, WorkShifts[rng.Next(WorkShifts.Length)]);
                    else world.Rest(e, d);
                }
            }

            void Configure(AutoRosterRequest r)
            {
                r.RhythmStart = rhythmStart;
                r.DefaultShiftId = defaultShift;
                r.HolidayCover = cover;
                r.OffRotationEmployeeIds = off;
                r.RhythmOverrides = overrides;
                r.DraftCells = drafts;
            }

            return new Scenario(world, month, mode, Configure);
        }
    }

    /* ==================================================================================
     * The independent reading of the rules
     * ================================================================================ */

    private sealed class Checker
    {
        private readonly RosterWorld.Run _run;
        private readonly PlannerInput _in;
        private readonly AutoRosterPreview _p;
        private readonly Dictionary<EmpDay, AutoRosterCell> _cells;
        private readonly Dictionary<int, AutoRosterRhythm> _rhythm;

        public Checker(RosterWorld.Run run)
        {
            _run = run;
            _in = run.Input;
            _p = run.Preview;
            _cells = _p.Cells.ToDictionary(c => new EmpDay(c.EmployeeId, c.WorkDate));
            _rhythm = _p.Rhythm.ToDictionary(r => r.EmployeeId);
        }

        public void All()
        {
            OneCellPerBranchDay();
            FactsAreUntouched();
            WrittenCellsAreWellFormed();
            RunsWithinTheCapOrReported();
            WeeksOnQuotaOrReported();
            StaffingOrReported();
            ShiftsCoveredOrReported();
            SummaryAndGhosts();
        }

        private bool Actionable(DateOnly d) => _in.InMonth(d) && d >= _in.Today && !_in.MonthLocked;
        private static bool Written(AutoRosterCell c) => c.Change is "insert" or "update" or "delete" or "unchanged";

        private bool Has(string code, int? employee, DateOnly from, DateOnly to)
            => _p.Issues.Any(i => i.Code == code && (employee is null || i.EmployeeId == employee) && i.Date is { } d && d >= from && d <= to);

        private void OneCellPerBranchDay()
        {
            Assert.Equal(_cells.Count, _p.Cells.Count);
            foreach (var s in _in.Staff)
                foreach (var d in RosterCalendar.Days(_in.WindowFrom, _in.WindowTo))
                    Assert.Equal(_in.InBranch(s.EmployeeId, d), _cells.ContainsKey(new EmpDay(s.EmployeeId, d)));
        }

        /// <summary>§2.1 / D10, read straight from the spec: these cells are never changed.</summary>
        private void FactsAreUntouched()
        {
            var onRotation = _in.Staff.ToDictionary(s => s.EmployeeId, s => s.OnRotation);
            foreach (var c in _p.Cells)
            {
                var key = new EmpDay(c.EmployeeId, c.WorkDate);
                var row = _in.RowOf(c.EmployeeId, c.WorkDate);
                _in.Cells.TryGetValue(key, out var meta);
                var hasDraft = _in.DraftCells.ContainsKey(key);
                var leave = _in.LeaveOn(c.EmployeeId, c.WorkDate);

                var never = !onRotation[c.EmployeeId]
                            || !_in.InMonth(c.WorkDate)
                            || (_in.InMonth(c.WorkDate) && (_in.MonthLocked || c.WorkDate < _in.Today || _in.Locks.ContainsKey(key)))
                            || (row is not null && meta is { IsPinned: true })
                            || (row is not null && leave != LeaveKind.None)
                            || (row is not null && !hasDraft && _in.Mode == RosterMode.FillEmpty)
                            || (row is not null && !hasDraft && _in.Mode == RosterMode.ReplanAuto && meta?.Matches(row) != true);

                if (!never)
                    continue;
                Assert.Equal("kept", c.Change);

                // A ghost (outside the month, no row, not past) is planned but never saved.
                var ghost = !_in.InMonth(c.WorkDate) && row is null && c.WorkDate >= _in.Today && onRotation[c.EmployeeId];
                if (ghost)
                    Assert.Equal("ghost", c.Origin);
                else
                    Assert.Equal(StateOf(row), c.State);
            }
        }

        private static string StateOf(RosterRow? row) => row switch
        {
            { IsRestDay: true } => "rest",
            { ShiftId: not null } => "work",
            _ => "none",
        };

        private void WrittenCellsAreWellFormed()
        {
            foreach (var c in _p.Cells.Where(Written))
            {
                var leave = _in.LeaveOn(c.EmployeeId, c.WorkDate);
                var holiday = _in.Holidays.ContainsKey(c.WorkDate);
                var draft = c.Origin == "draft";

                // D5: a leave day is never a rest day.
                if (leave != LeaveKind.None)
                    Assert.NotEqual("rest", c.State);

                // D4: never a rest row on a holiday — only the manager's draft can put one there, and it is an error.
                if (holiday && c.State == "rest")
                {
                    Assert.True(draft, $"{c.EmployeeId} {c.WorkDate}: planned rest on a holiday");
                    Assert.True(Has("REST_ON_HOLIDAY", c.EmployeeId, c.WorkDate, c.WorkDate));
                }

                // Never a working day without an active shift, unless reported.
                if (c.State == "work" && !_in.IsActiveShift(c.ShiftId))
                    Assert.True(Has("WORK_WITHOUT_SHIFT", c.EmployeeId, c.WorkDate, c.WorkDate), $"{c.EmployeeId} {c.WorkDate}: work without an active shift, unreported");
                if (c.State != "work")
                    Assert.Null(c.ShiftId);

                // No gaps: a written day with no row is a holiday off or the manager's own "empty".
                if (c.State == "none")
                    Assert.True(holiday || draft, $"{c.EmployeeId} {c.WorkDate}: a gap");

                // A weekly-pattern "unavailable" day is a rest unless a fact or draft says otherwise.
                if (_in.Settings.PatternRestDays == PatternRestRule.Unavailable && _in.IsPatternRest(c.EmployeeId, c.WorkDate)
                    && c.Origin == "planned")
                    Assert.Equal("rest", c.State);
            }
        }

        /// <summary>Employed that day: the context's day list in and before the window, the staff record's dates after it.</summary>
        private bool Employed(int e, DateOnly d) => d <= _in.WindowTo
            ? _in.IsEmployed(e, d)
            : _in.Staff.Any(s => s.EmployeeId == e && (s.HireDate is null || s.HireDate <= d) && (s.TerminationDate is null || d <= s.TerminationDate));

        private bool WorksOn(int e, DateOnly d)
        {
            if (!Employed(e, d) || _in.LeaveOn(e, d) == LeaveKind.Full)
                return false;
            if (_cells.TryGetValue(new EmpDay(e, d), out var c))
                return c.State == "work";
            return _in.RowOf(e, d) is { IsWork: true };
        }

        private bool RestsOn(int e, DateOnly d)
        {
            if (!_in.IsEmployed(e, d) || _in.LeaveOn(e, d) != LeaveKind.None)
                return false;
            if (_cells.TryGetValue(new EmpDay(e, d), out var c))
                return c.State == "rest";
            return _in.RowOf(e, d) is { IsRestDay: true };
        }

        /// <summary>
        /// Runs are followed past the window to the horizon: the following month's saved opening run
        /// (when it was planned first) joins this window's closing one.
        /// </summary>
        private void RunsWithinTheCapOrReported()
        {
            var cap = _in.Settings.MaxConsecutiveWorkDays;
            foreach (var e in _rhythm.Keys)
            {
                DateOnly? start = null;
                for (var d = _in.WindowFrom.AddDays(-31); d <= _in.HorizonTo.AddDays(1); d = d.AddDays(1))
                {
                    if (d <= _in.HorizonTo && WorksOn(e, d))
                    {
                        start ??= d;
                        continue;
                    }
                    if (start is { } s && d.DayNumber - s.DayNumber > cap)
                    {
                        var days = RosterCalendar.Days(s, d.AddDays(-1)).ToList();
                        var relevant = days.Any(x => _cells.TryGetValue(new EmpDay(e, x), out var c) && (Written(c) || Actionable(x)));
                        if (relevant)
                            Assert.True(_p.Issues.Any(i => i.Code == "CONSECUTIVE_CAP" && i.EmployeeId == e),
                                $"employee {e}: {days.Count} days in a row from {s}, unreported");

                        // The planner never causes a breach itself: when one is an error (written days in
                        // it), something it may not move is in it — a draft edit, a leave row, or a holiday
                        // cover nobody else could have taken without a breach of their own.
                        var written = days.Where(x => _cells.TryGetValue(new EmpDay(e, x), out var c) && Written(c)).ToList();
                        if (written.Count > 0)
                        {
                            var cells = days.Select(x => _cells.TryGetValue(new EmpDay(e, x), out var c) ? c : null).ToList();
                            var excused = cells.Any(c => c?.Origin is "draft" or "leave")
                                          || cells.Any(c => c is { Origin: "holiday", State: "work" } && NobodyElseCouldCover(c.WorkDate));
                            Assert.True(excused, $"employee {e}: the planner made a {days.Count}-day run from {s}");
                        }
                    }
                    start = null;
                }
            }
        }

        /// <summary>
        /// Everyone left off a holiday the planner decided (not on leave) would also have had a run past
        /// the cap had they covered it, counting only the days the planner does not choose: rows it keeps,
        /// pins, drafts, leave rows and covers — so the cover had to go to someone who breaks it.
        /// </summary>
        private bool NobodyElseCouldCover(DateOnly holiday)
        {
            var cap = _in.Settings.MaxConsecutiveWorkDays;
            foreach (var off in _p.Cells.Where(c => c.WorkDate == holiday && c is { Origin: "holiday", State: "none" }
                                                    && _in.LeaveOn(c.EmployeeId, holiday) == LeaveKind.None))
            {
                var e = off.EmployeeId;
                int before = 0, after = 0;
                for (var d = holiday.AddDays(-1); FixedWork(e, d); d = d.AddDays(-1)) before++;
                for (var d = holiday.AddDays(1); FixedWork(e, d); d = d.AddDays(1)) after++;
                if (before + 1 + after <= cap)
                    return false;
            }
            return true;
        }

        private bool FixedWork(int e, DateOnly d)
        {
            if (!_cells.TryGetValue(new EmpDay(e, d), out var c))
                return WorksOn(e, d);
            if (c.Origin is "planned" || (c.Origin == "ghost" && _in.LeaveOn(e, d) == LeaveKind.None))
                return false;
            return WorksOn(e, d);
        }

        private void WeeksOnQuotaOrReported()
        {
            foreach (var (e, r) in _rhythm)
            {
                var rhythm = new ResolvedRhythm(e, r.AnchorWeekStart, r.AnchorWorkDays, r.IsNew);
                for (var ws = _in.WindowFrom; ws <= _in.WindowTo; ws = ws.AddDays(7))
                {
                    var days = Enumerable.Range(0, 7).Select(i => ws.AddDays(i)).ToList();
                    var actionable = days.Any(d => _cells.TryGetValue(new EmpDay(e, d), out var c) && (Written(c) || Actionable(d)));
                    if (!actionable)
                        continue;

                    var employed = days.Count(d => _in.IsEmployed(e, d));
                    var holidaysOff = days.Count(d => _cells.TryGetValue(new EmpDay(e, d), out var c) && c.State == "none" && _in.Holidays.ContainsKey(d));
                    var quota = Math.Max(0, employed - rhythm.WorkDaysIn(ws) - (_in.Settings.HolidayCountsAsRest ? holidaysOff : 0));
                    var rests = days.Count(d => RestsOn(e, d));
                    if (rests == quota)
                        continue;

                    var from = ws < _in.MonthStart ? _in.MonthStart : ws;
                    var to = ws.AddDays(6) > _in.MonthEnd ? _in.MonthEnd : ws.AddDays(6);
                    Assert.True(Has("RHYTHM_SHORT", e, from, to) || Has("RHYTHM_OVER", e, from, to) || Has("REST_ABSORBED_BY_LEAVE", e, from, to),
                        $"employee {e}, week {ws}: {rests} rests for a quota of {quota}, unreported");

                    // The planner adds a rest beyond the quota only when the hard cap demands it: take the
                    // week's planned rests away and some run would break the cap.
                    var planned = days.Where(d => _cells.TryGetValue(new EmpDay(e, d), out var c) && c.State == "rest" && c.Origin is "planned" or "ghost" && c.ReasonCode != "REST_PATTERN").ToList();
                    if (rests > quota && planned.Count > 0)
                        Assert.True(WouldBreakCapWithout(e, planned), $"employee {e}, week {ws}: {rests - quota} rest(s) over the quota without need");
                }
            }
        }

        /// <summary>Turn these rests into working days: would a run then exceed the cap?</summary>
        private bool WouldBreakCapWithout(int e, List<DateOnly> rests)
        {
            var cap = _in.Settings.MaxConsecutiveWorkDays;
            var run = 0;
            for (var d = _in.WindowFrom.AddDays(-31); d <= _in.HorizonTo; d = d.AddDays(1))
            {
                run = WorksOn(e, d) || rests.Contains(d) ? run + 1 : 0;
                if (run > cap)
                    return true;
            }
            return false;
        }

        private void StaffingOrReported()
        {
            if (_in.MonthLocked)
                return;
            foreach (var d in RosterCalendar.Days(_in.MonthStart, _in.MonthEnd).Where(d => d >= _in.Today))
            {
                var onDuty = _p.Cells.Count(c => c.WorkDate == d && c.State == "work" && _in.LeaveOn(c.EmployeeId, d) != LeaveKind.Full);
                Assert.Equal(onDuty, _p.PerDay.Single(x => x.Date == d).OnDuty);
                var (min, _) = _in.StaffingFor(d);
                if (min is { } m && onDuty < m)
                    Assert.True(Has("SHORT_STAFFED", null, d, d), $"{d}: {onDuty} on duty for a minimum of {m}, unreported");
            }
        }

        /// <summary>
        /// D16: every shift a day must cover has its minimum on it, or the preview names that shift as
        /// short that day (an open holiday's thin cover is the manager's choice and needs no report) —
        /// and a shift is never left short while someone the run decides (a planned or holiday-cover
        /// working day) sits on a shift that could spare them.
        /// </summary>
        private void ShiftsCoveredOrReported()
        {
            if (_in.MonthLocked)
                return;
            foreach (var d in RosterCalendar.Days(_in.MonthStart, _in.MonthEnd).Where(d => d >= _in.Today))
            {
                var rules = _in.CoverRulesFor(d).Where(r => r.MinOnDuty > 0).ToList();
                var working = _p.Cells.Where(c => c.WorkDate == d && c.State == "work" && _in.LeaveOn(c.EmployeeId, d) != LeaveKind.Full).ToList();
                int On(int shift) => working.Count(c => c.ShiftId == shift);
                bool Spares(int shift) => rules.FirstOrDefault(r => r.ShiftId == shift) is not { } rule || On(shift) > rule.MinOnDuty;

                var counted = _p.PerDay.Single(x => x.Date == d).Shifts.Where(s => s.Min > 0).Select(s => (s.ShiftId, s.OnDuty, s.Min));
                Assert.Equal(rules.Select(r => (r.ShiftId!.Value, On(r.ShiftId!.Value), r.MinOnDuty)), counted);

                var holiday = _in.Holidays.ContainsKey(d);
                foreach (var rule in rules)
                {
                    var shift = rule.ShiftId!.Value;
                    if (On(shift) >= rule.MinOnDuty)
                        continue;
                    var name = _in.Shifts[shift].Name;
                    Assert.True(
                        (holiday && On(shift) > 0)
                        || _p.Issues.Any(i => i.Date == d && i.Code is "SHIFT_UNCOVERED" or "SHORT_STAFFED" && i.Message.Contains(name)),
                        $"{d}: {On(shift)} on {name} for a minimum of {rule.MinOnDuty}, unreported");

                    var couldCover = working
                        .Where(c => c.Origin is "planned" or "holiday" && c.ShiftId is { } from && from != shift && Spares(from))
                        .Select(c => c.EmployeeId)
                        .ToList();
                    Assert.True(couldCover.Count == 0, $"{d}: {name} short while {string.Join(", ", couldCover)} could have covered it");
                }
            }
        }

        private void SummaryAndGhosts()
        {
            var month = _p.Cells.Where(c => _in.InMonth(c.WorkDate)).ToList();
            Assert.Equal(month.Count(c => c.Change == "insert"), _p.Summary.Inserts);
            Assert.Equal(month.Count(c => c.Change == "update"), _p.Summary.Updates);
            Assert.Equal(month.Count(c => c.Change == "delete"), _p.Summary.Deletes);
            Assert.Equal(month.Count(c => c.Change == "unchanged"), _p.Summary.Unchanged);
            Assert.Equal(month.Count(c => c.Change == "kept"), _p.Summary.Kept);
            Assert.All(_p.Cells.Where(c => !_in.InMonth(c.WorkDate)), c => Assert.Equal("kept", c.Change));
            Assert.All(_p.Cells.Where(c => c.Origin == "ghost"), c => Assert.False(_in.InMonth(c.WorkDate)));

            // The diff agrees with the expected state it will be checked against.
            foreach (var c in month.Where(Written))
            {
                var exists = c.Expected.Exists;
                var same = exists && (c.State == "rest" ? c.Expected.IsRestDay == true && c.Expected.ShiftId is null
                                    : c.State == "work" && c.Expected.IsRestDay == false && c.Expected.ShiftId == c.ShiftId);
                var expected = c.State == "none" ? (exists ? "delete" : "unchanged") : !exists ? "insert" : same ? "unchanged" : "update";
                Assert.Equal(expected, c.Change);
            }
        }
    }
}
