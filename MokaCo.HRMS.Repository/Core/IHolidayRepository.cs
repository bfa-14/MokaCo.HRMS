using MokaCo.HRMS.Model.Core;

namespace MokaCo.HRMS.Repository.Core;

public interface IHolidayRepository
{
    /// <summary>Both filters optional. A branch filter keeps the all-branch holidays too: they apply to that branch.</summary>
    Task<IEnumerable<Holiday>> GetAllAsync(int? year, int? branchId);

    /// <summary>core.usp_Holiday_Upsert: insert when holidayId is null. Re-derives the attendance days it touches; a paid month is refused.</summary>
    Task<Holiday?> UpsertAsync(int? holidayId, HolidayUpsertRequest request, int actedByUserId);

    Task<bool> DeleteAsync(int holidayId, int actedByUserId);
}
