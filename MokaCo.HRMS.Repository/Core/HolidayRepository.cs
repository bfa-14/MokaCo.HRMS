using System.Data;
using Dapper;
using MokaCo.HRMS.Model.Core;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.Core;

public class HolidayRepository : IHolidayRepository
{
    private readonly IDbConnectionFactory _factory;
    public HolidayRepository(IDbConnectionFactory factory) => _factory = factory;

    public async Task<IEnumerable<Holiday>> GetAllAsync(int? year, int? branchId)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<Holiday>(
            "core.usp_Holiday_GetAll",
            new { Year = year, BranchId = branchId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<Holiday?> UpsertAsync(int? holidayId, HolidayUpsertRequest request, int actedByUserId)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<Holiday>(
            "core.usp_Holiday_Upsert",
            new
            {
                HolidayId = holidayId,
                HolidayDate = request.HolidayDate.Date,
                request.Name,
                request.NameAr,
                request.IsPaid,
                request.BranchId,
                ActedByUserId = actedByUserId,
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<bool> DeleteAsync(int holidayId, int actedByUserId)
    {
        using var db = _factory.Create();
        var deleted = await db.QuerySingleOrDefaultAsync<int?>(
            "core.usp_Holiday_Delete",
            new { HolidayId = holidayId, ActedByUserId = actedByUserId },
            commandType: CommandType.StoredProcedure);
        return deleted is not null;
    }
}
