using System.Globalization;
using MokaCo.HRMS.Model.Attendance;

namespace MokaCo.HRMS.Services.Attendance.AutoRoster;

/// <summary>One week of one employee's 6/5 rhythm, measured on a grid.</summary>
public sealed record WeekCheck(
    DateOnly WeekStart, int WorkDays, int Quota, int Rests, int Open, int Over, int Absorbed, int Short)
{
    /// <summary>Exactly the quota, or short only by rests a leave absorbed.</summary>
    public bool Ok => Over == 0 && Short == 0;
}

/// <summary>
/// The §2.7 rules, checked on a grid — the planner's result, or (<see cref="ValidateSubmission"/>)
/// the rows a commit would leave behind. ONE implementation for both, so the preview and the save
/// can never disagree about what is an error.
///
/// It reports, it never repairs. Errors block the commit (400); warnings and infos are shown and
/// saved past. A rule broken only by facts (rows this run may not touch) is at most a warning: the
/// manager cannot be stopped from saving by something the save does not change.
/// </summary>
public static class RosterPlanValidator
{
    public const string Error = "error";
    public const string Warning = "warning";
    public const string Info = "info";

    public const string MonthLocked = "MONTH_LOCKED";
    public const string WorkWithoutShift = "WORK_WITHOUT_SHIFT";
    public const string RestOnHoliday = "REST_ON_HOLIDAY";
    public const string ConsecutiveCap = "CONSECUTIVE_CAP";
    public const string HolidayHiddenByRest = "HOLIDAY_HIDDEN_BY_REST";
    public const string RhythmShort = "RHYTHM_SHORT";
    public const string RhythmOver = "RHYTHM_OVER";
    public const string RestAbsorbedByLeave = "REST_ABSORBED_BY_LEAVE";
    public const string ShortStaffed = "SHORT_STAFFED";
    public const string ShiftUncovered = "SHIFT_UNCOVERED";
    public const string Turnaround = "TURNAROUND";
    public const string WeeklyRestHours = "WEEKLY_REST_HOURS";
    public const string PatternRestWorked = "PATTERN_REST_WORKED";
    public const string LongRun = "LONG_RUN";

    /// <summary>Every issue of a decided grid, sorted (errors first, then by date, employee, code).</summary>
    public static List<AutoRosterIssue> Validate(PlannerInput input, RosterGrid grid, IReadOnlyDictionary<int, ResolvedRhythm> rhythms)
    {
        var issues = new List<AutoRosterIssue>();
        if (input.MonthLocked)
            issues.Add(Issue(Error, MonthLocked, null, null,
                "A roster approval is waiting for this month — it is read-only until the request is decided."));

        CheckCells(input, grid, issues);
        foreach (var employee in grid.Staff)
        {
            if (!rhythms.TryGetValue(employee.EmployeeId, out var rhythm))
                continue;
            CheckRuns(input, grid, employee.EmployeeId, issues);
            CheckWeeks(input, grid, rhythm, issues);
            CheckShiftTiming(input, grid, employee.EmployeeId, issues);
        }
        CheckStaffing(input, grid, issues);
        return Sort(issues);
    }

    /// <summary>
    /// The commit's server-side check: the rows as they stand, with <paramref name="cells"/> applied
    /// on top (upsert / delete), validated with the same rules as the preview. Ghost days are open —
    /// next month's run decides them — so they never make a week short or a run too long here.
    /// <paramref name="rhythm"/> (the commit's rhythm rows) overrides the anchors it would resolve.
    /// Cells outside the month or the branch are skipped: the procedure refuses them by name.
    /// </summary>
    public static List<AutoRosterIssue> ValidateSubmission(
        PlannerInput input, IEnumerable<AutoRosterCommitCell> cells, IEnumerable<AutoRosterCommitRhythm>? rhythm = null)
    {
        var grid = RosterPlanner.Classify(input, includeDrafts: false);
        var rhythms = new SortedDictionary<int, ResolvedRhythm>();
        foreach (var (e, r) in RosterPlanner.ResolveRhythms(input, grid))
            rhythms[e] = r;

        foreach (var r in rhythm ?? [])
        {
            if (!r.OnRotation)
                rhythms.Remove(r.EmployeeId);
            else if (r.AnchorWorkDays is 5 or 6 && grid.Staff.Any(s => s.EmployeeId == r.EmployeeId))
                rhythms[r.EmployeeId] = new ResolvedRhythm(r.EmployeeId, RosterCalendar.WeekStart(r.AnchorWeekStart), r.AnchorWorkDays, false);
        }

        // Start from the rows as they are: nothing is written but what was submitted.
        foreach (var employee in grid.Staff)
        {
            foreach (var c in grid.CellsOf(employee.EmployeeId))
            {
                c.IsFact = true;
                c.ReasonCode = null;
                c.ReasonArgs = null;
                c.IsCoverCandidate = false;
                c.State = c.Kind == CellKind.Ghost ? CellState.Open : GridCell.StateOf(c.Current);
                c.ShiftId = c.State == CellState.Work ? c.Current?.ShiftId : null;
            }
        }

        foreach (var submitted in cells)
        {
            if (!grid.TryGet(submitted.EmployeeId, submitted.WorkDate, out var c) || !c.InMonth || !c.Employed || !c.InBranch)
                continue;

            c.IsFact = false;
            if (string.Equals(submitted.Action, "delete", StringComparison.OrdinalIgnoreCase))
            {
                c.State = CellState.None;
                c.ShiftId = null;
            }
            else if (submitted.IsRestDay)
            {
                c.State = CellState.Rest;
                c.ShiftId = null;
            }
            else
            {
                // (NULL, 0) arrives here as work without a shift and is refused as such.
                c.State = CellState.Work;
                c.ShiftId = submitted.ShiftId;
            }
        }

        return Validate(input, grid, rhythms);
    }

    public static bool HasErrors(IEnumerable<AutoRosterIssue> issues) => issues.Any(i => i.Severity == Error);

    /// <summary>Staff working in the branch that day (off-rotation staff included; a full-day leave is not on duty).</summary>
    public static int OnDuty(RosterGrid grid, DateOnly date)
        => grid.CellsOn(date).Count(c => c.InBranch && c.CountsAsWorkForRun);

    /// <summary>
    /// §2.3 measured on the grid: quota = employed days − T (− holidays off when they count as rest);
    /// rests = rest rows outside leave, any branch. A shortfall is absorbed by leave (info) only when
    /// no plannable or draft working day was left that could have taken the rest.
    /// </summary>
    public static WeekCheck CheckWeek(PlannerInput input, RosterGrid grid, ResolvedRhythm rhythm, DateOnly weekStart)
    {
        var e = rhythm.EmployeeId;
        var workDays = rhythm.WorkDaysIn(weekStart);
        int employed = 0, holidaysOff = 0, rests = 0, open = 0, flex = 0, leaveDays = 0;
        for (var i = 0; i < 7; i++)
        {
            if (!grid.TryGet(e, weekStart.AddDays(i), out var c) || !c.Employed)
                continue;
            employed++;
            if (c.InBranch && c.IsHoliday && c.State == CellState.None)
                holidaysOff++;
            if (c.CountsAsRest)
                rests++;
            if (c.State == CellState.Open)
                open++;
            if ((c.IsPlannable || c.Kind == CellKind.Draft) && c.State == CellState.Work && c.Leave == LeaveKind.None && !c.IsHoliday)
                flex++;
            if (c.Leave != LeaveKind.None)
                leaveDays++;
        }

        var quota = Math.Max(0, employed - workDays - (input.Settings.HolidayCountsAsRest ? holidaysOff : 0));
        var over = Math.Max(0, rests - quota);
        var shortfall = Math.Max(0, quota - rests - open);
        var absorbed = flex == 0 ? Math.Min(shortfall, leaveDays) : 0;
        return new WeekCheck(RosterCalendar.WeekStart(weekStart), workDays, quota, rests, open, over, absorbed, shortfall - absorbed);
    }

    /* ---- cell rules ---- */

    private static void CheckCells(PlannerInput input, RosterGrid grid, List<AutoRosterIssue> issues)
    {
        foreach (var employee in grid.Staff)
        {
            foreach (var c in grid.CellsOf(employee.EmployeeId))
            {
                if (c.IsWritten)
                {
                    if (c.State == CellState.Work && !input.IsActiveShift(c.ShiftId))
                        issues.Add(Issue(Error, WorkWithoutShift, c.EmployeeId, c.Date,
                            c.ShiftId is null ? "A working day needs a shift." : $"Shift {c.ShiftId} is not active."));

                    if (c.State == CellState.Rest && c.IsHoliday)
                        issues.Add(Issue(Error, RestOnHoliday, c.EmployeeId, c.Date,
                            $"{HolidayName(input, c.Date)} is a public holiday, not a rest day — leave the day empty."));

                    if (c.State == CellState.Work && c.Leave == LeaveKind.None && input.IsPatternRest(c.EmployeeId, c.Date))
                        issues.Add(Issue(Info, PatternRestWorked, c.EmployeeId, c.Date, "Working on a weekly-pattern rest day."));
                }
                else if (c.InMonth && c.InBranch && c.Employed && c.IsHoliday && c.State == CellState.Rest)
                {
                    // Rest outranks holiday in the day rule, so this row turns the holiday into an ordinary rest day.
                    issues.Add(Issue(Warning, HolidayHiddenByRest, c.EmployeeId, c.Date,
                        $"A rest row on {HolidayName(input, c.Date)} hides the public holiday — give a day off in lieu."));
                }
            }
        }
    }

    /* ---- consecutive working days (D7) ---- */

    /// <summary>
    /// Runs are followed from a month before the window to <see cref="PlannerInput.HorizonTo"/>: a run
    /// this window leaves at its end joins the following month's saved opening run (planned first, it
    /// read this month as empty), and the two together are what the cap is about.
    /// </summary>
    private static void CheckRuns(PlannerInput input, RosterGrid grid, int e, List<AutoRosterIssue> issues)
    {
        var cap = input.Settings.MaxConsecutiveWorkDays;
        var preferred = Math.Min(input.Settings.PreferredMaxConsecutiveWorkDays, cap);
        DateOnly? start = null;
        var length = 0;

        for (var d = input.WindowFrom.AddDays(-31); d <= input.HorizonTo; d = d.AddDays(1))
        {
            if (IsWorkForRun(input, grid, e, d))
            {
                start ??= d;
                length++;
                continue;
            }
            if (start is { } s)
                ReportRun(input, grid, e, s, d.AddDays(-1), length, cap, preferred, issues);
            start = null;
            length = 0;
        }
        if (start is { } last)
            ReportRun(input, grid, e, last, input.HorizonTo, length, cap, preferred, issues);
    }

    private static void ReportRun(PlannerInput input, RosterGrid grid, int e, DateOnly from, DateOnly to, int length,
        int cap, int preferred, List<AutoRosterIssue> issues)
    {
        if (length <= preferred || from > input.WindowTo)
            return;

        var inWindow = RosterCalendar.Days(from < input.WindowFrom ? input.WindowFrom : from, to > input.WindowTo ? input.WindowTo : to)
            .Select(d => grid[e, d]).ToList();
        var relevant = inWindow.Any(c => c.IsWritten || (c.InMonth && c.InBranch && c.Date >= input.Today && !input.MonthLocked));
        if (!relevant)
            return;

        if (length > cap)
        {
            var planned = inWindow.Any(c => c.IsWritten && c.State == CellState.Work);
            issues.Add(Issue(planned ? Error : Warning, ConsecutiveCap, e, ClampToMonth(input, from.AddDays(cap)),
                $"{length} working days in a row ({RosterPlanner.Day(from)} – {RosterPlanner.Day(to)}); the limit is {cap}."));
        }
        else
        {
            issues.Add(Issue(Info, LongRun, e, ClampToMonth(input, from.AddDays(preferred)),
                $"{length} working days in a row ({RosterPlanner.Day(from)} – {RosterPlanner.Day(to)}); {preferred} or fewer is preferred."));
        }
    }

    private static bool IsWorkForRun(PlannerInput input, RosterGrid grid, int e, DateOnly d)
    {
        if (d >= input.WindowFrom && d <= input.WindowTo)
            return grid[e, d].CountsAsWorkForRun;
        return input.WorksOutsideWindow(e, d);
    }

    /* ---- the 6/5 rhythm per week ---- */

    private static void CheckWeeks(PlannerInput input, RosterGrid grid, ResolvedRhythm rhythm, List<AutoRosterIssue> issues)
    {
        var e = rhythm.EmployeeId;
        foreach (var ws in grid.WeekStarts)
        {
            // Only weeks the run can still act on: a past or locked week is history, not a to-do.
            var actionable = Enumerable.Range(0, 7)
                .Select(i => grid[e, ws.AddDays(i)])
                .Any(c => c.IsWritten || (c.InMonth && c.InBranch && c.Employed && c.Date >= input.Today && !input.MonthLocked));
            if (!actionable)
                continue;

            var check = CheckWeek(input, grid, rhythm, ws);
            var date = ClampToMonth(input, ws);
            var label = $"the {check.WorkDays}-day week of {RosterPlanner.Day(ws)}";

            if (check.Over > 0)
                issues.Add(Issue(Info, RhythmOver, e, date, $"{check.Rests} rest days in {label}; it needs {check.Quota}."));
            if (check.Absorbed > 0)
                issues.Add(Issue(Info, RestAbsorbedByLeave, e, date,
                    $"{check.Absorbed} rest day(s) of {label} fall inside a leave and are not given."));
            if (check.Short > 0)
                issues.Add(Issue(Warning, RhythmShort, e, date, $"{check.Rests} rest day(s) in {label}; it needs {check.Quota}."));
        }
    }

    /* ---- legal hours (D15): warnings only ---- */

    private static void CheckShiftTiming(PlannerInput input, RosterGrid grid, int e, List<AutoRosterIssue> issues)
    {
        var minBetween = TimeSpan.FromHours(input.Settings.MinHoursBetweenShifts);
        for (var d = input.WindowFrom; d < input.WindowTo; d = d.AddDays(1))
        {
            var a = grid[e, d];
            var b = grid[e, d.AddDays(1)];
            if (!(a.IsWritten || b.IsWritten) || !a.CountsAsWorkForRun || !b.CountsAsWorkForRun)
                continue;
            if (ShiftOf(input, a) is not { } first || ShiftOf(input, b) is not { } second)
                continue;

            var gap = second.StartOn(b.Date) - first.EndOn(a.Date);
            if (gap < minBetween)
                issues.Add(Issue(Warning, Turnaround, e, b.InMonth ? b.Date : a.Date,
                    $"{Hours(gap)} hours between {first.Name} and {second.Name}; the minimum is {input.Settings.MinHoursBetweenShifts}."));
        }

        var minWeekly = TimeSpan.FromHours(input.Settings.MinWeeklyRestHours);
        foreach (var ws in grid.WeekStarts)
        {
            var cells = Enumerable.Range(0, 7).Select(i => grid[e, ws.AddDays(i)]).ToList();
            if (!cells.Any(c => c.IsWritten) || !cells.Any(c => c.CountsAsWorkForRun))
                continue;

            var longest = LongestRest(input, grid, e, ws);
            if (longest < minWeekly)
                issues.Add(Issue(Warning, WeeklyRestHours, e, ClampToMonth(input, ws),
                    $"The longest rest in the week of {RosterPlanner.Day(ws)} is {Hours(longest)} hours; the minimum is {input.Settings.MinWeeklyRestHours}."));
        }
    }

    /// <summary>
    /// The longest rest between shifts that BELONGS to the week: the one whose midpoint falls in it.
    /// "Overlaps the week" would let last weekend's long rest, ending Monday morning, hide this week's
    /// Saturday-night-to-Monday-morning one. Shifts are read from two days before the week to two days
    /// after it; a rest that runs past what is known counts at its known length, so an unknown edge
    /// can only lengthen a rest — a warning is raised on what is known, never on a guess.
    /// </summary>
    private static TimeSpan LongestRest(PlannerInput input, RosterGrid grid, int e, DateOnly ws)
    {
        var scanStart = ws.AddDays(-2).ToDateTime(TimeOnly.MinValue);
        var scanEnd = ws.AddDays(9).ToDateTime(TimeOnly.MinValue);
        var weekStart = ws.ToDateTime(TimeOnly.MinValue);
        var weekEnd = ws.AddDays(7).ToDateTime(TimeOnly.MinValue);

        var intervals = new List<(DateTime Start, DateTime End)>();
        for (var d = ws.AddDays(-2); d <= ws.AddDays(8); d = d.AddDays(1))
        {
            ShiftInfo? shift = null;
            if (d >= input.WindowFrom && d <= input.WindowTo)
            {
                var c = grid[e, d];
                if (c.CountsAsWorkForRun)
                    shift = ShiftOf(input, c);
            }
            else if (input.WorksOutsideWindow(e, d) && input.RowOf(e, d) is { ShiftId: { } shiftId })
            {
                shift = input.Shifts.TryGetValue(shiftId, out var s) ? s : null;
            }

            if (shift is not null)
                intervals.Add((shift.StartOn(d), shift.EndOn(d)));
        }

        var longest = TimeSpan.Zero;
        var previousEnd = scanStart;
        var openStart = true;   // nothing known before the first shift
        foreach (var (start, end) in intervals.OrderBy(i => i.Start))
        {
            var gap = start - previousEnd;
            var belongs = openStart
                ? start > weekStart
                : previousEnd + gap / 2 >= weekStart && previousEnd + gap / 2 < weekEnd;
            if (gap > longest && belongs)
                longest = gap;
            if (end > previousEnd)
                previousEnd = end;
            openStart = false;
        }
        if (previousEnd < weekEnd && scanEnd - previousEnd > longest)
            longest = scanEnd - previousEnd;
        return longest;
    }

    private static ShiftInfo? ShiftOf(PlannerInput input, GridCell c)
        => c.ShiftId is { } id && input.Shifts.TryGetValue(id, out var s) ? s : null;

    /* ---- staffing (D8) and the shifts to cover (D16): rest days beat staffing, so these are warnings ---- */

    private static void CheckStaffing(PlannerInput input, RosterGrid grid, List<AutoRosterIssue> issues)
    {
        if (input.MonthLocked)
            return;

        foreach (var date in RosterCalendar.Days(input.MonthStart, input.MonthEnd))
        {
            if (date < input.Today)
                continue;

            var onDuty = OnDuty(grid, date);
            var (min, _) = input.StaffingFor(date);
            if (min is { } m && onDuty < m)
                issues.Add(Issue(Warning, ShortStaffed, null, date, $"{onDuty} on duty; the minimum is {m}."));

            // A shift with nobody on it is SHIFT_UNCOVERED; one with somebody but fewer than its minimum
            // is SHORT_STAFFED. On an open public holiday the cover is the manager's choice, so a shift
            // it leaves empty is only an info, and a thin one is not reported.
            var holiday = input.Holidays.ContainsKey(date);
            foreach (var rule in input.CoverRulesFor(date))
            {
                if (rule.MinOnDuty <= 0)
                    continue;
                var onShift = OnShift(grid, date, rule.ShiftId!.Value);
                var name = input.Shifts.TryGetValue(rule.ShiftId!.Value, out var s) ? s.Name : $"shift {rule.ShiftId}";
                AutoRosterIssue? issue = null;
                if (onShift == 0)
                    issue = holiday
                        ? Issue(Info, ShiftUncovered, null, date, $"Nobody is on {name} on {HolidayName(input, date)}; raise its cover to cover every shift.")
                        : Issue(Warning, ShiftUncovered, null, date, $"Nobody is on {name}; it needs {rule.MinOnDuty}.");
                else if (!holiday && onShift < rule.MinOnDuty)
                    issue = Issue(Warning, ShortStaffed, null, date, $"{onShift} on {name}; the minimum is {rule.MinOnDuty}.");
                if (issue is not null)
                {
                    issue.ShiftId = rule.ShiftId;
                    issues.Add(issue);
                }
            }
        }
    }

    /// <summary>Staff working a given shift in the branch that day (a full-day leave is not on duty).</summary>
    public static int OnShift(RosterGrid grid, DateOnly date, int shiftId)
        => grid.CellsOn(date).Count(c => c.InBranch && c.CountsAsWorkForRun && c.ShiftId == shiftId);

    /* ---- helpers ---- */

    private static AutoRosterIssue Issue(string severity, string code, int? employeeId, DateOnly? date, string message)
        => new() { Severity = severity, Code = code, EmployeeId = employeeId, Date = date, Message = message };

    private static List<AutoRosterIssue> Sort(List<AutoRosterIssue> issues) => issues
        .OrderBy(i => i.Severity switch { Error => 0, Warning => 1, _ => 2 })
        .ThenBy(i => i.Date ?? DateOnly.MinValue)
        .ThenBy(i => i.EmployeeId ?? 0)
        .ThenBy(i => i.Code, StringComparer.Ordinal)
        .ThenBy(i => i.Message, StringComparer.Ordinal)
        .ToList();

    private static DateOnly ClampToMonth(PlannerInput input, DateOnly date)
        => date < input.MonthStart ? input.MonthStart : date > input.MonthEnd ? input.MonthEnd : date;

    private static string HolidayName(PlannerInput input, DateOnly date)
        => input.Holidays.TryGetValue(date, out var h) && !string.IsNullOrWhiteSpace(h.Name) ? h.Name : RosterPlanner.Day(date);

    private static string Hours(TimeSpan span) => Math.Round(span.TotalHours, 1).ToString(CultureInfo.InvariantCulture);
}
