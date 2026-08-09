using System.Data;
using Dapper;
using MokaCo.HRMS.Model.HR;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.HR;

/// <summary>Dapper access for departments via the hr.usp_Department_* stored procedures.</summary>
public class DepartmentRepository : IDepartmentRepository
{
    private readonly IDbConnectionFactory _factory;
    public DepartmentRepository(IDbConnectionFactory factory) => _factory = factory;

    public async Task<IEnumerable<Department>> GetAllAsync()
    {
        using var db = _factory.Create();
        return await db.QueryAsync<Department>(
            "hr.usp_Department_GetAll",
            commandType: CommandType.StoredProcedure);
    }

    public async Task<int> CreateAsync(string name)
    {
        using var db = _factory.Create();
        return await db.ExecuteScalarAsync<int>(
            "hr.usp_Department_Create",
            new { Name = name },
            commandType: CommandType.StoredProcedure);
    }

    public async Task UpdateAsync(int departmentId, string name, bool isActive)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "hr.usp_Department_Update",
            new { DepartmentId = departmentId, Name = name, IsActive = isActive },
            commandType: CommandType.StoredProcedure);
    }
}
