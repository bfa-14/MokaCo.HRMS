using MokaCo.HRMS.Model.Core;
using MokaCo.HRMS.Repository.Core;

namespace MokaCo.HRMS.Services.Core;

/// <summary>
/// Public holidays. The rules live in the procedures (a date and a name, one per date per branch, never on a
/// paid month) and their refusals travel to the client as they are; this layer adds nothing to them.
/// </summary>
public class HolidayService : IHolidayService
{
    private readonly IHolidayRepository _holidays;
    public HolidayService(IHolidayRepository holidays) => _holidays = holidays;

    public Task<IEnumerable<Holiday>> GetAllAsync(int? year, int? branchId) => _holidays.GetAllAsync(year, branchId);

    public Task<Holiday?> CreateAsync(HolidayUpsertRequest request, int actedByUserId)
        => _holidays.UpsertAsync(null, request, actedByUserId);

    public Task<Holiday?> UpdateAsync(int holidayId, HolidayUpsertRequest request, int actedByUserId)
        => _holidays.UpsertAsync(holidayId, request, actedByUserId);

    public Task<bool> DeleteAsync(int holidayId, int actedByUserId) => _holidays.DeleteAsync(holidayId, actedByUserId);
}
