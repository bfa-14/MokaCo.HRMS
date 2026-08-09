namespace MokaCo.HRMS.Model.Workflow;

/// <summary>
/// What raising an expense produced.
///
/// THE CHAIN IS RAISED IN FULL. Submitting no longer skips anything: only a decision knows the
/// GRANTED amount, and only the granted amount decides whether the Owner is needed. So creating an
/// expense reports a prediction, never a routing.
///
/// The USD conversion happens here and the rate is FROZEN on the row, so routing stays stable if
/// rates move mid-flight. With no rate on file the procedure refuses outright rather than guess one.
/// </summary>
public sealed class ExpenseCreated
{
    public int RequestInstanceId { get; set; }
    public string Status { get; set; } = string.Empty;
    public int? CurrentStepNo { get; set; }

    /// <summary>The amount in USD — equal to Amount for a USD expense, converted otherwise.</summary>
    public decimal AmountUsd { get; set; }

    /// <summary>The rate used for the conversion, stored so the USD figure stays explicable.</summary>
    public decimal RateUsed { get; set; }

    /// <summary>The USD figure above which the Owner must also sign.</summary>
    public decimal ThresholdUsd { get; set; }

    /// <summary>
    /// LIKELY, not settled — the procedure's own column name, and the distinction matters. The
    /// REQUESTED amount is above the threshold, so on present evidence the Owner will be asked. What
    /// actually decides is the amount the operations manager GRANTS: grant at or under the threshold
    /// and the remaining steps are skipped at that moment instead. Never phrase this to a requester
    /// as a settled fact.
    /// </summary>
    public bool OwnerLikelyNeeded { get; set; }
}

/// <summary>The expense payload (usp_Expense_GetPayload).</summary>
public sealed class ExpensePayload
{
    public int ExpenseReimbursementId { get; set; }
    public int EmployeeId { get; set; }
    public string EmployeeName { get; set; } = string.Empty;
    public DateTime ExpenseDate { get; set; }
    public string Category { get; set; } = string.Empty;

    public decimal Amount { get; set; }
    public string CurrencyCode { get; set; } = string.Empty;
    public decimal AmountUsd { get; set; }
    /// <summary>The rate the USD figure was computed at. 1 for a USD expense.</summary>
    public decimal RateUsed { get; set; }
    public decimal ThresholdUsd { get; set; }

    /// <summary>Null until an approver has decided. May be less than requested.</summary>
    public decimal? ApprovedAmount { get; set; }

    public string? Description { get; set; }
    /// <summary>When payroll paid it out. Null until then.</summary>
    public DateTime? ReimbursedInPayrollAt { get; set; }

    /// <summary>
    /// Attachments on the request. ZERO IS THE INTERESTING CASE: the decide procedure refuses to
    /// approve without one, so the panel warns before an approver meets that refusal.
    /// </summary>
    public int ReceiptCount { get; set; }

    /// <summary>
    /// Whether the REQUESTED amount is above the threshold. A statement about the claim, not about
    /// the routing: what the approver grants is what settles whether the Owner is asked.
    /// </summary>
    public bool OwnerSignatureRequired { get; set; }
}

/// <summary>One row of an employee's own expense history (usp_Expense_GetForEmployee).</summary>
public sealed class MyExpense
{
    public int ExpenseReimbursementId { get; set; }
    public int RequestInstanceId { get; set; }
    public string Status { get; set; } = string.Empty;
    public DateTime ExpenseDate { get; set; }
    public string Category { get; set; } = string.Empty;
    public decimal Amount { get; set; }
    public string CurrencyCode { get; set; } = string.Empty;
    public decimal AmountUsd { get; set; }
    public decimal? ApprovedAmount { get; set; }
    public DateTime SubmittedAt { get; set; }
}

/* ---- requests ---- */

/// <summary>
/// Raise an expense. EmployeeId is WHOSE expense it is; the API enforces that a caller without
/// REQUEST_RAISE_OTHERS may only pass their own.
/// </summary>
public sealed class ExpenseCreateRequest
{
    public int EmployeeId { get; set; }
    public DateTime ExpenseDate { get; set; }
    public string Category { get; set; } = string.Empty;
    public decimal Amount { get; set; }
    public string CurrencyCode { get; set; } = string.Empty;
    public string? Description { get; set; }
    public string? Title { get; set; }
}

/// <summary>
/// Approve an expense, optionally granting less. Null means "as requested" — the procedure's own
/// default, passed through rather than resolved here.
/// </summary>
public sealed class ExpenseDecideRequest
{
    /// <summary>
    /// REQUIRED by the procedure — every expense decision carries its figure, in the ORIGINAL
    /// currency. Deliberately still nullable HERE: an omitted field then arrives as NULL and earns
    /// the procedure's precise "State the approved amount" message, whereas a non-nullable decimal
    /// would bind to 0 and produce the wrong complaint ("must be between 0 and the 80.00 requested").
    /// </summary>
    public decimal? ApprovedAmount { get; set; }

    public string? Comment { get; set; }
    /// <summary>Verified against the stored Argon2id hash BEFORE anything is written. Never logged or echoed.</summary>
    public string? Password { get; set; }
}

/// <summary>
/// What an expense decision returned: the engine's result, the granted figure, and WHERE THE
/// REQUEST WENT because of it.
///
/// THE GRANTED AMOUNT ROUTES THE REQUEST. There is no signer cap any more — the operations manager
/// may grant anything up to what was claimed — and what he grants decides who else signs:
///   • at or under the threshold → the remaining steps are skipped and the request closes Approved
///     on his signature (<see cref="RemainingStepsSkipped"/>);
///   • above it → the Owner step stands and the request stays open on them
///     (<see cref="GoesToOwner"/>).
/// The Owner is never skipped by his own decision — he is the last word.
///
/// Both flags come from the procedure rather than being re-derived from ApprovedUsd and ThresholdUsd
/// by the caller: the routing also depends on where in the chain the decision was taken, which only
/// the procedure knows.
/// </summary>
public sealed class ExpenseDecisionResult
{
    public int RequestInstanceId { get; set; }
    public string Status { get; set; } = string.Empty;
    public int? CurrentStepNo { get; set; }
    public string? ClosedReason { get; set; }
    public string? Decision { get; set; }
    public bool SignedAsDeputy { get; set; }
    public bool SignedWithPassword { get; set; }

    /// <summary>The granted figure, in the expense's own currency.</summary>
    public decimal ApprovedAmount { get; set; }

    /// <summary>The same figure in USD at the rate frozen on the expense — what the routing tests.</summary>
    public decimal ApprovedUsd { get; set; }

    /// <summary>The USD figure the grant was tested against, so a near-threshold outcome stays explicable.</summary>
    public decimal ThresholdUsd { get; set; }

    /// <summary>
    /// The grant landed at or under the threshold and later steps existed, so they were skipped and
    /// the request closed Approved. The skipped steps show grey with their reason in the chain — the
    /// caller must refetch it, or the page will still show a step waiting on somebody.
    /// </summary>
    public bool RemainingStepsSkipped { get; set; }

    /// <summary>The grant was above the threshold and the request is now open on the Owner.</summary>
    public bool GoesToOwner { get; set; }
}
