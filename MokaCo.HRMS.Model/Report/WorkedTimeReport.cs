namespace MokaCo.HRMS.Model.Report;

/// <summary>
/// WORKED TIME (GET /api/reports/worked-time): per employee and for any period, the days and hours worked and the
/// progress against the company's standard month - with or without a roster.
///
/// Worked time is the attendance days the system builds from the punches (the same days as Daily attendance and
/// payroll). Expected time is the standard month spread over its calendar days: StandardDaysPerMonth x
/// StandardDayMinutes / days in the month for each day employed, nothing on a public holiday, nothing (or half) on a
/// day of approved leave. Both are counted up to <see cref="WorkedTimeHeader.CountedTo"/> (yesterday at the latest:
/// today is still being worked). Every punched day counts, on the roster or not: a day missing from an approved
/// roster is measured from its punches exactly as the processor measures a day with no shift (script 114).
/// </summary>
public class WorkedTimeReport
{
    public WorkedTimeHeader Header { get; set; } = new();
    public List<WorkedTimeRow> Rows { get; set; } = [];

    /// <summary>The sum of <see cref="Rows"/> (progress over the sums).</summary>
    public WorkedTimeRow Totals { get; set; } = new();

    /// <summary>Every employee's days of the period that have something to show, by employee then date.</summary>
    public List<WorkedTimeDay> Days { get; set; } = [];
}

public class WorkedTimeHeader
{
    public DateTime From { get; set; }
    public DateTime To { get; set; }

    /// <summary>The last day counted: the end of the period, or yesterday when the period reaches today. Null when
    /// nothing of the period has passed yet.</summary>
    public DateTime? CountedTo { get; set; }

    public int? BranchId { get; set; }
    public string? BranchName { get; set; }
    public int StandardDayMinutes { get; set; }
    public decimal StandardDaysPerMonth { get; set; }
    public DateTime GeneratedUtc { get; set; }
}

public class WorkedTimeRow
{
    public int EmployeeId { get; set; }
    public string FullName { get; set; } = string.Empty;
    public string BranchName { get; set; } = string.Empty;
    public string DepartmentName { get; set; } = string.Empty;

    /// <summary>Days with a first punch (a worked rest day or holiday counts too), or a day HR credited with worked time.</summary>
    /// <summary>The length of this person's working day in minutes: their shift's (the default day when none of their days was measured).</summary>
    public int StandardDayMinutes { get; set; }

    public int DaysWorked { get; set; }

    /// <summary>Time worked, extra time included: first in to last out (paired, gaps out) - on a day with an approved
    /// roster shift, the shift window plus the time after it.</summary>
    public int WorkedMinutes { get; set; }

    /// <summary>Worked minutes per day worked; 0 when no day was worked.</summary>
    public int AverageMinutes { get; set; }

    /// <summary>Time beyond the shift, or beyond the standard day when there is no shift - as detected, not as paid
    /// (overtime is paid only against an approved request).</summary>
    public int OvertimeMinutes { get; set; }

    /// <summary>Days whose ins and outs do not pair (a missing punch): their worked time may be short.</summary>
    public int MissingPunchDays { get; set; }

    public decimal LeaveDays { get; set; }
    public int HolidayDays { get; set; }
    public int ExpectedMinutes { get; set; }

    /// <summary>Worked / expected x 100, one decimal; null when nothing was expected.</summary>
    public decimal? ProgressPercent { get; set; }

    /// <summary>Of the days worked, those missing from an approved roster (they wait for a decision on Daily
    /// attendance > Not on roster). Counted in the figures above, measured from their punches.</summary>
    public int NotOnRosterDays { get; set; }

    /// <summary>Their worked minutes (part of <see cref="WorkedMinutes"/>).</summary>
    public int NotOnRosterMinutes { get; set; }
}

public class WorkedTimeDay
{
    public int EmployeeId { get; set; }
    public DateTime WorkDate { get; set; }
    public string BranchName { get; set; } = string.Empty;

    /// <summary>The attendance day's status (Present, RestDay, Holiday, Leave, Absent), or 'NotOnRoster' for a punched
    /// day waiting for a decision, or 'Leave' / 'Holiday' for a day with no attendance day.</summary>
    public string Kind { get; set; } = string.Empty;

    /// <summary>Wall clock (Beirut), as every punch.</summary>
    public DateTime? FirstIn { get; set; }
    public DateTime? LastOut { get; set; }
    public int WorkedMinutes { get; set; }
    public int OvertimeMinutes { get; set; }
    public bool MissingPunch { get; set; }

    /// <summary>Entered or corrected by HR.</summary>
    public bool IsManual { get; set; }

    /// <summary>A holiday's name, or 'HalfDay' for half a day of leave.</summary>
    public string? Note { get; set; }
    public string? NoteAr { get; set; }
}

/// <summary>A row of report.usp_Report_WorkedTime_Days (script 113): one employee on one day of their employment.</summary>
public class WorkedTimeEmployeeDay
{
    public int EmployeeId { get; set; }
    public string FullName { get; set; } = string.Empty;
    public string DepartmentName { get; set; } = string.Empty;
    public DateTime WorkDate { get; set; }
    public int BranchId { get; set; }
    public string BranchName { get; set; } = string.Empty;
    public string? HolidayName { get; set; }
    public string? HolidayNameAr { get; set; }

    /// <summary>A working shift on the branch's approved roster: the attendance day's WorkedMinutes is then the shift
    /// window and the time after it is OvertimeMinutes.</summary>
    public bool HasRosterShift { get; set; }
}

/// <summary>A row of report.usp_Report_WorkedTime_PunchDays (script 114): a punched day missing from an approved roster,
/// measured from its punches as the processor measures a day with no shift.</summary>
public class WorkedTimePunchDay
{
    public int EmployeeId { get; set; }
    public DateTime WorkDate { get; set; }
    public int? BranchId { get; set; }
    public DateTime? FirstIn { get; set; }
    public DateTime? LastOut { get; set; }
    public int PunchCount { get; set; }
    public int WorkedMinutes { get; set; }
    public bool MissingPunch { get; set; }

    /// <summary>Script 117: the length of the shift the day's first punch fits (0 from a database without that script: the default day is used).</summary>
    public int StandardMinutes { get; set; }
}

/// <summary>The first result of report.usp_Report_WorkedTime_Days: the standard the progress is measured against.</summary>
public class WorkedTimeStandard
{
    public int StandardDayMinutes { get; set; }
    public decimal StandardDaysPerMonth { get; set; }
}
