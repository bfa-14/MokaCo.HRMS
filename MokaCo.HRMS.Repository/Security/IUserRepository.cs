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

    /// <summary>
    /// security.usp_User_EndSessions (script 105, QA3 SEC-5): a new session stamp, so every access token
    /// issued so far is refused, and every refresh token revoked — one transaction. Returns how many
    /// refresh tokens were still live. Refuses an unknown user ("User not found."). MissingScriptException
    /// while script 105 is not applied.
    /// </summary>
    Task<int> EndSessionsAsync(int userId);

    /// <summary>
    /// security.usp_User_ClearLoginFailures (script 105): a password checked right AFTER sign-in (a
    /// signature) clears the failure count as a login does, without stamping LastLoginAt.
    /// MissingScriptException while script 105 is not applied.
    /// </summary>
    Task ClearLoginFailuresAsync(int userId);
    // inline CRUD
    Task<IEnumerable<UserListItem>> GetAllAsync();
    /// <summary>Accounts not yet claimed by any employee — feeds the "link account" picker.</summary>
    Task<IEnumerable<UserListItem>> GetUnlinkedAsync();
    Task<User?> GetByIdAsync(int userId);
    Task<int> CreateAsync(string username, string passwordHash, bool isActive, int? createdBy);
    Task<int> SetActiveAsync(int userId, bool isActive, int modifiedBy);
    Task<IEnumerable<string>> GetRoleNamesAsync(int userId);
    Task AssignRoleAsync(int userId, int roleId, int? assignedBy);

    /// <summary>
    /// security.usp_User_SetRoles — REPLACES the user's role set and returns it as stored. RAISERRORs
    /// on an unknown user or role, and when the change would leave no active Admin.
    /// </summary>
    Task<IEnumerable<UserRoleItem>> SetRolesAsync(int userId, IEnumerable<int> roleIds, int? assignedBy);
}
