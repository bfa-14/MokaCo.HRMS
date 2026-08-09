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
}

/// <summary>
/// One employee-day on approved leave, from GET /api/leave/days.
///
/// A deliberately SMALL contract — one row per employee-day — because it is a seam. Leave is
/// currently derived from hr.LEAVE_LEDGER ('Usage' movements matched on EffectiveDate), which is
/// the only source that exists: workflow.LEAVE_REQUEST, with a real FromDate..ToDate to expand,
/// belongs to the workflow stage and has not been built. When it arrives, only the procedure
/// behind this shape changes — every caller keeps working.
/// </summary>
public class LeaveDay
{
    public int EmployeeId { get; set; }

    /// <summary>The day itself. One row per employee-day, whatever the ledger holds underneath.</summary>
    public DateTime Date { get; set; }

    /// <summary>
    /// How much of the day is leave — 1.00 for a whole day, 0.50 for a half. Reported as a POSITIVE
    /// number: the ledger stores usage as a negative movement, and no caller should have to know
    /// that sign convention.
    /// </summary>
    public decimal DaysOnLeave { get; set; }
}
