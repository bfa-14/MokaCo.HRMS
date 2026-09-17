using System.Data;
using Dapper;
using MokaCo.HRMS.Model.Security;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.Security;

/// <summary>
/// Dapper access for users. Security-critical operations call the stored procedures
/// (usp_User_*); plain CRUD uses inline SQL.
/// </summary>
public class UserRepository : IUserRepository
{
    private readonly IDbConnectionFactory _factory;
    public UserRepository(IDbConnectionFactory factory) => _factory = factory;

    // ---- procedure-backed ----

    public async Task<User?> GetForLoginAsync(string username)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<User>(
            "security.usp_User_GetForLogin",
            new { Username = username },
            commandType: CommandType.StoredProcedure);
    }

    public async Task RegisterLoginSuccessAsync(int userId)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "security.usp_User_RegisterLoginSuccess",
            new { UserId = userId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<LoginFailureResult> RegisterLoginFailureAsync(int userId, int maxAttempts = 5, int lockoutMinutes = 15)
    {
        using var db = _factory.Create();
        return await db.QuerySingleAsync<LoginFailureResult>(
            "security.usp_User_RegisterLoginFailure",
            new { UserId = userId, MaxAttempts = maxAttempts, LockoutMinutes = lockoutMinutes },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<PermissionDto>> GetPermissionsAsync(int userId)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<PermissionDto>(
            "security.usp_User_GetPermissions",
            new { UserId = userId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<int> ChangePasswordAsync(int userId, string newPasswordHash)
    {
        using var db = _factory.Create();
        return await db.ExecuteScalarAsync<int>(
            "security.usp_User_ChangePassword",
            new { UserId = userId, NewPasswordHash = newPasswordHash },
            commandType: CommandType.StoredProcedure);
    }

    // ---- inline CRUD ----

    public async Task<IEnumerable<UserListItem>> GetAllAsync()
    {
        // security.usp_User_GetAll (73_leave_balance_and_users.sql): the users with their linked
        // employee, then every (user, role) pair — stitched here so the grid gets one row per user.
        using var db = _factory.Create();
        using var grid = await db.QueryMultipleAsync(
            "security.usp_User_GetAll",
            commandType: CommandType.StoredProcedure);

        var users = (await grid.ReadAsync<UserListItem>()).ToList();
        var roles = (await grid.ReadAsync<(int UserId, int RoleId, string Name)>()).ToList();

        var byUser = roles.ToLookup(r => r.UserId);
        foreach (var user in users)
        {
            user.Roles = byUser[user.UserId]
                .Select(r => new UserRoleItem { RoleId = r.RoleId, Name = r.Name })
                .ToList();
            user.RoleIds = user.Roles.Select(r => r.RoleId).ToList();
        }
        return users;
    }

    public async Task<IEnumerable<UserRoleItem>> SetRolesAsync(int userId, IEnumerable<int> roleIds, int? assignedBy)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<UserRoleItem>(
            "security.usp_User_SetRoles",
            new { UserId = userId, RoleIds = string.Join(',', roleIds), AssignedBy = assignedBy },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<UserListItem>> GetUnlinkedAsync()
    {
        // Proc lives in the hr schema (the link lives on hr.EMPLOYEE) but reads security.[USER];
        // it excludes accounts already linked, so the picker cannot offer a taken one.
        using var db = _factory.Create();
        return await db.QueryAsync<UserListItem>(
            "hr.usp_User_GetUnlinked",
            commandType: CommandType.StoredProcedure);
    }

    public async Task<User?> GetByIdAsync(int userId)
    {
        const string sql = @"SELECT * FROM security.[USER] WHERE UserId = @UserId;";
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<User>(sql, new { UserId = userId });
    }

    public async Task<int> CreateAsync(string username, string passwordHash, bool isActive, int? createdBy)
    {
        const string sql = @"
            INSERT INTO security.[USER] (Username, PasswordHash, IsActive, PasswordChangedAt, CreatedBy)
            VALUES (@Username, @PasswordHash, @IsActive, SYSUTCDATETIME(), @CreatedBy);
            SELECT CAST(SCOPE_IDENTITY() AS INT);";
        using var db = _factory.Create();
        return await db.ExecuteScalarAsync<int>(sql, new { Username = username, PasswordHash = passwordHash, IsActive = isActive, CreatedBy = createdBy });
    }

    public async Task<int> SetActiveAsync(int userId, bool isActive, int modifiedBy)
    {
        const string sql = @"
            UPDATE security.[USER]
            SET IsActive = @IsActive, ModifiedAt = SYSUTCDATETIME(), ModifiedBy = @ModifiedBy
            WHERE UserId = @UserId;";
        using var db = _factory.Create();
        return await db.ExecuteAsync(sql, new { UserId = userId, IsActive = isActive, ModifiedBy = modifiedBy });
    }

    public async Task<IEnumerable<string>> GetRoleNamesAsync(int userId)
    {
        const string sql = @"
            SELECT r.Name
            FROM security.USER_ROLE ur
            JOIN security.[ROLE] r ON r.RoleId = ur.RoleId
            WHERE ur.UserId = @UserId
            ORDER BY r.Name;";
        using var db = _factory.Create();
        return await db.QueryAsync<string>(sql, new { UserId = userId });
    }

    public async Task AssignRoleAsync(int userId, int roleId, int? assignedBy)
    {
        // idempotent: ignore if the pair already exists
        const string sql = @"
            IF NOT EXISTS (SELECT 1 FROM security.USER_ROLE WHERE UserId = @UserId AND RoleId = @RoleId)
                INSERT INTO security.USER_ROLE (UserId, RoleId, AssignedBy)
                VALUES (@UserId, @RoleId, @AssignedBy);";
        using var db = _factory.Create();
        await db.ExecuteAsync(sql, new { UserId = userId, RoleId = roleId, AssignedBy = assignedBy });
    }
}
