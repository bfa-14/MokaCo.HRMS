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

/// <summary>
/// One leave type's balance for ONE LEAVE YEAR — a row of hr.usp_Leave_GetBalanceByYear, which sums
/// hr.vw_LEAVE_BALANCE over the year's periods. Remaining = Entitlement + CarriedOver − Used + Adjusted.
/// </summary>
public class LeaveTypeYearBalance
{
    public int LeaveTypeId { get; set; }
    public string LeaveType { get; set; } = string.Empty;
    public bool IsPaid { get; set; }
    /// <summary>The year's Accrual movements — what the year opening granted (plus any later accrual).</summary>
    public decimal Entitlement { get; set; }
    public decimal CarriedOver { get; set; }
    public decimal Used { get; set; }
    public decimal Adjusted { get; set; }
    public decimal Remaining { get; set; }
    public int Year { get; set; }
}

/// <summary>
/// GET /api/employees/{id}/leave-balance without a leaveTypeId: every type for the leave year.
/// <see cref="YearOpened"/> is false — and <see cref="Balances"/> EMPTY — when hr.usp_LeaveYear_Open
/// has not been run for this employee and year, which is the honest answer: there is no entitlement
/// to measure against yet, not a balance of zero.
/// </summary>
public class LeaveYearBalance
{
    public int EmployeeId { get; set; }
    public int Year { get; set; }
    public bool YearOpened { get; set; }
    public List<LeaveTypeYearBalance> Balances { get; set; } = new();
}
