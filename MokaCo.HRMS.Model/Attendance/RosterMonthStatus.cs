namespace MokaCo.HRMS.Model.Attendance;

/// <summary>
/// WHERE ONE BRANCH-MONTH OF ROSTER HAS GOT TO — attendance.usp_RosterMonth_Get.
///
/// The whole response is NULL when the branch-month has no row yet, which is the ordinary state of
/// a month nobody has put up: there is no record to describe, and inventing a synthetic "Draft" row
/// here would be this layer deciding something the procedure did not say.
///
/// <see cref="Status"/> is a plain string, not an enum: an unrecognised state from a newer server
/// must render as itself on the client rather than fail to deserialize.
/// </summary>
public class RosterMonthStatus
{
    public int BranchId { get; set; }

    /// <summary>The month asked for, echoed back as its first day.</summary>
    public DateTime MonthDate { get; set; }

    /// <summary>Draft · Pending · Approved.</summary>
    public string Status { get; set; } = string.Empty;

    /// <summary>When the month was signed off. Null unless Approved.</summary>
    public DateTime? ApprovedAt { get; set; }

    /// <summary>The ROSTER_APPROVAL request carrying it. Null while Draft — nothing to link to yet.</summary>
    public int? RequestInstanceId { get; set; }

    /// <summary>
    /// That request's OWN status (Pending, Approved, Rejected, Cancelled), which is not the same
    /// fact as <see cref="Status"/> above: a rejected or cancelled request leaves the month back at
    /// Draft while the request it came from still exists and is still worth linking to.
    /// </summary>
    public string? RequestStatus { get; set; }
}
