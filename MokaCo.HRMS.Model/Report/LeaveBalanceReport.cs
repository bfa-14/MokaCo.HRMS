namespace MokaCo.HRMS.Model.Report;

/// <summary>Title block for the Leave Balance Report (result set 1 of report.usp_Report_LeaveBalance).</summary>
public class LeaveBalanceHeader
{
    public string ReportTitle { get; set; } = string.Empty;

    /// <summary>The balances are rolled up to the END of this period, inclusive — so 'as of 2026-06' means everything through June.</summary>
    public string AsOfPeriod { get; set; } = string.Empty;

    public string BranchName { get; set; } = string.Empty;
    public DateTime GeneratedUtc { get; set; }
}

/// <summary>
/// One employee's balance in one leave type. Sourced from the derived hr.vw_LEAVE_BALANCE rolled up
/// to the as-of period, so the number here can never drift from the ledger it was computed from —
/// Remaining is always exactly Accrued + CarriedOver − Used.
/// </summary>
public class LeaveBalanceRow
{
    public int EmployeeId { get; set; }
    public string FullName { get; set; } = string.Empty;
    public string BranchName { get; set; } = string.Empty;
    public string LeaveType { get; set; } = string.Empty;

    /// <summary>Whether time taken in this type is paid. An unpaid type's remaining balance means something different, so it is shown.</summary>
    public bool IsPaid { get; set; }

    public decimal Accrued { get; set; }
    public decimal CarriedOver { get; set; }
    public decimal Used { get; set; }

    /// <summary>Accrued + carried over − used. The column people actually open this report to read.</summary>
    public decimal Remaining { get; set; }
}
