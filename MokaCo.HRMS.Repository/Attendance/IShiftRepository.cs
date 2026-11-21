using MokaCo.HRMS.Model.Attendance;

namespace MokaCo.HRMS.Repository.Attendance;

public interface IShiftRepository
{
    Task<IEnumerable<Shift>> GetAllAsync();
    Task<int> CreateAsync(string name, TimeSpan startTime, TimeSpan endTime, int? graceMinutes, bool crossesMidnight, int breakMinutes, int? callerUserId);

    /// <summary>Name and Active; hours that differ are recorded from <paramref name="effectiveFrom"/> (script 117).</summary>
    Task UpdateAsync(int shiftId, string name, TimeSpan startTime, TimeSpan endTime, int? graceMinutes, bool crossesMidnight, int breakMinutes, bool isActive,
        DateOnly? effectiveFrom, DateOnly? effectiveTo, string? note, int? callerUserId);

    /// <summary>The shift's history of hours, oldest first.</summary>
    Task<IEnumerable<ShiftHours>> GetHoursAsync(int shiftId);

    /// <summary>Takes one change of hours back; the days it covered are derived again.</summary>
    Task<int> DeleteHoursAsync(int shiftHoursId, int? callerUserId);

    /// <summary>Puts on attendance.SHIFT the hours in force today (a change dated ahead takes its place on its day). Returns the shifts updated.</summary>
    Task<int> SyncCurrentAsync();
}
