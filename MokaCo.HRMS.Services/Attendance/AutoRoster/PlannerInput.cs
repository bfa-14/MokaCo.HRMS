using System.Collections.Frozen;

namespace MokaCo.HRMS.Services.Attendance.AutoRoster;

/// <summary>D11: which existing rows a run may change.</summary>
public enum RosterMode
{
    /// <summary>Only empty days.</summary>
    FillEmpty,

    /// <summary>Empty days and rows still equal to what the generator last wrote; hand edits survive, and so does every saved week that still fits.</summary>
    ReplanAuto,

    /// <summary>Everything except pinned, locked and leave days, planned afresh: the generator's saved rests are not held on to.</summary>
    ReplanAll,
}

/// <summary>D2: how a rhythm that is not stored yet starts.</summary>
public enum RhythmStartRule
{
    /// <summary>Everyone's first planned week is a 6-day week.</summary>
    Aligned,

    /// <summary>Half the team starts on a 5-day week, so the number on duty is even week to week.</summary>
    Staggered,
}

/// <summary>D6: what a weekly-pattern rest day means to the planner.</summary>
public enum PatternRestRule
{
    /// <summary>Preferred for the weekday rest; fairness and the 6/5 rule win.</summary>
    Preference,

    /// <summary>A fixed rest day.</summary>
    Unavailable,
}

/// <summary>The §3.2 settings, typed and defaulted.</summary>
public sealed record PlannerSettings
{
    public RhythmStartRule RhythmStart { get; init; } = RhythmStartRule.Aligned;
    public bool HolidayCountsAsRest { get; init; }
    public int MaxConsecutiveWorkDays { get; init; } = 7;
    public int PreferredMaxConsecutiveWorkDays { get; init; } = 6;
    public int FairnessLookbackWeeks { get; init; } = 26;
    public bool PairRestDays { get; init; } = true;
    public PatternRestRule PatternRestDays { get; init; } = PatternRestRule.Preference;
    public int MinHoursBetweenShifts { get; init; } = 11;
    public int MinWeeklyRestHours { get; init; } = 36;

    public static PlannerSettings Default { get; } = new();
}

/// <summary>An employee-day: the key of every per-cell map.</summary>
public readonly record struct EmpDay(int EmployeeId, DateOnly Date);

/// <summary>
/// A SHIFT_ASSIGNMENT row. Work = a shift and IsRestDay = 0; rest = IsRestDay = 1. A row with neither
/// (NULL, 0) can exist — the SQL accepts it — and counts as neither: payroll and the dashboard ignore it.
/// </summary>
public readonly record struct RosterRow(int? ShiftId, bool IsRestDay)
{
    public bool IsWork => !IsRestDay && ShiftId is not null;
}

public sealed record PlannerEmployee(
    int EmployeeId, string FullName, int? PositionId, string? Position,
    DateOnly? HireDate, DateOnly? TerminationDate, bool OnRotation);

/// <summary>ROSTER_CELL: what the generator last wrote (AutoState NULL = written by hand) and the pin.</summary>
public sealed record CellMeta(string? AutoState, int? AutoShiftId, string? ReasonCode, bool IsPinned)
{
    /// <summary>The row still equals the AUTO value — ReplanAuto may change it. Anything else is a hand edit.</summary>
    public bool Matches(RosterRow? row) => AutoState switch
    {
        "work" => row is { IsWork: true } r && r.ShiftId == AutoShiftId,
        "rest" => row is { IsRestDay: true },
        "none" => row is null,
        _ => false,
    };
}

public enum LeaveKind { None, Half, Full }

public sealed record HolidayInfo(DateOnly Date, string Name, bool IsPaid);

public sealed record ShiftInfo(
    int ShiftId, string Name, TimeSpan StartTime, TimeSpan EndTime, bool CrossesMidnight, int BreakMinutes, bool IsActive)
{
    /// <summary>When the shift starting on <paramref name="day"/> starts.</summary>
    public DateTime StartOn(DateOnly day) => day.ToDateTime(TimeOnly.MinValue) + StartTime;

    /// <summary>When it ends: the next day for an overnight shift, which still belongs to its start day.</summary>
    public DateTime EndOn(DateOnly day)
        => day.ToDateTime(TimeOnly.MinValue) + EndTime + (CrossesMidnight || EndTime <= StartTime ? TimeSpan.FromDays(1) : TimeSpan.Zero);
}

public sealed record PatternDay(int EmployeeId, int DayOfWeek, int? ShiftId, bool IsRestDay);

public sealed record StoredRhythm(int EmployeeId, DateOnly AnchorWeekStart, int AnchorWorkDays, bool OnRotation);

public sealed record StaffingRule(int? DayOfWeek, int? ShiftId, int MinOnDuty, int? TargetOnDuty);

public sealed record RhythmOverride(int EmployeeId, DateOnly WeekStart, int WorkDays);

/// <summary>The state of a cell: a working row, a rest row, no row, or (a commit's ghost) not decided by anyone yet.</summary>
public enum CellState { None, Work, Rest, Open }

/// <summary>A manager's draft edit, fixed exactly as sent.</summary>
public sealed record DraftCell(int EmployeeId, DateOnly Date, CellState State, int? ShiftId, bool IsPinned);

/// <summary>
/// Everything one planning run reads, normalised and frozen: no database, no clock (Today comes from
/// the context header, the Beirut date the database read), no request object. Two equal inputs give
/// the same plan whatever order the rows arrived in — every map is keyed, every list sorted.
/// Built by <see cref="AutoRosterInputFactory"/>.
/// </summary>
public sealed class PlannerInput
{
    public required int BranchId { get; init; }

    /// <summary>The 1st of the target month.</summary>
    public required DateOnly MonthStart { get; init; }

    public DateOnly MonthEnd => RosterCalendar.MonthEnd(MonthStart);
    public required DateOnly WindowFrom { get; init; }
    public required DateOnly WindowTo { get; init; }
    public required DateOnly HistoryFrom { get; init; }

    /// <summary>
    /// The last day after the window whose rows and leave are read: the following month may already be
    /// saved, and its opening run joins this window's closing one. A run can only break the cap through
    /// the first <see cref="PlannerSettings.MaxConsecutiveWorkDays"/> of those days, so that is as far as it looks.
    /// </summary>
    public DateOnly HorizonTo => WindowTo.AddDays(Settings.MaxConsecutiveWorkDays);

    /// <summary>Beirut today. Days before it are never changed, in any month state (D10).</summary>
    public required DateOnly Today { get; init; }

    public RosterMode Mode { get; init; } = RosterMode.FillEmpty;
    public PlannerSettings Settings { get; init; } = PlannerSettings.Default;

    /// <summary>A roster approval is waiting for this branch-month: the whole month is refused (MONTH_LOCKED).</summary>
    public bool MonthLocked { get; init; }

    public int? DefaultShiftId { get; init; }

    /// <summary>The branch's staff, sorted by EmployeeId, with the on-rotation flag already resolved (request over stored).</summary>
    public IReadOnlyList<PlannerEmployee> Staff { get; init; } = [];

    /// <summary>Employed days → the branch of that day. A day missing here is a day the person was not employed.</summary>
    public IReadOnlyDictionary<EmpDay, int> BranchOfDay { get; init; } = FrozenDictionary<EmpDay, int>.Empty;

    /// <summary>Roster rows of every branch: history, window and the days after it up to <see cref="HorizonTo"/>.</summary>
    public IReadOnlyDictionary<EmpDay, RosterRow> Rows { get; init; } = FrozenDictionary<EmpDay, RosterRow>.Empty;

    /// <summary>Target-month days the guard would refuse (Paid · Past · Recorded).</summary>
    public IReadOnlyDictionary<EmpDay, string> Locks { get; init; } = FrozenDictionary<EmpDay, string>.Empty;

    /// <summary>The branch's public holidays (all-branch rows and its own).</summary>
    public IReadOnlyDictionary<DateOnly, HolidayInfo> Holidays { get; init; } = FrozenDictionary<DateOnly, HolidayInfo>.Empty;

    /// <summary>Holidays worked in the 12 months before the window — the fewest covers next.</summary>
    public IReadOnlyDictionary<int, int> HolidaysWorked { get; init; } = FrozenDictionary<int, int>.Empty;

    /// <summary>Leave (Approved, Pending, OnHold), one entry per day up to <see cref="HorizonTo"/>. A full day beats a half day.</summary>
    public IReadOnlyDictionary<EmpDay, LeaveKind> LeaveDays { get; init; } = FrozenDictionary<EmpDay, LeaveKind>.Empty;

    public IReadOnlyDictionary<int, ShiftInfo> Shifts { get; init; } = FrozenDictionary<int, ShiftInfo>.Empty;

    /// <summary>Weekly pattern by (EmployeeId, ISO weekday).</summary>
    public IReadOnlyDictionary<(int EmployeeId, int DayOfWeek), PatternDay> Patterns { get; init; }
        = FrozenDictionary<(int, int), PatternDay>.Empty;

    public IReadOnlyDictionary<int, StoredRhythm> Rhythms { get; init; } = FrozenDictionary<int, StoredRhythm>.Empty;
    public IReadOnlyDictionary<EmpDay, CellMeta> Cells { get; init; } = FrozenDictionary<EmpDay, CellMeta>.Empty;
    public IReadOnlyList<StaffingRule> Staffing { get; init; } = [];

    /// <summary>Cover per holiday from the drawer; a holiday not here is closed.</summary>
    public IReadOnlyDictionary<DateOnly, int> HolidayCover { get; init; } = FrozenDictionary<DateOnly, int>.Empty;

    public IReadOnlyDictionary<int, RhythmOverride> RhythmOverrides { get; init; } = FrozenDictionary<int, RhythmOverride>.Empty;
    public IReadOnlyDictionary<EmpDay, DraftCell> DraftCells { get; init; } = FrozenDictionary<EmpDay, DraftCell>.Empty;

    /* ---- small lookups the planner and the validator share ---- */

    public bool InMonth(DateOnly date) => date >= MonthStart && date <= MonthEnd;

    public RosterRow? RowOf(int employeeId, DateOnly date)
        => Rows.TryGetValue(new EmpDay(employeeId, date), out var row) ? row : null;

    public LeaveKind LeaveOn(int employeeId, DateOnly date)
        => LeaveDays.TryGetValue(new EmpDay(employeeId, date), out var kind) ? kind : LeaveKind.None;

    public bool IsEmployed(int employeeId, DateOnly date) => BranchOfDay.ContainsKey(new EmpDay(employeeId, date));

    /// <summary>
    /// A day OUTSIDE the window that continues a run of working days: a working row (any branch), not a
    /// full-day leave, employed. Before the window the employed days are known day by day; after it only
    /// the rows are read (through <see cref="HorizonTo"/>), so the hire and termination dates decide.
    /// </summary>
    public bool WorksOutsideWindow(int employeeId, DateOnly date)
    {
        if (RowOf(employeeId, date) is not { IsWork: true } || LeaveOn(employeeId, date) == LeaveKind.Full)
            return false;
        if (date <= WindowTo)
            return IsEmployed(employeeId, date);

        _staffById ??= Staff.GroupBy(s => s.EmployeeId).ToDictionary(g => g.Key, g => g.First());
        return _staffById.TryGetValue(employeeId, out var s)
               && (s.HireDate is null || s.HireDate <= date)
               && (s.TerminationDate is null || date <= s.TerminationDate);
    }

    private Dictionary<int, PlannerEmployee>? _staffById;

    public bool InBranch(int employeeId, DateOnly date)
        => BranchOfDay.TryGetValue(new EmpDay(employeeId, date), out var branch) && branch == BranchId;

    public bool IsActiveShift(int? shiftId) => shiftId is { } id && Shifts.TryGetValue(id, out var s) && s.IsActive;

    public PatternDay? PatternOn(int employeeId, DateOnly date)
        => Patterns.TryGetValue((employeeId, RosterCalendar.IsoDayOfWeek(date)), out var p) ? p : null;

    /// <summary>A weekly-pattern rest day (the pattern says rest on this weekday).</summary>
    public bool IsPatternRest(int employeeId, DateOnly date) => PatternOn(employeeId, date) is { IsRestDay: true };

    /// <summary>
    /// Minimum and target on duty for a day, any shift. On a public holiday the cover asked for IS the
    /// minimum: a closed holiday (cover 0) is not short-staffed, it is closed.
    /// </summary>
    public (int? Min, int? Target) StaffingFor(DateOnly date)
    {
        if (Holidays.ContainsKey(date) && InMonth(date))
        {
            var cover = HolidayCover.TryGetValue(date, out var c) ? c : 0;
            return (cover, null);
        }

        var rule = RuleFor(date, null);
        return rule is null ? (null, null) : (rule.MinOnDuty, rule.TargetOnDuty);
    }

    /// <summary>The staffing rows with a shift that apply to a day (a weekday row beats an every-day row for the same shift).</summary>
    public IEnumerable<StaffingRule> ShiftRulesFor(DateOnly date)
    {
        if (Holidays.ContainsKey(date))
            yield break;

        foreach (var shiftId in Staffing.Where(r => r.ShiftId is not null).Select(r => r.ShiftId!.Value).Distinct().Order())
        {
            if (RuleFor(date, shiftId) is { } rule)
                yield return rule;
        }
    }

    private StaffingRule? RuleFor(DateOnly date, int? shiftId)
    {
        var dow = RosterCalendar.IsoDayOfWeek(date);
        return Staffing.FirstOrDefault(r => r.ShiftId == shiftId && r.DayOfWeek == dow)
            ?? Staffing.FirstOrDefault(r => r.ShiftId == shiftId && r.DayOfWeek is null);
    }
}
