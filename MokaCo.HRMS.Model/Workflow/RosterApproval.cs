namespace MokaCo.HRMS.Model.Workflow;

/// <summary>
/// ROSTER APPROVAL — one branch's WHOLE MONTH of roster, put up for signature as a single request.
///
/// THE SUBJECT IS A BRANCH AND A MONTH, not a person. There is no EmployeeId in the payload: the
/// header still needs one (every request is filed against somebody), so it is the RAISER's own
/// employee record, taken from the caller identity exactly as RaisedByUserId is. Nothing about
/// whose roster it is comes from the client.
///
/// NO TYPED DECISION EXISTS, deliberately. Approving one changes no figure the approver chose — the
/// engine's ApplyApprovalEffects activates the month — so it goes through the GENERIC approve path
/// like any request whose approval is just an approval. That is why ROSTER_APPROVAL is absent from
/// RequestService.TypedDecideOnly, and adding it there would break deciding rather than protect it.
/// </summary>
public class RosterApprovalCreateRequest
{
    public int BranchId { get; set; }

    /// <summary>
    /// The month, as its FIRST DAY: 'yyyy-MM-01'. A whole date rather than a 'yyyy-MM' string
    /// because that is what the table stores; the day is normalised to 01 before the procedure sees
    /// it, so a caller sending mid-month cannot create a second request for the same month.
    /// </summary>
    public DateTime MonthDate { get; set; }

    /// <summary>
    /// Optional title override. Left null/blank, the STORED PROCEDURE composes the standard title —
    /// the format lives there and only there, so a hand-typed default cannot drift from it.
    /// </summary>
    public string? Title { get; set; }
}

/// <summary>What raising one produced — the same three fields every typed create returns.</summary>
public class RosterApprovalCreated
{
    public int RequestInstanceId { get; set; }

    /// <summary>Pending, or Approved already if every step in the chain skipped itself.</summary>
    public string Status { get; set; } = string.Empty;

    public int? CurrentStepNo { get; set; }
}
