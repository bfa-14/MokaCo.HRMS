namespace MokaCo.HRMS.Model.Attendance;

/// <summary>
/// Maps to attendance.ATTENDANCE_CORRECTION. A correction is a LOGGED, APPROVED change to a
/// PROCESSED day — it stores the OLD and the NEW values side by side so the change can be defended
/// later. The raw punches from the machine are NEVER overwritten: what the device said and what HR
/// decided are two different facts, and both survive.
/// Approving one applies the new values, recomputes the day against the same rules as everywhere
/// else, clears the anomaly, and marks the record manual so the processor stops touching it.
/// </summary>
public class Correction
{
    public int CorrectionId { get; set; }
    public long AttendanceId { get; set; }
    public DateTime WorkDate { get; set; }
    public int EmployeeId { get; set; }
    public string FullName { get; set; } = string.Empty;

    public DateTime? OldFirstInUtc { get; set; }
    public DateTime? OldLastOutUtc { get; set; }
    public int? OldExitMinutes { get; set; }
    public string? OldStatus { get; set; }

    public DateTime? NewFirstInUtc { get; set; }
    public DateTime? NewLastOutUtc { get; set; }
    public int? NewExitMinutes { get; set; }
    public string? NewStatus { get; set; }

    /// <summary>Mandatory. A correction without a reason is an unexplained change to someone's pay.</summary>
    public string Reason { get; set; } = string.Empty;

    /// <summary>Pending / Approved / Rejected. A PENDING correction means the figures are about to change, so it blocks payroll.</summary>
    public string ApprovalStatus { get; set; } = string.Empty;

    public int RequestedBy { get; set; }
    public string? RequestedByUser { get; set; }
    public int? ApprovedBy { get; set; }
    public string? ApprovedByUser { get; set; }

    public DateTime RequestedUtc { get; set; }
    public DateTime? ActedUtc { get; set; }
}

/// <summary>What approving a correction recomputed, so the caller can show the new numbers immediately.</summary>
public class CorrectionApplyResult
{
    public long AttendanceId { get; set; }
    public int WorkedMinutes { get; set; }
    public decimal DayFraction { get; set; }
    public int LateMinutes { get; set; }
}
