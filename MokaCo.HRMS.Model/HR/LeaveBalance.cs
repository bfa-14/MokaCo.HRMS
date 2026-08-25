namespace MokaCo.HRMS.Model.HR;

/// <summary>
/// Derived leave balance from hr.vw_LEAVE_BALANCE (via hr.usp_LeaveBalance_Get): the summed
/// ledger per employee / leave type / month. Read-only — never written directly.
///
/// THE COLUMNS ADD UP: Remaining = Accrued + CarriedOver − Used + Adjusted. All five come from
/// the same view over the same ledger rows, so the total can never disagree with its parts — and
/// every part is shown, because a Remaining that cannot be reconstructed is one nobody can check.
/// </summary>
public class LeaveBalance
{
    public int EmployeeId { get; set; }
    public int LeaveTypeId { get; set; }
    public string PeriodYearMonth { get; set; } = string.Empty;
    public decimal Accrued { get; set; }
    public decimal CarriedOver { get; set; }
    public decimal Used { get; set; }

    /// <summary>
    /// The Adjustment movements — everything that moved this balance by hand rather than by rule:
    /// an HR correction, a discretionary grant waived at approval, the year-close settlement.
    ///
    /// SIGNED, and both signs are ordinary: positive gives days back, negative takes them away. It
    /// is separate from Used because "taken as leave" and "adjusted away" are different facts about
    /// an employee, and folding them together would lose the one somebody later has to explain.
    /// </summary>
    public decimal Adjusted { get; set; }

    public decimal Remaining { get; set; }
}
