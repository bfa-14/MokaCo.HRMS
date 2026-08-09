namespace MokaCo.HRMS.Model.Security;

/// <summary>Lightweight row for the users grid (no hash, no security internals).</summary>
public class UserListItem
{
    public int UserId { get; set; }
    public string Username { get; set; } = string.Empty;
    public bool IsActive { get; set; }
    public DateTime? LastLoginAt { get; set; }
}
