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
