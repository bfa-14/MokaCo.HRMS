using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Repository.Attendance;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Services.Attendance;

/// <summary>
/// Shift definitions. A shift is what makes "late" and "a full day" mean something, and its hours are DATED
/// (script 117): a change applies from a day - optionally until a day, after which the hours before come back -
/// and never re-judges the days before it. The procedures own the rules (a paid day keeps its hours, the days a
/// change reaches are derived again); what they refuse reaches the caller as a 409 with their sentence (the API's
/// error handler), as every other attendance refusal does.
/// </summary>
public class ShiftService : IShiftService
{
    private readonly IShiftRepository _repo;
    public ShiftService(IShiftRepository repo) => _repo = repo;

    public Task<IEnumerable<Shift>> GetAllAsync() => _repo.GetAllAsync();

    public Task<int> CreateAsync(ShiftCreateRequest request, int? callerUserId)
        => _repo.CreateAsync(request.Name, request.StartTime, request.EndTime,
            request.GraceMinutes, request.CrossesMidnight, request.BreakMinutes, callerUserId);

    public async Task UpdateAsync(int shiftId, ShiftUpdateRequest request, int? callerUserId)
    {
        if (request.EffectiveTo is not null && request.EffectiveFrom is null)
            throw new WorkflowException(400, "Choose the day the new hours start.");
        if (request.EffectiveTo is { } to && request.EffectiveFrom is { } from && to < from)
            throw new WorkflowException(400, "The last day of the new hours is before their first day.");

        var note = string.IsNullOrWhiteSpace(request.Note) ? null : request.Note.Trim();
        if (note is { Length: > 200 })
            throw new WorkflowException(400, "The note is at most 200 characters.");

        await _repo.UpdateAsync(shiftId, request.Name, request.StartTime, request.EndTime,
            request.GraceMinutes, request.CrossesMidnight, request.BreakMinutes, request.IsActive,
            request.EffectiveFrom, request.EffectiveTo, note, callerUserId);
    }

    public Task<IEnumerable<ShiftHours>> GetHoursAsync(int shiftId) => _repo.GetHoursAsync(shiftId);

    public async Task<ShiftHoursChangeResult> DeleteHoursAsync(int shiftHoursId, int? callerUserId)
        => new() { DaysRederived = await _repo.DeleteHoursAsync(shiftHoursId, callerUserId) };

    public Task<int> SyncCurrentAsync() => _repo.SyncCurrentAsync();
}
