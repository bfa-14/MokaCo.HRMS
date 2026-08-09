namespace MokaCo.HRMS.Model.HR;

/// <summary>Maps to hr.EMPLOYEE. The central person record (soft-deleted, never hard deleted).</summary>
public class Employee
{
    public int EmployeeId { get; set; }
    public int? UserId { get; set; }
    public int BranchId { get; set; }
    public int DepartmentId { get; set; }
    public int PositionId { get; set; }
    public string FullName { get; set; } = string.Empty;
    public string? NationalId { get; set; }
    public string? NssfNumber { get; set; }
    public DateTime HireDate { get; set; }
    public DateTime? TerminationDate { get; set; }
    /// <summary>1 = staff (default), 2 = management, 3 = executive — picks which published chain their requests follow.</summary>
    public int ApprovalTier { get; set; } = 1;
    /// <summary>Who this person reports to (a LineManager step climbs this). Null for the top of a reporting line.</summary>
    public int? ReportsToEmployeeId { get; set; }
    public bool IsDeleted { get; set; }
    public DateTime CreatedAt { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime? ModifiedAt { get; set; }
    public int? ModifiedBy { get; set; }
}
