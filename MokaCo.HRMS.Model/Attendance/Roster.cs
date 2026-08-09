namespace MokaCo.HRMS.Model.Attendance;

/// <summary>
/// Maps to attendance.SHIFT_ASSIGNMENT — THE ROSTER. One row per employee-day, which tells the
/// processor what the person was SUPPOSED to work. Without a row here attendance cannot tell late
/// from early, or absent from a day off, so a missing roster row is a payroll problem and not a
/// cosmetic one (see <see cref="RosterGap"/>).
/// HR never types these one by one — they are GENERATED. For an overnight shift, WorkDate is the
/// day the shift STARTS.
/// </summary>
public class ShiftAssignment
{
    public int ShiftAssignmentId { get; set; }
    public int EmployeeId { get; set; }
    public string FullName { get; set; } = string.Empty;

    /// <summary>NULL on a rest day — a rest day is an assignment with no shift, not the absence of an assignment.</summary>
    public int? ShiftId { get; set; }
    public string? ShiftName { get; set; }
    public TimeSpan? StartTime { get; set; }
    public TimeSpan? EndTime { get; set; }

    public DateTime WorkDate { get; set; }

    /// <summary>1 = rostered day off. Punchless rest days become 'RestDay' records, NOT absences.</summary>
    public bool IsRestDay { get; set; }
}

/// <summary>
/// An employee-day with NO roster row at all — distinct from a rest day, which IS rostered.
/// The processor cannot judge these days, so payroll readiness counts them and HR is expected to
/// clear them (by generating the roster) before the month is paid.
/// </summary>
public class RosterGap
{
    public int EmployeeId { get; set; }
    public string FullName { get; set; } = string.Empty;
    public DateTime WorkDate { get; set; }
}

/// <summary>
/// Maps to attendance.EMPLOYEE_SHIFT_PATTERN — an employee's DEFAULT WEEK. It is a template and
/// holds no dates; roster generation expands it into real dated rows. This is what stops HR from
/// hand-typing a roster every month.
/// </summary>
public class ShiftPattern
{
    public int PatternId { get; set; }
    public int EmployeeId { get; set; }

    /// <summary>ISO weekday: 1 = Monday .. 7 = Sunday. Deliberately independent of the server's @@DATEFIRST locale.</summary>
    public byte DayOfWeek { get; set; }

    public int? ShiftId { get; set; }
    public string? ShiftName { get; set; }
    public bool IsRestDay { get; set; }
    public bool IsActive { get; set; }
}

/// <summary>
/// One day of an employee's current weekly template, as the availability-change form reads it —
/// attendance.usp_EmployeePattern_Get, which always returns SEVEN ROWS whether or not the employee
/// has a pattern on file.
///
/// THAT IS THE POINT OF IT. <see cref="ShiftPattern"/> returns only the rows that exist, so an
/// employee with three configured days yields three rows and a form built on it would silently offer
/// a three-day week. This one answers for all seven and marks the invented ones with
/// <see cref="NoPatternRow"/>, so "nobody has configured this day" is visible rather than looking
/// like a considered decision.
///
/// <see cref="IsAvailable"/> is the derived answer the form actually needs: false for a rest day OR a
/// day with no shift, true otherwise — including a day with no pattern row at all, which is treated
/// as available because an unconfigured employee is not thereby unavailable.
/// </summary>
public class EmployeePatternDay
{
    /// <summary>ISO weekday: 1 = Monday .. 7 = Sunday.</summary>
    public byte DayOfWeek { get; set; }

    public bool IsAvailable { get; set; }
    public int? ShiftId { get; set; }
    public string? ShiftName { get; set; }
    public TimeSpan? StartTime { get; set; }
    public TimeSpan? EndTime { get; set; }

    /// <summary>No row exists for this day — the figures beside it are defaults, not settings.</summary>
    public bool NoPatternRow { get; set; }
}

/// <summary>
/// How many roster rows a generator actually wrote. Generators are re-runnable and, with
/// Overwrite off, they only INSERT missing days — so a small number here usually means the roster
/// was already there and manual changes were preserved, not that the generator failed.
/// </summary>
public class RosterGenerateResult
{
    public int RowsInserted { get; set; }
}

/// <summary>How many employees a bulk generation touched (one call per employee under the hood).</summary>
public class RosterBulkResult
{
    public int EmployeesProcessed { get; set; }
}
