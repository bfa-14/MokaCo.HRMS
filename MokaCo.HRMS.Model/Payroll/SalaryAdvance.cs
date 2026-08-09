namespace MokaCo.HRMS.Model.Payroll;

/// <summary>
/// A salary advance — payroll.usp_Advance_GetList.
///
/// <see cref="RemainingAmount"/> is the figure that matters: generation deducts
/// MIN(MonthlyDeduction, RemainingAmount) each period, and APPROVING the run is what actually
/// reduces it. Until a run is approved the balance is untouched, so a draft regenerated five times
/// still owes the same amount.
/// </summary>
public class SalaryAdvance
{
    public int SalaryAdvanceId { get; set; }
    public int EmployeeId { get; set; }
    public string EmployeeName { get; set; } = string.Empty;
    public decimal Amount { get; set; }
    public string CurrencyCode { get; set; } = string.Empty;
    public DateTime AdvanceDate { get; set; }
    public decimal MonthlyDeduction { get; set; }
    public decimal RemainingAmount { get; set; }
    /// <summary>Format 2026-09 — no deduction is taken from a period before this one.</summary>
    public string FirstDeductionPeriod { get; set; } = string.Empty;
    public string? Reason { get; set; }
    /// <summary>Set by Approve when the remaining balance reaches zero. Settled rows are read-only.</summary>
    public bool IsSettled { get; set; }
    public string? CreatedBy { get; set; }
    public DateTime CreatedAt { get; set; }
}

/// <summary>What usp_Advance_Create returns.</summary>
public class SalaryAdvanceCreated
{
    public int SalaryAdvanceId { get; set; }
    /// <summary>Equals the full amount at creation — nothing has been deducted yet.</summary>
    public decimal RemainingAmount { get; set; }
}

/// <summary>What usp_Advance_UpdateMonthly returns.</summary>
public class SalaryAdvanceMonthlyResult
{
    public int SalaryAdvanceId { get; set; }
    public decimal MonthlyDeduction { get; set; }
    public decimal RemainingAmount { get; set; }
}

/// <summary>POST /api/payroll/advances. The creator comes from the token.</summary>
public class SalaryAdvanceCreateRequest
{
    public int EmployeeId { get; set; }
    public decimal Amount { get; set; }
    public string CurrencyCode { get; set; } = string.Empty;
    public DateTime AdvanceDate { get; set; }
    public decimal MonthlyDeduction { get; set; }
    /// <summary>Format 2026-09.</summary>
    public string FirstDeductionPeriod { get; set; } = string.Empty;
    public string? Reason { get; set; }
}

/// <summary>PUT /api/payroll/advances/{id}/monthly — reschedule what comes off each month.</summary>
public class SalaryAdvanceMonthlyRequest
{
    public decimal MonthlyDeduction { get; set; }
}
