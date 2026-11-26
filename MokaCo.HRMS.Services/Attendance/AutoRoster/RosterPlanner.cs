using System.Globalization;
using System.Numerics;
using System.Text.Json;
using MokaCo.HRMS.Model.Attendance;

namespace MokaCo.HRMS.Services.Attendance.AutoRoster;

/// <summary>
/// An employee's 6/5 anchor as this run uses it. <paramref name="AlternateFrom"/> is the new-hire rule's W0
/// (<see cref="PlannerInput.AlternateFrom"/>): every week that starts before it is a 6-day week, whatever the anchor
/// says; from it the anchor's alternation applies. Null: no new-hire period (the hire date is unknown).
/// </summary>
public sealed record ResolvedRhythm(int EmployeeId, DateOnly AnchorWeekStart, int AnchorWorkDays, bool IsNew, DateOnly? AlternateFrom = null)
{
    /// <summary>
    /// T(e,w): 6 or 5 for the week containing <paramref name="anyDayOfWeek"/> — THE ONE PLACE the rhythm is decided
    /// (the planner's quotas, the validator, the preview's counters and the setup's first week all ask here).
    /// </summary>
    public int WorkDaysIn(DateOnly anyDayOfWeek)
        => IsNewHireWeek(anyDayOfWeek)
            ? 6
            : RosterCalendar.WorkDaysInWeek(RosterCalendar.WeekIndex(AnchorWeekStart), AnchorWorkDays, RosterCalendar.WeekIndex(anyDayOfWeek));

    /// <summary>The week starts before W0: a 6-day week of the new-hire period.</summary>
    public bool IsNewHireWeek(DateOnly anyDayOfWeek)
        => AlternateFrom is { } w0 && RosterCalendar.WeekStart(anyDayOfWeek) < w0;
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
///
/// The owner's rules of November 2026 (docs: the shift-roster spec), each made where its comment says:
/// R6 a new hire works 6-day weeks for RosterNewHireSixDayMonths months, then 6, 5, 6, 5 (<see cref="ResolvedRhythm"/>);
/// R4 the shift leaders are placed first, one per shift, and their rest days avoid days without a leader
/// (<see cref="Run"/>.SeparateLeads, the weekday cost, the weekend step); R3 every shift to cover keeps its
/// minimum reachable on every day, weekends included (the water-fill's room, the cost, the repair); R5 each
/// day's people are spread evenly over its shifts (Balance); R1 the turnaround and weekly-rest maths read
/// the hours in force on each date (<see cref="PlannerInput.HoursOn"/>).
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

    /// <summary>A shift leader moved off the shift the other leader is on (each shift keeps one), or the person who changed places with them.</summary>
    public const string ReasonLeadApart = "WORK_LEAD_APART";

    /// <summary>R5: moved to another shift the day must cover so the shifts' head-counts stay even (or follow the stored targets).</summary>
    public const string ReasonShiftBalance = "WORK_SHIFT_BALANCE";

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
        if (input.Rotation is null)
        {
            run.PlanWeeks();
            run.AssignShifts();
        }
        else
        {
            // The fixed rotation: the rule decides the free days and their shifts (no fairness, no shift cover).
            RotationRule.Apply(input, grid);
        }

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

    /// <summary>How far back a W0 still decides a new rhythm's parity (see <see cref="ResolveRhythms(PlannerInput, RosterGrid)"/>).</summary>
    public const int JustFinishedWeeks = 4;

    /// <summary>
    /// The week of <paramref name="day"/> starts before <paramref name="w0"/>: a 6-day week of the new-hire period. A 6/5 override
    /// for such a week (the drawer's "first week" of somebody still in the period - the drawer no longer offers it, but an old
    /// draft or another API caller may send it) changes nothing that week and must not decide the alternation from W0 either:
    /// it is ignored, so W0 starts the alternation with a 6-day week (or a stored anchor decides it), and the anchor the
    /// preview returns and the commit saves is that one. An override for W0 or a later week still applies.
    /// </summary>
    internal static bool IsNewHireWeek(DateOnly? w0, DateOnly day) => w0 is { } start && RosterCalendar.WeekStart(day) < start;

    /// <summary>
    /// Stored → as stored; overridden → the override; neither → anchored on the first window week the
    /// person is employed. Aligned starts on a 6-day week unless that week's facts already hold two rest
    /// rows; Staggered balances the 6- and 5-day first weeks of the whole branch (ties start on 6).
    ///
    /// R6, the new-hire rule, on top: every rhythm carries the person's W0 (<see cref="PlannerInput.AlternateFrom"/>),
    /// so a week before it is a 6-day week whatever the anchor says. A person with neither a stored anchor nor an
    /// override whose W0 is not before the first week they are employed in the window is anchored ON W0 as a 6-day
    /// week ("one week 6 days and the next week 5"), whatever Aligned or Staggered would choose: the anchor the commit
    /// saves is then that, and next month's run carries the same alternation on. A stored anchor or an override still
    /// decides the weeks from W0 on — the manager's (or an earlier run's) explicit choice wins there; an override for a week
    /// before W0 is ignored (<see cref="IsNewHireWeek"/>).
    /// </summary>
    public static IReadOnlyDictionary<int, ResolvedRhythm> ResolveRhythms(PlannerInput input, RosterGrid grid)
    {
        // The fixed rotation carries its own 6/5: the start date's week and each person's group.
        if (input.Rotation is not null)
            return RotationRule.ResolveRhythms(input);

        var result = new SortedDictionary<int, ResolvedRhythm>();
        var weeks = grid.WeekStarts;
        var firstWeek = weeks.Count > 0 ? weeks[0] : RosterCalendar.WeekStart(input.WindowFrom);
        var pending = new List<(PlannerEmployee Employee, DateOnly Anchor)>();
        int sixes = 0, fives = 0;

        foreach (var employee in input.Staff.Where(s => s.OnRotation))
        {
            var e = employee.EmployeeId;
            var w0 = input.AlternateFrom(e);
            input.Rhythms.TryGetValue(e, out var stored);
            var storedRhythm = stored is null ? null : new ResolvedRhythm(e, stored.AnchorWeekStart, stored.AnchorWorkDays, false, w0);

            ResolvedRhythm? resolved = storedRhythm;
            if (input.RhythmOverrides.TryGetValue(e, out var o) && !IsNewHireWeek(w0, o.WeekStart))
            {
                var weekStart = RosterCalendar.WeekStart(o.WeekStart);
                resolved = storedRhythm is not null && storedRhythm.WorkDaysIn(weekStart) == o.WorkDays
                    ? storedRhythm
                    : new ResolvedRhythm(e, weekStart, o.WorkDays, true, w0);
            }

            var anchor = weeks.FirstOrDefault(ws => Enumerable.Range(0, 7).Any(i => input.IsEmployed(e, ws.AddDays(i))), firstWeek);

            // A new rhythm for somebody still in (or just finishing) the new-hire period starts its alternation on W0.
            // "Just finishing" reaches back up to 4 weeks before the person's first window week: someone whose 6-day
            // period ended a few weeks ago and who was never auto-rostered since keeps the W0 parity (6 on W0, then 5,
            // 6, ...) instead of a fresh Aligned/Staggered start that could hand them a third 6-day week in a row.
            // Long-serving staff (W0 further back) keep the branch's Aligned/Staggered choice.
            if (resolved is null && w0 is { } start && start >= anchor.AddDays(-7 * JustFinishedWeeks))
                resolved = new ResolvedRhythm(e, start, 6, true, w0);

            if (resolved is not null)
            {
                result[e] = resolved;
                if (resolved.WorkDaysIn(firstWeek) == 6) sixes++; else fives++;
                continue;
            }

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
                result[e] = new ResolvedRhythm(e, anchor, restFacts >= 2 ? 5 : 6, true, input.AlternateFrom(e));
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
                result[employee.EmployeeId] = new ResolvedRhythm(employee.EmployeeId, anchor, anchorType, true, input.AlternateFrom(employee.EmployeeId));
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
        private readonly int? _defaultShift;
        private readonly int? _firstActiveShift;
        private readonly Dictionary<int, int?> _frequent = new();
        private (int? Shift, Dictionary<DateOnly, int?> Days)? _guessed;
        private readonly Dictionary<int, HashSet<int>> _known = new();
        private readonly Dictionary<int, int> _moves = new();
        private WeekCover? _cover;
        private Dictionary<int, (int Shift, DateOnly Last)> _carried = new();

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
            _defaultShift = input.IsActiveShift(input.DefaultShiftId) ? input.DefaultShiftId : null;
            _firstActiveShift = input.Shifts.Values.Where(s => s.IsActive).OrderBy(s => s.ShiftId).Select(s => (int?)s.ShiftId).FirstOrDefault();
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
            public List<int> Stable = [];               // Pool narrowed to the most stable, before anything was chosen
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

        /// <summary>
        /// The days of the week of <paramref name="ws"/> each person in <see cref="_carried"/> would be held on with the rest days
        /// <paramref name="persons"/> chose (other days as decided): by employee and weekday, the shift they are held on.
        /// </summary>
        private Dictionary<(int Employee, int Day), int> ProjectHolds(DateOnly ws, List<PersonWeek> persons)
        {
            var result = new Dictionary<(int Employee, int Day), int>();
            foreach (var (e, hold) in _carried)
            {
                var p = persons.FirstOrDefault(x => x.EmployeeId == e);
                foreach (var d in HoldAfter(e, hold.Last, hold.Shift, Works(e, ws, p?.PMask ?? 0, p?.Chosen ?? 0), ws.AddDays(6)).Days)
                    if (d >= ws)
                        result[(e, d.DayNumber - ws.DayNumber)] = hold.Shift;
            }
            return result;
        }

        /// <summary>
        /// How <see cref="HoldAfter"/> reads a week whose rest days are being chosen: the person's plannable days of the week
        /// (<paramref name="pMask"/>) as rests where <paramref name="restMask"/> has them and as worked otherwise, the open days of
        /// the later weeks as worked (nothing decided yet never ends a hold), and every other day as decided.
        /// </summary>
        private Func<DateOnly, bool?> Works(int e, DateOnly ws, int pMask, int restMask) => d =>
        {
            var i = d.DayNumber - ws.DayNumber;
            if (i is >= 0 and < 7 && (pMask >> i & 1) == 1)
                return (restMask >> i & 1) == 0;
            if (i >= 7 && d <= _in.WindowTo && _grid[e, d] is { IsPlannable: true, State: CellState.None })
                return true;
            return null;
        };

        /// <summary>
        /// The hold somebody carries into the week of <paramref name="ws"/>: the shift, and the last day they worked it before the
        /// first day of the week the shift cover may still decide for them - when that shift was not their own and comes from a
        /// row (last month's saved days, a locked day, a draft, a leave day's row), or from a hold such a row started that still
        /// held on that day (<see cref="HeldAfter"/>, read from the weeks planned already: their rest days are decided). Rest days
        /// in between are read as they are; a day nothing is known about ends it. Whether it still holds in the week depends on
        /// the week's rest days (<see cref="ProjectHolds"/>). Null: no hold.
        /// </summary>
        private (int Shift, DateOnly Last)? CarriedHold(int e, DateOnly ws)
        {
            // The first day of the week the shift cover may still decide for them.
            DateOnly? open = null;
            for (var d = ws; d < ws.AddDays(7) && open is null; d = d.AddDays(1))
                if (_grid[e, d] is { IsFact: false, ShiftId: null, Leave: LeaveKind.None, InBranch: true, Employed: true } c
                    && c.Kind != CellKind.Ghost && (c.IsPlannable || c.State == CellState.Work))
                    open = d;
            if (open is not { } from)
                return null;

            // Their last working day before it, through known rest days only.
            DateOnly? lastDay = null;
            for (var d = from.AddDays(-1); d >= from.AddDays(-4) && lastDay is null; d = d.AddDays(-1))
            {
                if (WorkedRow(e, d) is not null || (d >= _in.WindowFrom && _grid[e, d].CountsAsWorkForRun))
                    lastDay = d;
                else if (!KnownRest(e, d))
                    return null;
            }
            if (lastDay is not { } last)
                return null;

            var shift = WorkedRow(e, last);
            if (shift is null)
            {
                // A day this run decided (an earlier week): held there by a row before it, or on their own shift.
                for (var d = last.AddDays(-1); d >= last.AddDays(-28) && shift is null; d = d.AddDays(-1))
                {
                    if (WorkedRow(e, d) is { } source)
                    {
                        // The days of this week and later are not decided yet: read as worked, as the hold would read them.
                        if (!HoldAfter(e, d, source, Works(e, ws.AddDays(-7), 0, 0)).Days.Contains(last))
                            return null;
                        shift = source;
                    }
                    else if (!KnownRest(e, d) && !(d >= _in.WindowFrom && _grid[e, d].CountsAsWorkForRun))
                        return null;
                }
            }
            return shift is { } s && s != HomeShift(e, last) ? (s, last) : null;
        }

        /// <summary>The shift of a day somebody worked from a row: saved before the window, or a window day whose shift is fixed (a fact, a draft, a leave day's row). Null for a day this run decides.</summary>
        private int? WorkedRow(int e, DateOnly d)
        {
            if (d < _in.WindowFrom)
                return _in.WorksOutsideWindow(e, d) ? _in.RowOf(e, d)?.ShiftId : null;
            var c = _grid[e, d];
            return c.CountsAsWorkForRun && c.Kind != CellKind.Ghost && c.ShiftId is { } id ? id : null;
        }

        private List<PersonWeek> SolveWeek(int k, List<int> employees)
        {
            var ws = _weeks[k];
            var weekIndex = RosterCalendar.WeekIndex(ws);
            var persons = employees.Select(e => BuildPerson(e, k, weekIndex)).ToList();
            var pMaskOf = persons.ToDictionary(p => p.EmployeeId, p => p.PMask);

            // R3: the holds carried into the week (last month's saved evening for a morning person, and so on), for step 7.
            _carried = new Dictionary<int, (int Shift, DateOnly Last)>();
            foreach (var e in _planned)
                if (CarriedHold(e, ws) is { } hold)
                    _carried[e] = hold;

            // onDuty(d): staff who would work d if no more rests were placed.
            // D16: a day must also hold enough people for every shift it has to cover, so its minimum is
            // at least the sum of theirs (and its target the sum of their targets, when any is set) —
            // the slots, the weekday cost and the repair below then keep that many on duty. By shift,
            // _cover counts who would be on each one from where each person starts (§2.6): a rest that
            // would empty a shift costs more than one that leaves it covered, so few people need moving.
            var onDuty = new int[7];
            var min = new int?[7];
            var target = new int?[7];
            var weekCover = _cover = new WeekCover();
            for (var i = 0; i < 7; i++)
            {
                var date = ws.AddDays(i);
                var rules = _in.ShiftRulesFor(date).ToList();
                foreach (var rule in rules)
                    _cover.Min[(i, rule.ShiftId!.Value)] = rule.MinOnDuty;
                _cover.Shifts[i] = rules.Count;
                _cover.Targets[i] = rules.Any(r => r.TargetOnDuty is not null);

                // R3: who the shift cover will be able to move that day (Cover runs on the month's days from today),
                // and the shifts the rows it cannot move already fill.
                var covered = _in.InMonth(date) && date >= _in.Today;
                var fixedOn = new Dictionary<int, int>();
                foreach (var c in _grid.CellsOn(date))
                {
                    if (!c.InBranch || !c.Employed)
                        continue;
                    int? shift = null;
                    var canMove = false;
                    if (pMaskOf.TryGetValue(c.EmployeeId, out var mask) && (mask >> i & 1) == 1)
                    {
                        onDuty[i]++;
                        shift = CarriedShift(c) ?? StartShift(c);
                        _cover.StartOf[(c.EmployeeId, i)] = shift;
                        canMove = true;
                    }
                    else if (c.CountsAsWorkForRun)
                    {
                        onDuty[i]++;
                        shift = c.ShiftId ?? CarriedShift(c) ?? StartShift(c);
                        canMove = !c.IsFact && c.ShiftId is null && c.Leave == LeaveKind.None;
                    }
                    else
                    {
                        continue;
                    }
                    if (shift is { } counted)
                        _cover.Counted[(c.EmployeeId, i)] = counted;
                    if (shift is { } on && _cover.Min.ContainsKey((i, on)))
                    {
                        _cover.Duty[(i, on)] = _cover.Duty.GetValueOrDefault((i, on)) + 1;
                        if (!_in.ShiftLeads.Contains(c.EmployeeId))
                            _cover.Others[(i, on)] = _cover.Others.GetValueOrDefault((i, on)) + 1;
                    }
                    if (canMove && covered)
                        _cover.Movable[i]++;
                    else if (shift is { } held)
                        fixedOn[held] = fixedOn.GetValueOrDefault(held) + 1;
                    if (_in.ShiftLeads.Contains(c.EmployeeId))
                        _cover.Leads[i]++;
                }
                if (covered)
                    _cover.Deficit[i] = rules.Sum(r => Math.Max(0, r.MinOnDuty - fixedOn.GetValueOrDefault(r.ShiftId!.Value)));

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

            // The room a day has for one more rest: above its minimum on duty and - R3, weekends included - above what
            // its shifts still need from the people the cover can move (rows it cannot move may all sit on one shift).
            int Room(int i)
            {
                var room = onDuty[i] - slots[i] - (min[i] ?? 0);
                return weekCover.Deficit[i] > 0 ? Math.Min(room, weekCover.Movable[i] - slots[i] - weekCover.Deficit[i]) : room;
            }

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
                    var key = Room(i);
                    var bestKey = Room(best);
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
                List<PersonWeek> FairShare(List<PersonWeek> pool)
                {
                    var mostOwed = pool.Count == 0 ? 0 : pool.Max(p => WeekendLedger.Key(Ledger.Owed(p.EmployeeId, kind)));
                    return pool
                        .Where(p => p.Options.Any(o => (o >> x & 1) == 1))
                        .Where(p => WeekendLedger.Key(Ledger.Owed(p.EmployeeId, kind)) > mostOwed - 1 + 1e-6)
                        .OrderByDescending(p => WeekendLedger.Key(Ledger.Owed(p.EmployeeId, kind)))
                        .ThenByDescending(p => WeekendLedger.Key(Ledger.OwedTotal(p.EmployeeId)))
                        .ThenByDescending(p => _weekendStreak.TryGetValue(p.EmployeeId, out var s) ? s : 0)
                        .ThenBy(p => p.Rotation)
                        .ThenBy(p => p.EmployeeId)
                        .ToList();
                }

                // R4, soft: a shift leader whose day off would leave the day without any leader - while another leader
                // works it, so it can be helped - waits for another weekend (the ledger makes them the most owed next
                // time). The fair share is then worked out WITHOUT them, so the people a deferred leader would have
                // kept out are in it again and somebody else takes the slot. A leader is never deferred when they are
                // the only one working that day, and a slot nobody else can take goes to the deferred leader after
                // all: keeping leaders apart never costs the branch a weekend day off.
                var deferred = new List<PersonWeek>();
                List<PersonWeek> picks;
                for (;;)
                {
                    picks = [];
                    var leadRests = _cover?.LeadRests[x] ?? 0;
                    PersonWeek? wait = null;
                    foreach (var p in FairShare(competitors.Where(p => !deferred.Contains(p)).ToList()))
                    {
                        if (picks.Count >= free)
                            break;
                        if (LeavesNoLead(p.EmployeeId, x, leadRests))
                        {
                            wait = p;
                            break;
                        }
                        picks.Add(p);
                        if (_in.ShiftLeads.Contains(p.EmployeeId))
                            leadRests++;
                    }
                    if (wait is null)
                        break;
                    deferred.Add(wait);
                }
                foreach (var p in picks.Concat(deferred).Take(Math.Max(0, free)))
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

            // Step 7 — R3: a hold carried into the week keeps its people off their own shift; that shift keeps its minimum without them.
            if (_carried.Count > 0)
                ProtectHeld(ws, persons, onDuty, min);
            return persons;
        }

        /// <summary>
        /// Step 7, R3: a HOLD CARRIED INTO THE WEEK (<see cref="CarriedHold"/>: last month's saved evening for a morning person, a
        /// locked day, or a hold such a row started that lasted through the weeks already planned) keeps its people on that shift
        /// day by day while their own would come too soon - less than the minimum hours after a working day, less than the weekly
        /// rest after rest days - as <see cref="HeldAfter"/> reads a hold inside the month, and how long depends on the rest days
        /// just chosen (<see cref="ProjectHolds"/>). The shift cover keeps somebody on the held shift only while their own shift can
        /// spare them; one left at its minimum WITH them sends them back: a turnaround on the second day of the month, or a short
        /// weekly rest after one day off. So a weekday whose shift, counted without the people held elsewhere, is below its minimum
        /// takes back a rest of somebody who starts on that shift (not a shift leader, not one of the held), moved to another
        /// weekday of the week that keeps that day's minimum, its shift's and the cover's - as long as one can, and only to rest
        /// days the person's options allow (the hard cap, and in ReplanAuto the rests the generator saved: a regenerate moves
        /// nothing). Weekend days are left to the weekend step (fairness), and when nothing can move the cover still decides
        /// (after a rest day it sends the person back at once rather than into a turnaround later, <see cref="HoldLasts"/>), and
        /// the validator reports.
        /// </summary>
        private void ProtectHeld(DateOnly ws, List<PersonWeek> persons, int[] onDuty, int?[] min)
        {
            var cover = _cover!;
            var holds = ProjectHolds(ws, persons);
            if (holds.Count == 0)
                return;
            var byId = persons.ToDictionary(p => p.EmployeeId);
            bool Rests(int e, int i) => byId.TryGetValue(e, out var p) && (p.PMask >> i & 1) == 1 && (p.Chosen >> i & 1) == 1;
            int? ShiftOf(int e, int i) => holds.TryGetValue((e, i), out var held) ? held : cover.Counted.TryGetValue((e, i), out var counted) ? counted : null;
            int On(int i, int shift) => cover.Counted.Keys.Count(x => x.Day == i && !Rests(x.Employee, i) && ShiftOf(x.Employee, i) == shift);
            int Working(int i) => onDuty[i] - persons.Count(p => Rests(p.EmployeeId, i));
            int Movable(int i) => cover.Movable[i] - persons.Count(p => Rests(p.EmployeeId, i));
            bool Open(int i) => i < Saturday && ws.AddDays(i) is var date && _in.InMonth(date) && date >= _in.Today;

            void MoveRest(PersonWeek p, int from, int to)
            {
                p.Chosen = (p.Chosen & ~(1 << from)) | (1 << to);
                p.Reason[to] = ReasonLevel;
                p.Args[to] = null;
                p.Reason[from] = null;
                p.Args[from] = null;
            }

            for (var guard = 0; guard < 7 * persons.Count; guard++)
            {
                var moved = false;
                holds = ProjectHolds(ws, persons);
                foreach (var (i, shift) in holds.Keys.Where(x => Open(x.Day) && HomeShift(x.Employee, ws.AddDays(x.Day)) is { } home && cover.Min.ContainsKey((x.Day, home)))
                             .Select(x => (x.Day, HomeShift(x.Employee, ws.AddDays(x.Day))!.Value)).Distinct().OrderBy(x => x.Day).ThenBy(x => x.Item2))
                {
                    if (On(i, shift) >= cover.Min[(i, shift)])
                        continue;
                    (PersonWeek P, int Day, int Spare)? best = null;
                    foreach (var p in persons.Where(p => Rests(p.EmployeeId, i) && !_carried.ContainsKey(p.EmployeeId) && !_in.ShiftLeads.Contains(p.EmployeeId)
                                                         && cover.Counted.TryGetValue((p.EmployeeId, i), out var start) && start == shift)
                                 .OrderBy(p => (p.Shape.RestRows >> i & 1) == 1 ? 1 : 0).ThenBy(p => p.Rotation).ThenBy(p => p.EmployeeId))
                    {
                        for (var j = 0; j < 7; j++)
                        {
                            if (j == i || !Open(j) || (p.PMask >> j & 1) == 0 || (p.Chosen >> j & 1) == 1
                                || !p.Stable.Contains((p.Chosen & ~(1 << i)) | (1 << j))
                                || Working(j) - 1 < (min[j] ?? 0) || (cover.Deficit[j] > 0 && Movable(j) - 1 < cover.Deficit[j]))
                                continue;
                            var spare = ShiftOf(p.EmployeeId, j) is { } there && cover.Min.TryGetValue((j, there), out var m) ? On(j, there) - 1 - m : int.MaxValue;
                            if (spare < 0)
                                continue;
                            if (best is null || spare > best.Value.Spare)
                                best = (p, j, spare);
                        }
                        if (best is not null)
                            break;
                    }
                    if (best is { } pick)
                    {
                        MoveRest(pick.P, i, pick.Day);
                        moved = true;
                        break;
                    }
                }
                if (!moved)
                    break;
            }
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
            p.Stable = p.Options;
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
            {
                cover.Placed[(day, shift)] = cover.Placed.GetValueOrDefault((day, shift)) + 1;
                if (!_in.ShiftLeads.Contains(p.EmployeeId))
                    cover.OthersPlaced[(day, shift)] = cover.OthersPlaced.GetValueOrDefault((day, shift)) + 1;
            }
            if (_cover is { } leads && _in.ShiftLeads.Contains(p.EmployeeId))
                leads.LeadRests[day]++;
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
        /// its minimum (or below what its shifts still need from the people the cover can move, R3 -
        /// the larger of the two shortfalls, never both), 15 per day a run goes past the preferred maximum,
        /// 12 per person the shift the person starts on would be below its minimum (D16: it would take a
        /// move to cover it), 10 for a rest above the day's slot count, 8 for a shift leader's rest that
        /// leaves the day without a leader or a working day where more leaders work than the day has shifts
        /// (R4); bonuses 5 for a 5-day week's adjacent pair and 3 for a pattern rest day; and
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
                var below = min[i] is { } m && after < m ? m - after : 0;
                if (_cover is { } need && need.Deficit[i] > 0)
                    below = Math.Max(below, need.Deficit[i] - (need.Movable[i] - tmp[i] - 1));
                if (below > 0)
                    cost += 100 * below;   // deeper below the minimum costs more: spread a shortage, never pile it up
                cost -= 0.01 * (after - (target[i] ?? min[i] ?? 0));
                tmp[i]++;

                var cell = p.Cells[i];
                if (_in.Settings.PatternRestDays == PatternRestRule.Preference && _in.IsPatternRest(p.EmployeeId, cell.Date))
                    cost -= 3;

                // D16: resting here would leave the shift this person starts on short of its minimum.
                if (_cover is { } cover && cover.StartOf.TryGetValue((p.EmployeeId, i), out var start) && start is { } shift
                    && cover.Min.TryGetValue((i, shift), out var shiftMin))
                {
                    var left = cover.Duty.GetValueOrDefault((i, shift)) - cover.Placed.GetValueOrDefault((i, shift)) - 1;
                    if (shiftMin > 0 && left < shiftMin)
                        cost += 12 * (shiftMin - left);

                    // R5: ... or, for somebody who is not a shift leader, the others left on it two or more below those of
                    // another shift of the day (no targets: an even split; the leaders are spread one per shift whatever their
                    // own). The shift cover can seldom even that out afterwards - moving people back to the earlier shift
                    // breaks a rest rule - so the rests of a day are better shared between the people of each shift.
                    if (!cover.Targets[i] && !_in.ShiftLeads.Contains(p.EmployeeId))
                    {
                        int Others((int Day, int Shift) k) => cover.Others.GetValueOrDefault(k) - cover.OthersPlaced.GetValueOrDefault(k);
                        var mine = Others((i, shift)) - 1;
                        var most = cover.Min.Keys.Where(k => k.Day == i && k.Shift != shift).Select(Others).DefaultIfEmpty(mine).Max();
                        if (most - mine >= 2)
                            cost += 8 * (most - mine - 1);
                    }
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

            // R4, soft: a leader rests where it leaves another leader on duty, and works where the leaders do not
            // outnumber the shifts (so nobody has to share).
            if (_cover is { } lead && _in.ShiftLeads.Contains(p.EmployeeId))
            {
                for (var i = 0; i < 7; i++)
                {
                    if ((p.PMask >> i & 1) == 0 || (p.Chosen >> i & 1) == 1 || lead.Shifts[i] == 0)
                        continue;
                    var working = lead.Leads[i] - lead.LeadRests[i];
                    if ((add >> i & 1) == 1 ? working - 1 <= 0 : working > lead.Shifts[i])
                        cost += 8;
                }
            }

            // R3, a hold carried into the week (CarriedHold) that these rest days would end on a day nothing can keep the person on
            // that shift (a night covered only at the weekend: last month's Sunday night, then a Monday with no night to cover) while
            // going back is still too soon: a turnaround, or a short weekly rest. Rest days that end the hold in time are better.
            if (_carried.TryGetValue(p.EmployeeId, out var hold))
            {
                var ws = p.Cells[0].Date;
                var end = HoldAfter(p.EmployeeId, hold.Last, hold.Shift, Works(p.EmployeeId, ws, p.PMask, option), ws.AddDays(6));
                cost += end.Turnaround ? 50 : end.ShortRest ? 20 : 0;
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

        /// <summary>
        /// Step 6. A day below its minimum - or, R3, whose shifts are left short because too few of the people the cover
        /// can move are on duty (one shift's minimum, not only the day's total) - takes back a rest that can move to a day
        /// that stays at or above both its own.
        /// </summary>
        private void Repair(List<PersonWeek> persons, int[] onDuty, int?[] min, int[] placed)
        {
            var duty = new int[7];
            var movable = new int[7];
            var deficit = new int[7];
            for (var i = 0; i < 7; i++)
            {
                duty[i] = onDuty[i] - placed[i];
                movable[i] = (_cover?.Movable[i] ?? 0) - placed[i];
                deficit[i] = _cover?.Deficit[i] ?? 0;
            }
            bool Short(int i) => (min[i] is { } m && duty[i] < m) || (deficit[i] > 0 && movable[i] < deficit[i]);
            bool CanGive(int j) => duty[j] - 1 >= (min[j] ?? 0) && (deficit[j] == 0 || movable[j] - 1 >= deficit[j]);

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
                    if (!inMonth[i] || !Short(i))
                        continue;

                    // A rest the generator saved on this very day is moved last: a re-planned rest moves first.
                    foreach (var p in persons.Where(p => (p.Chosen >> i & 1) == 1)
                                 .OrderBy(p => (p.Shape.RestRows >> i & 1) == 1 ? 1 : 0)
                                 .ThenBy(p => p.Rotation).ThenBy(p => p.EmployeeId))
                    {
                        var targets = Enumerable.Range(0, 7)
                            .Where(j => j != i && inMonth[j] && (p.Chosen >> j & 1) == 0 && CanGive(j))
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
                            movable[i]++;
                            movable[j]--;
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

            /// <summary>R5: Duty and Placed for the people who are not shift leaders (the leaders are spread one per shift on their own).</summary>
            public readonly Dictionary<(int Day, int Shift), int> Others = new();
            public readonly Dictionary<(int Day, int Shift), int> OthersPlaced = new();
            public readonly Dictionary<(int Employee, int Day), int?> StartOf = new();

            /// <summary>The shift each person the week counts was counted on, by employee and weekday (<see cref="CarriedShift"/>, <see cref="StartShift"/>).</summary>
            public readonly Dictionary<(int Employee, int Day), int> Counted = new();

            /// <summary>R3: the people the shift cover can move that day if no more rests were placed (planner-decided working days).</summary>
            public readonly int[] Movable = new int[7];

            /// <summary>R3: what the day's shifts still need beyond the rows the cover cannot move (Σ minimum − fixed, per shift).</summary>
            public readonly int[] Deficit = new int[7];

            /// <summary>R4: the shift leaders who would work that day, and how many of them were given it off so far.</summary>
            public readonly int[] Leads = new int[7];
            public readonly int[] LeadRests = new int[7];

            /// <summary>The shifts the day must cover.</summary>
            public readonly int[] Shifts = new int[7];

            /// <summary>Some shift of the day has a target: the split follows the targets, not an even one.</summary>
            public readonly bool[] Targets = new bool[7];
        }

        /// <summary>
        /// R4: this person is a shift leader and their day off (with <paramref name="leadRests"/> leaders already off) would
        /// leave a day with shifts to cover without any leader although two or more would work it - a day off that another
        /// leader's day could make room for. With one leader working (one leader in the branch, the other on leave, off
        /// rotation or gone) nothing can be helped: false.
        /// </summary>
        private bool LeavesNoLead(int e, int day, int leadRests)
            => _cover is { } c && _in.ShiftLeads.Contains(e) && c.Shifts[day] > 0 && c.Leads[day] >= 2 && c.Leads[day] - leadRests - 1 <= 0;

        /// <summary>
        /// Day by day, oldest first (a move looks at the shift the day before): every working day still
        /// without a shift starts on the person's own (<see cref="StartShift"/>), then the day's working
        /// shift leaders are placed one per shift (R4), each shift the day must cover (D16) is brought up to
        /// its minimum, and then towards its target, by moving people from a shift that can spare them, and
        /// the rest are spread evenly over the shifts (R5) (<see cref="Cover"/>).
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
        /// most frequent shift before the window (<see cref="MostFrequentShift"/>), else the drawer's default, else a
        /// shift the branch covers (<see cref="GuessedShift"/>) (§2.6). Coverage may move the person off it.
        /// </summary>
        private int? StartShift(GridCell cell) => HomeShift(cell.EmployeeId, cell.Date);

        /// <summary>
        /// For the rest days, which are placed before any shift is chosen: the shift somebody will start on instead of their own
        /// because of the shift last KNOWN before the days not decided yet (last month's saved rows, a locked day), when it is a
        /// shift to cover that day. A morning person who worked last month's last evening is held on the evening on the first
        /// day not decided yet, if they work it (<see cref="StayOn"/>: the morning would come too soon); and a leader moved onto
        /// an earlier shift stays there (<see cref="LeaderStaysOn"/>). Counted on their own shift, the rest days could leave the
        /// shift they cannot go back to at its minimum without them, and the shift cover would have to send them back: a
        /// turnaround across the month's end. Only that first day here: whether a later one is held depends on the rest days
        /// still to be placed: step 7 of the week (<see cref="ProtectHeld"/>) projects them and keeps the person's own shift at its
        /// minimum without them.
        /// Null: their own shift.
        /// </summary>
        private int? CarriedShift(GridCell cell)
        {
            var e = cell.EmployeeId;
            var known = cell.Date.AddDays(-1);
            while (known >= _in.WindowFrom && known >= cell.Date.AddDays(-7) && _grid[e, known] is { IsPlannable: true, State: CellState.None })
                known = known.AddDays(-1);
            var carried = LeaderStaysOn(e, known.AddDays(1))
                          ?? (known == cell.Date.AddDays(-1) && HomeShift(e, cell.Date) is { } own ? StayOn(e, cell.Date, own) : null);
            return carried is { } shift && _in.CoverRulesFor(cell.Date).Any(r => r.ShiftId == shift) ? carried : null;
        }

        private int? HomeShift(int e, DateOnly date)
        {
            var pattern = _in.PatternOn(e, date);
            if (pattern is { IsRestDay: false } && _in.IsActiveShift(pattern.ShiftId))
                return pattern.ShiftId;
            if (!_frequent.TryGetValue(e, out var frequent))
                _frequent[e] = frequent = MostFrequentShift(e);

            return frequent ?? _defaultShift ?? GuessedShift(date);
        }

        /// <summary>
        /// The start shift of somebody with nothing to go by (no pattern, no rows before the window, no drawer default: a new
        /// hire). The lowest-numbered active shift may be one the branch never runs, and Cover and Balance only spread people who
        /// are on a shift to cover, so the new hire would stay there for good (next month's most frequent shift). So: the shift
        /// the branch covers on the most days of the window (ties: the first active shift, then the earliest start), the SAME
        /// every day - a guess that changed with the weekday's cover would put an evening on Sunday before a morning on Monday.
        /// On a day that shift is not covered, the first shift covered that day, but only when that run of days makes no
        /// turnaround with the days around it; otherwise the person keeps the guessed shift.
        /// </summary>
        private int? GuessedShift(DateOnly date)
        {
            if (_guessed is null)
            {
                var days = _grid.Days;
                var covered = days.ToDictionary(d => d, d => _in.CoverRulesFor(d).Select(r => r.ShiftId!.Value).ToList());
                var guess = covered.Values.SelectMany(s => s).GroupBy(s => s)
                    .OrderByDescending(g => g.Count())
                    .ThenBy(g => g.Key == _firstActiveShift ? 0 : 1)
                    .ThenBy(g => _in.Shifts[g.Key].StartTime)
                    .ThenBy(g => g.Key)
                    .Select(g => (int?)g.Key)
                    .FirstOrDefault() ?? _firstActiveShift;
                var byDay = new Dictionary<DateOnly, int?>();
                var minGap = TimeSpan.FromHours(_in.Settings.MinHoursBetweenShifts);
                bool TooClose(int? a, DateOnly dayA, int? b)
                    => a is { } x && b is { } y && x != y && _in.HoursOn(x, dayA) is { } first && _in.HoursOn(y, dayA.AddDays(1)) is { } second
                       && second.StartOn(dayA.AddDays(1)) - first.EndOn(dayA) < minGap;
                for (var i = 0; i < days.Count; i++)
                {
                    if (guess is null || covered[days[i]].Count == 0 || covered[days[i]].Contains(guess.Value))
                    {
                        byDay[days[i]] = guess;
                        continue;
                    }
                    // A run of days the guess is not covered on: each takes the first shift covered that day, unless the
                    // run would then start or end (or change inside) with a turnaround.
                    var end = i;
                    while (end + 1 < days.Count && covered[days[end + 1]].Count > 0 && !covered[days[end + 1]].Contains(guess.Value))
                        end++;
                    var run = Enumerable.Range(i, end - i + 1).Select(k => (int?)covered[days[k]][0]).ToList();
                    var turnaround = TooClose(guess, days[i].AddDays(-1), run[0]) || TooClose(run[^1], days[end], guess)
                                     || Enumerable.Range(0, run.Count - 1).Any(k => TooClose(run[k], days[i + k], run[k + 1]));
                    for (var k = i; k <= end; k++)
                        byDay[days[k]] = turnaround ? guess : run[k - i];
                    i = end;
                }
                _guessed = (guess, byDay);
            }
            var (all, perDay) = _guessed.Value;
            return perDay.TryGetValue(date, out var shift) ? shift : all;
        }

        /// <summary>
        /// D16 for one day. First, someone who worked a shift to cover yesterday that was not their own
        /// (moved to cover it, or put there by hand) stays on it today when going back to their own would
        /// leave less than the minimum hours between the two shifts — a morning person who covered an
        /// evening does not start at seven the next morning — provided the shift they leave can spare them;
        /// after rest days only when tomorrow could keep them there too (<see cref="HoldLasts"/>).
        /// Then the working SHIFT LEADERS are placed, one per shift (<see cref="SeparateLeads"/>, R4). Then
        /// the shift furthest below its minimum is served first; it takes a person whose move breaks no rest
        /// rule when there is one, the cheapest (<see cref="MoveCost"/>, <see cref="BestMover"/>), from a shift
        /// above its own minimum — or from a shift nobody has to cover; a leader is taken only when nobody
        /// else can go, and onto a shift without one if possible.
        /// Then, the same way, a shift below its target takes someone from a shift above its own target (or
        /// minimum), and never into a turnaround shorter than the minimum. Then the people left are SPREAD
        /// over the shifts to cover so their head-counts differ by one at most, or follow the targets'
        /// proportions (<see cref="Balance"/>, R5). Only working days the run decides are moved, never a
        /// fact, a draft edit or a leave day's row. A shift that still cannot be covered is reported by the
        /// validator (SHIFT_UNCOVERED, SHORT_STAFFED).
        /// </summary>
        private void Cover(DateOnly date, List<GridCell> open)
        {
            // Nothing to cover that day (a closed holiday, or every shift stored with minimum 0: the manager's "no shift
            // needs covering"): nobody is moved, leaders included - the validator still reports two leaders together.
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
            var movedBy = new Dictionary<int, string>();
            int Count(int shift) => count.GetValueOrDefault(shift);
            bool CanSpare(int shift) => !min.TryGetValue(shift, out var m) || Count(shift) > m;
            void MoveBy(GridCell c, int to, string reason)
            {
                Move(c, to, count);
                movedBy[c.EmployeeId] = reason;
            }

            // Staying is fine when the shift left can spare them, or when somebody else can take their place there without
            // a short rest of their own (the minimums below then move that person).
            bool OthersCanFill(int shift, GridCell except) => movable.Any(o =>
                o != except && o.ShiftId is { } from && from != shift && CanSpare(from) && !MoveCost(o, shift, date).Turnaround);

            // After rest days, staying starts a hold that must LAST: the person is held on each working day after it until a long
            // enough rest, and a day their own shift cannot spare them sends them back right after a held day - a turnaround.
            // Going back today breaks the weekly rest instead (that is why they would stay), the lesser breach: so after rest days
            // they stay only when tomorrow, as it stands, could keep them held too (HoldLasts). Right after a working day going
            // back is a turnaround already, and they stay as before.
            Ahead? lasting = null;
            foreach (var c in movable.OrderBy(c => c.EmployeeId))
            {
                if (c.ShiftId is not { } current
                    || StayOn(c.EmployeeId, date, current) is not { } stay
                    || !min.ContainsKey(stay)
                    || !(CanSpare(current) || OthersCanFill(current, c))
                    || (ShiftOn(c.EmployeeId, date.AddDays(-1)) is null && !HoldLasts(c.EmployeeId, date, stay, lasting ??= new Ahead(this, date))))
                    continue;
                MoveBy(c, stay, ReasonShiftCover);
            }

            // R4: a leader moved onto a shift earlier than their own to keep the leaders apart stays on it on their next working
            // days (LeaderStaysOn), while it is still a shift to cover and holds no other leader - on a day they are the only
            // leader working too. Sent home, they would need moving again when the other leader is back, often right after one
            // rest day: that move leaves the week without its weekly rest (an evening, a day off, then a morning: 32 hours), so it
            // is refused, and both leaders would share the evening until one of them has two days off.
            foreach (var c in movable.Where(c => _in.ShiftLeads.Contains(c.EmployeeId)).OrderBy(c => c.EmployeeId))
            {
                if (c.ShiftId is not { } current
                    || LeaderStaysOn(c.EmployeeId, date) is not { } stay
                    || stay == current
                    || !min.ContainsKey(stay)
                    || LeadsOn(date, stay).Count > 0
                    || !(CanSpare(current) || OthersCanFill(current, c)))
                    continue;
                MoveBy(c, stay, ReasonLeadApart);
            }

            SeparateLeads(date, movable, LeaderShifts(date, rules), count, min, MoveBy);

            bool NotLead(GridCell c) => !_in.ShiftLeads.Contains(c.EmployeeId);
            var stuck = new HashSet<int>();
            while (rules.Select(r => r.ShiftId!.Value)
                       .Where(sh => !stuck.Contains(sh) && Count(sh) < min[sh])
                       .OrderBy(sh => Count(sh) - min[sh])
                       .Select(sh => (int?)sh)
                       .FirstOrDefault() is { } to)
            {
                // A leader moves only when nobody else can (the minimum outranks keeping them apart), and onto a
                // shift without a leader when that is enough.
                var mover = BestMover(date, movable, to, CanSpare, strict: false, NotLead)
                            ?? (LeadsOn(date, to).Count == 0 ? BestMover(date, movable, to, CanSpare, strict: false) : null)
                            ?? BestMover(date, movable, to, CanSpare, strict: false);
                if (mover is null)
                    stuck.Add(to);
                else
                    MoveBy(mover, to, ReasonShiftCover);
            }

            // The targets spread people like Balance (R5) does, so with the days ahead in mind too (EvensOut): nobody is moved
            // onto a shift they would then be held on while that only shifts the lopsided day to later.
            stuck.Clear();
            Ahead? ahead = null;
            while (rules.Select(r => r.ShiftId!.Value)
                       .Where(sh => !stuck.Contains(sh) && target.TryGetValue(sh, out var t) && Count(sh) < t)
                       .OrderBy(sh => Count(sh) - target[sh])
                       .Select(sh => (int?)sh)
                       .FirstOrDefault() is { } to)
            {
                var mover = BestMover(date, movable, to,
                    from => min.ContainsKey(from) && Count(from) > (target.TryGetValue(from, out var t) ? t : min[from]),
                    strict: true,
                    c => NotLead(c) && EvensOut(() => ahead ??= new Ahead(this, date), rules, Count, c, to, HeldAfter(c.EmployeeId, date, to)));
                if (mover is null)
                    stuck.Add(to);
                else
                {
                    MoveBy(mover, to, ReasonShiftCover);
                    ahead = null;
                }
            }

            Balance(date, movable, rules, count, min, MoveBy);

            foreach (var c in movable)
            {
                if (c.ShiftId == start[c.EmployeeId] || c.ReasonCode is not (null or ReasonShiftCover or ReasonShiftBalance or ReasonLeadApart))
                    continue;
                var name = c.ShiftId is { } id && _in.Shifts.TryGetValue(id, out var info) ? info.Name : null;
                c.ReasonCode = movedBy.TryGetValue(c.EmployeeId, out var reason) ? reason : ReasonShiftCover;
                c.ReasonArgs = RosterPlanner.Args(("shift", name ?? string.Empty));
            }
        }

        /// <summary>The shift leaders working <paramref name="shift"/> in the branch that day, as decided so far.</summary>
        private List<GridCell> LeadsOn(DateOnly date, int shift) => _grid.CellsOn(date)
            .Where(c => _in.ShiftLeads.Contains(c.EmployeeId) && c.InBranch && c.CountsAsWorkForRun && c.ShiftId == shift)
            .ToList();

        /// <summary>
        /// The shifts the day's leaders are spread over: the shifts it must cover; and when it covers fewer than two,
        /// those plus every other active shift somebody works in the branch that day (one evening to cover and a
        /// morning that is worked anyway still keep two leaders apart).
        /// </summary>
        private List<int> LeaderShifts(DateOnly date, IReadOnlyList<StaffingRule> rules)
        {
            var shifts = rules.Select(r => r.ShiftId!.Value).ToList();
            if (shifts.Count >= 2)
                return shifts;
            var used = _grid.CellsOn(date)
                .Where(c => c.InBranch && c.CountsAsWorkForRun && c.ShiftId is { } id && _in.IsActiveShift(id) && !shifts.Contains(id))
                .Select(c => c.ShiftId!.Value)
                .Distinct()
                .OrderBy(id => _in.Shifts[id].StartTime)
                .ThenBy(id => id);
            return shifts.Concat(used).ToList();
        }

        /// <summary>
        /// R4 — TWO SHIFT LEADERS NEVER SHARE A SHIFT (<see cref="PlannerInput.ShiftLeads"/>), placed FIRST, before the
        /// minimums and the balance. While a shift holds two leaders or more and another of the day's shifts
        /// (<see cref="LeaderShifts"/>) holds none, one of them - one whose day this run decides - goes to the shift
        /// without a leader: alone when the shift it leaves keeps its minimum (and is the fuller of the two), otherwise
        /// changing places with somebody from there, so both keep their numbers. With nobody to change places with
        /// and a minimum the move would break, the leaders stay together: a leader move never takes a shift below its
        /// minimum, and never makes a turnaround that nothing can undo later, nor a week without its weekly rest (the rest
        /// days just before it decided, <see cref="BreaksWeeklyRestBefore"/>), nor, onto a shift nobody has to cover, a
        /// turnaround or a short weekly rest at all (<see cref="MoveCost"/>), for the leader or the person changing
        /// places. The cheapest move is taken (a likely turnaround costs, so a safe move comes first; then the one that
        /// holds the person on the new shift for the fewest days, <see cref="HeldAfter"/>). So two leaders
        /// share a shift only when more of them work than the day has shifts, when no move is safe, or when somebody
        /// else placed them (all reported, LEADS_SAME_SHIFT). A day with no shift to cover moves nobody (<see cref="Cover"/>
        /// returns first).
        /// </summary>
        private void SeparateLeads(DateOnly date, List<GridCell> movable, List<int> shifts, Dictionary<int, int> count,
            Dictionary<int, int> min, Action<GridCell, int, string> moveBy)
        {
            if (_in.ShiftLeads.Count < 2 || shifts.Count < 2)
                return;
            int Count(int shift) => count.GetValueOrDefault(shift);

            // A move is refused when it breaks a rest rule for certain (a turnaround with the day before, or one the hold it
            // starts must end in - MoveCost's Certain), or when it goes onto a shift nobody has to cover and
            // breaks either rest rule: nobody is kept on such a shift the next day, so a night worked for one day is followed
            // by the person's own morning. It is refused too when the rest days just before it - decided already, like the
            // shift before them - would come out shorter than the weekly rest and are the week's only long enough rest (an
            // evening, one day off, then a morning: 32 hours). On a shift to cover, a turnaround that is only likely or a
            // short rest after the day still just costs (MoveCost): Cover keeps the person on that shift when going back
            // would be too short.
            bool Unsafe(GridCell cell, int to, (double Cost, bool Turnaround, bool ShortRest, bool Certain) move)
                => move.Certain || (!min.ContainsKey(to) && (move.Turnaround || move.ShortRest))
                   || (move.ShortRest && BreaksWeeklyRestBefore(cell.EmployeeId, date, to));

            for (var guard = 0; guard < 2 * shifts.Count; guard++)
            {
                var crowded = shifts.Select(sh => (Shift: sh, Leads: LeadsOn(date, sh)))
                    .Where(x => x.Leads.Count >= 2)
                    .OrderByDescending(x => x.Leads.Count)
                    .FirstOrDefault();
                if (crowded.Leads is null)
                    return;
                var free = shifts.Where(sh => LeadsOn(date, sh).Count == 0).ToList();
                if (free.Count == 0)
                    return;

                var canGoAlone = !min.TryGetValue(crowded.Shift, out var crowdedMin) || Count(crowded.Shift) - 1 >= crowdedMin;
                (GridCell Lead, GridCell? Other, int To, double Cost)? best = null;
                foreach (var lead in crowded.Leads.Where(movable.Contains).OrderBy(c => c.EmployeeId))
                    foreach (var to in free)
                    {
                        // Never an unsafe move, for the leader or whoever changes places with them: leaders that cannot be
                        // moved safely stay together, reported.
                        var leadMove = MoveCost(lead, to, date);
                        if (Unsafe(lead, to, leadMove))
                            continue;
                        // A move holds the person on that shift while going back would be too short a rest: the shorter
                        // the hold, the better (R5 - the shifts' head-counts stay as they were on the following days).
                        var leadCost = leadMove.Cost + HeldAfter(lead.EmployeeId, date, to).Count;
                        var partner = movable
                            .Where(c => c.ShiftId == to && !_in.ShiftLeads.Contains(c.EmployeeId))
                            .Select(c => (Cell: c, Move: MoveCost(c, crowded.Shift, date)))
                            .Where(x => !Unsafe(x.Cell, crowded.Shift, x.Move))
                            .Select(x => (x.Cell, Cost: x.Move.Cost + HeldAfter(x.Cell.EmployeeId, date, crowded.Shift).Count))
                            .OrderBy(x => x.Cost).ThenBy(x => x.Cell.EmployeeId)
                            .Select(x => ((GridCell Cell, double Cost)?)x)
                            .FirstOrDefault();
                        (GridCell? Other, double Cost) option;
                        if (canGoAlone && (partner is null || Count(crowded.Shift) > Count(to)))
                            option = (null, leadCost);
                        else if (partner is { } swap)
                            option = (swap.Cell, leadCost + swap.Cost);
                        else
                            continue;
                        if (best is null || option.Cost < best.Value.Cost - 1e-9)
                            best = (lead, option.Other, to, option.Cost);
                    }
                if (best is not { } pick)
                    return;

                moveBy(pick.Lead, pick.To, ReasonLeadApart);
                if (pick.Other is { } other)
                    moveBy(other, crowded.Shift, ReasonLeadApart);
            }
        }

        /// <summary>
        /// R5 — DIVIDE THE PEOPLE ACROSS THE SHIFTS. After the leaders, the minimums and the targets, the day's working
        /// people are spread over the shifts it must cover so their head-counts differ by one at most - or, when targets
        /// are stored, follow the targets' proportions (a shift without a target weighs its minimum). The fullest shift
        /// gives somebody to the emptiest while that brings them closer (or keeps them as close, for somebody going back
        /// to the shift the generator saved for them: the minimum may have taken a different person this time). Only a working day this run decides moves, never
        /// a shift leader (already placed), never somebody on a shift that is not to be covered, never into a turnaround
        /// shorter than the minimum, and never below the minimum of the shift left, and never somebody who would then be held on
        /// that shift (<see cref="HeldAfter"/>) unless today and the days it holds them on are more even together (<see cref="EvensOut"/>). Who moves (<see cref="BalanceCost"/>):
        /// whoever was on that shift the day before, then whoever it is the home shift of, then whoever moved the least
        /// this month - so over the month the moves are shared - and whoever it would hold there for the fewest days.
        /// </summary>
        private void Balance(DateOnly date, List<GridCell> movable, IReadOnlyList<StaffingRule> rules, Dictionary<int, int> count,
            Dictionary<int, int> min, Action<GridCell, int, string> moveBy)
        {
            if (rules.Count < 2)
                return;
            var shifts = rules.Select(r => r.ShiftId!.Value).ToList();
            var proportional = rules.Any(r => r.TargetOnDuty is not null);
            var weight = rules.ToDictionary(r => r.ShiftId!.Value, r => proportional ? Math.Max(r.TargetOnDuty ?? 0, r.MinOnDuty) : 1d);
            var totalWeight = weight.Values.Sum();
            if (totalWeight <= 0)
                return;
            int Count(int shift) => count.GetValueOrDefault(shift);
            var people = shifts.Sum(Count);
            double Surplus(int shift) => Count(shift) - people * weight[shift] / totalWeight;
            var order = shifts.Select((sh, i) => (sh, i)).ToDictionary(x => x.sh, x => x.i);
            var ring = Math.Max(1, _planned.Count);

            // The days ahead in mind. Somebody moved today onto a shift they cannot leave the next day is HELD on it (StayOn): day
            // after day, until a rest long enough to go back to their own shift - after an evening, a seven o'clock morning needs
            // two days off (one gives 32 hours, under the weekly rest). The way back is refused by the same rules, so a move that
            // evens today out but holds the person on a shift the following days already have their share of turns one even day
            // into a lopsided week, and the moves pile up on the later shift. So a move is made only when it evens out today and the
            // days it holds the person on together (EvensOut, counting everyone already held), not when it trades one lopsided day
            // for another. And the mover whose hold ends soonest (a pair of days off coming) is preferred.
            Ahead? ahead = null;

            for (var guard = 0; guard <= movable.Count * shifts.Count; guard++)
            {
                GridCell? mover = null;
                var moveTo = 0;
                foreach (var from in shifts.OrderByDescending(Surplus).ThenBy(sh => order[sh]))
                {
                    if (min.TryGetValue(from, out var m) && Count(from) - 1 < m)
                        continue;
                    foreach (var to in shifts.OrderBy(Surplus).ThenBy(sh => order[sh]))
                    {
                        // A move that evens the two out; or one that leaves them as even as they were and puts somebody
                        // back on the shift the generator saved for them (ReplanAuto: a regenerate moves nobody else).
                        var gap = Surplus(from) - Surplus(to);
                        if (to == from || gap < 1 - 1e-9)
                            continue;
                        var evens = gap > 1 + 1e-9;
                        var bestCost = double.MaxValue;
                        foreach (var c in movable
                                     .Where(c => c.ShiftId == from && !_in.ShiftLeads.Contains(c.EmployeeId))
                                     .Where(c => evens || SavedShift(c) == to)
                                     .OrderBy(c => RosterCalendar.Mod(_ordinal[c.EmployeeId] + date.DayNumber, ring))
                                     .ThenBy(c => c.EmployeeId))
                        {
                            var (cost, refused) = BalanceCost(c, to, date);
                            if (refused)
                                continue;
                            var held = HeldAfter(c.EmployeeId, date, to);
                            cost += held.Count;
                            if (cost >= bestCost - 1e-9 || (evens && !EvensOut(() => ahead ??= new Ahead(this, date), rules, Count, c, to, held, strict: !proportional)))
                                continue;
                            mover = c;
                            bestCost = cost;
                        }
                        if (mover is not null)
                        {
                            moveTo = to;
                            break;
                        }
                    }
                    if (mover is not null)
                        break;
                }
                if (mover is null)
                    return;
                moveBy(mover, moveTo, ReasonShiftBalance);
                ahead = null;   // the move changes who is held from today
            }
        }

        /// <summary>
        /// Moving <paramref name="c"/> onto <paramref name="to"/> today evens the shifts out over today AND every later day it holds
        /// them there (<paramref name="held"/>, <see cref="HeldAfter"/>): summed over those days, how far each is beyond "within
        /// one" (<see cref="Spread"/> less one, squared) goes down. Squared, so closing a wide gap today is worth opening a
        /// narrower one on a held day (five against two today becomes four against three, while an even day later becomes four
        /// against two), but trading one lopsided day for an equally lopsided one later is not - the moves would pile up on the
        /// later shift with nobody allowed back. <paramref name="strict"/> (an even split, no targets): no held day may even end
        /// up worse and as far apart as today is now - the projection cannot see every later move, so a doubtful trade is not made.
        /// </summary>
        private static bool EvensOut(Func<Ahead> ahead, IReadOnlyList<StaffingRule> rules, Func<int, int> count, GridCell c, int to, List<DateOnly> held, bool strict = false)
        {
            // Within one is even; beyond it, each person further apart weighs more than the one before.
            static double Uneven(double spread) => Math.Pow(Math.Max(0, spread - 1), 2);
            var from = c.ShiftId!.Value;
            var today = Spread(rules, count);
            var change = Uneven(Spread(rules, s => count(s) + (s == to ? 1 : 0) - (s == from ? 1 : 0))) - Uneven(today);
            foreach (var day in held)
            {
                var (without, with) = ahead().Spreads(day, c.EmployeeId, to);
                if (strict && with > without + 1e-9 && with >= today - 1e-9)
                    return false;
                change += Uneven(with) - Uneven(without);
            }
            return change < -1e-9;
        }

        /// <summary>
        /// How far apart a day's shifts are: the fullest one's surplus over its share less the emptiest one's, in people - the
        /// shares even, or following the targets when the day has any (a shift without one weighs its minimum). 0 with fewer
        /// than two shifts.
        /// </summary>
        private static double Spread(IReadOnlyList<StaffingRule> rules, Func<int, int> count)
        {
            if (rules.Count < 2)
                return 0;
            var proportional = rules.Any(r => r.TargetOnDuty is not null);
            double Weight(StaffingRule r) => proportional ? Math.Max(r.TargetOnDuty ?? 0, r.MinOnDuty) : 1d;
            var total = rules.Sum(Weight);
            if (total <= 0)
                return 0;
            var people = rules.Sum(r => count(r.ShiftId!.Value));
            var surplus = rules.Select(r => count(r.ShiftId!.Value) - people * Weight(r) / total).ToList();
            return surplus.Max() - surplus.Min();
        }

        /// <summary>
        /// HELD: the days after <paramref name="date"/> on which somebody who works <paramref name="shift"/> that day would start on
        /// it again (<see cref="StayOn"/>) - each working day this run decides, in the month, whose own shift is another one that
        /// would start too soon after their last day on <paramref name="shift"/> (less than the minimum hours after a working day,
        /// less than the minimum weekly rest after rest days), while <paramref name="shift"/> is still a shift to cover. Read from
        /// the rest days, which are all decided before any shift is. A hold still in force at the month's end goes on into the next
        /// month: that month's run counts the person on the shift they are held on when it places its rest days (<see cref="CarriedHold"/>).
        /// </summary>
        private List<DateOnly> HeldAfter(int e, DateOnly date, int shift) => HoldAfter(e, date, shift).Days;

        /// <summary>
        /// What a hold comes to: the days it keeps somebody on a shift (<see cref="HeldAfter"/>), and whether the day it ends sends
        /// them back TOO SOON - nothing can keep them on the shift that day (it is not a shift to cover then, or the day's shift is
        /// fixed already) while going back still breaks a rest rule: a TURNAROUND right after a held day, or a weekly rest shorter
        /// than the minimum (<see cref="ShortWeeklyRest"/>) after rest days. A night covered only at the weekend is the usual case:
        /// held on Sunday's night after Saturday's, the person must be back on their own shift on Monday, or on Tuesday after one
        /// day off - eight or 24 hours after the night. <c>Certain</c>: that day is in the month (decided); the first day of the
        /// next month is only read as worked on their own shift (its run decides it), so a breach there is likely, not certain.
        /// </summary>
        private readonly record struct Hold(List<DateOnly> Days, bool Turnaround, bool ShortRest, bool Certain);

        /// <summary>
        /// The <see cref="Hold"/> of somebody who works <paramref name="shift"/> on <paramref name="date"/>. <paramref name="works"/>
        /// reads the days of a week whose rest days are still being chosen (<see cref="ProjectHolds"/>): true works (on their own
        /// shift, unless the hold keeps them), false rests, null as decided. The walk stops after <paramref name="until"/>, or on
        /// the first day of the next month: that month's run carries a hold on (<see cref="CarriedHold"/>) on a shift it covers.
        /// </summary>
        private Hold HoldAfter(int e, DateOnly date, int shift, Func<DateOnly, bool?>? works = null, DateOnly? until = null)
        {
            var held = new List<DateOnly>();
            var worked = new Dictionary<DateOnly, int>();
            var end = until is { } u && u < _in.MonthEnd ? u : _in.MonthEnd.AddDays(1);
            if (works is not null)
                for (var d = date.AddDays(-3); d <= end.AddDays(9); d = d.AddDays(1))
                    if (works(d) == true && HomeShift(e, d) is { } home)
                        worked[d] = home;
            worked[date] = shift;
            var minGap = TimeSpan.FromHours(_in.Settings.MinHoursBetweenShifts);
            var last = date;
            for (var d = date.AddDays(1); d <= end; d = d.AddDays(1))
            {
                var dayAfter = d == last.AddDays(1);
                if (_in.HoursOn(shift, last) is not { } then)
                    break;
                bool TooSoon(int back)
                    => _in.HoursOn(back, d) is { } hours
                       && (dayAfter ? hours.StartOn(d) - then.EndOn(last) < minGap : ShortWeeklyRest(e, then, last, d, back, worked));

                if (d > _in.MonthEnd)
                {
                    // The next month's first day. Its run keeps them on the shift if it covers it that day; if it does not, they
                    // are back on their own shift: read as worked there, whatever that month's rows say - they may be saved only
                    // after this month, and the answer must not change then (D11). A holiday there may be covered or not: unknown.
                    if (!_in.Holidays.ContainsKey(d) && _in.CoverRulesFor(d).All(r => r.ShiftId != shift) && _in.LeaveOn(e, d) == LeaveKind.None
                        && HomeShift(e, d) is { } next && next != shift && TooSoon(next))
                        return new Hold(held, dayAfter, !dayAfter, Certain: false);
                    break;
                }

                var c = d >= _in.WindowFrom ? _grid[e, d] : null;
                if (!(works?.Invoke(d) ?? c is { CountsAsWorkForRun: true }))
                {
                    if (works?.Invoke(d) == false || KnownRest(e, d))
                        continue;
                    break;
                }
                if (c is null || c.Kind == CellKind.Ghost)
                    break;

                var own = HomeShift(e, d);
                if (c is { IsFact: false, ShiftId: null, Leave: LeaveKind.None } && own is { } o && o != shift
                    && _in.CoverRulesFor(d).Any(r => r.ShiftId == shift))
                {
                    if (!TooSoon(o))
                        break;
                    held.Add(d);
                    worked[d] = shift;
                    last = d;
                    continue;
                }

                // Nothing keeps them on the shift today (not a shift to cover, or the day's shift is fixed): the shift they work
                // instead - the fixed one, or their own - may still come too soon.
                if ((c.ShiftId ?? own) is { } instead && instead != shift && TooSoon(instead))
                    return new Hold(held, dayAfter, !dayAfter, Certain: true);
                break;
            }
            return new Hold(held, false, false, false);
        }

        /// <summary>
        /// The days after the one being balanced as Cover will start them if nobody else moves: each working person on a fixed
        /// or decided shift, else - while held (<see cref="HeldAfter"/> from their last working day so far) - the shift they are
        /// held on, else a leader on the earlier shift they stay on (<see cref="LeaderStaysOn"/>), else their own. <see cref="Spreads"/> tells how far apart a day's shifts would be, as projected and with one person moved.
        /// </summary>
        private sealed class Ahead
        {
            private readonly Run _run;
            private readonly Dictionary<(int Employee, DateOnly Date), int> _shift = new();
            private readonly Dictionary<DateOnly, Dictionary<int, int>> _count = new();

            public Ahead(Run run, DateOnly date)
            {
                _run = run;
                var input = run._in;
                var leads = new Dictionary<int, int>();
                foreach (var person in run._grid.Staff)
                {
                    var e = person.EmployeeId;
                    (int Shift, DateOnly Date)? last = null;
                    for (var d = date; d >= date.AddDays(-4) && last is null; d = d.AddDays(-1))
                        if (run.ShiftOn(e, d) is { } on)
                            last = (on.Shift.ShiftId, d);
                    if (last is not { } l)
                        continue;
                    foreach (var d in run.HeldAfter(e, l.Date, l.Shift))
                        _shift[(e, d)] = l.Shift;
                    if (run.LeaderStaysOn(e, date.AddDays(1)) is { } stay)
                        leads[e] = stay;
                }
                for (var d = date.AddDays(1); d <= input.MonthEnd && d <= input.WindowTo; d = d.AddDays(1))
                {
                    var count = _count[d] = new Dictionary<int, int>();
                    var rules = input.CoverRulesFor(d);
                    foreach (var c in run._grid.CellsOn(d))
                    {
                        if (!c.InBranch || !c.CountsAsWorkForRun)
                            continue;
                        // A fixed or decided shift; else held; else a leader's stay on an earlier shift (Cover); else their own.
                        var projected = c.ShiftId
                                        ?? (_shift.TryGetValue((c.EmployeeId, d), out var held) ? held
                                            : leads.TryGetValue(c.EmployeeId, out var lead) && rules.Any(r => r.ShiftId == lead) ? lead
                                            : run.StartShift(c));
                        if (projected is not { } s)
                            continue;
                        _shift[(c.EmployeeId, d)] = s;
                        count[s] = count.GetValueOrDefault(s) + 1;
                    }
                }
            }

            /// <summary>How many people the day has on <paramref name="shift"/> as projected, <paramref name="except"/> left out.</summary>
            public int On(DateOnly day, int shift, int except)
                => _count.TryGetValue(day, out var count)
                    ? count.GetValueOrDefault(shift) - (_shift.TryGetValue((except, day), out var s) && s == shift ? 1 : 0)
                    : 0;

            /// <summary>
            /// As the day is projected, somebody besides <paramref name="except"/> could take a place on <paramref name="shift"/> the
            /// way Cover's stay step counts on it: a working day the shift cover decides, on a shift that can spare them (not one to
            /// cover, or above its minimum), and no turnaround after their shift the day before.
            /// </summary>
            public bool CanFill(DateOnly day, int shift, int except)
            {
                var input = _run._in;
                if (!_count.TryGetValue(day, out var count) || input.HoursOn(shift, day) is not { } to)
                    return false;
                var rules = input.CoverRulesFor(day);
                var minGap = TimeSpan.FromHours(input.Settings.MinHoursBetweenShifts);
                foreach (var c in _run._grid.CellsOn(day))
                {
                    if (c.EmployeeId == except || !c.InBranch || !c.CountsAsWorkForRun || c.IsFact || c.ShiftId is not null
                        || c.Leave != LeaveKind.None || c.Kind == CellKind.Ghost
                        || !_shift.TryGetValue((c.EmployeeId, day), out var from) || from == shift)
                        continue;
                    if (rules.FirstOrDefault(r => r.ShiftId == from) is { } rule && count.GetValueOrDefault(from) <= rule.MinOnDuty)
                        continue;
                    var before = day.AddDays(-1);
                    int? then = _shift.TryGetValue((c.EmployeeId, before), out var projected) ? projected : _run.ShiftOn(c.EmployeeId, before)?.Shift.ShiftId;
                    if (then is { } t && input.HoursOn(t, before) is { } hours && to.StartOn(day) - hours.EndOn(before) < minGap)
                        continue;
                    return true;
                }
                return false;
            }

            /// <summary>The day's <see cref="Spread"/> as projected, and with <paramref name="e"/> on <paramref name="shift"/> instead of where they would start.</summary>
            public (double Without, double With) Spreads(DateOnly day, int e, int shift)
            {
                var rules = _run._in.CoverRulesFor(day);
                if (!_count.TryGetValue(day, out var count))
                    return (0, 0);
                int? own = _shift.TryGetValue((e, day), out var s) ? s : null;
                return (Spread(rules, id => count.GetValueOrDefault(id)),
                        Spread(rules, id => count.GetValueOrDefault(id) + (id == shift ? 1 : 0) - (id == own ? 1 : 0)));
            }
        }

        /// <summary>
        /// Somebody kept on <paramref name="shift"/> today after rest days can stay held on it TOMORROW (<see cref="HoldAfter"/>): their
        /// own shift keeps its minimum without them as tomorrow is projected (<paramref name="ahead"/>), or somebody else could take
        /// the place (<see cref="Ahead.CanFill"/>) - and the hold does not end in a breach tomorrow anyway (a shift not covered then,
        /// <see cref="Hold"/>). A rest day before the next held day: the same question is asked again that day. Only tomorrow:
        /// further ahead the projection cannot see the moves Cover will still make, and a hold judged unable to last too soon
        /// costs a weekly rest for nothing.
        /// </summary>
        private bool HoldLasts(int e, DateOnly date, int shift, Ahead ahead)
        {
            var hold = HoldAfter(e, date, shift);
            var tomorrow = date.AddDays(1);
            if (hold.Days.Count == 0)
                return !(hold.Turnaround && hold.Certain);
            if (hold.Days[0] != tomorrow)
                return true;
            return !(HomeShift(e, tomorrow) is { } home && _in.CoverRulesFor(tomorrow).FirstOrDefault(r => r.ShiftId == home) is { } rule
                     && ahead.On(tomorrow, home, e) < rule.MinOnDuty && !ahead.CanFill(tomorrow, home, e));
        }

        /// <summary>
        /// What a balancing move costs: <see cref="MoveCost"/> - REFUSED when it makes a turnaround or a weekly rest shorter than
        /// the minimum (evening the shifts out never breaks a rest rule) - less 6 for the shift worked the day before (a run of
        /// days on one shift is kept) and 3 for the person's home shift, plus 4 for leaving the shift worked the day before and 2
        /// for leaving the home shift.
        /// </summary>
        private (double Cost, bool Refused) BalanceCost(GridCell cell, int to, DateOnly date)
        {
            var (cost, turnaround, shortRest, _) = MoveCost(cell, to, date);
            var refused = turnaround || shortRest;
            var from = cell.ShiftId!.Value;
            if (ShiftOn(cell.EmployeeId, date.AddDays(-1)) is { } before)
            {
                if (before.Shift.ShiftId == to)
                    cost -= 6;
                else if (before.Shift.ShiftId == from)
                    cost += 4;
            }
            var home = HomeShift(cell.EmployeeId, date);
            if (home == to)
                cost -= 3;
            else if (home == from)
                cost += 2;
            return (cost, refused);
        }

        /// <summary>
        /// A ghost day after the month: nothing has to be covered there (the next month's run decides it),
        /// but someone who covered a shift on the month's last day does not go back to their own the next
        /// morning on paper either — the turnaround would be reported against the month.
        /// </summary>
        private void StayAfterCover(DateOnly date, List<GridCell> open)
        {
            foreach (var c in open.Where(c => c.Kind == CellKind.Ghost && c.Leave == LeaveKind.None))
                if (c.ShiftId is { } current && StayOn(c.EmployeeId, date, current) is { } stay)
                    c.ShiftId = stay;
        }

        /// <summary>
        /// The shift somebody starting on <paramref name="current"/> today should stay on instead: the one they worked on their
        /// last working day, when that was not their own shift (moved to cover or balance it, or put there by hand) and going
        /// back to their own today would leave too short a rest — less than the minimum hours between two shifts after the
        /// day before, or, after one or two rest days, less than the minimum weekly rest (an evening, a day off, then a
        /// seven o'clock morning is a 32-hour rest). Null: go back to their own.
        /// </summary>
        private int? StayOn(int e, DateOnly date, int current)
        {
            if (_in.HoursOn(current, date) is not { } now)
                return null;
            var yesterday = date.AddDays(-1);
            if (ShiftOn(e, yesterday) is { } before)
            {
                return before.Shift.ShiftId != current
                       && before.Shift.ShiftId != HomeShift(e, yesterday)
                       && now.StartOn(date) - before.Shift.EndOn(yesterday) < TimeSpan.FromHours(_in.Settings.MinHoursBetweenShifts)
                    ? before.Shift.ShiftId
                    : null;
            }

            // After rest days: the last shift before them (a ghost day is the next month's to decide: unknown) - held only when
            // going back would leave the week without its weekly rest. After an evening, one day off before a morning is 32 hours:
            // too short in a 6-day week, but no breach in a week whose other day off gives a long rest.
            return LastShiftBeforeRest(e, date) is { } last
                   && last.Shift.ShiftId != current
                   && last.Shift.ShiftId != HomeShift(e, last.Date)
                   && ShortWeeklyRest(e, last.Shift, last.Date, date, current, null)
                ? last.Shift.ShiftId
                : null;
        }

        /// <summary>
        /// R4: the shift a shift leader stays on today - the one of their last working day (the day before, or the last one before
        /// their rest days), when that was a shift starting EARLIER than their own (moved there to keep the leaders apart, or
        /// saved so last month) and the branch has more than one leader. Null: their own shift.
        /// Only an earlier shift: the move onto it is the hard one to make again - right after a day on their own shift it is a
        /// turnaround, after one rest day a short weekly rest - while the way back is always open, so a leader sent home would
        /// soon be stuck beside the other one. A leader moved onto a LATER shift goes home when the rest rules allow
        /// (<see cref="StayOn"/>): moving them out again later is always possible, and leaving the earlier shifts their leaders
        /// keeps every later clash one that such a move can fix.
        /// The saved rows carry no reason, so any such shift counts: next month the leader starts where this month left them,
        /// and once the most frequent shift before the window (<see cref="MostFrequentShift"/>) is that one, it is their own.
        /// </summary>
        private int? LeaderStaysOn(int e, DateOnly date)
        {
            if (_in.ShiftLeads.Count < 2 || !_in.ShiftLeads.Contains(e))
                return null;
            var last = ShiftOn(e, date.AddDays(-1)) ?? LastShiftBeforeRest(e, date);
            return last is { } l && HomeShift(e, l.Date) is { } home && l.Shift.ShiftId != home
                   && _in.HoursOn(home, l.Date) is { } own && l.Shift.StartTime < own.StartTime
                ? l.Shift.ShiftId
                : null;
        }

        /// <summary>
        /// The person (of those <paramref name="who"/> allows) to move onto <paramref name="to"/> from a shift <paramref name="canSpare"/>
        /// allows: one whose move breaks no rest rule whenever there is one, then one whose breach is only likely (the stay step
        /// may still undo it), a certain breach last (<see cref="MoveCost"/>) - and among those the cheapest; ties turn with the
        /// day. <paramref name="strict"/>: a turnaround or a certain breach is never taken.
        /// </summary>
        private GridCell? BestMover(DateOnly date, List<GridCell> movable, int to, Func<int, bool> canSpare, bool strict, Func<GridCell, bool>? who = null)
        {
            GridCell? best = null;
            var bestRank = (Breach: int.MaxValue, Cost: double.MaxValue);
            var people = Math.Max(1, _planned.Count);
            foreach (var c in movable
                         .Where(c => c.ShiftId is { } from && from != to && canSpare(from) && (who is null || who(c)))
                         .OrderBy(c => RosterCalendar.Mod(_ordinal[c.EmployeeId] + date.DayNumber, people))
                         .ThenBy(c => c.EmployeeId))
            {
                var (cost, turnaround, shortRest, certain) = MoveCost(c, to, date);
                if (strict && (turnaround || certain))
                    continue;
                var breach = certain ? 2 : turnaround || shortRest ? 1 : 0;
                if (breach < bestRank.Breach || (breach == bestRank.Breach && cost < bestRank.Cost - 1e-9))
                {
                    best = c;
                    bestRank = (breach, cost);
                }
            }
            return best;
        }

        /// <summary>
        /// What moving a person onto shift <paramref name="to"/> costs, largest first:
        ///   - 50 for a TURNAROUND: less than RosterMinHoursBetweenShifts after the shift worked the day
        ///     before, or before the one the day after when the person could not stay on this shift then
        ///     (a day this run does not decide cannot be stayed on);
        ///   - 20 when the next day is a rest and the shift after it would start less than
        ///     RosterMinWeeklyRestHours after this one ends (an evening, one day off, then a morning), and
        ///     20 the same way when the day before was a rest and the last shift before it ended too late,
        ///     or when the move leaves a week without a rest of that length at all (<see cref="TakesWeeklyRest"/>);
        ///   - 10 for leaving a shift nobody has to cover (a night worker covering a morning is the last resort);
        ///   - 8 for leaving the shift the generator saved there — and −8 for going back to it, so a
        ///     regenerate moves the same people as before;
        ///   - 4 for leaving the weekly pattern's shift, and 4 when the person will stay on this shift
        ///     tomorrow too (going back would be a turnaround: <see cref="Cover"/> keeps them on it);
        ///   - 3 per day the person already worked off their own shift this month (moves are shared);
        ///   - 2 for a shift the person has not worked in the last eight weeks.
        /// The flags: <c>Turnaround</c> and <c>ShortRest</c> for the two rest rules above, and <c>Certain</c> for a breach
        /// nothing can undo later (a turnaround with the day before, or with a day after that cannot be stayed on; or either rule
        /// broken on the day the hold the move starts ends, <see cref="Hold"/>) - the others are only likely: the stay step of
        /// <see cref="Cover"/> keeps a person on a shift to cover when going back would be too short.
        /// </summary>
        private (double Cost, bool Turnaround, bool ShortRest, bool Certain) MoveCost(GridCell cell, int to, DateOnly date)
        {
            var e = cell.EmployeeId;
            var from = cell.ShiftId!.Value;
            var shift = _in.HoursOn(to, date)!;   // R1: the hours in force that day
            var minGap = TimeSpan.FromHours(_in.Settings.MinHoursBetweenShifts);
            double cost = 0;
            var turnaround = false;
            var shortRest = false;
            var certain = false;

            // The day before as decided. A ghost day before the month (the previous month's run decides it; nothing is saved
            // there yet) is read as worked on the person's own shift, as ShortWeeklyRest reads a day nobody has decided: read as
            // nothing, an evening person was moved onto the morning right after it - a turnaround if that day is worked, a
            // 32-hour weekly rest if it is a rest. Only likely, not certain: the previous month's run may yet decide it otherwise,
            // so it keeps the balancing from such a move but does not on its own keep two leaders together.
            var dayBefore = date.AddDays(-1);
            var decided = ShiftOn(e, dayBefore);
            var known = decided
                        ?? (dayBefore < _in.MonthStart && Unknown(e, dayBefore) && HomeShift(e, dayBefore) is { } own
                            && _in.HoursOn(own, dayBefore) is { } ownHours ? (ownHours, dayBefore) : null);
            if (known is { } before)
            {
                if (shift.StartOn(date) - before.Shift.EndOn(before.Date) < minGap)
                {
                    turnaround = true;
                    certain = decided is not null;   // the day before is decided already
                    cost += 50;
                }
            }
            else if (LastShiftBeforeRest(e, date) is { } last
                     && shift.StartOn(date) - last.Shift.EndOn(last.Date) < TimeSpan.FromHours(_in.Settings.MinWeeklyRestHours))
            {
                cost += 20;   // the rest days just taken would come out shorter than the weekly rest (an evening, a day off, a morning)
                shortRest = true;
            }

            var next = date.AddDays(1);
            if (ShiftOn(e, next) is { } after)
            {
                if (after.Shift.StartOn(next) - shift.EndOn(date) < minGap)
                {
                    // Staying on this shift tomorrow is possible only on a day this run still decides (not a saved row,
                    // a draft edit or a leave day's row with its own shift).
                    var decides = next > _in.WindowTo || _grid[e, next] is { IsFact: false, ShiftId: null, Leave: LeaveKind.None };
                    if (decides && CanStayOn(to, next, after.Shift.ShiftId))
                        cost += 4;
                    else
                    {
                        turnaround = true;
                        cost += 50;

                        // Certain when nothing can keep them on it tomorrow: a day this run does not decide, or a shift
                        // tomorrow does not cover (Cover keeps nobody there). A shift left tomorrow that cannot spare them
                        // only as the day stands so far may still be helped by the time tomorrow is planned. (|=: a
                        // turnaround with the day before stays certain.)
                        certain |= !decides || _in.CoverRulesFor(next).All(r => r.ShiftId != to);
                    }
                }
            }
            else if (FirstShiftAfterRest(e, next) is { } back
                     && back.Shift.StartOn(back.Date) - shift.EndOn(date) < TimeSpan.FromHours(_in.Settings.MinWeeklyRestHours))
            {
                cost += 20;
                shortRest = true;
            }

            // Long enough rests can still leave a week without one: the validator gives a rest to the week its middle falls
            // in, so an evening before Sunday and Monday off moves a morning person's long rest into the next week.
            if (!shortRest && !turnaround && TakesWeeklyRest(e, date, from, to))
            {
                cost += 20;
                shortRest = true;
            }

            // Further ahead, the day the hold this move starts ends (HoldAfter): when nothing can keep the person on the shift
            // then - it is not covered that day (a night covered only at the weekend), or that day's shift is fixed - while going
            // back still breaks a rest rule, a turnaround after a held day or a short weekly rest after rest days follows. The rest
            // days are decided before any shift, so nothing undoes it: CERTAIN (likely only on the next month's first day).
            var hold = HoldAfter(e, date, to);
            if (hold.Turnaround || hold.ShortRest)
            {
                if (!turnaround && !shortRest)
                    cost += hold.Turnaround ? 50 : 20;
                turnaround |= hold.Turnaround;
                shortRest |= hold.ShortRest;
                certain |= hold.Certain;
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
            return (cost, turnaround, shortRest, certain);
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

        /// <summary>
        /// The last shift worked before a run of rest days ending the day before <paramref name="date"/> (null when that day is
        /// not a rest, or nothing is known). It reads back past the window's first day too: rest days at the start of a month
        /// follow the previous month's saved rows, and the rest they make is just as short. A ghost day is unknown, rest or
        /// work: it is the next month's to decide and may be decided differently by the next run, so nothing here hangs on it
        /// (a regenerate must move nobody).
        /// </summary>
        private (ShiftInfo Shift, DateOnly Date)? LastShiftBeforeRest(int e, DateOnly date)
        {
            for (var d = date.AddDays(-1); d >= date.AddDays(-4); d = d.AddDays(-1))
            {
                if (ShiftOn(e, d) is { } worked)
                    return d == date.AddDays(-1) ? null : worked;
                if (!KnownRest(e, d))
                    return null;
            }
            return null;
        }

        /// <summary>
        /// Working <paramref name="to"/> on <paramref name="date"/> right after rest days would make that rest shorter than the
        /// weekly minimum, and the week it belongs to would then have no rest that long at all: a WEEKLY_REST_HOURS warning for
        /// certain, since the rest days and the shift before them are decided already (<see cref="ShortWeeklyRest"/>).
        /// </summary>
        private bool BreaksWeeklyRestBefore(int e, DateOnly date, int to)
            => LastShiftBeforeRest(e, date) is { } last && ShortWeeklyRest(e, last.Shift, last.Date, date, to, null);

        /// <summary>
        /// The rest from <paramref name="last"/> (worked on <paramref name="lastDate"/>) to <paramref name="to"/> on
        /// <paramref name="date"/> is shorter than the weekly minimum AND the week it belongs to (by its midpoint, as the validator
        /// reads it) has no other rest that long. The validator asks for the week's LONGEST rest, so a short rest in a week that
        /// keeps a long one elsewhere (a 5-day week's other day off) breaks nothing. Only a long rest that is KNOWN counts: a day
        /// nobody has decided yet (a ghost day, a day after the window with no row) is taken as worked on the person's own shift,
        /// or next month's run would find the breach. <paramref name="worked"/>: days to read on these shifts instead of as
        /// decided (a hold being projected).
        /// </summary>
        private bool ShortWeeklyRest(int e, ShiftInfo last, DateOnly lastDate, DateOnly date, int to, IReadOnlyDictionary<DateOnly, int>? worked)
        {
            var weekly = TimeSpan.FromHours(_in.Settings.MinWeeklyRestHours);
            if (_in.HoursOn(to, date) is not { } shift)
                return false;
            var end = last.EndOn(lastDate);
            var start = shift.StartOn(date);
            if (start - end >= weekly)
                return false;
            var week = RosterCalendar.WeekStart(DateOnly.FromDateTime(end + (start - end) / 2));
            return LongestRestInWeek(week, d => d == date ? shift
                : worked is not null && worked.TryGetValue(d, out var id) ? _in.HoursOn(id, d)
                : ShiftOn(e, d)?.Shift ?? (Unknown(e, d) && HomeShift(e, d) is { } own ? _in.HoursOn(own, d) : null)) < weekly;
        }

        /// <summary>
        /// Working <paramref name="to"/> instead of <paramref name="from"/> on <paramref name="date"/> leaves a week without a rest
        /// of the weekly minimum that it had: the rests either side of the day change length, and their middle - which decides
        /// the week a rest belongs to, as the validator reads it - may cross Sunday night. Days are read as in
        /// <see cref="ShortWeeklyRest"/> (a day nobody has decided: worked on the person's own shift).
        /// </summary>
        private bool TakesWeeklyRest(int e, DateOnly date, int from, int to)
        {
            var weekly = TimeSpan.FromHours(_in.Settings.MinWeeklyRestHours);
            ShiftInfo? Read(DateOnly d) => ShiftOn(e, d)?.Shift ?? (Unknown(e, d) && HomeShift(e, d) is { } own ? _in.HoursOn(own, d) : null);
            foreach (var week in new[] { date.AddDays(-3), date, date.AddDays(3) }.Select(RosterCalendar.WeekStart).Distinct())
                if (LongestRestInWeek(week, d => d == date ? _in.HoursOn(from, d) : Read(d)) >= weekly
                    && LongestRestInWeek(week, d => d == date ? _in.HoursOn(to, d) : Read(d)) < weekly)
                    return true;
            return false;
        }

        /// <summary>
        /// Nobody has decided the day yet: a ghost day, the same day once today has passed it unsaved (a window day outside the
        /// month with no row - read the same either way, or a regenerate would move somebody), or a day after the window with no row.
        /// </summary>
        private bool Unknown(int e, DateOnly date)
            => date > _in.WindowTo
                ? _in.RowOf(e, date) is null
                : date >= _in.WindowFrom && _grid[e, date] is { Kind: CellKind.Ghost } or { Kind: CellKind.Outside, Current: null };

        /// <summary>
        /// The longest rest between shifts that belongs to the week of <paramref name="weekStart"/> (its midpoint falls in it), as
        /// the validator measures it, from the shift <paramref name="on"/> gives each day (null: none, so a rest).
        /// </summary>
        private static TimeSpan LongestRestInWeek(DateOnly weekStart, Func<DateOnly, ShiftInfo?> on)
        {
            var from = weekStart.ToDateTime(TimeOnly.MinValue);
            var to = weekStart.AddDays(7).ToDateTime(TimeOnly.MinValue);
            var previousEnd = weekStart.AddDays(-2).ToDateTime(TimeOnly.MinValue);
            var longest = TimeSpan.Zero;
            var first = true;
            for (var d = weekStart.AddDays(-2); d <= weekStart.AddDays(8); d = d.AddDays(1))
            {
                if (on(d) is not { } shift)
                    continue;
                var gap = shift.StartOn(d) - previousEnd;
                var middle = previousEnd + gap / 2;
                if (gap > longest && (first ? shift.StartOn(d) > from : middle >= from && middle < to))
                    longest = gap;
                previousEnd = shift.EndOn(d) > previousEnd ? shift.EndOn(d) : previousEnd;
                first = false;
            }
            var open = weekStart.AddDays(9).ToDateTime(TimeOnly.MinValue) - previousEnd;
            return previousEnd < to && open > longest ? open : longest;
        }

        /// <summary>
        /// A day known to be a rest that counts: a window day decided as one (a ghost day is unknown), or before the window a
        /// saved rest row without leave.
        /// </summary>
        private bool KnownRest(int e, DateOnly date)
            => date >= _in.WindowFrom
                ? _grid[e, date] is { Kind: not CellKind.Ghost, CountsAsRest: true }
                : _in.IsEmployed(e, date) && _in.RowOf(e, date) is { IsRestDay: true } && _in.LeaveOn(e, date) == LeaveKind.None;

        /// <summary>
        /// The first shift worked after a run of rest days starting on <paramref name="date"/> (null when the day is not a rest, or
        /// nothing is known). Only the month's days: the next month's are its run's to decide, and read here they would change the
        /// answer once that month is saved after this one - a regenerate would then move somebody (D11). That run reads this
        /// month's last shift itself when it plans the days after the rest (<see cref="StayOn"/>, <see cref="CarriedHold"/>).
        /// </summary>
        private (ShiftInfo Shift, DateOnly Date)? FirstShiftAfterRest(int e, DateOnly date)
        {
            for (var d = date; d <= date.AddDays(3) && d <= _in.MonthEnd; d = d.AddDays(1))
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
        /// The shift someone works on a day, for the turnaround — with the hours in force ON that day (R1,
        /// <see cref="PlannerInput.HoursOn"/>): a window day as decided so far (a working
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
            return id is { } shiftId && _in.HoursOn(shiftId, date) is { } info ? (info, date) : null;
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

        /// <summary>
        /// The employee's most frequent active shift in the 8 weeks before the window, the last 4 counting double (ties: the
        /// latest used, then the lowest id). The weeks before keep a week or two of cover or balancing on another shift - the
        /// planner's own moves, saved last month - from making that shift the person's own: a morning person held on the
        /// evening for half of December is still a morning person in January. A real change of shift wins within a month.
        /// </summary>
        private int? MostFrequentShift(int e)
        {
            var recent = _in.WindowFrom.AddDays(-28);
            return RosterCalendar.Days(_in.WindowFrom.AddDays(-56), _in.WindowFrom.AddDays(-1))
                .Select(d => (Date: d, Row: _in.RowOf(e, d)))
                .Where(x => x.Row is { IsWork: true } r && _in.IsActiveShift(r.ShiftId))
                .GroupBy(x => x.Row!.Value.ShiftId!.Value)
                .OrderByDescending(g => g.Sum(x => x.Date >= recent ? 2 : 1))
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
