namespace MokaCo.HRMS.Model.Security;

/// <summary>
/// An account as a pick-list entry (GET /api/users/names): who it is, nothing about how it is used. The full list —
/// last sign-in, roles — stays behind USER_MANAGE.
/// </summary>
public record UserPickItem(int UserId, string Username, string? EmployeeName);

/// <summary>A role as a pick-list entry (GET /api/roles/names). Its permissions stay behind ROLE_MANAGE.</summary>
public record RolePickItem(int RoleId, string Name);

/// <summary>
/// The projections behind the two pick-lists. The chain builder is WORKFLOW_CONFIGURE's page, and its "which role" and
/// "which user" boxes read lists that needed ROLE_MANAGE and USER_MANAGE — a chain editor without those saw two empty
/// boxes (QA3). Pure, so the rules are tested without a database.
/// </summary>
public static class PickLists
{
    /// <summary>The ACTIVE accounts only — a disabled login cannot sign a step — by username.</summary>
    public static List<UserPickItem> Users(IEnumerable<UserListItem> users)
        => users.Where(u => u.IsActive)
                .OrderBy(u => u.Username, StringComparer.OrdinalIgnoreCase)
                .Select(u => new UserPickItem(u.UserId, u.Username, u.EmployeeName))
                .ToList();

    /// <summary>Every role, by name.</summary>
    public static List<RolePickItem> Roles(IEnumerable<Role> roles)
        => roles.OrderBy(r => r.Name, StringComparer.OrdinalIgnoreCase)
                .Select(r => new RolePickItem(r.RoleId, r.Name))
                .ToList();
}
