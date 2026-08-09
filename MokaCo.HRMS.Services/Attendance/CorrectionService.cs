using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Repository.Attendance;

namespace MokaCo.HRMS.Services.Attendance;

/// <summary>
/// Corrections to processed days.
///
/// A correction is a LOGGED change, not an edit: it records the old values, the new values, who
/// asked, who approved, and why. The raw punches from the machine are never overwritten, so "what
/// the device recorded" and "what HR concluded" both survive and can be told apart a year later,
/// when someone disputes a payslip.
///
/// Approving one recomputes the day against the rostered shift using the same rules as every other
/// day, then marks the record manual so the processor leaves it alone from then on.
/// </summary>
public class CorrectionService : ICorrectionService
{
    private readonly ICorrectionRepository _repo;
    public CorrectionService(ICorrectionRepository repo) => _repo = repo;

    /// <summary>The requester is taken from the JWT, never from the request body — a correction must name the person who actually asked for it.</summary>
    public Task<int> CreateAsync(CorrectionCreateRequest request, int requestedBy)
        => _repo.CreateAsync(request.AttendanceId, requestedBy, request.NewFirstInUtc,
            request.NewLastOutUtc, request.NewExitMinutes, request.NewStatus, request.Reason);

    public Task<CorrectionApplyResult?> ApproveAsync(int correctionId, int approvedBy)
        => _repo.ApproveAsync(correctionId, approvedBy);

    public Task RejectAsync(int correctionId, int approvedBy) => _repo.RejectAsync(correctionId, approvedBy);

    /// <summary>The queue. While anything sits here, the month's figures are about to change — so payroll is blocked.</summary>
    public Task<IEnumerable<Correction>> GetPendingAsync() => _repo.GetPendingAsync();

    public Task<IEnumerable<Correction>> GetByRecordAsync(long attendanceId) => _repo.GetByRecordAsync(attendanceId);
}
