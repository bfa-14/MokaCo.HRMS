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

    // ---- inline CRUD ----

    public async Task<IEnumerable<UserListItem>> GetAllAsync()
    {
        const string sql = @"
            SELECT UserId, Username, IsActive, LastLoginAt
            FROM security.[USER]
            ORDER BY Username;";
        using var db = _factory.Create();
        return await db.QueryAsync<UserListItem>(sql);
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
