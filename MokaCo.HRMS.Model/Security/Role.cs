namespace MokaCo.HRMS.Model.Security;

/// <summary>Maps to security.[ROLE]. A named bundle of permissions.</summary>
public class Role
{
    public int RoleId { get; set; }
    public string Name { get; set; } = string.Empty;
    public bool IsSystem { get; set; }
    public DateTime CreatedAt { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime? ModifiedAt { get; set; }
    public int? ModifiedBy { get; set; }
}
