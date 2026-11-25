using MokaCo.HRMS.Model.Attendance;

namespace MokaCo.HRMS.Services.Attendance;

public interface IShiftService
{
    Task<IEnumerable<Shift>> GetAllAsync();
    Task<int> CreateAsync(ShiftCreateRequest request, int? callerUserId);
    Task UpdateAsync(int shiftId, ShiftUpdateRequest request, int? callerUserId);

    /// <summary>The shift's history of hours, oldest first (script 117).</summary>
    Task<IEnumerable<ShiftHours>> GetHoursAsync(int shiftId);

    /// <summary>Takes one change of hours back; the days it covered are derived again.</summary>
    Task<ShiftHoursChangeResult> DeleteHoursAsync(int shiftHoursId, int? callerUserId);

    /// <summary>
    /// The shift's change log, newest first (script 122): who changed its hours, name or active, from what to what.
    /// Empty while the script is not applied (there was no log before it).
    /// </summary>
    Task<IEnumerable<ShiftChange>> GetChangesAsync(int shiftId);

    /// <summary>Puts on the shifts the hours in force today. Returns the shifts updated (the nightly job).</summary>
    Task<int> SyncCurrentAsync();
}
