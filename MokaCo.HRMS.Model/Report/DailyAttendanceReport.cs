namespace MokaCo.HRMS.Model.Report;

/// <summary>Title block for the Daily Attendance Sheet (result set 1 of report.usp_Report_DailyAttendance).</summary>
public class DailyAttendanceHeader
{
    public string ReportTitle { get; set; } = string.Empty;
    public DateTime WorkDate { get; set; }
    public string BranchName { get; set; } = string.Empty;
    public DateTime GeneratedUtc { get; set; }
}

/// <summary>
/// One employee on one day, for a branch manager's morning sheet: who was in, who was late, who
/// never showed. The rows arrive ordered by branch then status, so the printout groups without the
/// client having to sort.
/// </summary>
public class DailyAttendanceRow
{
    public int EmployeeId { get; set; }
    public string FullName { get; set; } = string.Empty;
    public string BranchName { get; set; } = string.Empty;

    /// <summary>The rostered shift, or null when the day had no roster — which is itself worth seeing on the sheet.</summary>
    public string? ShiftName { get; set; }

    public DateTime? FirstInUtc { get; set; }
    public DateTime? LastOutUtc { get; set; }
    public int LateMinutes { get; set; }
    public decimal WorkedHours { get; set; }
    public int OvertimeMinutes { get; set; }

    /// <summary>Minutes away mid-day beyond the break — the exit permissions a manager may need to chase.</summary>
    public int ExitActualMinutes { get; set; }

    public decimal DayFraction { get; set; }
    public string Status { get; set; } = string.Empty;

    /// <summary>The punches did not add up. Flagged on the sheet so a manager knows this row's hours are not yet trustworthy.</summary>
    public bool HasAnomaly { get; set; }

    public string Source { get; set; } = string.Empty;
}
