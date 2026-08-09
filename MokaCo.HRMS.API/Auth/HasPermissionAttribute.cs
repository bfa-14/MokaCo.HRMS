using Microsoft.AspNetCore.Authorization;

namespace MokaCo.HRMS.Api.Auth;

/// <summary>Usage: [HasPermission("USER_MANAGE")] on a controller/action.</summary>
public class HasPermissionAttribute : AuthorizeAttribute
{
    public const string Prefix = "perm:";
    public HasPermissionAttribute(string permission) => Policy = Prefix + permission;
}
