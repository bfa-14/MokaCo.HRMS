using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Repository.Attendance;

namespace MokaCo.HRMS.Services.Attendance;

/// <summary>
/// Shift definitions (thin wrapper over the repository). A shift is what makes "late" and "a full
/// day" mean something — editing one retroactively changes how future days are judged, but never
/// re-judges days already processed.
/// </summary>
public class ShiftService : IShiftService
{
    private readonly IShiftRepository _repo;
    public ShiftService(IShiftRepository repo) => _repo = repo;

    public Task<IEnumerable<Shift>> GetAllAsync() => _repo.GetAllAsync();

    public Task<int> CreateAsync(ShiftCreateRequest request)
        => _repo.CreateAsync(request.Name, request.StartTime, request.EndTime,
            request.GraceMinutes, request.CrossesMidnight, request.BreakMinutes);

    public Task UpdateAsync(int shiftId, ShiftUpdateRequest request)
        => _repo.UpdateAsync(shiftId, request.Name, request.StartTime, request.EndTime,
            request.GraceMinutes, request.CrossesMidnight, request.BreakMinutes, request.IsActive);
}
