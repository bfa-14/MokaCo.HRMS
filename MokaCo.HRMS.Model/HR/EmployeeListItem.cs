namespace MokaCo.HRMS.Model.HR;

/// <summary>Grid row from hr.usp_Employee_GetAll (resolved lookup names, excludes soft-deleted).</summary>
public class EmployeeListItem
{
    public int EmployeeId { get; set; }
    public string FullName { get; set; } = string.Empty;
    public string? NationalId { get; set; }
    public string? NssfNumber { get; set; }
    public DateTime HireDate { get; set; }
    public DateTime? TerminationDate { get; set; }
    /// <summary>1 = staff (default), 2 = management, 3 = executive. The grid tags only tier &gt; 1.</summary>
    public int ApprovalTier { get; set; } = 1;
    public string Branch { get; set; } = string.Empty;
    public string Department { get; set; } = string.Empty;
    public string Position { get; set; } = string.Empty;
}
