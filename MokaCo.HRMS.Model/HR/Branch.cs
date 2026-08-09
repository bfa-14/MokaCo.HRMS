namespace MokaCo.HRMS.Model.HR;

/// <summary>Maps to hr.BRANCH. A physical location an employee belongs to.</summary>
public class Branch
{
    public int BranchId { get; set; }
    public string Name { get; set; } = string.Empty;
    public bool IsActive { get; set; }
}
