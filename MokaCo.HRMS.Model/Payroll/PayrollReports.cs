namespace MokaCo.HRMS.Model.Payroll;

/// <summary>
/// One employee's statutory position in a run — payroll.usp_PayrollRun_GetStatutoryReport.
///
/// This is the sheet that goes to the NSSF and the tax office, so every figure is stated in the
/// run's PRIMARY currency: the procedure converts each contributing line at the run's frozen rate
/// before summing, because a contribution base is a single legal number, not a pair.
///
/// That makes it the one deliberate exception to "currencies never merge" — and the reason it is
/// safe is the same reason NetPrimary is safe: the rate is frozen into the run and printed beside it.
/// </summary>
public sealed class StatutoryReportRow
{
    public int PayslipId { get; set; }
    public int EmployeeId { get; set; }
    public string EmployeeName { get; set; } = string.Empty;
    /// <summary>Copied onto the payslip at generation. Null when the employee has none on file.</summary>
    public string? NssfNumber { get; set; }
    public string BranchName { get; set; } = string.Empty;

    /// <summary>
    /// The wage base the engine contributed on, rebuilt from the payslip's own lines (Salary,
    /// Overtime, Leave and Attendance lines only — tips, expenses and adjustments are not wages).
    /// Null when a payslip has none of those lines at all.
    /// </summary>
    public decimal? WageBasePrimary { get; set; }

    public decimal NssfEmployeeShare { get; set; }
    public decimal NssfEmployerShare { get; set; }
    public decimal IncomeTax { get; set; }
}

/// <summary>
/// One of the SIGNED-IN USER'S OWN payslips — payroll.usp_Payslip_GetMine.
///
/// APPROVED RUNS ONLY, by the procedure's own join: nobody reads a draft of their own pay, because
/// a draft still changes and a person who has seen a number will remember it as a promise.
///
/// The employee is resolved from hr.EMPLOYEE.UserId, so an account not linked to an employee simply
/// gets an empty list — which is the honest answer, not an error.
/// </summary>
public sealed class MyPayslip
{
    public int PayslipId { get; set; }
    public string PeriodYearMonth { get; set; } = string.Empty;
    /// <summary>Primary / Supplemental — an off-cycle month is tagged rather than hidden.</summary>
    public string RunType { get; set; } = "Primary";
    public decimal NetUsd { get; set; }
    public decimal NetLbp { get; set; }
    /// <summary>The "≈" comparable at the run's frozen rate. Never a payable figure.</summary>
    public decimal NetPrimary { get; set; }
    public string? PaymentMethod { get; set; }
    public DateTime? PaidAt { get; set; }
}

/// <summary>
/// One payslip in an employee's history, for the HR tab — payroll.usp_Payslip_GetForEmployee.
///
/// Unlike <see cref="MyPayslip"/> this includes UNAPPROVED runs and says so through
/// <see cref="RunStatus"/>: HR is preparing the month and needs to see the draft they are working
/// on. The person being paid does not.
/// </summary>
public sealed class EmployeePayslip
{
    public int PayslipId { get; set; }
    public string PeriodYearMonth { get; set; } = string.Empty;
    public string RunType { get; set; } = "Primary";
    /// <summary>Draft / Review / Approved / Cancelled.</summary>
    public string RunStatus { get; set; } = string.Empty;
    public decimal GrossUsd { get; set; }
    public decimal GrossLbp { get; set; }
    public decimal NetUsd { get; set; }
    public decimal NetLbp { get; set; }
    public decimal NetPrimary { get; set; }
    public string? PaymentMethod { get; set; }
    public DateTime? PaidAt { get; set; }
}

/// <summary>
/// "Was this request ever paid?" — payroll.usp_PayslipLine_Lookup.
///
/// Answers for one (SourceType, SourceId) pair, preferring an APPROVED run over an open one and
/// ignoring cancelled runs entirely. Absent means "not paid yet", which is why the endpoint answers
/// 404 rather than an empty object: the request pages render the badge only on a hit.
/// </summary>
public sealed class PayslipLineLookup
{
    public int PayslipId { get; set; }
    public int PayrollRunId { get; set; }
    public string PeriodYearMonth { get; set; } = string.Empty;
    public string RunType { get; set; } = "Primary";
    /// <summary>Draft / Review / Approved. Cancelled runs are never returned.</summary>
    public string RunStatus { get; set; } = string.Empty;
}
