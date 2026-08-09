namespace MokaCo.HRMS.Model.HR;

/// <summary>Maps to hr.DEPARTMENT. An organisational grouping for employees.</summary>
public class Department
{
    public int DepartmentId { get; set; }
    public string Name { get; set; } = string.Empty;
    public bool IsActive { get; set; }
}
