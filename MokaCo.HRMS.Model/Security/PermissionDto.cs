namespace MokaCo.HRMS.Model.Security;

/// <summary>A permission as returned by usp_User_GetPermissions (Code + Module).</summary>
public class PermissionDto
{
    public string Code { get; set; } = string.Empty;
    public string Module { get; set; } = string.Empty;
}
