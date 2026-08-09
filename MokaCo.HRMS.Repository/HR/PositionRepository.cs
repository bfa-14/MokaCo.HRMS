using System.Data;
using Dapper;
using MokaCo.HRMS.Model.HR;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.HR;

/// <summary>Dapper access for positions via the hr.usp_Position_* stored procedures.</summary>
public class PositionRepository : IPositionRepository
{
    private readonly IDbConnectionFactory _factory;
    public PositionRepository(IDbConnectionFactory factory) => _factory = factory;

    public async Task<IEnumerable<Position>> GetAllAsync()
    {
        using var db = _factory.Create();
        return await db.QueryAsync<Position>(
            "hr.usp_Position_GetAll",
            commandType: CommandType.StoredProcedure);
    }

    public async Task<int> CreateAsync(string title)
    {
        using var db = _factory.Create();
        return await db.ExecuteScalarAsync<int>(
            "hr.usp_Position_Create",
            new { Title = title },
            commandType: CommandType.StoredProcedure);
    }

    public async Task UpdateAsync(int positionId, string title, bool isActive)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "hr.usp_Position_Update",
            new { PositionId = positionId, Title = title, IsActive = isActive },
            commandType: CommandType.StoredProcedure);
    }
}
