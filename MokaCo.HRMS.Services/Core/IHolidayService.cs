using MokaCo.HRMS.Model.Core;

namespace MokaCo.HRMS.Services.Core;

public interface IHolidayService
{
    Task<IEnumerable<Holiday>> GetAllAsync(int? year, int? branchId);
    Task<Holiday?> CreateAsync(HolidayUpsertRequest request, int actedByUserId);
    Task<Holiday?> UpdateAsync(int holidayId, HolidayUpsertRequest request, int actedByUserId);
    Task<bool> DeleteAsync(int holidayId, int actedByUserId);
}
