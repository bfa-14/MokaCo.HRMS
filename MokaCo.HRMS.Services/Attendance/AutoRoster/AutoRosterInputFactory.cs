using System.Collections.Frozen;
using System.Globalization;
using MokaCo.HRMS.Model.Attendance;

namespace MokaCo.HRMS.Services.Attendance.AutoRoster;

/// <summary>
/// usp_AutoRoster_GetContext's 15 result sets + the drawer's request → one <see cref="PlannerInput"/>.
/// Pure mapping: DateTime columns become DateOnly, settings get their §3.2 defaults, the request's
/// choices (mode, off-rotation list, holiday cover, overrides, draft edits) are folded in. The
/// service only has to fetch the context and call <see cref="Create"/>.
/// </summary>
public static class AutoRosterInputFactory
{
    public static readonly string[] Modes = ["FillEmpty", "ReplanAuto", "ReplanAll"];

    /// <summary>
    /// The sentence a 400 should carry when the request cannot be planned at all, or null when it can.
    /// Checked before the context is read, so a typo never costs a database round trip.
    /// </summary>
    public static string? Problem(AutoRosterRequest request)
    {
        if (request is null)
            return "Send the branch, the month and the mode.";
        if (request.BranchId <= 0)
            return "Choose a branch.";
        if (!RosterCalendar.TryParseMonth(request.Month, out _))
            return "The month must look like 2026-12.";
        if (!TryParseMode(request.Mode, out _))
            return "Choose a real mode.";
        if (request.RhythmStart is { } start && !string.IsNullOrWhiteSpace(start) && !TryParseRhythmStart(start, out _))
            return "The rhythm start must be Aligned or Staggered.";
        if (request.HolidayCover.Any(c => c.Count < 0))
            return "Holiday cover cannot be negative.";
        if (request.RhythmOverrides.Any(o => o.WorkDays is not (5 or 6)))
            return "A week has 6 or 5 working days.";
        return null;
    }

    /// <summary>Builds the planner's input. Throws <see cref="ArgumentException"/> with <see cref="Problem"/>'s sentence on a bad request.</summary>
    public static PlannerInput Create(AutoRosterContext context, AutoRosterRequest request)
    {
        ArgumentNullException.ThrowIfNull(context);
        if (Problem(request) is { } problem)
            throw new ArgumentException(problem, nameof(request));

        RosterCalendar.TryParseMonth(request.Month, out var monthStart);
        TryParseMode(request.Mode, out var mode);

        // The window is DEFINED by the month (D1); the header's copy is the same arithmetic done in SQL.
        var (windowFrom, windowTo) = RosterCalendar.Window(monthStart);
        var settings = ReadSettings(context.Settings, request.RhythmStart);
        var header = context.Header;
        var historyFrom = header.HistoryFrom == default
            ? windowFrom.AddDays(-7 * settings.FairnessLookbackWeeks)
            : D(header.HistoryFrom);
        var today = D(header.Today);

        // The table's CHECK keeps AnchorWorkDays to 5/6; anything else is ignored rather than trusted.
        var rhythms = new Dictionary<int, StoredRhythm>();
        foreach (var r in context.Rhythm.Where(r => r.AnchorWorkDays is 5 or 6).OrderBy(r => r.EmployeeId))
            rhythms.TryAdd(r.EmployeeId, new StoredRhythm(r.EmployeeId, RosterCalendar.WeekStart(D(r.AnchorWeekStart)), r.AnchorWorkDays, r.OnRotation));

        // NULL = as stored; a list (even empty) is the drawer's complete answer.
        var offRotation = request.OffRotationEmployeeIds is { } list
            ? list.ToHashSet()
            : context.Rhythm.Where(r => !r.OnRotation).Select(r => r.EmployeeId).ToHashSet();

        var staff = context.Staff
            .GroupBy(s => s.EmployeeId)
            .Select(g => g.First())
            .OrderBy(s => s.EmployeeId)
            .Select(s => new PlannerEmployee(
                s.EmployeeId, s.FullName, s.PositionId, s.Position,
                s.HireDate is { } h ? D(h) : null, s.TerminationDate is { } t ? D(t) : null,
                OnRotation: !offRotation.Contains(s.EmployeeId)))
            .ToList();

        var branchOfDay = new Dictionary<EmpDay, int>();
        foreach (var day in context.StaffDays.OrderBy(x => x.EmployeeId).ThenBy(x => x.WorkDate).ThenBy(x => x.BranchId))
            branchOfDay.TryAdd(new EmpDay(day.EmployeeId, D(day.WorkDate)), day.BranchId);

        // UQ_ShiftAssignment makes (EmployeeId, WorkDate) unique; the ordering only makes a broken feed deterministic.
        var rows = new Dictionary<EmpDay, RosterRow>();
        foreach (var row in context.Rows.OrderBy(x => x.EmployeeId).ThenBy(x => x.WorkDate).ThenBy(x => x.ShiftId).ThenBy(x => x.IsRestDay))
            rows.TryAdd(new EmpDay(row.EmployeeId, D(row.WorkDate)), new RosterRow(row.ShiftId, row.IsRestDay));

        var locks = new Dictionary<EmpDay, string>();
        foreach (var l in context.Locks.OrderBy(x => x.EmployeeId).ThenBy(x => x.WorkDate).ThenBy(x => x.Reason, StringComparer.Ordinal))
            locks.TryAdd(new EmpDay(l.EmployeeId, D(l.WorkDate)), l.Reason);

        // A branch's own row beats the all-branch row for the same date (its name and paid flag win).
        var holidays = context.Holidays
            .Where(h => h.BranchId is null || h.BranchId == request.BranchId)
            .GroupBy(h => D(h.HolidayDate))
            .ToDictionary(
                g => g.Key,
                g =>
                {
                    var h = g.OrderBy(x => x.BranchId is null ? 1 : 0).ThenBy(x => x.Name, StringComparer.Ordinal).First();
                    return new HolidayInfo(g.Key, h.Name, h.IsPaid);
                });

        var holidaysWorked = context.HolidaysWorked
            .GroupBy(h => h.EmployeeId)
            .ToDictionary(g => g.Key, g => g.Sum(x => x.Days));

        // Read past the window too: a leave in the following month's saved opening run breaks that run.
        var horizonTo = windowTo.AddDays(settings.MaxConsecutiveWorkDays);
        var leaveDays = new Dictionary<EmpDay, LeaveKind>();
        foreach (var leave in context.Leaves.OrderBy(x => x.EmployeeId).ThenBy(x => x.FromDate))
        {
            var kind = string.IsNullOrWhiteSpace(leave.HalfDay) ? LeaveKind.Full : LeaveKind.Half;
            var from = Max(D(leave.FromDate), historyFrom);
            var to = Min(D(leave.ToDate), horizonTo);
            for (var d = from; d <= to; d = d.AddDays(1))
            {
                var key = new EmpDay(leave.EmployeeId, d);
                if (!leaveDays.TryGetValue(key, out var existing) || existing < kind)
                    leaveDays[key] = kind;
            }
        }

        var shifts = context.Shifts
            .GroupBy(s => s.ShiftId)
            .ToDictionary(g => g.Key, g =>
            {
                var s = g.First();
                return new ShiftInfo(s.ShiftId, s.Name, s.StartTime, s.EndTime, s.CrossesMidnight, s.BreakMinutes, s.IsActive);
            });

        var patterns = new Dictionary<(int, int), PatternDay>();
        foreach (var p in context.Patterns.Where(p => p.DayOfWeek is >= 1 and <= 7).OrderBy(p => p.EmployeeId).ThenBy(p => p.DayOfWeek))
            patterns.TryAdd((p.EmployeeId, p.DayOfWeek), new PatternDay(p.EmployeeId, p.DayOfWeek, p.ShiftId, p.IsRestDay));

        var cells = new Dictionary<EmpDay, CellMeta>();
        foreach (var c in context.Cells.OrderBy(x => x.EmployeeId).ThenBy(x => x.WorkDate))
            cells.TryAdd(new EmpDay(c.EmployeeId, D(c.WorkDate)), new CellMeta(c.AutoState, c.AutoShiftId, c.ReasonCode, c.IsPinned));

        var staffing = context.Staffing
            .Where(s => s.DayOfWeek is null or (>= 1 and <= 7))
            .Select(s => new StaffingRule(s.DayOfWeek, s.ShiftId, Math.Max(0, s.MinOnDuty), s.TargetOnDuty))
            .OrderBy(s => s.DayOfWeek ?? 0).ThenBy(s => s.ShiftId ?? 0).ThenBy(s => s.MinOnDuty)
            .ToList();

        // Duplicates in a request: the last one wins, as it would in the drawer that built the list.
        var cover = new Dictionary<DateOnly, int>();
        foreach (var c in request.HolidayCover)
            cover[c.Date] = Math.Max(0, c.Count);

        var overrides = new Dictionary<int, RhythmOverride>();
        foreach (var o in request.RhythmOverrides)
            overrides[o.EmployeeId] = new RhythmOverride(o.EmployeeId, RosterCalendar.WeekStart(o.WeekStart), o.WorkDays);

        var drafts = new Dictionary<EmpDay, DraftCell>();
        foreach (var c in request.DraftCells)
        {
            var state = c.IsRestDay ? CellState.Rest : c.ShiftId is not null ? CellState.Work : CellState.None;
            drafts[new EmpDay(c.EmployeeId, c.WorkDate)] =
                new DraftCell(c.EmployeeId, c.WorkDate, state, state == CellState.Work ? c.ShiftId : null, c.IsPinned == true);
        }

        return new PlannerInput
        {
            BranchId = request.BranchId,
            MonthStart = monthStart,
            WindowFrom = windowFrom,
            WindowTo = windowTo,
            HistoryFrom = historyFrom,
            Today = today,
            Mode = mode,
            Settings = settings,
            MonthLocked = header.OpenRequestId is not null,
            DefaultShiftId = request.DefaultShiftId,
            Staff = staff,
            BranchOfDay = branchOfDay.ToFrozenDictionary(),
            Rows = rows.ToFrozenDictionary(),
            Locks = locks.ToFrozenDictionary(),
            Holidays = holidays.ToFrozenDictionary(),
            HolidaysWorked = holidaysWorked.ToFrozenDictionary(),
            LeaveDays = leaveDays.ToFrozenDictionary(),
            Shifts = shifts.ToFrozenDictionary(),
            Patterns = patterns.ToFrozenDictionary(),
            Rhythms = rhythms.ToFrozenDictionary(),
            Cells = cells.ToFrozenDictionary(),
            Staffing = staffing,
            HolidayCover = cover.ToFrozenDictionary(),
            RhythmOverrides = overrides.ToFrozenDictionary(),
            DraftCells = drafts.ToFrozenDictionary(),
        };
    }

    /// <summary>
    /// The 'Roster' settings with the §3.2 defaults for anything missing or unreadable — a typo in
    /// core.SETTING must not stop the planner, it gets the documented default instead.
    /// </summary>
    public static PlannerSettings ReadSettings(IEnumerable<AutoRosterSettingRow> rows, string? rhythmStartOverride = null)
    {
        var map = new Dictionary<string, string?>(StringComparer.OrdinalIgnoreCase);
        foreach (var row in rows)
            map[row.SettingKey.Trim()] = row.SettingValue?.Trim();

        var d = PlannerSettings.Default;
        var rhythmText = string.IsNullOrWhiteSpace(rhythmStartOverride) ? Text("RosterRhythmStart") : rhythmStartOverride;
        var max = Math.Clamp(Int("RosterMaxConsecutiveWorkDays", d.MaxConsecutiveWorkDays), 1, 31);

        return new PlannerSettings
        {
            RhythmStart = TryParseRhythmStart(rhythmText, out var start) ? start : d.RhythmStart,
            HolidayCountsAsRest = Bool("RosterHolidayCountsAsRest", d.HolidayCountsAsRest),
            MaxConsecutiveWorkDays = max,
            // A preferred maximum above the hard cap would mean nothing; clamp it under.
            PreferredMaxConsecutiveWorkDays = Math.Clamp(Int("RosterPreferredMaxConsecutiveWorkDays", d.PreferredMaxConsecutiveWorkDays), 1, max),
            FairnessLookbackWeeks = Math.Clamp(Int("RosterFairnessLookbackWeeks", d.FairnessLookbackWeeks), 0, 52),
            PairRestDays = Bool("RosterPairRestDays", d.PairRestDays),
            PatternRestDays = string.Equals(Text("RosterPatternRestDays"), "Unavailable", StringComparison.OrdinalIgnoreCase)
                ? PatternRestRule.Unavailable
                : PatternRestRule.Preference,
            MinHoursBetweenShifts = Math.Max(0, Int("RosterMinHoursBetweenShifts", d.MinHoursBetweenShifts)),
            MinWeeklyRestHours = Math.Max(0, Int("RosterMinWeeklyRestHours", d.MinWeeklyRestHours)),
        };

        string? Text(string key) => map.TryGetValue(key, out var v) ? v : null;

        int Int(string key, int fallback)
            => int.TryParse(Text(key), NumberStyles.Integer, CultureInfo.InvariantCulture, out var v) ? v : fallback;

        bool Bool(string key, bool fallback) => Text(key)?.ToLowerInvariant() switch
        {
            "1" or "true" or "yes" => true,
            "0" or "false" or "no" => false,
            _ => fallback,
        };
    }

    /// <summary>The settings as the setup endpoint shows them.</summary>
    public static AutoRosterSettings ToDto(PlannerSettings s) => new()
    {
        RosterRhythmStart = s.RhythmStart.ToString(),
        RosterHolidayCountsAsRest = s.HolidayCountsAsRest,
        RosterMaxConsecutiveWorkDays = s.MaxConsecutiveWorkDays,
        RosterPreferredMaxConsecutiveWorkDays = s.PreferredMaxConsecutiveWorkDays,
        RosterFairnessLookbackWeeks = s.FairnessLookbackWeeks,
        RosterPairRestDays = s.PairRestDays,
        RosterPatternRestDays = s.PatternRestDays.ToString(),
        RosterMinHoursBetweenShifts = s.MinHoursBetweenShifts,
        RosterMinWeeklyRestHours = s.MinWeeklyRestHours,
    };

    public static bool TryParseMode(string? text, out RosterMode mode)
        => Enum.TryParse(text?.Trim(), ignoreCase: true, out mode) && Enum.IsDefined(mode) && !int.TryParse(text, out _);

    public static bool TryParseRhythmStart(string? text, out RhythmStartRule rule)
        => Enum.TryParse(text?.Trim(), ignoreCase: true, out rule) && Enum.IsDefined(rule) && !int.TryParse(text, out _);

    private static DateOnly D(DateTime value) => DateOnly.FromDateTime(value);
    private static DateOnly Max(DateOnly a, DateOnly b) => a > b ? a : b;
    private static DateOnly Min(DateOnly a, DateOnly b) => a < b ? a : b;
}
