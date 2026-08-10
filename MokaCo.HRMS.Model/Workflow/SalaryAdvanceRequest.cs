namespace MokaCo.HRMS.Model.Workflow;

/// <summary>
/// What raising a salary advance produced.
///
/// No money has moved and no ledger row exists yet — the request is the ASK. The
/// payroll.SALARY_ADVANCE row that payroll recovers against is written only by the final approval.
/// </summary>
public sealed class SalaryAdvanceCreated
{
    public int RequestInstanceId { get; set; }
    public string Status { get; set; } = string.Empty;
    public int? CurrentStepNo { get; set; }
    /// <summary>CEILING(amount / monthly) — how long recovery will take, from the procedure itself.</summary>
    public int Months { get; set; }
}

/// <summary>
/// The payload — workflow.usp_SalaryAdvance_GetPayload.
///
/// The last four properties are the LIFECYCLE: waiting → <see cref="CreatedAdvanceId"/> written by
/// the final approval → then <see cref="RemainingAmount"/> falling month by month as payroll
/// recovers it, until <see cref="IsSettled"/>. The last two are LIVE figures joined from the ledger,
/// not a snapshot of the request, so the panel shows what is actually still owed today.
/// </summary>
public sealed class SalaryAdvancePayload
{
    public int SalaryAdvanceRequestId { get; set; }
    public int EmployeeId { get; set; }
    public string EmployeeName { get; set; } = string.Empty;

    /// <summary>What was ASKED FOR. Unchanged by the chain — the ask is part of the record.</summary>
    public decimal Amount { get; set; }

    /// <summary>
    /// What the last approver signed for, or null while nobody has. The STANDING figure is
    /// <c>ApprovedAmount ?? Amount</c> — that is what the next approver is deciding about, and each
    /// signature may tighten it, never raise it.
    /// </summary>
    public decimal? ApprovedAmount { get; set; }

    public string CurrencyCode { get; set; } = string.Empty;

    /// <summary>What was asked to come off each month.</summary>
    public decimal MonthlyDeduction { get; set; }

    /// <summary>
    /// The signed monthly, or null while nobody has signed. Standing monthly is
    /// <c>ApprovedMonthlyDeduction ?? MonthlyDeduction</c>, and the procedure keeps it inside the
    /// approved amount: tightening the advance to 200 silently clamps a 300/month schedule to 200,
    /// because a deduction larger than the loan is not a schedule, it is an error.
    /// </summary>
    public decimal? ApprovedMonthlyDeduction { get; set; }

    /// <summary>Format 2026-09 — recovery starts here, and it must be an open month.</summary>
    public string FirstDeductionPeriod { get; set; } = string.Empty;

    /// <summary>
    /// How many months recovery takes. Computed by the procedure FROM THE STANDING FIGURES, so it
    /// already reflects any tightening — do not recompute it from <see cref="Amount"/>.
    /// </summary>
    public int Months { get; set; }
    public string? Reason { get; set; }

    /// <summary>The ledger row. Null until the final approval writes it.</summary>
    public int? CreatedAdvanceId { get; set; }
    public DateTime? AdvanceCreatedAt { get; set; }
    /// <summary>Live from the ledger; null before the row exists. Falls as payroll recovers.</summary>
    public decimal? RemainingAmount { get; set; }
    /// <summary>Null before the row exists; true once nothing is left to recover.</summary>
    public bool? IsSettled { get; set; }
}

/// <summary>POST /api/salary-advance-requests. The raiser comes from the token.</summary>
public sealed class SalaryAdvanceCreateRequest
{
    public int EmployeeId { get; set; }
    public decimal Amount { get; set; }
    public string CurrencyCode { get; set; } = string.Empty;
    /// <summary>Above zero and no more than the advance — the procedure enforces both.</summary>
    public decimal MonthlyDeduction { get; set; }
    /// <summary>Format 2026-09. Must be a month whose primary payroll is not yet locked.</summary>
    public string FirstDeductionPeriod { get; set; } = string.Empty;
    public string? Reason { get; set; }
    public string? Title { get; set; }
}

/// <summary>
/// POST /api/salary-advance-requests/{id}/decide — the APPROVE path, carrying both signed figures.
///
/// TWO NUMBERS, ONE SIGNATURE: how much is lent, and how fast it comes back. The approver signs
/// both, and the procedure keeps them consistent — the monthly can never exceed the amount, so
/// tightening the loan tightens the schedule with it whether or not the caller says so.
/// Rejecting carries no figures and does not come through here.
/// </summary>
public sealed class SalaryAdvanceDecideRequest
{
    /// <summary>
    /// Required, above zero. Nullable so "not sent" and "sent as zero" stay distinguishable.
    /// </summary>
    public decimal? ApprovedAmount { get; set; }

    /// <summary>
    /// OPTIONAL, and null is a real answer rather than a missing one: it means "keep the standing
    /// schedule", and the procedure carries it over — clamped down to the approved amount if
    /// tightening the loan has made it too big. Send a value only to change the schedule
    /// deliberately.
    /// </summary>
    public decimal? ApprovedMonthlyDeduction { get; set; }

    public string? Comment { get; set; }
    public string? Password { get; set; }
}

/// <summary>The generic decision outcome, plus both signed figures and the ledger row if this signature created it.</summary>
public sealed class SalaryAdvanceDecisionResult
{
    public int RequestInstanceId { get; set; }
    public string Status { get; set; } = string.Empty;
    public int? CurrentStepNo { get; set; }
    public string? ClosedReason { get; set; }
    public string? Decision { get; set; }
    public bool SignedAsDeputy { get; set; }
    public bool SignedWithPassword { get; set; }

    /// <summary>The amount this signature set, echoed back by the procedure.</summary>
    public decimal ApprovedAmount { get; set; }

    /// <summary>
    /// The monthly this signature set — READ THIS RATHER THAN THE REQUEST BODY. When the caller
    /// sent null, or sent a figure larger than the approved amount, this is the value the procedure
    /// actually settled on, and it is what the employee will really have deducted.
    /// </summary>
    public decimal ApprovedMonthlyDeduction { get; set; }

    /// <summary>Non-null once the final approval has written the advance the payroll recovers.</summary>
    public int? CreatedAdvanceId { get; set; }
}
