using Dapper;
using MokaCo.HRMS.Model.Security;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.Security;

/// <summary>Read-only list of permissions (developer-seeded reference data).</summary>
public class PermissionRepository : IPermissionRepository
{
    private readonly IDbConnectionFactory _factory;
    public PermissionRepository(IDbConnectionFactory factory) => _factory = factory;

    public async Task<IEnumerable<Permission>> GetAllAsync()
    {
        const string sql = @"SELECT * FROM security.PERMISSION ORDER BY Module, Code;";
        using var db = _factory.Create();
        return await db.QueryAsync<Permission>(sql);
    }
}
