namespace MokaCo.HRMS.Model.Security;

/// <summary>Maps to security.PERMISSION. A single capability the API checks by Code.</summary>
public class Permission
{
    public int PermissionId { get; set; }
    public string Code { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    public string Module { get; set; } = string.Empty;
}
