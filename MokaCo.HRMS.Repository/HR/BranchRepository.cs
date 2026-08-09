using System.Data;
using Dapper;
using MokaCo.HRMS.Model.HR;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.HR;

/// <summary>Dapper access for branches via the hr.usp_Branch_* stored procedures.</summary>
public class BranchRepository : IBranchRepository
{
    private readonly IDbConnectionFactory _factory;
    public BranchRepository(IDbConnectionFactory factory) => _factory = factory;

    public async Task<IEnumerable<Branch>> GetAllAsync()
    {
        using var db = _factory.Create();
        return await db.QueryAsync<Branch>(
            "hr.usp_Branch_GetAll",
            commandType: CommandType.StoredProcedure);
    }

    public async Task<int> CreateAsync(string name)
    {
        using var db = _factory.Create();
        return await db.ExecuteScalarAsync<int>(
            "hr.usp_Branch_Create",
            new { Name = name },
            commandType: CommandType.StoredProcedure);
    }

    public async Task UpdateAsync(int branchId, string name, bool isActive)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "hr.usp_Branch_Update",
            new { BranchId = branchId, Name = name, IsActive = isActive },
            commandType: CommandType.StoredProcedure);
    }
}
