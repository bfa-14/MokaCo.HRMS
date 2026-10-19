using System.Globalization;
using System.Numerics;
using System.Text.Json;
using MokaCo.HRMS.Model.Attendance;

namespace MokaCo.HRMS.Services.Attendance.AutoRoster;

/// <summary>An employee's 6/5 anchor as this run uses it.</summary>
public sealed record ResolvedRhythm(int EmployeeId, DateOnly AnchorWeekStart, int AnchorWorkDays, bool IsNew)
{
    /// <summary>T(e,w): 6 or 5 for the week containing <paramref name="anyDayOfWeek"/>.</summary>
    public int WorkDaysIn(DateOnly anyDayOfWeek)
        => RosterCalendar.WorkDaysInWeek(RosterCalendar.WeekIndex(AnchorWeekStart), AnchorWorkDays, RosterCalendar.WeekIndex(anyDayOfWeek));
}

/// <summary>What <see cref="RosterPlanner.Plan"/> returns: the decided grid, the rhythms, the weekend balances and the API's preview.</summary>
public sealed class RosterPlan
{
    public required RosterGrid Grid { get; init; }
    public required IReadOnlyDictionary<int, ResolvedRhythm> Rhythms { get; init; }
    public required WeekendLedger Ledger { get; init; }
    public required AutoRosterPreview Preview { get; init; }
}

/// <summary>
/// The auto-roster planner (docs/AUTO_ROSTER.md §2): every employee alternates a 6-day week (one rest
/// day) and a 5-day week (two), the Saturdays and Sundays off go to whoever is most owed, and leave,
/// holidays, locks, pins and the manager's edits are facts it plans around.
///
/// PURE AND DETERMINISTIC, like AvailabilityMath: no database, no clock (today arrives in the input),
/// no randomness, every loop in EmployeeId/date order. The same input gives the same plan. It decides;
/// it never saves — the commit procedure re-checks everything the database owns.
///
/// §2.4 holidays first, then a backward pass over the window that works out, per person and week, the
/// longest run each week may leave at Sunday — from the rows after the window (the following month
/// may be saved already) back to the first week. Then a greedy week-by-week pass, oldest week first:
/// the feasible rest sets per person (hard cap on consecutive days, within that limit), the number of
/// rests per day (water-filled to keep on-duty level and above the minimum), weekend days by the
/// fair-share ledger, weekdays by a small cost, a staffing repair, and the ledger update. Last, every
/// working day gets its shift, and every shift the branch must cover (D16: morning and evening, say)
/// gets its people — rest days were already spread so each day has enough for all its shifts, and a
/// shift still short takes someone from a shift that can spare them. Anything it cannot satisfy is
/// left to <see cref="RosterPlanValidator"/> to report.
///
/// "Regenerate = 0 changes" (D11) is built in, not hoped for: in ReplanAuto a person's options are first
/// narrowed to those that keep the rests the generator saved, so a saved week that still fits stays as
/// it is whatever else moved — today passing, a leave or an edit elsewhere.
///
/// Refinements of §2, each explained where it is made: holiday cover passes over anyone it would push
/// past the hard cap; a week whose quota is met but whose working days would still break the cap gets
/// an extra rest (reported RHYTHM_OVER) before the cap is relaxed; rests a person can only take on one
/// day are seeded before the water-fill, and leftover slots start from a day that turns with the week
/// instead of always Monday; and a weekend day goes only to someone within one day of the most owed
/// competitor.
/// </summary>
public static class RosterPlanner
{
    public const string ReasonWeekendOwed = "REST_WEEKEND_OWED";
    public const string ReasonLevel = "REST_LEVEL";
    public const string ReasonPair = "REST_PAIR";
    public const string ReasonPattern = "REST_PATTERN";
    public const string ReasonConsecutive = "REST_CONSECUTIVE";
    public const string ReasonHolidayCover = "WORK_HOLIDAY_COVER";
    public const string ReasonHolidayOff = "HOLIDAY_OFF";
    public const string ReasonShiftCover = "WORK_SHIFT_COVER";

    private const int Saturday = 5;
    private const int Sunday = 6;

    /// <summary>Plans the input's month and builds the preview (cells, rhythm, counters, issues, summary).</summary>
    public static RosterPlan Plan(PlannerInput input)
    {
        ArgumentNullException.ThrowIfNull(input);

        var grid = Classify(input, includeDrafts: true);
        var rhythms = ResolveRhythms(input, grid);
        var run = new Run(input, grid, rhythms);
        run.PlanHolidays();
        run.PlanWeeks();
        run.AssignShifts();

        var issues = RosterPlanValidator.Validate(input, grid, rhythms);
        return new RosterPlan
        {
            Grid = grid,
            Rhythms = rhythms,
            Ledger = run.Ledger,
            Preview = BuildPreview(input, grid, rhythms, run.Ledger, issues),
        };
    }

    /// <summary>Shorthand for <c>Plan(input).Preview</c>.</summary>
    public static AutoRosterPreview Preview(PlannerInput input) => Plan(input).Preview;

    /* ==================================================================================
     * §2.1 classification
     * ================================================================================ */

    /// <summary>
    /// Every staff member × window day, classified (§2.1, first match wins). Facts keep their row;
    /// fixed cells (leave, draft, unavailable, holiday) get their state; plannable cells are left
    /// undecided (<see cref="GridCell.IsPlannable"/>). <paramref name="includeDrafts"/> = false gives
    /// the base classification the commit validator re-uses for a submitted grid.
    /// </summary>
    public static RosterGrid Classify(PlannerInput input, bool includeDrafts = true)
    {
        var days = RosterCalendar.Days(input.WindowFrom, input.WindowTo).ToList();
        var cells = new List<GridCell>(input.Staff.Count * days.Count);
        foreach (var employee in input.Staff)
            foreach (var day in days)
                cells.Add(ClassifyCell(input, employee, day, includeDrafts));
        return new RosterGrid(input.Staff, days, cells);
    }

    private static GridCell ClassifyCell(PlannerInput input, PlannerEmployee employee, DateOnly date, bool includeDrafts)
    {
        var e = employee.EmployeeId;
        var key = new EmpDay(e, date);
        var employed = input.BranchOfDay.TryGetValue(key, out var branch);
        var inBranch = employed && branch == input.BranchId;
        var current = input.RowOf(e, date);

        var cell = new GridCell
        {
            EmployeeId = e,
            Date = date,
            InMonth = input.InMonth(date),
            Employed = employed,
            InBranch = inBranch,
            Current = current,
            Leave = employed ? input.LeaveOn(e, date) : LeaveKind.None,
            IsHoliday = inBranch && input.Holidays.ContainsKey(date),
            Kind = CellKind.Fact,
            IsFact = true,
            State = GridCell.StateOf(current),
            ShiftId = current is { IsWork: true } r ? r.ShiftId : null,
        };

        if (!employed) { cell.Kind = CellKind.NotEmployed; return cell; }
        if (!inBranch) { cell.Kind = CellKind.OtherBranch; return cell; }
        if (!employee.OnRotation) { cell.Kind = CellKind.OffRotation; return cell; }

        if (cell.InMonth && (input.MonthLocked || date < input.Today || input.Locks.ContainsKey(key)))
        {
            cell.Kind = CellKind.Locked;
            return cell;
        }

        if (!cell.InMonth)
        {
            // A row outside the month is that month's business; no row before today is unknown.
            if (current is not null || date < input.Today)
            {
                cell.Kind = CellKind.Outside;
                return cell;
            }

            // A GHOST: planned so the straddling week works out, never saved. The next month's run
            // reads what this one saved and completes the week, in either generation order.
            cell.Kind = CellKind.Ghost;
            cell.IsFact = false;
            if (cell.IsHoliday)
                Decide(cell, CellState.None, ReasonHolidayOff);
            else if (cell.Leave != LeaveKind.None)
                Decide(cell, CellState.Work, null);
            else if (input.Settings.PatternRestDays == PatternRestRule.Unavailable && input.IsPatternRest(e, date))
                Decide(cell, CellState.Rest, ReasonPattern);
            else
                MakePlannable(cell);
            return cell;
        }

        input.Cells.TryGetValue(key, out var meta);
        if (current is not null && meta is { IsPinned: true })
        {
            cell.Kind = CellKind.Pinned;
            return cell;
        }

        DraftCell? draft = includeDrafts && input.DraftCells.TryGetValue(key, out var d) ? d : null;

        if (cell.Leave != LeaveKind.None)
        {
            // An existing row inside a leave is never changed: the leave was priced on it (D5).
            if (current is not null)
            {
                cell.Kind = CellKind.Leave;
                return cell;
            }

            // An empty leave day that is also a public holiday stays a holiday off: the leave cost
            // nothing for it, and a working row would make an unpaid holiday cost a day.
            if (cell.IsHoliday)
            {
                cell.Kind = CellKind.Holiday;
                cell.IsFact = false;
                Decide(cell, CellState.None, ReasonHolidayOff);
                return cell;
            }

            // An empty leave day gets a WORKING row, so the leave costs what it was priced at and
            // payroll's unpaid-leave deduction does not move. Never a rest day.
            cell.Kind = CellKind.Leave;
            cell.IsFact = false;
            Decide(cell, CellState.Work, null);
            cell.ShiftId = draft is { State: CellState.Work } ? draft.ShiftId : null;
            return cell;
        }

        var modeAllows = current is null || input.Mode switch
        {
            RosterMode.FillEmpty => false,
            RosterMode.ReplanAuto => meta?.Matches(current) == true,
            _ => true,
        };

        // The manager's draft edit wins — on a holiday too: it is how the manager chooses WHO covers.
        if (draft is not null)
        {
            cell.Kind = CellKind.Draft;
            cell.IsFact = false;
            Decide(cell, draft.State, null);
            cell.ShiftId = draft.State == CellState.Work ? draft.ShiftId : null;
            return cell;
        }

        if (cell.IsHoliday)
        {
            if (!modeAllows)
                return cell;   // a protected row on a holiday stays a fact (a rest one is reported)

            cell.Kind = CellKind.Holiday;
            cell.IsFact = false;
            cell.IsCoverCandidate = true;
            Decide(cell, CellState.None, ReasonHolidayOff);
            return cell;
        }

        if (!modeAllows)
            return cell;

        if (input.Settings.PatternRestDays == PatternRestRule.Unavailable && input.IsPatternRest(e, date))
        {
            cell.Kind = CellKind.Unavailable;
            cell.IsFact = false;
            Decide(cell, CellState.Rest, ReasonPattern);
            return cell;
        }

        cell.Kind = CellKind.Planned;
        cell.IsFact = false;
        MakePlannable(cell);
        return cell;
    }

    private static void Decide(GridCell cell, CellState state, string? reason)
    {
        cell.State = state;
        cell.ShiftId = null;
        cell.ReasonCode = reason;
        cell.ReasonArgs = null;
    }

    private static void MakePlannable(GridCell cell)
    {
        cell.IsPlannable = true;
        Decide(cell, CellState.None, null);
    }

    /* ==================================================================================
     * §2.2 rhythm
     * ================================================================================ */

    /// <summary>The anchors of the on-rotation staff (§2.2), with no plan around them — what the setup's "first week" column shows.</summary>
    public static IReadOnlyDictionary<int, ResolvedRhythm> ResolveRhythms(PlannerInput input)
        => ResolveRhythms(input, Classify(input, includeDrafts: false));

    /// <summary>
    /// Stored → as stored; overridden → the override; neither → anchored on the first window week the
    /// person is employed. Aligned starts on a 6-day week unless that week's facts already hold two rest
    /// rows; Staggered balances the 6- and 5-day first weeks of the whole branch (ties start on 6).
    /// </summary>
    public static IReadOnlyDictionary<int, ResolvedRhythm> ResolveRhythms(PlannerInput input, RosterGrid grid)
    {
        var result = new SortedDictionary<int, ResolvedRhythm>();
        var weeks = grid.WeekStarts;
        var firstWeek = weeks.Count > 0 ? weeks[0] : RosterCalendar.WeekStart(input.WindowFrom);
        var pending = new List<(PlannerEmployee Employee, DateOnly Anchor)>();
        int sixes = 0, fives = 0;

        foreach (var employee in input.Staff.Where(s => s.OnRotation))
        {
            var e = employee.EmployeeId;
            input.Rhythms.TryGetValue(e, out var stored);
            var storedRhythm = stored is null ? null : new ResolvedRhythm(e, stored.AnchorWeekStart, stored.AnchorWorkDays, false);

            ResolvedRhythm? resolved = storedRhythm;
            if (input.RhythmOverrides.TryGetValue(e, out var o))
            {
                var weekStart = RosterCalendar.WeekStart(o.WeekStart);
                resolved = storedRhythm is not null && storedRhythm.WorkDaysIn(weekStart) == o.WorkDays
                    ? storedRhythm
                    : new ResolvedRhythm(e, weekStart, o.WorkDays, true);
            }

            if (resolved is not null)
            {
                result[e] = resolved;
                if (resolved.WorkDaysIn(firstWeek) == 6) sixes++; else fives++;
                continue;
            }

            var anchor = weeks.FirstOrDefault(ws => Enumerable.Range(0, 7).Any(i => input.IsEmployed(e, ws.AddDays(i))), firstWeek);
            pending.Add((employee, anchor));
        }

        if (input.Settings.RhythmStart == RhythmStartRule.Aligned)
        {
            foreach (var (employee, anchor) in pending)
            {
                var e = employee.EmployeeId;
                var restFacts = Enumerable.Range(0, 7)
                    .Select(i => grid.TryGet(e, anchor.AddDays(i), out var c) ? c : null)
                    .Count(c => c is not null && c.IsFact && c.CountsAsRest);
                result[e] = new ResolvedRhythm(e, anchor, restFacts >= 2 ? 5 : 6, true);
            }
        }
        else
        {
            var firstIndex = RosterCalendar.WeekIndex(firstWeek);
            foreach (var (employee, anchor) in pending
                         .OrderBy(p => p.Employee.PositionId ?? int.MaxValue)
                         .ThenBy(p => p.Employee.HireDate ?? DateOnly.MaxValue)
                         .ThenBy(p => p.Employee.EmployeeId))
            {
                var typeInFirstWeek = sixes <= fives ? 6 : 5;
                if (typeInFirstWeek == 6) sixes++; else fives++;
                var anchorType = RosterCalendar.Mod(RosterCalendar.WeekIndex(anchor) - firstIndex, 2) == 0
                    ? typeInFirstWeek
                    : 11 - typeInFirstWeek;
                result[employee.EmployeeId] = new ResolvedRhythm(employee.EmployeeId, anchor, anchorType, true);
            }
        }

        return result;
    }

    /* ==================================================================================
     * The run: holidays, weeks, shifts
     * ================================================================================ */

    private sealed class Run
    {
        private readonly PlannerInput _in;
        private readonly RosterGrid _grid;
        private readonly IReadOnlyDictionary<int, ResolvedRhythm> _rhythms;
        private readonly List<int> _planned;
        private readonly Dictionary<int, int> _ordinal = new();
        private readonly IReadOnlyList<DateOnly> _weeks;
        private readonly int _cap;
        private readonly int _preferred;
        private readonly Dictionary<int, int> _holidaysWorked;
        private readonly Dictionary<int, int> _weekendStreak = new();
        private readonly Dictionary<(int Employee, int Week), WeekShape> _shapes = new();
        private readonly Dictionary<(int Mask, int Size), List<int>> _combinations = new();
        private readonly int? _fallbackShift;
        private readonly Dictionary<int, int?> _frequent = new();
        private readonly Dictionary<int, HashSet<int>> _known = new();
        private readonly Dictionary<int, int> _moves = new();
        private WeekCover? _cover;

        public WeekendLedger Ledger { get; }

        public Run(PlannerInput input, RosterGrid grid, IReadOnlyDictionary<int, ResolvedRhythm> rhythms)
        {
            _in = input;
            _grid = grid;
            _rhythms = rhythms;
            _planned = input.Staff.Where(s => s.OnRotation && rhythms.ContainsKey(s.EmployeeId)).Select(s => s.EmployeeId).ToList();
            for (var i = 0; i < _planned.Count; i++)
                _ordinal[_planned[i]] = i;
            _weeks = grid.WeekStarts;
            _cap = input.Settings.MaxConsecutiveWorkDays;
            _preferred = Math.Min(input.Settings.PreferredMaxConsecutiveWorkDays, _cap);
            _holidaysWorked = _planned.ToDictionary(e => e, e => input.HolidaysWorked.TryGetValue(e, out var n) ? n : 0);
            Ledger = WeekendLedger.FromHistory(input, _planned, _weekendStreak);
            var firstActive = input.Shifts.Values.Where(s => s.IsActive).OrderBy(s => s.ShiftId).Select(s => (int?)s.ShiftId).FirstOrDefault();
            _fallbackShift = input.IsActiveShift(input.DefaultShiftId) ? input.DefaultShiftId : firstActive;
        }

        /* ---- §2.4 holidays first ---- */

        public void PlanHolidays()
        {
            foreach (var h in _in.Holidays.Keys.Where(_in.InMonth).Order())
            {
                if (h < _in.WindowFrom || h > _in.WindowTo)
                    continue;

                var onDay = _grid.CellsOn(h).ToList();
                var candidates = onDay.Where(c => c.IsCoverCandidate).Select(c => c.EmployeeId).ToList();
                if (candidates.Count == 0)
                    continue;

                // Working facts (and the manager's draft work) on the holiday already cover it.
                var covered = onDay.Count(c => c.InBranch && !c.IsCoverCandidate && c.State == CellState.Work && c.Leave == LeaveKind.None);
                var wanted = _in.HolidayCover.TryGetValue(h, out var n) ? n : 0;
                var remaining = Math.Max(0, wanted - covered);

                // Cover is a fixed working day, so whoever is chosen must be able to work it within the hard
                // cap: someone whose fixed working days around the holiday (pinned, recorded, leave rows,
                // earlier covers — the weeks are not planned yet) already reach the cap with it is asked
                // LAST, whatever their holiday count. Only when nobody else is left is that person chosen,
                // and the preview then carries the CONSECUTIVE_CAP error: the manager lowers the cover or
                // moves a fixed day — the planner cannot.
                var offset = RosterCalendar.Mod(RosterCalendar.WeekIndex(h), candidates.Count);
                var chosen = candidates
                    .Select((e, i) => (
                        Employee: e,
                        Rotation: RosterCalendar.Mod(i - offset, candidates.Count),
                        PastCap: RunBefore(e, h) + 1 + RunAfter(e, h) > _cap))
                    .OrderBy(x => x.PastCap ? 1 : 0)
                    .ThenBy(x => _holidaysWorked.TryGetValue(x.Employee, out var w) ? w : 0)
                    .ThenBy(x => x.Rotation)
                    .Take(remaining)
                    .Select(x => x.Employee)
                    .ToHashSet();

                var name = _in.Holidays[h].Name;
                foreach (var cell in onDay.Where(c => c.IsCoverCandidate))
                {
                    cell.IsCoverCandidate = false;
                    if (chosen.Contains(cell.EmployeeId))
                    {
                        var worked = _holidaysWorked.TryGetValue(cell.EmployeeId, out var w) ? w : 0;
                        cell.State = CellState.Work;
                        cell.ReasonCode = ReasonHolidayCover;
                        cell.ReasonArgs = Args(("holiday", name), ("worked", worked));
                        _holidaysWorked[cell.EmployeeId] = worked + 1;
                    }
                    else
                    {
                        cell.State = CellState.None;
                        cell.ReasonCode = ReasonHolidayOff;
                        cell.ReasonArgs = Args(("holiday", name));
                    }
                }
            }
        }

        /* ---- §2.3 quotas, and each week's shape, computed for every week before any is planned ---- */

        /// <summary>One person's week as the planning passes read it. Only its plannable days change while weeks are planned.</summary>
        private sealed class WeekShape
        {
            public int WorkDays;
            public int Need;                                // need(e,w), already capped at |P|
            public int PMask;                               // the plannable days (P)
            public int FixedRestMask;
            public int RowMask;                             // plannable days whose row is still what the generator wrote
            public int RestRows;                            // … and of those, the rests
            public readonly int[] Kinds = new int[7];       // 0 breaks a run · 1 fixed work · 2 plannable
            public readonly GridCell[] Cells = new GridCell[7];
            public int AllowedOut;                          // the longest run the week may leave at Sunday (hard)
            public int KeepOut;                             // … and still keep the later weeks' saved rests (stability)
        }

        private void ComputeShapes()
        {
            foreach (var e in _planned)
            {
                for (var k = 0; k < _weeks.Count; k++)
                {
                    var ws = _weeks[k];
                    var s = new WeekShape { WorkDays = _rhythms[e].WorkDaysIn(ws) };
                    int employed = 0, holidaysOff = 0, fixedRests = 0;
                    for (var i = 0; i < 7; i++)
                    {
                        var c = _grid[e, ws.AddDays(i)];
                        s.Cells[i] = c;
                        if (c.IsPlannable)
                        {
                            s.Kinds[i] = 2;
                            s.PMask |= 1 << i;
                            switch (AutoStateOf(c))
                            {
                                case CellState.Rest: s.RowMask |= 1 << i; s.RestRows |= 1 << i; break;
                                case CellState.Work: s.RowMask |= 1 << i; break;
                            }
                        }
                        else if (c.CountsAsWorkForRun)
                        {
                            s.Kinds[i] = 1;
                        }
                        else if (c.CountsAsRest)
                        {
                            s.FixedRestMask |= 1 << i;
                        }

                        if (!c.Employed)
                            continue;
                        employed++;
                        if (c.IsPlannable)
                            continue;
                        if (c.InBranch && c.IsHoliday && c.State == CellState.None)
                            holidaysOff++;
                        if (c.CountsAsRest)
                            fixedRests++;
                    }

                    var quota = Math.Max(0, employed - s.WorkDays - (_in.Settings.HolidayCountsAsRest ? holidaysOff : 0));
                    s.Need = Math.Min(Math.Max(0, quota - fixedRests), BitOperations.PopCount((uint)s.PMask));
                    _shapes[(e, k)] = s;
                }
            }
        }

        /// <summary>
        /// The look-ahead, computed BACKWARD from the end of the window before any week is planned. For each
        /// person and week: the longest run the week may leave at Sunday so that the weeks after it can
        /// still be planned as well as if they started fresh (the same rests, no more days past the cap).
        /// The last week reads the rows after the window — the following month may be saved already — and
        /// every earlier week reads the week after it, which itself already accounts for the one after
        /// that. One week ahead was not enough: a pinned weekend off two weeks on can force the next
        /// week's rest late, and the week planned today must then end early, or the next one needs a
        /// rest beyond its quota.
        ///
        /// The same pass gives the STABILITY look-ahead (<see cref="WeekShape.KeepOut"/>): the longest run
        /// the week may leave and still let the later weeks keep the rests the generator saved there. It
        /// only ever chooses between options that are equally good otherwise (a ghost day, a re-planned
        /// day), so it never costs a rest or a day past the cap.
        /// </summary>
        private void ComputeLookAhead()
        {
            foreach (var e in _planned)
            {
                var allowed = Math.Max(0, _cap - RunAfter(e, _in.WindowTo));
                var keep = allowed;
                for (var k = _weeks.Count - 1; k >= 0; k--)
                {
                    var s = _shapes[(e, k)];
                    s.AllowedOut = allowed;
                    s.KeepOut = keep;

                    // How long a run this week can take in and still be planned as well as from a rest:
                    // the same number of rests and days past the cap, then the same stability.
                    var fresh = Score(s, 0);
                    int maxIn = 0, keepIn = 0;
                    for (var carry = 1; carry <= _cap; carry++)
                    {
                        var score = Score(s, carry);
                        if (score.Excess != fresh.Excess || score.Count != fresh.Count)
                            break;
                        maxIn = carry;
                        if (keepIn == carry - 1 && score.Dist == fresh.Dist && score.Breaks == fresh.Breaks)
                            keepIn = carry;
                    }
                    allowed = maxIn;
                    keep = keepIn;
                }
            }
        }

        /* ---- §2.5 week by week ---- */

        public void PlanWeeks()
        {
            ComputeShapes();
            ComputeLookAhead();
            for (var k = 0; k < _weeks.Count; k++)
            {
                var ws = _weeks[k];

                // Nobody to choose for: the plannable days of a zero-need week are working days —
                // unless working them all would break the hard cap (BuildPerson then asks for a rest).
                var weekIndex = RosterCalendar.WeekIndex(ws);
                var withNeed = new List<int>();
                foreach (var e in _planned)
                {
                    var s = _shapes[(e, k)];
                    if (s.PMask == 0)
                        continue;
                    if (s.Need > 0 || BuildPerson(e, k, weekIndex).Need > 0)
                    {
                        withNeed.Add(e);
                        continue;
                    }
                    for (var i = 0; i < 7; i++)
                        if ((s.PMask >> i & 1) == 1)
                            SetPlanned(s.Cells[i], rest: false, null, null);
                }

                if (withNeed.Count > 0)
                    foreach (var p in SolveWeek(k, withNeed))
                        Apply(p);

                AddWeekToLedger(ws);
            }
        }

        private sealed class PersonWeek
        {
            public required WeekShape Shape;
            public int EmployeeId;
            public int Rotation;
            public int Carried;
            public int Need;                            // the rests to place: need(e,w), or more when the cap demands them
            public List<int> Pool = [];                 // the rest sets the hard cap allows (or the least-bad, when none does)
            public List<int> Options = [];              // Pool narrowed to the most stable, then by what has been chosen so far
            public bool CapLimited;
            public bool ExtraRest;                      // more rests than the quota: the hard cap demanded them
            public int Chosen;
            public readonly string?[] Reason = new string?[7];
            public readonly string?[] Args = new string?[7];
            public int Remaining => Need - BitOperations.PopCount((uint)Chosen);
            public int PMask => Shape.PMask;
            public int WorkDays => Shape.WorkDays;
            public int FixedRestMask => Shape.FixedRestMask;
            public GridCell[] Cells => Shape.Cells;
            public int[] Kinds => Shape.Kinds;

            /// <summary>Some plannable day still holds what the generator saved: the options were narrowed to keep it.</summary>
            public bool HasRows => Shape.RowMask != 0;
        }

        private List<PersonWeek> SolveWeek(int k, List<int> employees)
        {
            var ws = _weeks[k];
            var weekIndex = RosterCalendar.WeekIndex(ws);
            var persons = employees.Select(e => BuildPerson(e, k, weekIndex)).ToList();
            var pMaskOf = persons.ToDictionary(p => p.EmployeeId, p => p.PMask);

            // onDuty(d): staff who would work d if no more rests were placed.
            // D16: a day must also hold enough people for every shift it has to cover, so its minimum is
            // at least the sum of theirs (and its target the sum of their targets, when any is set) —
            // the slots, the weekday cost and the repair below then keep that many on duty. By shift,
            // _cover counts who would be on each one from where each person starts (§2.6): a rest that
            // would empty a shift costs more than one that leaves it covered, so few people need moving.
            var onDuty = new int[7];
            var min = new int?[7];
            var target = new int?[7];
            _cover = new WeekCover();
            for (var i = 0; i < 7; i++)
            {
                var date = ws.AddDays(i);
                var rules = _in.ShiftRulesFor(date).ToList();
                foreach (var rule in rules)
                    _cover.Min[(i, rule.ShiftId!.Value)] = rule.MinOnDuty;

                foreach (var c in _grid.CellsOn(date))
                {
                    if (!c.InBranch || !c.Employed)
                        continue;
                    int? shift = null;
                    if (pMaskOf.TryGetValue(c.EmployeeId, out var mask) && (mask >> i & 1) == 1)
                    {
                        onDuty[i]++;
                        shift = StartShift(c);
                        _cover.StartOf[(c.EmployeeId, i)] = shift;
                    }
                    else if (c.CountsAsWorkForRun)
                    {
                        onDuty[i]++;
                        shift = c.ShiftId ?? StartShift(c);
                    }
                    if (shift is { } on && _cover.Min.ContainsKey((i, on)))
                        _cover.Duty[(i, on)] = _cover.Duty.GetValueOrDefault((i, on)) + 1;
                }

                (min[i], target[i]) = _in.StaffingFor(date);
                var coverMin = rules.Sum(r => r.MinOnDuty);
                if (coverMin > 0)
                    min[i] = Math.Max(min[i] ?? 0, coverMin);
                if (rules.Any(r => r.TargetOnDuty is not null))
                    target[i] = Math.Max(target[i] ?? 0, rules.Sum(r => r.TargetOnDuty ?? r.MinOnDuty));
            }

            // Step 2 — slots. A day every remaining option of a person holds (the cap leaves no other, or
            // the rest is kept where the generator saved it) is that person's already: it is seeded first,
            // so the water-fill shares out only the rests still free to go anywhere — around the kept ones.
            // The free ones are water-filled over the days where somebody with need can rest. Ties go to
            // the day with fewer slots, then in calendar order STARTING FROM A DAY THAT TURNS WITH THE
            // WEEK. A fixed Monday-first order would hand every leftover slot to Monday–Friday: five
            // people in a week needing five rests would never have a Saturday or Sunday to share, week
            // after week.
            var slots = new int[7];
            var seeded = new int[7];
            var canRest = new int[7];
            var total = 0;
            foreach (var p in persons)
            {
                var forced = p.Options.Count == 0 ? 0 : p.Options.Aggregate(~0, (acc, o) => acc & o);
                total += Math.Max(0, p.Need - BitOperations.PopCount((uint)forced));
                for (var i = 0; i < 7; i++)
                {
                    if ((forced >> i & 1) == 1)
                        seeded[i]++;
                    else if (p.Options.Any(o => (o >> i & 1) == 1))
                        canRest[i]++;
                }
            }
            Array.Copy(seeded, slots, 7);

            var firstDay = RosterCalendar.Mod(weekIndex, 7);
            for (var n = 0; n < total; n++)
            {
                var best = -1;
                for (var step = 0; step < 7; step++)
                {
                    var i = (firstDay + step) % 7;
                    if (canRest[i] <= slots[i] - seeded[i])
                        continue;
                    if (best < 0)
                    {
                        best = i;
                        continue;
                    }
                    var key = onDuty[i] - slots[i] - (min[i] ?? 0);
                    var bestKey = onDuty[best] - slots[best] - (min[best] ?? 0);
                    if (key > bestKey || (key == bestKey && slots[i] < slots[best]))
                        best = i;
                }
                if (best < 0)
                    break;
                slots[best]++;
            }

            var placed = new int[7];
            var weekendOrder = RosterCalendar.Mod(weekIndex, 2) == 0 ? new[] { Saturday, Sunday } : new[] { Sunday, Saturday };

            // Step 3 — forced: every remaining option holds this weekend day.
            foreach (var p in persons)
                foreach (var x in weekendOrder)
                    if (p.Remaining > 0 && (p.Chosen >> x & 1) == 0 && p.Options.Count > 0 && p.Options.All(o => (o >> x & 1) == 1))
                        Choose(p, x, p.CapLimited ? ReasonConsecutive : ReasonLevel, null, placed);

            // Step 4 — weekend days by the fair-share ledger.
            foreach (var x in weekendOrder)
            {
                var date = ws.AddDays(x);
                var kind = date.DayOfWeek;
                var free = slots[x] - placed[x];

                // "Up to" slots(x): a weekend day goes only to someone within one day of the most owed
                // competitor — anyone with a rest still to place who could take this day, INCLUDING
                // those the hard cap keeps from it this week. Handing it further down the queue is what
                // spreads weekends unevenly: that person would end two days ahead of the one the cap
                // held back. An unused slot's rest goes to a weekday instead. Someone whose saved rests
                // are being kept elsewhere is not competing: stability, not the cap, keeps them off it.
                var competitors = persons
                    .Where(p => p.Remaining > 0 && (p.Chosen >> x & 1) == 0 && (p.PMask >> x & 1) == 1)
                    .Where(p => !p.HasRows || p.Options.Any(o => (o >> x & 1) == 1))
                    .ToList();
                var mostOwed = competitors.Count == 0 ? 0 : competitors.Max(p => WeekendLedger.Key(Ledger.Owed(p.EmployeeId, kind)));
                var eligible = competitors
                    .Where(p => p.Options.Any(o => (o >> x & 1) == 1))
                    .Where(p => WeekendLedger.Key(Ledger.Owed(p.EmployeeId, kind)) > mostOwed - 1 + 1e-6)
                    .OrderByDescending(p => WeekendLedger.Key(Ledger.Owed(p.EmployeeId, kind)))
                    .ThenByDescending(p => WeekendLedger.Key(Ledger.OwedTotal(p.EmployeeId)))
                    .ThenByDescending(p => _weekendStreak.TryGetValue(p.EmployeeId, out var s) ? s : 0)
                    .ThenBy(p => p.Rotation)
                    .ThenBy(p => p.EmployeeId)
                    .ToList();

                foreach (var p in eligible.Take(Math.Max(0, free)))
                {
                    var owed = Math.Round(Ledger.Owed(p.EmployeeId, kind), 2);
                    Choose(p, x, ReasonWeekendOwed, RosterPlanner.Args(("owed", owed)), placed);
                }

                // Not picked: drop the options holding this day, unless none would be left (then it is forced).
                foreach (var p in persons.Where(p => p.Remaining > 0 && (p.Chosen >> x & 1) == 0))
                {
                    var keep = p.Options.Where(o => (o >> x & 1) == 0).ToList();
                    if (keep.Count > 0)
                        p.Options = keep;
                    else if (p.Options.Count > 0)
                        Choose(p, x, p.CapLimited ? ReasonConsecutive : ReasonLevel, null, placed);
                }
            }

            // Step 5 — weekdays: most constrained first, cheapest option.
            foreach (var p in persons.Where(p => p.Remaining > 0)
                         .OrderBy(p => p.Options.Count).ThenBy(p => p.Rotation).ThenBy(p => p.EmployeeId).ToList())
            {
                if (p.Options.Count == 0)
                    continue;

                var best = p.Options[0];
                var bestCost = double.MaxValue;
                foreach (var o in p.Options)
                {
                    var cost = Cost(p, o, placed, slots, onDuty, min, target);
                    if (cost < bestCost - 1e-9)
                    {
                        best = o;
                        bestCost = cost;
                    }
                }

                var add = best & ~p.Chosen;
                for (var i = 0; i < 7; i++)
                    if ((add >> i & 1) == 1)
                        Choose(p, i, WeekdayReason(p, i, best), null, placed);
            }

            // Step 6 — repair: a day below its minimum takes back one rest that can move to a day that stays at or above its own.
            Repair(persons, onDuty, min, placed);
            return persons;
        }

        /// <summary>
        /// One person's week, ready to choose from. Step 1 — the pool: every rest set of the needed size
        /// that keeps every run within the hard cap, counting the run carried in and the longest run the
        /// later weeks can take at Sunday (<see cref="ComputeLookAhead"/>).
        ///
        /// When none does although the quota is already met (fixed rests, a partial week after a hire, a
        /// transfer or before a termination), one more rest day is tried, then another: the cap is the
        /// hard rule (CONSECUTIVE_CAP is an error) and a week over its quota is only reported
        /// (RHYTHM_OVER, info) — so the planner does the one thing the manager would have to do by hand
        /// instead of handing back a plan that cannot be saved. When even that cannot keep the cap (the
        /// facts already break it), the cap is relaxed for this person and week: the fewest days past it,
        /// then the fewest extra rests — planned days never lengthen a breach the facts started. The
        /// validator reports what is left.
        ///
        /// Then STABILITY (D11, "regenerate = 0 changes"): of the pool, only the options that move the
        /// fewest of the rests and working days the generator saved on these days are kept, and of those
        /// the ones that let the later weeks keep theirs. A saved week that still fits — the quota, the
        /// cap, its place in the run — therefore stays exactly as saved whatever else moved: today passing
        /// (days before it become facts), an edit or a leave in another week, another person's change. A
        /// week that no longer fits changes as few days as it can, and the rest of the week is chosen as
        /// usual around them. Only ReplanAuto does this (<see cref="AutoStateOf"/>); rows written by hand
        /// are never held on to.
        /// </summary>
        private PersonWeek BuildPerson(int e, int k, int weekIndex)
        {
            var s = _shapes[(e, k)];
            var carried = RunBefore(e, _weeks[k]);
            var best = Best(s, carried);
            var p = new PersonWeek
            {
                Shape = s,
                EmployeeId = e,
                Rotation = RosterCalendar.Mod(_ordinal[e] + weekIndex, Math.Max(1, _planned.Count)),
                Carried = carried,
                Need = best.Count,
                Pool = best.Pool,
            };
            p.ExtraRest = p.Need > s.Need;
            p.CapLimited = p.ExtraRest || best.Excess > 0 || p.Pool.Count < best.Combinations;

            var ranked = p.Pool.Select(o => (Option: o, Rank: (Dist(s, o), Breaks(s, carried, o)))).ToList();
            var top = ranked.Min(r => r.Rank);
            p.Options = ranked.Where(r => r.Rank == top).Select(r => r.Option).ToList();
            return p;
        }

        /// <summary>
        /// The pool for a week and a carried-in run: the rest sets of the smallest size from need(e,w) up
        /// with the fewest days past the hard cap (none, when the week can be planned within it).
        /// </summary>
        private (int Excess, int Count, List<int> Pool, int Combinations) Best(WeekShape s, int carried)
        {
            var size = BitOperations.PopCount((uint)s.PMask);
            var best = (Excess: int.MaxValue, Count: s.Need, Pool: new List<int>(), Combinations: 0);
            for (var count = s.Need; count <= size; count++)
            {
                var options = Combinations(s.PMask, count);
                var excess = options.Select(o => Runs(s, carried, o).OverCap).ToList();
                var least = excess.Min();
                if (least < best.Excess)
                    best = (least, count, options.Where((_, i) => excess[i] == least).ToList(), options.Count);
                if (least == 0)
                    break;
            }
            return best;
        }

        /// <summary>A week's best achievable outcome for a carried-in run: days past the cap, rests, then stability.</summary>
        private (int Excess, int Count, int Dist, int Breaks) Score(WeekShape s, int carried)
        {
            var best = Best(s, carried);
            var (dist, breaks) = best.Pool.Select(o => (Dist(s, o), Breaks(s, carried, o))).Min();
            return (best.Excess, best.Count, dist, breaks);
        }

        /// <summary>How many of the generator's saved days a rest set changes (a rest made work, or work made rest).</summary>
        private static int Dist(WeekShape s, int restMask) => BitOperations.PopCount((uint)((restMask ^ s.RestRows) & s.RowMask));

        /// <summary>1 when the run this rest set leaves at Sunday would make a later week give up its saved rests.</summary>
        private int Breaks(WeekShape s, int carried, int restMask) => Runs(s, carried, restMask).EndRun > s.KeepOut ? 1 : 0;

        private List<int> Combinations(int mask, int size)
        {
            if (!_combinations.TryGetValue((mask, size), out var list))
                _combinations[(mask, size)] = list = RosterPlanner.Combinations(mask, size);
            return list;
        }

        private void Choose(PersonWeek p, int day, string? reason, string? args, int[] placed)
        {
            if ((p.Chosen >> day & 1) == 1)
                return;
            p.Chosen |= 1 << day;
            p.Reason[day] = reason;
            p.Args[day] = args;
            placed[day]++;
            if (_cover is { } cover && cover.StartOf.TryGetValue((p.EmployeeId, day), out var start) && start is { } shift)
                cover.Placed[(day, shift)] = cover.Placed.GetValueOrDefault((day, shift)) + 1;
            p.Options = p.Options.Where(o => (o & p.Chosen) == p.Chosen).ToList();
        }

        private string WeekdayReason(PersonWeek p, int day, int option)
        {
            if (p.ExtraRest || (p.CapLimited && p.Pool.All(o => (o >> day & 1) == 1)))
                return ReasonConsecutive;
            if (_in.Settings.PatternRestDays == PatternRestRule.Preference && _in.IsPatternRest(p.EmployeeId, p.Cells[day].Date))
                return ReasonPattern;
            if (p.WorkDays == 5 && _in.Settings.PairRestDays)
            {
                var rests = p.FixedRestMask | option;
                if ((day > 0 && (rests >> (day - 1) & 1) == 1) || (day < 6 && (rests >> (day + 1) & 1) == 1))
                    return ReasonPair;
            }
            return ReasonLevel;
        }

        /// <summary>
        /// The weekday cost (§2.5 step 5). Weights, largest first: 100 per person a day would be below
        /// its minimum, 15 per day a run goes past the preferred maximum, 12 per person the shift the
        /// person starts on would be below its minimum (D16: it would take a move to cover it), 10 for a
        /// rest above the day's slot count; bonuses 5 for a 5-day week's adjacent pair and 3 for a pattern rest day; and
        /// small nudges toward the day with the most spare staff and a short run left at Sunday. Keeping
        /// the generator's saved rests is not a bonus here: <see cref="BuildPerson"/> already narrowed
        /// the options to them, which no weight could guarantee.
        /// </summary>
        private double Cost(PersonWeek p, int option, int[] placed, int[] slots, int[] onDuty, int?[] min, int?[] target)
        {
            double cost = 0;
            var add = option & ~p.Chosen;
            var tmp = (int[])placed.Clone();
            for (var i = 0; i < 7; i++)
            {
                if ((add >> i & 1) == 0)
                    continue;

                if (tmp[i] >= slots[i])
                    cost += 10;
                var after = onDuty[i] - tmp[i] - 1;
                if (min[i] is { } m && after < m)
                    cost += 100 * (m - after);   // deeper below the minimum costs more: spread a shortage, never pile it up
                cost -= 0.01 * (after - (target[i] ?? min[i] ?? 0));
                tmp[i]++;

                var cell = p.Cells[i];
                if (_in.Settings.PatternRestDays == PatternRestRule.Preference && _in.IsPatternRest(p.EmployeeId, cell.Date))
                    cost -= 3;

                // D16: resting here would leave the shift this person starts on short of its minimum.
                if (_cover is { } cover && cover.StartOf.TryGetValue((p.EmployeeId, i), out var start) && start is { } shift
                    && cover.Min.TryGetValue((i, shift), out var shiftMin) && shiftMin > 0)
                {
                    var left = cover.Duty.GetValueOrDefault((i, shift)) - cover.Placed.GetValueOrDefault((i, shift)) - 1;
                    if (left < shiftMin)
                        cost += 12 * (shiftMin - left);
                }
            }

            if (p.WorkDays == 5 && _in.Settings.PairRestDays)
            {
                var rests = p.FixedRestMask | option;
                for (var i = 0; i < 6; i++)
                {
                    var pair = (1 << i) | (1 << (i + 1));
                    if ((rests & pair) == pair && (add & pair) != 0)
                    {
                        cost -= 5;
                        break;
                    }
                }
            }

            var (_, overPreferred, endRun) = Runs(p.Shape, p.Carried, option);
            cost += 15 * overPreferred + 0.5 * Math.Max(0, endRun - 4);
            return cost;
        }

        /// <summary>
        /// For a rest set: the working days past the hard cap, the days past the preferred maximum and
        /// the run left at Sunday. Days past the cap include the ones the later weeks will have to work
        /// past it: each day the run left at Sunday is longer than <see cref="WeekShape.AllowedOut"/>
        /// (unless that day is past the cap already within this week).
        /// </summary>
        private (int OverCap, int OverPreferred, int EndRun) Runs(WeekShape s, int carried, int restMask)
        {
            int run = carried, overCap = 0, overPreferred = 0;
            for (var i = 0; i < 7; i++)
            {
                var work = s.Kinds[i] == 1 || (s.Kinds[i] == 2 && (restMask >> i & 1) == 0);
                run = work ? run + 1 : 0;
                if (!work)
                    continue;
                if (run > _cap)
                    overCap++;
                if (run > _preferred)
                    overPreferred++;
            }

            overCap += Math.Max(0, run - s.AllowedOut - Math.Max(0, run - _cap));
            return (overCap, overPreferred, run);
        }

        private void Repair(List<PersonWeek> persons, int[] onDuty, int?[] min, int[] placed)
        {
            var duty = new int[7];
            for (var i = 0; i < 7; i++)
                duty[i] = onDuty[i] - placed[i];

            // Only the target month's days: a ghost day is the next month's to decide and no run saves it,
            // so a repair that read it — a rest moved onto it, or a ghost day "below its minimum" — would
            // move a saved rest somewhere else at every regenerate.
            var inMonth = new bool[7];
            for (var i = 0; i < 7; i++)
                inMonth[i] = persons.Count > 0 && _in.InMonth(persons[0].Cells[i].Date);

            for (var guard = 0; guard < 7 * Math.Max(1, persons.Count); guard++)
            {
                var moved = false;
                for (var i = 0; i < 7 && !moved; i++)
                {
                    if (!inMonth[i] || min[i] is not { } m || duty[i] >= m)
                        continue;

                    // A rest the generator saved on this very day is moved last: a re-planned rest moves first.
                    foreach (var p in persons.Where(p => (p.Chosen >> i & 1) == 1)
                                 .OrderBy(p => (p.Shape.RestRows >> i & 1) == 1 ? 1 : 0)
                                 .ThenBy(p => p.Rotation).ThenBy(p => p.EmployeeId))
                    {
                        var targets = Enumerable.Range(0, 7)
                            .Where(j => j != i && inMonth[j] && (p.Chosen >> j & 1) == 0 && duty[j] - 1 >= (min[j] ?? 0))
                            .OrderBy(j => j >= Saturday ? 1 : 0)
                            .ThenByDescending(j => duty[j] - (min[j] ?? 0))
                            .ThenBy(j => j);
                        foreach (var j in targets)
                        {
                            var moveTo = (p.Chosen & ~(1 << i)) | (1 << j);
                            if (!p.Pool.Contains(moveTo))
                                continue;
                            p.Chosen = moveTo;
                            p.Reason[j] = ReasonLevel;
                            p.Args[j] = null;
                            p.Reason[i] = null;
                            p.Args[i] = null;
                            duty[i]++;
                            duty[j]--;
                            moved = true;
                            break;
                        }
                        if (moved)
                            break;
                    }
                }
                if (!moved)
                    break;
            }
        }

        private void Apply(PersonWeek p)
        {
            for (var i = 0; i < 7; i++)
            {
                if (p.Kinds[i] != 2)
                    continue;
                var rest = (p.Chosen >> i & 1) == 1;
                string? reason = null, args = null;
                if (rest)
                {
                    reason = p.Reason[i] ?? ReasonLevel;
                    args = p.Args[i];

                    // A rest kept where the generator saved it keeps the reason it was given then: re-planning
                    // a week where nothing had to move should not explain it differently.
                    var cell = p.Cells[i];
                    if ((p.Shape.RestRows >> i & 1) == 1
                        && _in.Cells.TryGetValue(new EmpDay(cell.EmployeeId, cell.Date), out var meta)
                        && meta.ReasonCode is { Length: > 0 } stored && stored != reason)
                    {
                        reason = stored;
                        args = stored == ReasonWeekendOwed && RosterCalendar.IsWeekend(cell.Date)
                            ? RosterPlanner.Args(("owed", Math.Round(Ledger.Owed(p.EmployeeId, cell.Date.DayOfWeek), 2)))
                            : null;
                    }
                }
                SetPlanned(p.Cells[i], rest, reason, args);
            }
        }

        private static void SetPlanned(GridCell cell, bool rest, string? reason, string? args)
        {
            cell.State = rest ? CellState.Rest : CellState.Work;
            cell.ShiftId = null;
            cell.ReasonCode = reason;
            cell.ReasonArgs = args;
        }

        /// <summary>
        /// What the generator saved on a plannable day that still holds it (ROSTER_CELL's AutoState
        /// matches the row): Rest or Work; null for an empty day, a ghost or a row written by hand.
        /// Only ReplanAuto holds on to it. ReplanAll is the manager's "plan it again from scratch" (the
        /// drawer asks first): after a settings change, or to re-balance, it must be free to move every
        /// rest — and with nothing changed it still gives the same plan, being a function of the facts.
        /// </summary>
        private CellState? AutoStateOf(GridCell cell)
        {
            if (_in.Mode != RosterMode.ReplanAuto || cell.Current is null
                || !_in.Cells.TryGetValue(new EmpDay(cell.EmployeeId, cell.Date), out var meta) || !meta.Matches(cell.Current))
                return null;
            return meta.AutoState switch
            {
                "rest" => CellState.Rest,
                "work" => CellState.Work,
                _ => null,
            };
        }

        /// <summary>Working days in a row ending the day before <paramref name="date"/> — decided window days, then history rows.</summary>
        private int RunBefore(int e, DateOnly date)
        {
            var run = 0;
            for (var d = date.AddDays(-1); run < 62; d = d.AddDays(-1))
            {
                var work = d >= _in.WindowFrom ? _grid[e, d].CountsAsWorkForRun : _in.WorksOutsideWindow(e, d);
                if (!work)
                    break;
                run++;
            }
            return run;
        }

        /// <summary>
        /// Working days in a row starting the day after <paramref name="date"/>: decided window days (a day
        /// not planned yet breaks it), then the rows after the window — the following month's, when it was
        /// saved first. Counted to one past the cap, which is all any caller needs.
        /// </summary>
        private int RunAfter(int e, DateOnly date)
        {
            var run = 0;
            for (var d = date.AddDays(1); run <= _cap; d = d.AddDays(1))
            {
                var work = d <= _in.WindowTo
                    ? _grid[e, d].CountsAsWorkForRun
                    : d <= _in.HorizonTo && _in.WorksOutsideWindow(e, d);
                if (!work)
                    break;
                run++;
            }
            return run;
        }

        /* ---- §2.5 step 7 and the history: the weekend ledger ---- */

        private void AddWeekToLedger(DateOnly ws)
        {
            var inPool = new HashSet<int>();
            var rested = new HashSet<int>();
            foreach (var x in new[] { Saturday, Sunday })
            {
                var date = ws.AddDays(x);
                var pool = new List<int>();
                var restedToday = new List<int>();
                foreach (var e in _planned)
                {
                    var c = _grid[e, date];
                    if (!c.InBranch || !c.Employed || c.Leave == LeaveKind.Full)
                        continue;
                    if (c.State is not (CellState.Work or CellState.Rest))
                        continue;
                    pool.Add(e);
                    inPool.Add(e);
                    if (c.State == CellState.Rest)
                    {
                        restedToday.Add(e);
                        rested.Add(e);
                    }
                }
                Ledger.AddDay(date, pool, restedToday);
            }
            WeekendLedger.UpdateStreaks(_weekendStreak, _planned, inPool, rested);
        }

        /* ---- §2.6 shifts, and D16: every shift to cover gets its people ---- */

        /// <summary>
        /// Who would be on each shift to cover, per day of the week being planned, counted from where each
        /// person starts (<see cref="StartShift"/>) — what the weekday cost reads so that a rest which would
        /// empty a shift costs more than one which leaves it covered.
        /// </summary>
        private sealed class WeekCover
        {
            public readonly Dictionary<(int Day, int Shift), int> Min = new();
            public readonly Dictionary<(int Day, int Shift), int> Duty = new();
            public readonly Dictionary<(int Day, int Shift), int> Placed = new();
            public readonly Dictionary<(int Employee, int Day), int?> StartOf = new();
        }

        /// <summary>
        /// Day by day, oldest first (a move looks at the shift the day before): every working day still
        /// without a shift starts on the person's own (<see cref="StartShift"/>), then each shift the day
        /// must cover (D16) is brought up to its minimum, and then towards its target, by moving people
        /// from a shift that can spare them (<see cref="Cover"/>).
        /// </summary>
        public void AssignShifts()
        {
            foreach (var date in _grid.Days)
            {
                var open = new List<GridCell>();
                foreach (var e in _planned)
                {
                    var cell = _grid[e, date];
                    if (cell.IsFact || cell.State != CellState.Work || cell.ShiftId is not null)
                        continue;
                    cell.ShiftId = StartShift(cell);
                    open.Add(cell);
                }

                if (open.Count > 0 && _in.InMonth(date) && date >= _in.Today)
                    Cover(date, open);
                else
                    StayAfterCover(date, open);

                // The month's days off their own shift so far, whoever decided them — a saved day counts
                // like a planned one, so the share does not change when today moves past it.
                if (!_in.InMonth(date))
                    continue;
                foreach (var e in _planned)
                {
                    var cell = _grid[e, date];
                    if (cell.InBranch && cell.CountsAsWorkForRun && cell.ShiftId is { } shift && shift != HomeShift(e, date))
                        _moves[e] = _moves.GetValueOrDefault(e) + 1;
                }
            }
        }

        /// <summary>
        /// The shift a working day starts from: the weekly pattern's for that weekday, else the person's
        /// most frequent shift in the four weeks before the window, else the drawer's default, else the
        /// first active shift (§2.6). Coverage may move the person off it.
        /// </summary>
        private int? StartShift(GridCell cell) => HomeShift(cell.EmployeeId, cell.Date);

        private int? HomeShift(int e, DateOnly date)
        {
            var pattern = _in.PatternOn(e, date);
            if (pattern is { IsRestDay: false } && _in.IsActiveShift(pattern.ShiftId))
                return pattern.ShiftId;
            if (!_frequent.TryGetValue(e, out var frequent))
                _frequent[e] = frequent = MostFrequentShift(e);
            return frequent ?? _fallbackShift;
        }

        /// <summary>
        /// D16 for one day. First, someone who worked a shift to cover yesterday that was not their own
        /// (moved to cover it, or put there by hand) stays on it today when going back to their own would
        /// leave less than the minimum hours between the two shifts — a morning person who covered an
        /// evening does not start at seven the next morning — provided the shift they leave can spare them.
        /// Then the shift furthest below its minimum is served first; it takes the cheapest person
        /// (<see cref="MoveCost"/>) from a shift above its own minimum — or from a shift nobody has to
        /// cover. Then, the same way, a shift below its target takes someone from a shift above its own
        /// target (or minimum), and never into a turnaround shorter than the minimum. Only working days the
        /// run decides are moved, never a fact, a draft edit or a leave day's row. A shift that still cannot
        /// be covered is reported by the validator (SHIFT_UNCOVERED, SHORT_STAFFED).
        /// </summary>
        private void Cover(DateOnly date, List<GridCell> open)
        {
            var rules = _in.CoverRulesFor(date);
            if (rules.Count == 0)
                return;

            var min = rules.ToDictionary(r => r.ShiftId!.Value, r => r.MinOnDuty);
            var target = rules.Where(r => r.TargetOnDuty is not null).ToDictionary(r => r.ShiftId!.Value, r => r.TargetOnDuty!.Value);
            var count = new Dictionary<int, int>();
            foreach (var c in _grid.CellsOn(date))
                if (c.InBranch && c.CountsAsWorkForRun && c.ShiftId is { } on)
                    count[on] = count.GetValueOrDefault(on) + 1;

            var movable = open.Where(c => c.Leave == LeaveKind.None).ToList();
            var start = movable.ToDictionary(c => c.EmployeeId, c => c.ShiftId);
            int Count(int shift) => count.GetValueOrDefault(shift);
            bool CanSpare(int shift) => !min.TryGetValue(shift, out var m) || Count(shift) > m;

            var minGap = TimeSpan.FromHours(_in.Settings.MinHoursBetweenShifts);
            foreach (var c in movable.OrderBy(c => c.EmployeeId))
            {
                var yesterday = date.AddDays(-1);
                if (c.ShiftId is not { } current
                    || ShiftOn(c.EmployeeId, yesterday) is not { } before
                    || !min.ContainsKey(before.Shift.ShiftId)
                    || before.Shift.ShiftId == current
                    || before.Shift.ShiftId == HomeShift(c.EmployeeId, yesterday)
                    || !CanSpare(current)
                    || _in.Shifts[current].StartOn(date) - before.Shift.EndOn(yesterday) >= minGap)
                    continue;
                Move(c, before.Shift.ShiftId, count);
            }

            var stuck = new HashSet<int>();
            while (rules.Select(r => r.ShiftId!.Value)
                       .Where(sh => !stuck.Contains(sh) && Count(sh) < min[sh])
                       .OrderBy(sh => Count(sh) - min[sh])
                       .Select(sh => (int?)sh)
                       .FirstOrDefault() is { } to)
            {
                var mover = BestMover(date, movable, to, CanSpare, strict: false);
                if (mover is null)
                    stuck.Add(to);
                else
                    Move(mover, to, count);
            }

            stuck.Clear();
            while (rules.Select(r => r.ShiftId!.Value)
                       .Where(sh => !stuck.Contains(sh) && target.TryGetValue(sh, out var t) && Count(sh) < t)
                       .OrderBy(sh => Count(sh) - target[sh])
                       .Select(sh => (int?)sh)
                       .FirstOrDefault() is { } to)
            {
                var mover = BestMover(date, movable, to,
                    from => min.ContainsKey(from) && Count(from) > (target.TryGetValue(from, out var t) ? t : min[from]),
                    strict: true);
                if (mover is null)
                    stuck.Add(to);
                else
                    Move(mover, to, count);
            }

            foreach (var c in movable)
            {
                if (c.ShiftId == start[c.EmployeeId] || c.ReasonCode is not (null or ReasonShiftCover))
                    continue;
                var name = c.ShiftId is { } id && _in.Shifts.TryGetValue(id, out var info) ? info.Name : null;
                c.ReasonCode = ReasonShiftCover;
                c.ReasonArgs = RosterPlanner.Args(("shift", name ?? string.Empty));
            }
        }

        /// <summary>
        /// A ghost day after the month: nothing has to be covered there (the next month's run decides it),
        /// but someone who covered a shift on the month's last day does not go back to their own the next
        /// morning on paper either — the turnaround would be reported against the month.
        /// </summary>
        private void StayAfterCover(DateOnly date, List<GridCell> open)
        {
            var minGap = TimeSpan.FromHours(_in.Settings.MinHoursBetweenShifts);
            var yesterday = date.AddDays(-1);
            foreach (var c in open.Where(c => c.Kind == CellKind.Ghost && c.Leave == LeaveKind.None))
            {
                if (c.ShiftId is { } current
                    && ShiftOn(c.EmployeeId, yesterday) is { } before
                    && before.Shift.ShiftId != current
                    && before.Shift.ShiftId != HomeShift(c.EmployeeId, yesterday)
                    && _in.Shifts[current].StartOn(date) - before.Shift.EndOn(yesterday) < minGap)
                    c.ShiftId = before.Shift.ShiftId;
            }
        }

        /// <summary>The cheapest person to move onto <paramref name="to"/> from a shift <paramref name="canSpare"/> allows; ties turn with the day.</summary>
        private GridCell? BestMover(DateOnly date, List<GridCell> movable, int to, Func<int, bool> canSpare, bool strict)
        {
            GridCell? best = null;
            var bestCost = double.MaxValue;
            var people = Math.Max(1, _planned.Count);
            foreach (var c in movable
                         .Where(c => c.ShiftId is { } from && from != to && canSpare(from))
                         .OrderBy(c => RosterCalendar.Mod(_ordinal[c.EmployeeId] + date.DayNumber, people))
                         .ThenBy(c => c.EmployeeId))
            {
                var (cost, turnaround) = MoveCost(c, to, date);
                if (strict && turnaround)
                    continue;
                if (cost < bestCost - 1e-9)
                {
                    best = c;
                    bestCost = cost;
                }
            }
            return best;
        }

        /// <summary>
        /// What moving a person onto shift <paramref name="to"/> costs, largest first:
        ///   - 50 for a TURNAROUND: less than RosterMinHoursBetweenShifts after the shift worked the day
        ///     before, or before the one the day after when the person could not stay on this shift then;
        ///   - 20 when the next day is a rest and the shift after it would start less than
        ///     RosterMinWeeklyRestHours after this one ends (an evening, one day off, then a morning);
        ///   - 10 for leaving a shift nobody has to cover (a night worker covering a morning is the last resort);
        ///   - 8 for leaving the shift the generator saved there — and −8 for going back to it, so a
        ///     regenerate moves the same people as before;
        ///   - 4 for leaving the weekly pattern's shift, and 4 when the person will stay on this shift
        ///     tomorrow too (going back would be a turnaround: <see cref="Cover"/> keeps them on it);
        ///   - 3 per day the person already worked off their own shift this month (moves are shared);
        ///   - 2 for a shift the person has not worked in the last eight weeks.
        /// </summary>
        private (double Cost, bool Turnaround) MoveCost(GridCell cell, int to, DateOnly date)
        {
            var e = cell.EmployeeId;
            var from = cell.ShiftId!.Value;
            var shift = _in.Shifts[to];
            var minGap = TimeSpan.FromHours(_in.Settings.MinHoursBetweenShifts);
            double cost = 0;
            var turnaround = false;

            if (ShiftOn(e, date.AddDays(-1)) is { } before && shift.StartOn(date) - before.Shift.EndOn(before.Date) < minGap)
            {
                turnaround = true;
                cost += 50;
            }

            var next = date.AddDays(1);
            if (ShiftOn(e, next) is { } after)
            {
                if (after.Shift.StartOn(next) - shift.EndOn(date) < minGap)
                {
                    if (CanStayOn(to, next, after.Shift.ShiftId))
                        cost += 4;
                    else
                    {
                        turnaround = true;
                        cost += 50;
                    }
                }
            }
            else if (FirstShiftAfterRest(e, next) is { } back
                     && back.Shift.StartOn(back.Date) - shift.EndOn(date) < TimeSpan.FromHours(_in.Settings.MinWeeklyRestHours))
            {
                cost += 20;
            }

            if (!_in.CoverRulesFor(date).Any(r => r.ShiftId == from))
                cost += 10;
            var saved = SavedShift(cell);
            if (saved == to)
                cost -= 8;
            else if (saved == from)
                cost += 8;
            if (_in.PatternOn(e, date) is { IsRestDay: false, ShiftId: { } patternShift } && patternShift == from)
                cost += 4;
            cost += 3 * _moves.GetValueOrDefault(e);
            if (!Knows(e, to))
                cost += 2;
            return (cost, turnaround);
        }

        /// <summary>
        /// Whether someone starting on <paramref name="leaving"/> on <paramref name="date"/> could stay on
        /// <paramref name="staying"/> instead — what <see cref="Cover"/> does after a move: the shift they
        /// leave can spare one, as far as the day is planned so far.
        /// </summary>
        private bool CanStayOn(int staying, DateOnly date, int leaving)
        {
            if (!_in.InMonth(date) || date > _in.WindowTo)
                return true;
            var rules = _in.CoverRulesFor(date);
            if (rules.All(r => r.ShiftId != staying))
                return false;
            if (rules.FirstOrDefault(r => r.ShiftId == leaving) is not { } rule)
                return true;
            var on = _grid.CellsOn(date).Count(c => c.InBranch && c.CountsAsWorkForRun && (c.ShiftId ?? StartShift(c)) == leaving);
            return on - 1 >= rule.MinOnDuty;
        }

        /// <summary>The first shift worked after a run of rest days starting on <paramref name="date"/> (null when the day is not a rest, or nothing is known).</summary>
        private (ShiftInfo Shift, DateOnly Date)? FirstShiftAfterRest(int e, DateOnly date)
        {
            for (var d = date; d <= date.AddDays(3) && d <= _in.WindowTo; d = d.AddDays(1))
            {
                if (ShiftOn(e, d) is { } worked)
                    return d == date ? null : worked;
                if (!_grid[e, d].CountsAsRest)
                    return null;
            }
            return null;
        }

        private static void Move(GridCell cell, int to, Dictionary<int, int> count)
        {
            var from = cell.ShiftId!.Value;
            count[from] = count.GetValueOrDefault(from) - 1;
            count[to] = count.GetValueOrDefault(to) + 1;
            cell.ShiftId = to;
        }

        /// <summary>
        /// The shift someone works on a day, for the turnaround: a window day as decided so far (a working
        /// day still without a shift: the one it starts on), else the saved row around the window. A ghost
        /// day is the next month's to decide — it is never saved, and may be decided differently by the
        /// next run — so it counts as unknown here: who covers a shift must not hang on it, or a regenerate
        /// would move someone else.
        /// </summary>
        private (ShiftInfo Shift, DateOnly Date)? ShiftOn(int e, DateOnly date)
        {
            int? id;
            if (date >= _in.WindowFrom && date <= _in.WindowTo)
            {
                var c = _grid[e, date];
                if (!c.CountsAsWorkForRun || c.Kind == CellKind.Ghost)
                    return null;
                id = c.ShiftId ?? StartShift(c);
            }
            else
            {
                id = _in.WorksOutsideWindow(e, date) ? _in.RowOf(e, date)?.ShiftId : null;
            }
            return id is { } shiftId && _in.Shifts.TryGetValue(shiftId, out var info) ? (info, date) : null;
        }

        /// <summary>The shift the generator saved on this working day (ReplanAuto, the row unchanged since), if it is still active.</summary>
        private int? SavedShift(GridCell cell)
            => AutoStateOf(cell) == CellState.Work
               && _in.Cells.TryGetValue(new EmpDay(cell.EmployeeId, cell.Date), out var meta)
               && _in.IsActiveShift(meta.AutoShiftId)
                ? meta.AutoShiftId
                : null;

        /// <summary>The person worked this shift in the eight weeks before the window, or their weekly pattern names it.</summary>
        private bool Knows(int e, int shiftId)
        {
            if (!_known.TryGetValue(e, out var known))
            {
                known = RosterCalendar.Days(_in.WindowFrom.AddDays(-ShiftCoverDetector.LookbackDays), _in.WindowFrom.AddDays(-1))
                    .Select(d => _in.RowOf(e, d))
                    .Where(r => r is { IsWork: true })
                    .Select(r => r!.Value.ShiftId!.Value)
                    .ToHashSet();
                for (var dow = 1; dow <= 7; dow++)
                    if (_in.Patterns.TryGetValue((e, dow), out var p) && p is { IsRestDay: false, ShiftId: { } ps })
                        known.Add(ps);
                _known[e] = known;
            }
            return known.Contains(shiftId);
        }

        /// <summary>The employee's most frequent active shift in the 4 weeks before the window (ties: the latest used, then the lowest id).</summary>
        private int? MostFrequentShift(int e)
        {
            var from = _in.WindowFrom.AddDays(-28);
            return RosterCalendar.Days(from, _in.WindowFrom.AddDays(-1))
                .Select(d => (Date: d, Row: _in.RowOf(e, d)))
                .Where(x => x.Row is { IsWork: true } r && _in.IsActiveShift(r.ShiftId))
                .GroupBy(x => x.Row!.Value.ShiftId!.Value)
                .OrderByDescending(g => g.Count())
                .ThenByDescending(g => g.Max(x => x.Date))
                .ThenBy(g => g.Key)
                .Select(g => (int?)g.Key)
                .FirstOrDefault();
        }
    }

    /// <summary>Every subset of the set bits of <paramref name="mask"/> with <paramref name="size"/> members, in calendar (lexicographic) order.</summary>
    internal static List<int> Combinations(int mask, int size)
    {
        var days = Enumerable.Range(0, 7).Where(i => (mask >> i & 1) == 1).ToArray();
        var result = new List<int>();
        if (size < 0 || size > days.Length)
            return result;

        void Walk(int start, int left, int acc)
        {
            if (left == 0)
            {
                result.Add(acc);
                return;
            }
            for (var i = start; i <= days.Length - left; i++)
                Walk(i + 1, left - 1, acc | (1 << days[i]));
        }

        Walk(0, size, 0);
        return result;
    }

    /// <summary>A reason's figures as a small JSON object.</summary>
    internal static string Args(params (string Key, object Value)[] pairs)
    {
        var map = new SortedDictionary<string, object>(StringComparer.Ordinal);
        foreach (var (key, value) in pairs)
            map[key] = value;
        return JsonSerializer.Serialize(map);
    }

    /* ==================================================================================
     * §2.8 the preview
     * ================================================================================ */

    private static AutoRosterPreview BuildPreview(
        PlannerInput input, RosterGrid grid, IReadOnlyDictionary<int, ResolvedRhythm> rhythms, WeekendLedger ledger, List<AutoRosterIssue> issues)
    {
        var preview = new AutoRosterPreview
        {
            BranchId = input.BranchId,
            MonthDate = input.MonthStart,
            WindowFrom = input.WindowFrom,
            WindowTo = input.WindowTo,
            Issues = issues,
        };

        foreach (var employee in grid.Staff)
        {
            foreach (var cell in grid.CellsOf(employee.EmployeeId))
            {
                if (!cell.Employed || !cell.InBranch)
                    continue;

                var change = ChangeOf(cell);
                preview.Cells.Add(new AutoRosterCell
                {
                    EmployeeId = cell.EmployeeId,
                    WorkDate = cell.Date,
                    State = StateText(cell.State),
                    ShiftId = cell.State == CellState.Work ? cell.ShiftId : null,
                    Origin = OriginOf(cell),
                    Change = change,
                    ReasonCode = cell.ReasonCode,
                    ReasonArgs = cell.ReasonArgs,
                    Expected = ExpectedOf(cell.Current),
                });

                if (!cell.InMonth)
                    continue;
                switch (change)
                {
                    case "insert": preview.Summary.Inserts++; break;
                    case "update": preview.Summary.Updates++; break;
                    case "delete": preview.Summary.Deletes++; break;
                    case "unchanged": preview.Summary.Unchanged++; break;
                    default: preview.Summary.Kept++; break;
                }
            }
        }

        foreach (var r in rhythms.Values.OrderBy(r => r.EmployeeId))
        {
            preview.Rhythm.Add(new AutoRosterRhythm
            {
                EmployeeId = r.EmployeeId,
                AnchorWeekStart = r.AnchorWeekStart,
                AnchorWorkDays = r.AnchorWorkDays,
                IsNew = r.IsNew,
            });
        }

        foreach (var employee in grid.Staff)
        {
            var e = employee.EmployeeId;
            var month = grid.CellsOf(e).Where(c => c.InMonth && c.Employed && c.InBranch).ToList();
            var counters = new AutoRosterEmployeeCounters
            {
                EmployeeId = e,
                WorkDays = month.Count(c => c.State == CellState.Work),
                RestDays = month.Count(c => c.CountsAsRest),
                SaturdaysOff = month.Count(c => c.CountsAsRest && RosterCalendar.IsSaturday(c.Date)),
                SundaysOff = month.Count(c => c.CountsAsRest && RosterCalendar.IsSunday(c.Date)),
            };

            if (rhythms.TryGetValue(e, out var rhythm))
            {
                counters.OwedSaturday = Math.Round(ledger.Owed(e, DayOfWeek.Saturday), 2);
                counters.OwedSunday = Math.Round(ledger.Owed(e, DayOfWeek.Sunday), 2);
                foreach (var ws in grid.WeekStarts)
                {
                    var check = RosterPlanValidator.CheckWeek(input, grid, rhythm, ws);
                    counters.Weeks.Add(new AutoRosterWeekCounter
                    {
                        WeekStart = ws,
                        WorkDays = check.WorkDays,
                        Rests = check.Rests,
                        Quota = check.Quota,
                        Ok = check.Ok,
                    });
                }
            }

            preview.PerEmployee.Add(counters);
        }

        foreach (var date in RosterCalendar.Days(input.MonthStart, input.MonthEnd))
        {
            var (min, target) = input.StaffingFor(date);
            preview.PerDay.Add(new AutoRosterDayCounters
            {
                Date = date,
                OnDuty = RosterPlanValidator.OnDuty(grid, date),
                Min = min,
                Target = target,
                Shifts = input.CoverRulesFor(date)
                    .Select(r => new AutoRosterShiftCounter
                    {
                        ShiftId = r.ShiftId!.Value,
                        OnDuty = RosterPlanValidator.OnShift(grid, date, r.ShiftId!.Value),
                        Min = r.MinOnDuty,
                        Target = r.TargetOnDuty,
                    })
                    .ToList(),
            });
        }

        return preview;
    }

    /// <summary>insert · update · delete · unchanged for a cell this run writes; kept for a fact, a ghost or a day outside the month.</summary>
    public static string ChangeOf(GridCell cell)
    {
        if (!cell.InMonth || cell.IsFact || !cell.Employed || !cell.InBranch)
            return "kept";

        var current = cell.Current;
        switch (cell.State)
        {
            case CellState.Work:
                if (current is null) return "insert";
                return !current.Value.IsRestDay && current.Value.ShiftId == cell.ShiftId ? "unchanged" : "update";
            case CellState.Rest:
                if (current is null) return "insert";
                return current.Value.IsRestDay && current.Value.ShiftId is null ? "unchanged" : "update";
            default:
                return current is null ? "unchanged" : "delete";
        }
    }

    private static string StateText(CellState state) => state switch
    {
        CellState.Work => "work",
        CellState.Rest => "rest",
        _ => "none",
    };

    private static string OriginOf(GridCell cell) => cell.Kind switch
    {
        CellKind.Locked => "locked",
        CellKind.Outside => "outside",
        CellKind.Ghost => "ghost",
        CellKind.Pinned => "pinned",
        CellKind.Leave => "leave",
        CellKind.Holiday => "holiday",
        CellKind.Draft => "draft",
        CellKind.Planned or CellKind.Unavailable => "planned",
        _ => "fact",
    };

    private static RosterCellExpected ExpectedOf(RosterRow? row) => row is { } r
        ? new RosterCellExpected { Exists = true, ShiftId = r.ShiftId, IsRestDay = r.IsRestDay }
        : new RosterCellExpected { Exists = false };

    internal static string Day(DateOnly date) => date.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
}
