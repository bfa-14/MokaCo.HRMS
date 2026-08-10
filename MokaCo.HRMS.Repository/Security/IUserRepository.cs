using MokaCo.HRMS.Model.Security;

namespace MokaCo.HRMS.Repository.Security;

public interface IUserRepository
{
    // procedure-backed (security-critical)
    Task<User?> GetForLoginAsync(string username);
    Task RegisterLoginSuccessAsync(int userId);
    Task<LoginFailureResult> RegisterLoginFailureAsync(int userId, int maxAttempts = 5, int lockoutMinutes = 15);
    Task<IEnumerable<PermissionDto>> GetPermissionsAsync(int userId);
    /// <summary>
    /// Writes an already-hashed password and stamps PasswordChangedAt. The hash is produced by the
    /// API — the procedure neither verifies nor computes one. Returns rows affected.
    /// </summary>
    Task<int> ChangePasswordAsync(int userId, string newPasswordHash);
    // inline CRUD
    Task<IEnumerable<UserListItem>> GetAllAsync();
    /// <summary>Accounts not yet claimed by any employee — feeds the "link account" picker.</summary>
    Task<IEnumerable<UserListItem>> GetUnlinkedAsync();
    Task<User?> GetByIdAsync(int userId);
    Task<int> CreateAsync(string username, string passwordHash, bool isActive, int? createdBy);
    Task<int> SetActiveAsync(int userId, bool isActive, int modifiedBy);
    Task<IEnumerable<string>> GetRoleNamesAsync(int userId);
    Task AssignRoleAsync(int userId, int roleId, int? assignedBy);
}
