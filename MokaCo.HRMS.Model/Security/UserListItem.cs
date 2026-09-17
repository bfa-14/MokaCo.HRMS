namespace MokaCo.HRMS.Model.Security;

/// <summary>Lightweight row for the users grid (no hash, no security internals).</summary>
public class UserListItem
{
    public int UserId { get; set; }
    public string Username { get; set; } = string.Empty;
    public bool IsActive { get; set; }
    public DateTime? LastLoginAt { get; set; }

    /// <summary>The employee this login belongs to (hr.EMPLOYEE.UserId), when linked.</summary>
    public int? EmployeeId { get; set; }
    public string? EmployeeName { get; set; }

    /// <summary>The user's roles as (id, name) pairs — what the grid shows and the role editor starts from.</summary>
    public List<UserRoleItem> Roles { get; set; } = new();

    /// <summary>The same roles as ids only, for callers that just need to pre-tick a checklist.</summary>
    public List<int> RoleIds { get; set; } = new();
}

/// <summary>One role on a user's account.</summary>
public class UserRoleItem
{
    public int RoleId { get; set; }
    public string Name { get; set; } = string.Empty;
}
