using MokaCo.HRMS.Model.Attendance;

namespace MokaCo.HRMS.Repository.Attendance;

public interface IShiftRepository
{
    Task<IEnumerable<Shift>> GetAllAsync();
    Task<int> CreateAsync(string name, TimeSpan startTime, TimeSpan endTime, int graceMinutes, bool crossesMidnight, int breakMinutes);
    Task UpdateAsync(int shiftId, string name, TimeSpan startTime, TimeSpan endTime, int graceMinutes, bool crossesMidnight, int breakMinutes, bool isActive);
}
