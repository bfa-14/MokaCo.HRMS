namespace MokaCo.HRMS.Model.HR;

/// <summary>
/// Derived leave balance from hr.vw_LEAVE_BALANCE (via hr.usp_LeaveBalance_Get): the summed
/// ledger per employee / leave type / month. Read-only — never written directly.
/// </summary>
public class LeaveBalance
{
    public int EmployeeId { get; set; }
    public int LeaveTypeId { get; set; }
    public string PeriodYearMonth { get; set; } = string.Empty;
    public decimal Accrued { get; set; }
    public decimal CarriedOver { get; set; }
    public decimal Used { get; set; }
    public decimal Remaining { get; set; }
}
