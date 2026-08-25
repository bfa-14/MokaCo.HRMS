namespace MokaCo.HRMS.Model.Payroll;

/// <summary>
/// One payslip as it appears in the run's grid — payroll.usp_PayrollRun_GetPayslips.
///
/// <see cref="Notes"/> is the warning channel: the generator writes "NO BASIC SALARY ON FILE." or
/// "NEGATIVE NET - review deductions." into it. Non-empty means the row wants a human, and the note
/// itself is the explanation — the UI shows it rather than inventing its own wording.
/// </summary>
public class PayslipListItem
{
    public int PayslipId { get; set; }
    public int EmployeeId { get; set; }
    public string EmployeeName { get; set; } = string.Empty;
    public string PositionTitle { get; set; } = string.Empty;
    public string BranchName { get; set; } = string.Empty;
    /// <summary>Days actually worked, summed from attendance as fractions. Null when nothing was recorded.</summary>
    public decimal? PaidDayFraction { get; set; }
    public decimal? UnpaidLeaveDays { get; set; }
    public decimal? PaidLeaveDays { get; set; }
    public int? OvertimeMinutes { get; set; }
    public decimal GrossUsd { get; set; }
    public decimal GrossLbp { get; set; }
    public decimal DeductionsUsd { get; set; }
    public decimal DeductionsLbp { get; set; }
    public decimal NetUsd { get; set; }
    public decimal NetLbp { get; set; }
    /// <summary>The "≈" comparable at this run's frozen rates. Never a payable figure.</summary>
    public decimal NetPrimary { get; set; }
    public string? PaymentMethod { get; set; }
    public DateTime? PaidAt { get; set; }
    public string? Notes { get; set; }
}

/// <summary>The payslip document — the TWO result sets of payroll.usp_Payslip_Get.</summary>
public class PayslipDetail
{
    /// <summary>Null when there is no such payslip — the controller turns that into a 404.</summary>
    public Payslip? Payslip { get; set; }
    public List<PayslipLine> Lines { get; set; } = [];
}

/// <summary>
/// Result set 1 — the payslip, plus the run context it was cut in.
///
/// The identity fields are COPIES taken when the payslip was generated, not joins to the employee
/// row: a payslip is a document about a moment, and renaming somebody next year must not restate
/// what their July payslip said.
/// </summary>
public class Payslip
{
    public int PayslipId { get; set; }
    public int PayrollRunId { get; set; }
    public int EmployeeId { get; set; }
    public string EmployeeName { get; set; } = string.Empty;
    public string PositionTitle { get; set; } = string.Empty;
    public string BranchName { get; set; } = string.Empty;
    public string? NssfNumber { get; set; }
    public DateTime HireDate { get; set; }
    public decimal? PaidDayFraction { get; set; }
    public decimal? UnpaidLeaveDays { get; set; }
    public decimal? PaidLeaveDays { get; set; }
    public int? OvertimeMinutes { get; set; }
    public decimal GrossUsd { get; set; }
    public decimal GrossLbp { get; set; }
    public decimal DeductionsUsd { get; set; }
    public decimal DeductionsLbp { get; set; }
    public decimal NetUsd { get; set; }
    public decimal NetLbp { get; set; }
    public decimal EmployerCostUsd { get; set; }
    public decimal EmployerCostLbp { get; set; }
    public decimal NetPrimary { get; set; }
    public string? PaymentMethod { get; set; }
    public string? PaymentReference { get; set; }
    public DateTime? PaidAt { get; set; }
    public string? Notes { get; set; }

    // --- the run this payslip belongs to, joined by the procedure ---
    public string PeriodYearMonth { get; set; } = string.Empty;
    /// <summary>Draft / Review / Approved / Cancelled. Payment is offered only on Approved.</summary>
    public string RunStatus { get; set; } = string.Empty;
    public DateTime? LockedAt { get; set; }
}

/// <summary>
/// Result set 2 — one line of the payslip, and where it came from.
///
/// EVERY FIGURE IS TRACEABLE, and <see cref="SourceType"/> plus <see cref="SourceId"/> is how. The
/// source types the generator writes are Salary, Leave, Attendance, Overtime, Tip, Expense, Advance,
/// Adjustment, Separation and Statutory; SourceId is the id in THAT source's own table (a
/// SalaryComponentId for Salary, an OvertimeRequestId for Overtime, and so on), and is null for the
/// two that have no single source row — Attendance and Statutory.
/// </summary>
public class PayslipLine
{
    public int PayslipLineId { get; set; }
    public string ComponentName { get; set; } = string.Empty;
    /// <summary>Earning / Deduction / EmployerCost — the grouping the document is read in.</summary>
    public string Category { get; set; } = string.Empty;
    /// <summary>+1 or -1. The amount is always positive; the sign says which way it moves.</summary>
    public short Sign { get; set; }
    public decimal Amount { get; set; }
    public string CurrencyCode { get; set; } = string.Empty;
    public string SourceType { get; set; } = string.Empty;
    public int? SourceId { get; set; }
    /// <summary>Minutes for overtime, days for leave — whatever the unit rate is charged per.</summary>
    public decimal? Quantity { get; set; }
    public decimal? UnitAmount { get; set; }
    public string? Note { get; set; }
    public int SortOrder { get; set; }

    /// <summary>
    /// The request this line came from, when it came from one.
    ///
    /// NOT from usp_Payslip_Get — that procedure is untouched. The repository resolves it in one
    /// extra read, because SourceId for a request-backed line is the TYPED table's id (an
    /// ExpenseReimbursementId, say) and the request pages are keyed by RequestInstanceId. Resolving
    /// it here rather than in the browser means the payslip renders its links from one response
    /// instead of one round trip per line.
    ///
    /// Null for Salary, Attendance, Advance, Adjustment and Statutory lines — those have no request
    /// behind them, and their links go elsewhere.
    /// </summary>
    public int? RequestInstanceId { get; set; }
}

/// <summary>POST /api/payroll/payslips/{id}/payment. Approved runs only — the procedure enforces it.</summary>
public class PayslipPaymentRequest
{
    /// <summary>Bank or Cash. Anything else earns the procedure's own refusal.</summary>
    public string PaymentMethod { get; set; } = string.Empty;
    public string? PaymentReference { get; set; }
}

/// <summary>What usp_Payslip_SetPayment returns once payment is recorded.</summary>
public class PayslipPaymentResult
{
    public int PayslipId { get; set; }
    public string? PaymentMethod { get; set; }
    public string? PaymentReference { get; set; }
    public DateTime? PaidAt { get; set; }
}

/// <summary>
/// "WHERE IS MY SALARY THIS MONTH" — payroll.usp_Payslip_GetMyStatus, one row or none.
///
/// The whole point is the ONE question an employee actually has, answered without opening anything:
/// has this month been prepared, is it final, and has the money gone out. It is deliberately NOT a
/// payslip — no lines, no gross, no employer cost — because the answer is needed by everybody every
/// month while the document itself is only worth opening once.
///
/// NONE is a real answer, not an error: no row means the month has not been generated yet, and the
/// controller returns null so the caller can say "not prepared yet" rather than show a failure.
/// </summary>
public class MyPayslipStatus
{
    public int PayslipId { get; set; }
    /// <summary>The period this covers, e.g. "2026-08".</summary>
    public string PeriodYearMonth { get; set; } = string.Empty;
    public string? RunType { get; set; }
    /// <summary>Draft / Review / Approved / Cancelled — the run's state, not the payment's.</summary>
    public string RunStatus { get; set; } = string.Empty;
    public decimal NetUsd { get; set; }
    public decimal NetLbp { get; set; }
    /// <summary>The "≈" comparable at this run's frozen rates. Never a payable figure.</summary>
    public decimal NetPrimary { get; set; }
    public string? PaymentMethod { get; set; }
    public DateTime? PaidAt { get; set; }
    /// <summary>
    /// Prepared | Ready | Paid — the procedure's own reading of the two states above, so the screen
    /// never has to re-derive "approved but unpaid" from a status and a null date and get it wrong.
    /// </summary>
    public string StatusCode { get; set; } = string.Empty;
}

/* "My payslips" is NOT modelled here. usp_Payslip_GetMine was already wired end to end — see
   MyPayslip in PayrollReports.cs, IPayrollRepository.GetMyPayslipsAsync, and MeController's
   GET /api/me/payslips. A second model over the same procedure would be two shapes for one answer,
   and the day the procedure gained a column only one of them would learn about it. */
