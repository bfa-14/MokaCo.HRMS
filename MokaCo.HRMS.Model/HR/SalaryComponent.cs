namespace MokaCo.HRMS.Model.HR;

/// <summary>
/// Maps to hr.SALARY_COMPONENT (row from hr.usp_SalaryComponent_GetByEmployee, with type name).
/// One row per component per currency — money is kept as amount + currency, never collapsed.
/// </summary>
public class SalaryComponent
{
    public int SalaryComponentId { get; set; }
    public int ComponentTypeId { get; set; }
    public string ComponentName { get; set; } = string.Empty;
    public decimal Amount { get; set; }
    public string CurrencyCode { get; set; } = string.Empty;
    public DateTime EffectiveFrom { get; set; }
    public DateTime? EffectiveTo { get; set; }
}

/// <summary>
/// One salary row as the SALARY ADMINISTRATION page reads it —
/// hr.usp_SalaryComponent_GetForEmployee.
///
/// Richer than <see cref="SalaryComponent"/> because that page shows history as well as the
/// present: <see cref="IsCurrent"/> separates the open row from the closed ones, and Category and
/// Sign let a deduction be shown as a deduction without a second lookup.
/// </summary>
public class EmployeeSalaryComponent
{
    public int SalaryComponentId { get; set; }
    public int ComponentTypeId { get; set; }
    public string ComponentName { get; set; } = string.Empty;
    /// <summary>Earning / Deduction / EmployerCost.</summary>
    public string Category { get; set; } = string.Empty;
    /// <summary>+1 or -1. The amount is always positive; the sign says which way it moves.</summary>
    public short Sign { get; set; }
    public decimal Amount { get; set; }
    public string CurrencyCode { get; set; } = string.Empty;
    public DateTime EffectiveFrom { get; set; }
    /// <summary>Null while the row is the standing one. Set closes it — history, never edited.</summary>
    public DateTime? EffectiveTo { get; set; }
    /// <summary>True for the one open row per component. Everything else is history.</summary>
    public bool IsCurrent { get; set; }
}

/// <summary>
/// PUT /api/employees/{id}/salary-components — set what a component is worth FROM a date.
///
/// Not an edit. The procedure closes the standing row the day before and opens a new one, so a
/// month that was already paid keeps saying what it paid. It refuses a date inside a locked month
/// and names the earliest date that would work.
/// </summary>
public class SalaryComponentSetRequest
{
    public int ComponentTypeId { get; set; }
    /// <summary>Above zero. To remove a component, END it instead — the procedure says so.</summary>
    public decimal Amount { get; set; }
    public string CurrencyCode { get; set; } = string.Empty;
    public DateTime EffectiveFrom { get; set; }
}

/// <summary>POST /api/salary-components/{id}/end — close a standing row on a date.</summary>
public class SalaryComponentEndRequest
{
    public DateTime EffectiveTo { get; set; }
}
