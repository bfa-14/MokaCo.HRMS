namespace MokaCo.HRMS.Model.Payroll;

/// <summary>
/// A correction aimed at a FUTURE period — payroll.usp_Adjustment_GetForPeriod.
///
/// This is the only way a locked run is ever put right: an approved run is history, so the fix is an
/// adjustment consumed by the NEXT period's payslip. <see cref="AppliedToPayslipId"/> non-null means
/// that has happened and the row is now itself history — the delete refuses, and the UI shows it as
/// consumed rather than offering an action that cannot work.
/// </summary>
public class PayrollAdjustment
{
    public int PayrollAdjustmentId { get; set; }
    public int EmployeeId { get; set; }
    public string EmployeeName { get; set; } = string.Empty;
    public string ComponentName { get; set; } = string.Empty;
    /// <summary>+1 or -1, from the component type. THE SIGN DECIDES DIRECTION; the amount is always positive.</summary>
    public short Sign { get; set; }
    public decimal Amount { get; set; }
    public string CurrencyCode { get; set; } = string.Empty;
    /// <summary>Format 2026-09 — the period whose generation will pick this up.</summary>
    public string TargetPeriod { get; set; } = string.Empty;
    public int? CorrectsRunId { get; set; }
    /// <summary>The period of the run being corrected, for reading without a second lookup.</summary>
    public string? CorrectsPeriod { get; set; }
    public string Reason { get; set; } = string.Empty;
    /// <summary>Non-null once a payslip consumed it. From then on it is history, not a plan.</summary>
    public int? AppliedToPayslipId { get; set; }
    public string? CreatedBy { get; set; }
    public DateTime CreatedAt { get; set; }

    /// <summary>
    /// The request that AUTHORISED this row — HR raised it, the Owner signed it.
    ///
    /// Null only for rows written before adjustments became a request type, when a reason and a
    /// creator were the whole story. Every row created from now on has one, and the history grid
    /// links through it so a figure on a payslip can be followed back to the signatures behind it.
    /// </summary>
    public int? RequestInstanceId { get; set; }
}

// The create DTO that used to live here is gone with its route. An adjustment is raised as a
// REQUEST now; its create shape is Model.Workflow.PayrollAdjustmentCreateRequest. Keeping a
// same-named type in this namespace would also have made the two ambiguous to any file that
// happened to import both.

/// <summary>What usp_Adjustment_Delete returns — 0 when nothing was removed.</summary>
public class PayrollAdjustmentDeleteResult
{
    public int Deleted { get; set; }
}

/// <summary>
/// A pay component the adjustment form may choose from — hr.COMPONENT_TYPE.
///
/// Read here rather than through /api/component-types for two reasons: that endpoint is gated on
/// EMP_VIEW, which the General Manager and Operations Manager roles do not hold, and its procedure
/// does not return <see cref="IsStanding"/> — the flag that separates what a person is ASSIGNED
/// (basic salary, allowances) from what payroll COMPUTES (overtime, NSSF, tax).
/// </summary>
public class PayrollComponentType
{
    public int ComponentTypeId { get; set; }
    public string Name { get; set; } = string.Empty;
    /// <summary>Earning / Deduction / EmployerCost.</summary>
    public string Category { get; set; } = string.Empty;
    public short Sign { get; set; }
    /// <summary>True for components a person carries month to month; false for ones a run produces.</summary>
    public bool IsStanding { get; set; }
}
