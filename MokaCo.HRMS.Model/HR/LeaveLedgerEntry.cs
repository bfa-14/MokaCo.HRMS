namespace MokaCo.HRMS.Model.HR;

/// <summary>
/// Maps to hr.LEAVE_LEDGER. ONE signed movement per row (+ credit, - usage). The running
/// balance is never stored — it is derived (see <see cref="LeaveBalance"/>).
/// </summary>
public class LeaveLedgerEntry
{
    public int LeaveLedgerId { get; set; }
    public int EmployeeId { get; set; }
    public int LeaveTypeId { get; set; }
    public string PeriodYearMonth { get; set; } = string.Empty;   // 'YYYY-MM'
    public string MovementType { get; set; } = string.Empty;      // Accrual / Usage / CarryOver / Adjustment
    public int? LeaveRequestId { get; set; }
    public decimal Days { get; set; }                             // + credit, - usage
    public DateTime EffectiveDate { get; set; }
    public string? Note { get; set; }
    public DateTime CreatedAt { get; set; }

    /// <summary>What wrote the row when it was not a leave request or a person: 'LeaveYear' (the year opening),
    /// 'ExitPermission' (exit-permission time converted to leave). Null for a manual movement.</summary>
    public string? SourceType { get; set; }

    /// <summary>
    /// QA3 (LEV-9): only a MANUAL adjustment may be deleted -- every other row is kept right by what wrote it (an
    /// approved leave, the year opening, the expiry). The rule of hr.usp_LeaveLedger_Delete, so the screen offers the
    /// delete only where it can work.
    /// </summary>
    public bool CanDelete { get; set; }
}

