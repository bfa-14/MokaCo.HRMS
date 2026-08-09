using System.Data;
using Dapper;
using MokaCo.HRMS.Model.Security;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.Security;

/// <summary>Inline Dapper CRUD for roles + their permission assignments.</summary>
public class RoleRepository : IRoleRepository
{
    private readonly IDbConnectionFactory _factory;
    public RoleRepository(IDbConnectionFactory factory) => _factory = factory;

    public async Task<IEnumerable<Role>> GetAllAsync()
    {
        const string sql = @"SELECT * FROM security.[ROLE] ORDER BY Name;";
        using var db = _factory.Create();
        return await db.QueryAsync<Role>(sql);
    }

    public async Task<Role?> GetByIdAsync(int roleId)
    {
        const string sql = @"SELECT * FROM security.[ROLE] WHERE RoleId = @RoleId;";
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<Role>(sql, new { RoleId = roleId });
    }

    public async Task<int> CreateAsync(string name, int? createdBy)
    {
        const string sql = @"
            INSERT INTO security.[ROLE] (Name, IsSystem, CreatedBy)
            VALUES (@Name, 0, @CreatedBy);
            SELECT CAST(SCOPE_IDENTITY() AS INT);";
        using var db = _factory.Create();
        return await db.ExecuteScalarAsync<int>(sql, new { Name = name, CreatedBy = createdBy });
    }

    public async Task UpdateAsync(int roleId, string name, int modifiedBy)
    {
        // guard against renaming a system role
        const string sql = @"
            UPDATE security.[ROLE]
            SET Name = @Name, ModifiedAt = SYSUTCDATETIME(), ModifiedBy = @ModifiedBy
            WHERE RoleId = @RoleId AND IsSystem = 0;";
        using var db = _factory.Create();
        await db.ExecuteAsync(sql, new { RoleId = roleId, Name = name, ModifiedBy = modifiedBy });
    }

    public async Task<IEnumerable<int>> GetPermissionIdsAsync(int roleId)
    {
        const string sql = @"SELECT PermissionId FROM security.ROLE_PERMISSION WHERE RoleId = @RoleId;";
        using var db = _factory.Create();
        return await db.QueryAsync<int>(sql, new { RoleId = roleId });
    }

    public async Task SetPermissionsAsync(int roleId, IEnumerable<int> permissionIds, int? assignedBy)
    {
        // replace the role's permission set in one transaction
        const string delSql = @"DELETE FROM security.ROLE_PERMISSION WHERE RoleId = @RoleId;";
        const string insSql = @"
            INSERT INTO security.ROLE_PERMISSION (RoleId, PermissionId, AssignedBy)
            VALUES (@RoleId, @PermissionId, @AssignedBy);";
        using var db = _factory.Create();
        db.Open();
        using var tx = db.BeginTransaction();
        await db.ExecuteAsync(delSql, new { RoleId = roleId }, tx);
        foreach (var pid in permissionIds)
            await db.ExecuteAsync(insSql, new { RoleId = roleId, PermissionId = pid, AssignedBy = assignedBy }, tx);
        tx.Commit();
    }

    /// <summary>Roles the chain builder may offer as an approver or deputy, each with its active-member count.</summary>
    public async Task<IEnumerable<ApproverRole>> GetApproversAsync()
    {
        using var db = _factory.Create();
        return await db.QueryAsync<ApproverRole>(
            "security.usp_Role_GetApprovers",
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<RoleRejectionBehaviour>> GetRejectionBehaviourAsync()
    {
        using var db = _factory.Create();
        return await db.QueryAsync<RoleRejectionBehaviour>(
            "security.usp_Role_GetRejectionBehaviour",
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>
    /// Flips the flag, then RE-READS the row through the Get procedure so the returned Meaning is the
    /// database's own wording — the Set procedure returns only the raw flag, and the caller wants the
    /// same sentence the list shows, not one this layer invented.
    /// </summary>
    public async Task<RoleRejectionBehaviour?> SetRejectionBehaviourAsync(int roleId, bool rejectionEndsRequest)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "security.usp_Role_SetRejectionBehaviour",
            new { RoleId = roleId, RejectionEndsRequest = rejectionEndsRequest },
            commandType: CommandType.StoredProcedure);

        var all = await db.QueryAsync<RoleRejectionBehaviour>(
            "security.usp_Role_GetRejectionBehaviour",
            commandType: CommandType.StoredProcedure);
        return all.FirstOrDefault(r => r.RoleId == roleId);
    }

    public async Task<IEnumerable<RoleSignatureRequirement>> GetSignatureRequirementsAsync()
    {
        using var db = _factory.Create();
        return await db.QueryAsync<RoleSignatureRequirement>(
            "security.usp_Role_GetSignatureRequirements",
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>
    /// Flips the flag then RE-READS the full row, so the caller gets a complete role (member count and
    /// all) rather than the partial the Set procedure selects. If a published chain uses the role, the
    /// procedure RAISERRORs and this throws a SqlException BEFORE the re-read — the controller turns
    /// that into the verbatim refusal the admin needs to see.
    /// </summary>
    public async Task<RoleSignatureRequirement?> SetApproverUsageAsync(int roleId, bool usableAsApprover)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "security.usp_Role_SetApproverUsage",
            new { RoleId = roleId, UsableAsApprover = usableAsApprover },
            commandType: CommandType.StoredProcedure);

        return await ReadSignatureRequirementAsync(db, roleId);
    }

    public async Task<RoleSignatureRequirement?> SetSignatureRequirementAsync(int roleId, bool requiresSignaturePassword)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "security.usp_Role_SetSignatureRequirement",
            new { RoleId = roleId, RequiresSignaturePassword = requiresSignaturePassword },
            commandType: CommandType.StoredProcedure);

        return await ReadSignatureRequirementAsync(db, roleId);
    }

    private static async Task<RoleSignatureRequirement?> ReadSignatureRequirementAsync(System.Data.IDbConnection db, int roleId)
    {
        var all = await db.QueryAsync<RoleSignatureRequirement>(
            "security.usp_Role_GetSignatureRequirements",
            commandType: CommandType.StoredProcedure);
        return all.FirstOrDefault(r => r.RoleId == roleId);
    }
}
