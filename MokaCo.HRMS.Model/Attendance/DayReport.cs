namespace MokaCo.HRMS.Model.Attendance;

/// <summary>Script 110: "something is wrong with this day", one report, with the day as it stands now.</summary>
public class DayReport
{
    public int ReportId { get; set; }
    public int EmployeeId { get; set; }
    public string EmployeeName { get; set; } = string.Empty;
    public int? BranchId { get; set; }
    public string? BranchName { get; set; }
    public DateTime WorkDate { get; set; }
    /// <summary>The reported times (the terminal's wall clock, like every punch). Either may be empty.</summary>
    public DateTime? ClaimedIn { get; set; }
    public DateTime? ClaimedOut { get; set; }
    public string Message { get; set; } = string.Empty;
    public int ReportedByUserId { get; set; }
    public string? ReportedBy { get; set; }
    public DateTime ReportedAtUtc { get; set; }
    /// <summary>Open | Accepted | Rejected | Withdrawn.</summary>
    public string Status { get; set; } = string.Empty;
    public string? DecidedBy { get; set; }
    public DateTime? DecidedAtUtc { get; set; }
    /// <summary>HR's answer to the reporter (a rejection always carries one).</summary>
    public string? DecisionNote { get; set; }
    public int? CorrectionId { get; set; }
    public long? AttendanceId { get; set; }
    public DateTime? CurrentFirstIn { get; set; }
    public DateTime? CurrentLastOut { get; set; }
    public string? CurrentStatus { get; set; }
    public int? CurrentWorkedMinutes { get; set; }
    public bool CurrentHasAnomaly { get; set; }
    public bool IsAboutMe { get; set; }
    public bool CanDecide { get; set; }
}

/// <summary>POST /api/day-reports. EmployeeId empty = the caller's own day.</summary>
public class DayReportCreateRequest
{
    public int? EmployeeId { get; set; }
    public DateTime WorkDate { get; set; }
    public DateTime? ClaimedIn { get; set; }
    public DateTime? ClaimedOut { get; set; }
    public string Message { get; set; } = string.Empty;
}

/// <summary>POST /api/day-reports/{id}/decide.</summary>
public class DayReportDecisionRequest
{
    public bool Accept { get; set; }
    /// <summary>Required to reject (the reporter reads it); optional to accept.</summary>
    public string? Note { get; set; }
}

public class DayReportDecisionResult
{
    public int ReportId { get; set; }
    public string Status { get; set; } = string.Empty;
    public int? CorrectionId { get; set; }
}

/// <summary>What the accept path reads first (attendance.usp_DayReport_Get).</summary>
public class DayReportHeader
{
    public int ReportId { get; set; }
    public int EmployeeId { get; set; }
    public DateTime WorkDate { get; set; }
    public DateTime? ClaimedIn { get; set; }
    public DateTime? ClaimedOut { get; set; }
    public string Message { get; set; } = string.Empty;
    public int ReportedByUserId { get; set; }
    public string Status { get; set; } = string.Empty;
    public long? AttendanceId { get; set; }
    public string? ReportedBy { get; set; }
}
