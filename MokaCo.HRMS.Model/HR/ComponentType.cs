namespace MokaCo.HRMS.Model.HR;

/// <summary>Maps to hr.COMPONENT_TYPE. A pay component catalogue entry (Category + Sign).</summary>
public class ComponentType
{
    public int ComponentTypeId { get; set; }
    public string Name { get; set; } = string.Empty;
    public string Category { get; set; } = string.Empty;   // Earning / Deduction
    public short Sign { get; set; }                         // +1 / -1

    /// <summary>False retires the type. One used by salary components or payslip lines cannot be deleted, only deactivated.</summary>
    public bool IsActive { get; set; } = true;

    /// <summary>
    /// The code payroll finds a type it WRITES by (BASIC, OVERTIME, NSSF_EMPLOYEE, …) — null for a type
    /// people assign themselves. QA3 PAY-10: the generator no longer looks types up by name.
    /// </summary>
    public string? SystemCode { get; set; }

    /// <summary>True when <see cref="SystemCode"/> is set: the type cannot be renamed, re-categorised,
    /// deactivated or deleted — the procedures refuse, and the page does not offer it.</summary>
    public bool IsSystem { get; set; }
}
