namespace MokaCo.HRMS.Model.Workflow;

/// <summary>
/// An exit permission — leave to be away mid-day — as returned by usp_ExitPermission_Create.
///
/// The permission and the attendance day are linked in ONE direction only: attendance points at the
/// permission, never the reverse. A permission is often approved BEFORE the day happens, when there
/// is no attendance record to point at yet — so it waits, and the nightly apply job pushes the
/// approved minutes in once the day is processed.
/// </summary>
public class ExitPermissionCreated
{
    public int ExitPermissionId { get; set; }
    public int RequestInstanceId { get; set; }
    public int EmployeeId { get; set; }
    public DateTime ExitDate { get; set; }
    public TimeSpan FromTime { get; set; }
    public TimeSpan ToTime { get; set; }
    public int Minutes { get; set; }

    /// <summary>1 = these hours come out of annual leave; 0 = handled as a pay matter, not deducted from leave.</summary>
    public bool ConvertToLeave { get; set; }

    /// <summary>The request's status straight after submit — Pending, or Approved if every step skipped itself.</summary>
    public string Status { get; set; } = string.Empty;
    public int? CurrentStepNo { get; set; }
    public string? Title { get; set; }
}

/// <summary>An exit permission in the employee's own list (usp_ExitPermission_GetForEmployee).</summary>
public class MyExitPermission
{
    public int ExitPermissionId { get; set; }
    public int RequestInstanceId { get; set; }
    public DateTime ExitDate { get; set; }
    public TimeSpan FromTime { get; set; }
    public TimeSpan ToTime { get; set; }
    public int Minutes { get; set; }
    public string Reason { get; set; } = string.Empty;
    public bool ConvertToLeave { get; set; }
    public string Status { get; set; } = string.Empty;
    public int? CurrentStepNo { get; set; }
    public string? CurrentStepName { get; set; }

    /// <summary>When the approved minutes were pushed into attendance. NULL until that happens — the day may not exist yet.</summary>
    public DateTime? AppliedToAttendanceAt { get; set; }

    public DateTime SubmittedAt { get; set; }
    public DateTime? ClosedAt { get; set; }
    public string? ClosedReason { get; set; }
}

/// <summary>
/// The exit-permission payload for a request, WITH what attendance eventually recorded
/// (usp_ExitPermission_GetByRequest).
///
/// The approved / actual / variance figures come from the attendance record and are all null until
/// the day exists and the permission is applied — that is why the request detail only shows the
/// comparison "once the day exists".
/// </summary>
public class ExitPermissionDetail
{
    public int ExitPermissionId { get; set; }
    public int RequestInstanceId { get; set; }
    public int EmployeeId { get; set; }
    public string FullName { get; set; } = string.Empty;
    public string BranchName { get; set; } = string.Empty;
    public DateTime ExitDate { get; set; }
    public TimeSpan FromTime { get; set; }
    public TimeSpan ToTime { get; set; }
    public int Minutes { get; set; }

    /// <summary>The requested minutes expressed as leave days at the configured standard day. Distinct from what is actually deducted.</summary>
    public decimal RequestedLeaveDays { get; set; }

    public string Reason { get; set; } = string.Empty;
    public bool ConvertToLeave { get; set; }
    public DateTime? AppliedToAttendanceAt { get; set; }
    public DateTime CreatedAt { get; set; }

    /* -- from the attendance record, once it exists (all null until then) -- */
    public long? AttendanceId { get; set; }

    /// <summary>What the punches actually showed they were away for.</summary>
    public int? ExitActualMinutes { get; set; }

    /// <summary>What this permission authorised (the approved minutes, pushed in on apply).</summary>
    public int? ExitApprovedMinutes { get; set; }

    /// <summary>Actual minus approved — kept independent of both, for HR to rule on.</summary>
    public int? ExitVarianceMinutes { get; set; }

    public int? ExitLeaveMinutes { get; set; }
    public string? ExitVarianceDisposition { get; set; }
}

/// <summary>A permission approved but not yet reflected in attendance (usp_ExitPermission_GetPendingApplication).</summary>
public class PendingApplication
{
    public int ExitPermissionId { get; set; }
    public int RequestInstanceId { get; set; }
    public int EmployeeId { get; set; }
    public string FullName { get; set; } = string.Empty;
    public string BranchName { get; set; } = string.Empty;
    public DateTime ExitDate { get; set; }
    public TimeSpan FromTime { get; set; }
    public TimeSpan ToTime { get; set; }
    public int Minutes { get; set; }
    public bool ConvertToLeave { get; set; }
    public string Status { get; set; } = string.Empty;

    /// <summary>The exit date is already in the past but the day was never applied — worth chasing.</summary>
    public bool IsOverdue { get; set; }
}

/// <summary>How many permissions a sweep pushed into attendance (usp_ExitPermission_ApplyToAttendance).</summary>
public class ApplyResult
{
    public int PermissionsApplied { get; set; }
}

/// <summary>How many leave movements a period close posted (usp_ExitPermission_PostLeaveUsage).</summary>
public class PostLeaveResult
{
    public int LeaveMovementsPosted { get; set; }
}

/// <summary>
/// The result of withdrawing a decision on an exit permission (usp_ExitPermission_WithdrawDecision):
/// the figure restored to what it was before the withdrawn step, and where the request now stands.
/// </summary>
public class WithdrawDecisionResult
{
    public int ExitPermissionId { get; set; }
    public int RequestedMinutes { get; set; }

    /// <summary>Null once the figure is unsigned back to "not yet approved".</summary>
    public int? ApprovedMinutes { get; set; }

    public string Status { get; set; } = string.Empty;
    public int? CurrentStepNo { get; set; }
}

/// <summary>
/// The result of a TYPED exit-permission decision (usp_ExitPermission_Decide): the engine's own
/// approval result, plus what the figure ended up being.
///
/// <see cref="MinutesReduced"/> and <see cref="WasReduced"/> come from the procedure rather than
/// being worked out here — the approver may have left the figure alone, and the difference between
/// "approved as asked" and "cut to 30" is the whole substance of the decision.
/// </summary>
public class ExitPermissionDecisionResult : TypedDecisionResult
{
    public int ExitPermissionId { get; set; }
    public int RequestedMinutes { get; set; }
    public int? ApprovedMinutes { get; set; }

    /// <summary>Requested minus approved. Zero when the approver granted the request in full.</summary>
    public int MinutesReduced { get; set; }
    public bool WasReduced { get; set; }
}

/* ---- request ---- */

/// <summary>
/// A decision on an exit permission, carrying the minutes being signed for.
///
/// ApprovedMinutes is OPTIONAL and null means "as it stands" — the procedure's own default, and the
/// common case. Sending the standing figure back explicitly means the same thing; sending MORE is
/// refused, because an approver may cut the time away but never extend it.
/// </summary>
public class ExitPermissionDecideRequest
{
    public int? ApprovedMinutes { get; set; }
    public string? Comment { get; set; }

    /// <summary>The decision the user chose, for the record. The engine action is always an approval here.</summary>
    public string? Code { get; set; }

    /// <summary>Verified before anything is written, exactly as the generic approve does it.</summary>
    public string? Password { get; set; }
}

/// <summary>
/// Raise an exit permission. EmployeeId is WHOSE request it is — a caller with only
/// REQUEST_RAISE_SELF may pass only their own; REQUEST_RAISE_OTHERS lifts that, and the API enforces
/// it before this ever reaches the database.
/// </summary>
public class ExitPermissionCreateRequest
{
    public int EmployeeId { get; set; }
    public DateTime ExitDate { get; set; }
    public TimeSpan FromTime { get; set; }
    public TimeSpan ToTime { get; set; }
    public string Reason { get; set; } = string.Empty;

    /// <summary>Default ON — the common case is that a mid-day exit comes out of annual leave.</summary>
    public bool ConvertToLeave { get; set; } = true;

    /// <summary>
    /// Optional title override. Left null/blank, the STORED PROCEDURE composes the standard title —
    /// the format lives there and only there, so a hand-typed default cannot drift from it.
    /// </summary>
    public string? Title { get; set; }
}

/// <summary>Period-close request to post the leave usage for converted exit permissions.</summary>
public class PostLeaveRequest
{
    public string PeriodYearMonth { get; set; } = string.Empty;
    public int LeaveTypeId { get; set; }
}
