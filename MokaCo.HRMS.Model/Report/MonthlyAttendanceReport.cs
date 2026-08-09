namespace MokaCo.HRMS.Model.Report;

/// <summary>Title block for the Monthly Attendance Summary (result set 1 of report.usp_Report_MonthlyAttendance).</summary>
public class MonthlyAttendanceHeader
{
    public string ReportTitle { get; set; } = string.Empty;
    public string Period { get; set; } = string.Empty;
    public DateTime PeriodStart { get; set; }
    public DateTime PeriodEnd { get; set; }

    /// <summary>The branch this run was filtered to, or 'All branches'. Named on the printout so a filtered sheet cannot be mistaken for the whole company.</summary>
    public string BranchName { get; set; } = string.Empty;

    public DateTime GeneratedUtc { get; set; }
}

/// <summary>
/// One employee's month, as HR reviews it before payroll. Every figure here becomes a pay line
/// somewhere, which is why the sheet is dense: leaving one out would hide a deduction or a credit.
/// </summary>
public class MonthlyAttendanceRow
{
    public int EmployeeId { get; set; }
    public string FullName { get; set; } = string.Empty;
    public string BranchName { get; set; } = string.Empty;
    public string DepartmentName { get; set; } = string.Empty;

    /// <summary>FRACTIONAL days worked — someone who left two hours early counts 0.75, not 1.</summary>
    public decimal DaysWorked { get; set; }

    public int FullDaysWorked { get; set; }
    public int PresentDays { get; set; }
    public int AbsentDays { get; set; }
    public int LeaveDays { get; set; }
    public int RestDays { get; set; }
    public int LateMinutes { get; set; }

    /// <summary>DETECTED overtime. It is on the review sheet so HR can see it, NOT so payroll pays it automatically.</summary>
    public int OvertimeMinutes { get; set; }

    public decimal WorkedHours { get; set; }

    /// <summary>Leave days drawn down by mid-day exits, converted from minutes at the configured standard day.</summary>
    public decimal ExitLeaveDays { get; set; }

    public decimal ApprovedLeaveDays { get; set; }

    /// <summary>Absences NOT covered by approved leave — the deduction. The column HR looks at hardest.</summary>
    public decimal UnpaidAbsenceDays { get; set; }
}
