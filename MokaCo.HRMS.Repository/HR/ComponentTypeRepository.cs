using System.Data;
using Dapper;
using MokaCo.HRMS.Model.HR;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.HR;

/// <summary>Dapper access for component types via the hr.usp_ComponentType_* stored procedures.</summary>
public class ComponentTypeRepository : IComponentTypeRepository
{
    private readonly IDbConnectionFactory _factory;
    public ComponentTypeRepository(IDbConnectionFactory factory) => _factory = factory;

    public async Task<IEnumerable<ComponentType>> GetAllAsync()
    {
        using var db = _factory.Create();
        return await db.QueryAsync<ComponentType>(
            "hr.usp_ComponentType_GetAll",
            commandType: CommandType.StoredProcedure);
    }

    public async Task<int> CreateAsync(string name, string category, short sign, bool? isActive = null)
    {
        using var db = _factory.Create();
        return await db.ExecuteScalarAsync<int>(
            "hr.usp_ComponentType_Create",
            new { Name = name, Category = category, Sign = sign, IsActive = isActive },
            commandType: CommandType.StoredProcedure);
    }

    public async Task UpdateAsync(int componentTypeId, string name, string category, short sign, bool? isActive = null)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "hr.usp_ComponentType_Update",
            new { ComponentTypeId = componentTypeId, Name = name, Category = category, Sign = sign, IsActive = isActive },
            commandType: CommandType.StoredProcedure);
    }

    public async Task DeleteAsync(int componentTypeId)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "hr.usp_ComponentType_Delete",
            new { ComponentTypeId = componentTypeId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task SetActiveAsync(int componentTypeId, bool isActive)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "hr.usp_ComponentType_SetActive",
            new { ComponentTypeId = componentTypeId, IsActive = isActive },
            commandType: CommandType.StoredProcedure);
    }
}
