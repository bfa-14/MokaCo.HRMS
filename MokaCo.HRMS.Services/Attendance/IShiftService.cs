using MokaCo.HRMS.Model.Attendance;

namespace MokaCo.HRMS.Services.Attendance;

public interface IShiftService
{
    Task<IEnumerable<Shift>> GetAllAsync();
    Task<int> CreateAsync(ShiftCreateRequest request);
    Task UpdateAsync(int shiftId, ShiftUpdateRequest request);
}
