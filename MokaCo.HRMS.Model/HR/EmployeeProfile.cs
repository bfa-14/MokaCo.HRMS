namespace MokaCo.HRMS.Model.HR;

/// <summary>
/// Full employee profile from hr.usp_Employee_GetProfile: the employee row + resolved
/// lookup names, plus the current salary-component child rows (two result sets).
/// </summary>
public class EmployeeProfile : Employee
{
    public string BranchName { get; set; } = string.Empty;
    public string DepartmentName { get; set; } = string.Empty;
    public string PositionTitle { get; set; } = string.Empty;
    /// <summary>The manager's name (resolved from ReportsToEmployeeId), so the form can show it before the employee list loads. Null at the top of a line.</summary>
    public string? ReportsToName { get; set; }
    public List<SalaryComponentLine> SalaryComponents { get; set; } = new();
}

/// <summary>A salary-component line as returned inside the employee profile (with type name).</summary>
public class SalaryComponentLine
{
    public int SalaryComponentId { get; set; }
    public string ComponentName { get; set; } = string.Empty;
    public decimal Amount { get; set; }
    public string CurrencyCode { get; set; } = string.Empty;
    public DateTime EffectiveFrom { get; set; }
    public DateTime? EffectiveTo { get; set; }
}
