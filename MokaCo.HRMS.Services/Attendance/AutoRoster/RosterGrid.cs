namespace MokaCo.HRMS.Services.Attendance.AutoRoster;

/// <summary>
/// §2.1 day classes. FIRST MATCH WINS, in the spec's order, with two refinements noted where they
/// are decided (<see cref="RosterPlanner.Classify"/>): a draft edit on a holiday is honoured (the
/// manager chose who covers), and an empty leave day that is also a holiday stays a holiday off.
/// </summary>
public enum CellKind
{
    /// <summary>Before hire / after termination: nothing is ever written.</summary>
    NotEmployed,

    /// <summary>Employed, but the branch of that day is another one: its row is a fact, no row is unknown.</summary>
    OtherBranch,

    /// <summary>The employee is off rotation: shown as the rows stand, never planned.</summary>
    OffRotation,

    /// <summary>In the month: paid, before today, recorded, or the whole month is waiting for approval.</summary>
    Locked,

    /// <summary>A window day outside the month with a row (a fact), or with none before today (unknown).</summary>
    Outside,

    /// <summary>A window day outside the month with no row, today or later: planned so the week works, never saved.</summary>
    Ghost,

    /// <summary>ROSTER_CELL.IsPinned with a row.</summary>
    Pinned,

    /// <summary>A full or half leave day: an existing row is frozen; an empty one becomes a working row.</summary>
    Leave,

    /// <summary>A public holiday the mode lets us decide: cover (work) or off (no row).</summary>
    Holiday,

    /// <summary>A manager's draft edit, fixed as sent.</summary>
    Draft,

    /// <summary>A weekly-pattern rest day under RosterPatternRestDays = Unavailable: a fixed rest.</summary>
    Unavailable,

    /// <summary>An existing row the mode protects.</summary>
    Fact,

    /// <summary>Plannable: becomes rest or work.</summary>
    Planned,
}

/// <summary>One employee-day of the planning window and what the run decided for it.</summary>
public sealed class GridCell
{
    public required int EmployeeId { get; init; }
    public required DateOnly Date { get; init; }
    public bool InMonth { get; init; }
    public bool Employed { get; init; }

    /// <summary>The branch of this day is the target branch.</summary>
    public bool InBranch { get; init; }

    /// <summary>The row as read (null = no row).</summary>
    public RosterRow? Current { get; init; }

    public LeaveKind Leave { get; init; }

    /// <summary>A public holiday of the branch (only meaningful on in-branch days).</summary>
    public bool IsHoliday { get; init; }

    public CellKind Kind { get; set; }

    /// <summary>Never changed by this run (or, for a submitted grid, not part of the submission).</summary>
    public bool IsFact { get; set; }

    /// <summary>In P (§2.3): the planner chooses rest or work here.</summary>
    public bool IsPlannable { get; set; }

    /// <summary>A holiday cell still waiting for the cover choice (§2.4).</summary>
    public bool IsCoverCandidate { get; set; }

    public CellState State { get; set; }
    public int? ShiftId { get; set; }
    public string? ReasonCode { get; set; }
    public string? ReasonArgs { get; set; }

    /// <summary>A cell this run would write: target month, this branch, employed, not a fact. Ghosts never are.</summary>
    public bool IsWritten => InMonth && Employed && InBranch && !IsFact;

    /// <summary>A full-day leave breaks a run of working days (D7); a half day is a working day.</summary>
    public bool CountsAsWorkForRun => Employed && State == CellState.Work && Leave != LeaveKind.Full;

    /// <summary>A rest that counts toward the rhythm: rests on leave days count neither as rest nor in the weekend ledger (D5).</summary>
    public bool CountsAsRest => Employed && State == CellState.Rest && Leave == LeaveKind.None;

    public static CellState StateOf(RosterRow? row) => row switch
    {
        null => CellState.None,
        { IsRestDay: true } => CellState.Rest,
        { ShiftId: not null } => CellState.Work,
        _ => CellState.None,
    };
}

/// <summary>Every staff member × every window day, keyed and sorted (EmployeeId, then date).</summary>
public sealed class RosterGrid
{
    private readonly Dictionary<EmpDay, GridCell> _cells;

    public RosterGrid(IReadOnlyList<PlannerEmployee> staff, IReadOnlyList<DateOnly> days, IEnumerable<GridCell> cells)
    {
        Staff = staff;
        Days = days;
        _cells = cells.ToDictionary(c => new EmpDay(c.EmployeeId, c.Date));
    }

    public IReadOnlyList<PlannerEmployee> Staff { get; }
    public IReadOnlyList<DateOnly> Days { get; }

    public GridCell this[int employeeId, DateOnly date] => _cells[new EmpDay(employeeId, date)];

    public bool TryGet(int employeeId, DateOnly date, out GridCell cell)
        => _cells.TryGetValue(new EmpDay(employeeId, date), out cell!);

    public IEnumerable<GridCell> CellsOf(int employeeId) => Days.Select(d => this[employeeId, d]);

    public IEnumerable<GridCell> CellsOn(DateOnly date) => Staff.Select(s => this[s.EmployeeId, date]);

    /// <summary>The window's Mondays, oldest first.</summary>
    public IReadOnlyList<DateOnly> WeekStarts => Days.Where(d => d.DayOfWeek == DayOfWeek.Monday).ToList();
}
