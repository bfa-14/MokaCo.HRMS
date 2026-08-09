using System.Data;
using Dapper;
using MokaCo.HRMS.Model.Core;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.Core;

/// <summary>Dapper access for global policy values via the core.usp_Setting_* stored procedures.</summary>
public class SettingRepository : ISettingRepository
{
    private readonly IDbConnectionFactory _factory;
    public SettingRepository(IDbConnectionFactory factory) => _factory = factory;

    public async Task<IEnumerable<Setting>> GetAllAsync()
    {
        using var db = _factory.Create();
        return await db.QueryAsync<Setting>(
            "core.usp_Setting_GetAll",
            commandType: CommandType.StoredProcedure);
    }

    public async Task<Setting?> GetAsync(string settingKey)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<Setting>(
            "core.usp_Setting_Get",
            new { SettingKey = settingKey },
            commandType: CommandType.StoredProcedure);
    }

    public async Task UpsertAsync(string settingKey, string settingValue, string dataType, string? description, int? modifiedBy)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "core.usp_Setting_Upsert",
            new
            {
                SettingKey = settingKey,
                SettingValue = settingValue,
                DataType = dataType,
                Description = description,
                ModifiedBy = modifiedBy
            },
            commandType: CommandType.StoredProcedure);
    }
}
