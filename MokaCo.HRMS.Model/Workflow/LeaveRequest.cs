namespace MokaCo.HRMS.Model.Workflow;

/// <summary>
/// Leave requests — the SECOND concrete request type, built on exactly the same pattern as exit
/// permissions: one typed table, a Create that wraps usp_Request_Submit, and a Decide that wraps
/// usp_Request_Approve and may grant fewer days than were asked for.
///
/// THE BALANCE RULE, because it explains most of the shapes here: days are DEDUCTED AT APPROVAL,
/// never reserved at submit. What stops double-booking is the overlap refusal in
/// usp_LeaveRequest_Create, not a reservation. A balance may therefore go negative — but only when
/// an approver knowingly grants it, so <see cref="LeaveRequestDecideResult.BalanceIsNegative"/> is
/// a WARNING carried back to the UI, never a refusal.
/// </summary>
public class LeaveRequestCreated
{
    public int RequestInstanceId { get; set; }

    /// <summary>Pending, or Approved already if every step in the chain skipped itself.</summary>
    public string Status { get; set; } = string.Empty;
    public int? CurrentStepNo { get; set; }
    public int WorkflowVersion { get; set; }

    /// <summary>Inclusive calendar days, counted by the procedure — never by the client.</summary>
    public decimal DaysRequested { get; set; }

    /// <summary>
    /// The request was raised at shorter notice than the type prefers. ADVISORY ONLY — the request
    /// was accepted and is in flight. It is reported so the requester can be told, not so anything
    /// can be undone; nothing about the chain changes because of it.
    /// </summary>
    public bool NoticeShorterThanPreferred { get; set; }

    /// <summary>The notice this type prefers, in days — the figure the warning quotes. 0 when it has no preference.</summary>
    public int NoticePreferredDays { get; set; }
}

/// <summary>
/// The result of usp_LeaveRequest_Decide: the ordinary engine approval, plus the granted figure and
/// what the balance became once the ledger was posted.
///
/// The ledger movement happens ONCE, at the moment the request closes Approved — guarded by
/// AppliedToLedgerAt on the row, so a repeat call cannot double-post.
/// </summary>
public class LeaveRequestDecideResult
{
    public int RequestInstanceId { get; set; }
    public string Status { get; set; } = string.Empty;
    public int? CurrentStepNo { get; set; }
    public string? ClosedReason { get; set; }
    public string? Decision { get; set; }
    public bool SignedAsDeputy { get; set; }
    public bool SignedWithPassword { get; set; }

    /// <summary>What this approver granted — at most what was requested.</summary>
    public decimal DaysApproved { get; set; }

    /// <summary>The balance AFTER any ledger posting this decision caused. Unchanged until the request closes Approved.</summary>
    public decimal BalanceAfter { get; set; }

    /// <summary>Approved into the negative. Informative — the approver already decided; this is for the record and the UI.</summary>
    public bool BalanceIsNegative { get; set; }

    /// <summary>
    /// The leave was granted DISCRETIONARILY: approved as leave, but no usage was posted to the
    /// ledger, so the balance is untouched. Decided per request by the approver, not by the type.
    ///
    /// This reports what the procedure actually DID, which is not the same as what was asked for:
    /// a non-final approver may tick the box, but only the decision that closes the request Approved
    /// reaches the ledger, so every earlier step returns false here.
    /// </summary>
    public bool DiscretionaryGranted { get; set; }
}

/// <summary>The leave payload behind a request (usp_LeaveRequest_GetPayload), with the employee's balance for that type.</summary>
public class LeaveRequestPayload
{
    public int LeaveRequestId { get; set; }
    public int EmployeeId { get; set; }
    public string EmployeeName { get; set; } = string.Empty;
    public int LeaveTypeId { get; set; }
    public string LeaveTypeName { get; set; } = string.Empty;
    public bool IsPaid { get; set; }
    public DateTime FromDate { get; set; }
    public DateTime ToDate { get; set; }
    public decimal DaysRequested { get; set; }

    /// <summary>Null until an approver has decided. May be less than requested.</summary>
    public decimal? DaysApproved { get; set; }

    public string? Reason { get; set; }

    /// <summary>When the usage was posted to the ledger. Null until the request closed Approved.</summary>
    public DateTime? AppliedToLedgerAt { get; set; }

    /// <summary>Who the leave was for, on a relation-capped type (bereavement). Null on every other type.</summary>
    public string? RelationToEmployee { get; set; }

    /// <summary>This type cannot be approved without an attachment — usp_LeaveRequest_Decide refuses.</summary>
    public bool RequiresCertificate { get; set; }

    /// <summary>
    /// Attachments on the request. This is the COUNT THE APPROVAL GATE COUNTS, so the page can say a
    /// certificate is still missing rather than letting an approver discover it as they sign.
    /// </summary>
    public int AttachmentCount { get; set; }

    /// <summary>The employee's CURRENT balance for this leave type — the all-time ledger sum.</summary>
    public decimal CurrentBalance { get; set; }

    /// <summary>
    /// This leave was granted discretionarily — approved, but never deducted from the balance. A
    /// property of THE REQUEST, decided by the approver, not of the leave type.
    ///
    /// False on everything still in flight: it becomes true only when the approval that closed the
    /// request chose to waive the deduction, which is why AppliedToLedgerAt can stay null on an
    /// approved request without that being a fault.
    /// </summary>
    public bool IsDiscretionary { get; set; }

    /* ── THE NOTICE, as it stood when the request was raised ──
       The same three figures LeaveRequestCreated reports back to the REQUESTER, carried on the
       payload so the APPROVER sees them too. Advisory, exactly as they are at submit: short notice
       has never blocked anything, and nothing here changes that — usp_LeaveRequest_Decide does not
       consult them. They are reported so a signer can weigh the request, not so one can be refused
       automatically. */

    /// <summary>Days between the request being raised and the leave starting.</summary>
    public int NoticeGivenDays { get; set; }

    /// <summary>The notice this type prefers, in days. 0 when it has no preference.</summary>
    public int NoticePreferredDays { get; set; }

    /// <summary>
    /// Raised at shorter notice than the type prefers. ALWAYS FALSE when the type has no
    /// preference, so a type that never set one cannot look like it was breached.
    /// </summary>
    public bool NoticeShorterThanPreferred { get; set; }
}

/// <summary>One row of an employee's own leave history (usp_LeaveRequest_GetForEmployee).</summary>
public class MyLeaveRequest
{
    public int LeaveRequestId { get; set; }
    public int RequestInstanceId { get; set; }
    public string Status { get; set; } = string.Empty;
    public string LeaveTypeName { get; set; } = string.Empty;
    public DateTime FromDate { get; set; }
    public DateTime ToDate { get; set; }
    public decimal DaysRequested { get; set; }
    public decimal? DaysApproved { get; set; }
    public string? Reason { get; set; }
    public DateTime SubmittedAt { get; set; }
}

/// <summary>
/// An employee's balance for ONE leave type (hr.usp_Leave_GetBalance) — the all-time ledger sum,
/// which is the only honest definition: the ledger is the record, this just adds it up.
/// </summary>
public class LeaveBalanceSummary
{
    public string LeaveTypeName { get; set; } = string.Empty;
    public bool IsPaid { get; set; }

    /// <summary>
    /// THE YEARLY FIGURE, for THIS employee at today's date — hr.fn_GetAnnualEntitlement resolves
    /// the highest accrual tier their service qualifies for. It replaces the old per-month rate,
    /// which could not express "15 days, then 21 after five years".
    ///
    /// Zero means the type does not accrue (no tiers), which is a real answer, not a missing one.
    /// </summary>
    public decimal AnnualEntitlementDays { get; set; }

    public decimal CurrentBalance { get; set; }
    public decimal TotalUsed { get; set; }
}

/* ---- requests ---- */

/// <summary>
/// Raise a leave request. As with exit permissions, EmployeeId is WHOSE request it is, and the API —
/// not the database — enforces that a caller without REQUEST_RAISE_OTHERS may only pass their own.
///
/// The day count is deliberately ABSENT: the procedure counts inclusive calendar days itself, so the
/// client cannot disagree with the stored figure.
/// </summary>
public class LeaveRequestCreateRequest
{
    public int EmployeeId { get; set; }
    public int LeaveTypeId { get; set; }
    public DateTime FromDate { get; set; }
    public DateTime ToDate { get; set; }
    public string? Reason { get; set; }

    /// <summary>
    /// Optional title override. Left null/blank, the STORED PROCEDURE composes the standard title —
    /// the format lives there and only there, so a hand-typed default cannot drift from it.
    /// </summary>
    public string? Title { get; set; }

    /// <summary>
    /// Who the leave is for, on a relation-capped type (bereavement). Required by the procedure for
    /// any type with relation entitlements, and it caps the days — a parent allows more than an aunt.
    /// Null on every other type, where the procedure ignores it.
    /// </summary>
    public string? RelationToEmployee { get; set; }
}

/// <summary>
/// Approve a leave request, optionally granting fewer days than were asked for. The dates are NOT
/// trimmed — the approver states a day count and the ledger posts that figure, because trimming the
/// dates would silently change which days the person is away.
/// </summary>
public class LeaveRequestDecideRequest
{
    /// <summary>Null means "as requested". The procedure refuses 0, negatives, and more than requested.</summary>
    public decimal? ApprovedDays { get; set; }

    public string? Comment { get; set; }

    /// <summary>The decision code the user chose, kept so the step records the label rather than just the action.</summary>
    public string? Code { get; set; }

    /// <summary>Sent only when the step or the caller's role demands a signature. Verified before anything is written.</summary>
    public string? Password { get; set; }

    /// <summary>
    /// Grant the leave WITHOUT deducting it from the balance — paid time off the books, as a
    /// one-off favour rather than a property of the leave type.
    ///
    /// Defaults to false, which is what every existing caller sends by omitting it: an absent field
    /// binds to false and the procedure's own @MakeDiscretionary default is 0, so the ordinary
    /// deduction is what happens unless somebody actively asks otherwise.
    ///
    /// Every approver in the chain may set it, but only the FINAL approval posts (or waives) the
    /// ledger movement — so it is the last approver's answer that takes effect, and the result's
    /// <see cref="LeaveRequestDecideResult.DiscretionaryGranted"/> says what was actually done.
    /// </summary>
    public bool MakeDiscretionary { get; set; }
}
