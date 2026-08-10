namespace MokaCo.HRMS.Model.Workflow;

/// <summary>
/// What raising a payroll adjustment produced.
///
/// Nothing lands in the ledger yet. The request is the CLAIM ("July underpaid Rami 40 USD"); the
/// payroll.PAYROLL_ADJUSTMENT row the next Generate consumes is written only by the FINAL approval.
/// Until then there is a request and nothing else.
/// </summary>
public sealed class PayrollAdjustmentCreated
{
    public int RequestInstanceId { get; set; }
    public string Status { get; set; } = string.Empty;
    public int? CurrentStepNo { get; set; }
}

/// <summary>
/// The payload — workflow.usp_PayrollAdjustment_GetPayload.
///
/// The last three properties are the LIFECYCLE, and they only ever move forwards:
/// waiting → <see cref="CreatedAdjustmentId"/> set at final approval → <see cref="AppliedToPayslipId"/>
/// set when the target period's run is locked. Read them in that order; each is null until its
/// moment, and the null is the state, not missing data.
/// </summary>
public sealed class PayrollAdjustmentPayload
{
    public int PayrollAdjustmentRequestId { get; set; }
    public int EmployeeId { get; set; }
    public string EmployeeName { get; set; } = string.Empty;

    public int ComponentTypeId { get; set; }
    public string ComponentName { get; set; } = string.Empty;
    /// <summary>Earning / Deduction / EmployerCost.</summary>
    public string Category { get; set; } = string.Empty;
    /// <summary>+1 or -1. THE SIGN DECIDES DIRECTION; the amount is always positive.</summary>
    public short Sign { get; set; }

    /// <summary>What was ASKED FOR. It never changes — the claim as raised is part of the record.</summary>
    public decimal Amount { get; set; }

    /// <summary>
    /// What the last approver actually signed for, or null while nobody has yet.
    ///
    /// THE STANDING FIGURE IS <c>ApprovedAmount ?? Amount</c>, and that is the number the next
    /// approver is deciding about — not the original request. Each signature may tighten it and
    /// never raise it, so reading <see cref="Amount"/> as "the amount" once a chain is underway
    /// shows a figure that has already been superseded.
    /// </summary>
    public decimal? ApprovedAmount { get; set; }

    public string CurrencyCode { get; set; } = string.Empty;

    /// <summary>The open period whose payslip will carry this line. Format 2026-09.</summary>
    public string TargetPeriod { get; set; } = string.Empty;

    public int? CorrectsRunId { get; set; }
    /// <summary>The period of the locked run being corrected, joined so the panel needs no second read.</summary>
    public string? CorrectsPeriod { get; set; }

    public string Reason { get; set; } = string.Empty;

    /// <summary>The ledger row this request created. Null until the final approval writes it.</summary>
    public int? CreatedAdjustmentId { get; set; }
    public DateTime? AdjustmentCreatedAt { get; set; }

    /// <summary>The payslip that consumed the ledger row. Null until the target period is locked.</summary>
    public int? AppliedToPayslipId { get; set; }
}

/// <summary>POST /api/payroll-adjustment-requests. The raiser comes from the token.</summary>
public sealed class PayrollAdjustmentCreateRequest
{
    public int EmployeeId { get; set; }
    public int ComponentTypeId { get; set; }
    /// <summary>Above zero. The component type's sign decides direction, not this figure.</summary>
    public decimal Amount { get; set; }
    public string CurrencyCode { get; set; } = string.Empty;
    /// <summary>Format 2026-09. A period whose run is already locked is refused.</summary>
    public string TargetPeriod { get; set; } = string.Empty;
    /// <summary>Optional, and must name an APPROVED run — a correction references history.</summary>
    public int? CorrectsRunId { get; set; }
    /// <summary>Required — the procedure refuses an unexplained adjustment, and says why.</summary>
    public string? Reason { get; set; }
    /// <summary>Optional override; the procedure composes one when this is blank.</summary>
    public string? Title { get; set; }
}

/// <summary>
/// POST /api/payroll-adjustment-requests/{id}/decide — the APPROVE path, and the figure being signed.
///
/// THE AMOUNT IS PART OF THE SIGNATURE. An approver is not agreeing to a claim someone else wrote;
/// they are stating the number that will land on the payslip, and it is recorded against their name.
/// The procedure is what enforces the rules — no more than was requested, and never more than an
/// earlier approver already allowed — so an approver may tighten a figure on its way up the chain
/// but never loosen it, and granting MORE means rejecting and raising again.
///
/// REJECTING CARRIES NO FIGURE, and does not come through here: there is nothing to sign for a
/// request that is being refused.
/// </summary>
public sealed class PayrollAdjustmentDecideRequest
{
    /// <summary>
    /// Required, above zero. Nullable so that "not sent at all" is distinguishable from "sent as
    /// zero" — the two are different mistakes and deserve different sentences. Zero is not a way to
    /// grant nothing; rejecting is.
    /// </summary>
    public decimal? ApprovedAmount { get; set; }

    public string? Comment { get; set; }
    /// <summary>Present only when the step requires a signature; verified against the caller's own hash.</summary>
    public string? Password { get; set; }
}

/// <summary>
/// The generic decision outcome plus the two facts this type adds: the figure that was signed, and
/// the ledger row if this signature was the one that created it.
/// </summary>
public sealed class PayrollAdjustmentDecisionResult
{
    public int RequestInstanceId { get; set; }
    public string Status { get; set; } = string.Empty;
    public int? CurrentStepNo { get; set; }
    public string? ClosedReason { get; set; }
    public string? Decision { get; set; }
    public bool SignedAsDeputy { get; set; }
    public bool SignedWithPassword { get; set; }

    /// <summary>
    /// The figure this signature actually set, echoed back BY THE PROCEDURE rather than by the
    /// caller. Read it rather than assuming the request body took effect — it is the new standing
    /// amount, and it is what the next approver in the chain will be shown.
    /// </summary>
    public decimal ApprovedAmount { get; set; }

    /// <summary>Non-null once the final approval has written the payroll ledger row.</summary>
    public int? CreatedAdjustmentId { get; set; }
}
