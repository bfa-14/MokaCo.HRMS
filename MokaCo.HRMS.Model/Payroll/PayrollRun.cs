namespace MokaCo.HRMS.Model.Payroll;

/// <summary>
/// One payroll run in the list — payroll.usp_PayrollRun_GetList.
///
/// <see cref="TotalNetPrimary"/> is the only figure here that mixes currencies, and it is a
/// COMPARABLE, not a sum of money anybody pays: the procedure adds each payslip's NetPrimary, which
/// was itself converted at the rate frozen into this run. The UI shows it prefixed "≈" for exactly
/// that reason. It is null while a run has no payslips.
/// </summary>
public class PayrollRunListItem
{
    public int PayrollRunId { get; set; }
    public string PeriodYearMonth { get; set; } = string.Empty;
    /// <summary>Draft / Review / Approved / Cancelled.</summary>
    public string Status { get; set; } = string.Empty;
    /// <summary>
    /// Primary / Supplemental. A supplemental is an OFF-CYCLE run: it pays approved, unconsumed
    /// adjustments for a period whose primary is already locked, and computes no statutory
    /// contributions. Both types use the same endpoints from here on.
    /// </summary>
    public string RunType { get; set; } = "Primary";
    public string PrimaryCurrency { get; set; } = string.Empty;
    public DateTime CreatedAt { get; set; }
    public string? CreatedBy { get; set; }
    public DateTime? GeneratedAt { get; set; }
    public DateTime? ApprovedAt { get; set; }
    public string? ApprovedBy { get; set; }
    /// <summary>Non-null is THE lock. Nothing may mutate the run once this is stamped.</summary>
    public DateTime? LockedAt { get; set; }
    public int PayslipCount { get; set; }
    public decimal? TotalNetPrimary { get; set; }
}

/// <summary>
/// The whole run page — the FOUR result sets of payroll.usp_PayrollRun_Get, in one round trip.
///
/// They are read together because they are one statement about one run: the totals and the payslips
/// they total must come from the same instant, or the header disagrees with the grid underneath it.
/// </summary>
public class PayrollRunDetail
{
    /// <summary>Null when there is no such run — the controller turns that into a 404.</summary>
    public PayrollRunHeader? Header { get; set; }
    public List<PayrollRunRate> Rates { get; set; } = [];
    /// <summary>
    /// Always present for a run that exists — the procedure's totals query is an aggregate with no
    /// GROUP BY, so it emits one row even when nothing has been generated. That row reads
    /// PayslipCount 0 with null sums, which is the honest shape of "nothing yet".
    /// </summary>
    public PayrollRunTotals? Totals { get; set; }
    public List<PayrollRunEvent> Events { get; set; } = [];
}

/// <summary>Result set 1 — the run itself.</summary>
public class PayrollRunHeader
{
    public int PayrollRunId { get; set; }
    public string PeriodYearMonth { get; set; } = string.Empty;
    public DateTime PeriodStart { get; set; }
    public DateTime PeriodEnd { get; set; }
    public string Status { get; set; } = string.Empty;
    /// <summary>Primary / Supplemental — see <see cref="PayrollRunListItem.RunType"/>.</summary>
    public string RunType { get; set; } = "Primary";
    public string PrimaryCurrency { get; set; } = string.Empty;
    public string? Notes { get; set; }
    public DateTime CreatedAt { get; set; }
    public string? CreatedBy { get; set; }
    public DateTime? GeneratedAt { get; set; }
    public DateTime? ApprovedAt { get; set; }
    public string? ApprovedBy { get; set; }
    public DateTime? LockedAt { get; set; }
    public DateTime? CancelledAt { get; set; }
    public string? CancelReason { get; set; }
}

/// <summary>
/// Result set 2 — one exchange rate FROZEN into this run at creation.
///
/// Frozen, not looked up: every payslip in the run converts at these numbers for as long as the run
/// exists, so a rate change next week cannot silently restate what people were paid. The UI prints
/// them because a comparable figure without its rate is not traceable.
/// </summary>
public class PayrollRunRate
{
    public string FromCurrency { get; set; } = string.Empty;
    public string ToCurrency { get; set; } = string.Empty;
    public decimal Rate { get; set; }
    /// <summary>Official / Market — whichever PayrollRateType named when the run was created.</summary>
    public string RateType { get; set; } = string.Empty;
    /// <summary>The date of the rate row that was snapshotted, not the date of the snapshot.</summary>
    public DateTime SourceEffectiveDate { get; set; }
}

/// <summary>
/// Result set 3 — the run's totals, PER CURRENCY and never merged.
///
/// USD and LBP travel side by side all the way to the screen. <see cref="NetPrimary"/> is the single
/// place the two meet, and only as a comparable at the frozen rate.
/// </summary>
public class PayrollRunTotals
{
    public decimal? GrossUsd { get; set; }
    public decimal? GrossLbp { get; set; }
    public decimal? DeductionsUsd { get; set; }
    public decimal? DeductionsLbp { get; set; }
    public decimal? NetUsd { get; set; }
    public decimal? NetLbp { get; set; }
    public decimal? EmployerCostUsd { get; set; }
    public decimal? EmployerCostLbp { get; set; }
    /// <summary>The "≈" comparable — every payslip's net converted at this run's frozen rates.</summary>
    public decimal? NetPrimary { get; set; }
    public int PayslipCount { get; set; }
    /// <summary>Payslips carrying a note (no basic salary on file, negative net). Amber when above zero.</summary>
    public int PayslipsWithWarnings { get; set; }
}

/// <summary>Result set 4 — the run's history: who did what, and when.</summary>
public class PayrollRunEvent
{
    /// <summary>Created / Generated / Review / Approved / Cancelled.</summary>
    public string Action { get; set; } = string.Empty;
    public string? ActedBy { get; set; }
    public DateTime ActedAt { get; set; }
    public string? Detail { get; set; }
}

/// <summary>What usp_PayrollRun_Create returns once the period passed the attendance gate.</summary>
public class PayrollRunCreated
{
    public int PayrollRunId { get; set; }
    public string PeriodYearMonth { get; set; } = string.Empty;
    public string Status { get; set; } = string.Empty;
    public string PrimaryCurrency { get; set; } = string.Empty;
}

/// <summary>What a status move returns — the run and the status it now holds.</summary>
public class PayrollRunStatusResult
{
    public int PayrollRunId { get; set; }
    public string Status { get; set; } = string.Empty;
    /// <summary>Stamped by Approve only; null from SendToReview and Cancel.</summary>
    public DateTime? LockedAt { get; set; }
}

/// <summary>What usp_PayrollRun_Generate returns — how many payslips, and how many need a look.</summary>
public class PayrollRunGenerateResult
{
    public int PayrollRunId { get; set; }
    public int PayslipCount { get; set; }
    public int PayslipsWithWarnings { get; set; }
}

/// <summary>One line of the payment sheet — approved runs only; the procedure refuses otherwise.</summary>
public class PaymentSheetRow
{
    public int PayslipId { get; set; }
    public string EmployeeName { get; set; } = string.Empty;
    public string BranchName { get; set; } = string.Empty;
    public decimal NetUsd { get; set; }
    public decimal NetLbp { get; set; }
    public string? PaymentMethod { get; set; }
    public string? PaymentReference { get; set; }
    public DateTime? PaidAt { get; set; }
}

/// <summary>
/// The attendance gate — attendance.usp_Attendance_PayrollReadiness.
///
/// Six counts and a verdict. <see cref="IsReady"/> is 1 only when every count is zero, and
/// usp_PayrollRun_Create runs this same check itself: the panel exists to make the refusal
/// UNDERSTANDABLE before it happens, not to replace it.
/// </summary>
public class PayrollReadiness
{
    public string PeriodYearMonth { get; set; } = string.Empty;
    public DateTime PeriodStart { get; set; }
    public DateTime PeriodEnd { get; set; }
    public int UnprocessedPunches { get; set; }
    public int UnresolvedPinPunches { get; set; }
    public int OpenAnomalies { get; set; }
    public int PendingCorrections { get; set; }
    public int RosteredDaysWithNoRecord { get; set; }
    public int UndecidedExitVariances { get; set; }
    public bool IsReady { get; set; }
}

/// <summary>POST /api/payroll/runs. The creator comes from the token, never the body.</summary>
public class PayrollRunCreateRequest
{
    /// <summary>Format 2026-08. The procedure validates the shape and says so if it is wrong.</summary>
    public string PeriodYearMonth { get; set; } = string.Empty;
    public string? Notes { get; set; }

    /// <summary>
    /// Primary (the default) or Supplemental. Passed straight through to @RunType — every rule
    /// about when a supplemental is allowed (the primary must be locked, only one open at a time,
    /// something must actually be payable) belongs to the procedure and arrives as its own sentence.
    /// </summary>
    public string? RunType { get; set; }
}

/// <summary>POST /api/payroll/runs/{id}/cancel. The procedure requires a non-empty reason.</summary>
public class PayrollRunCancelRequest
{
    public string? Reason { get; set; }
}
