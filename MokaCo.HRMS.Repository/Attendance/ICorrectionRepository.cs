using MokaCo.HRMS.Model.Attendance;

namespace MokaCo.HRMS.Repository.Attendance;

public interface ICorrectionRepository
{
    Task<int> CreateAsync(long attendanceId, int requestedBy, DateTime? newFirstInUtc, DateTime? newLastOutUtc, int? newExitMinutes, string? newStatus, string reason);
    Task<CorrectionApplyResult?> ApproveAsync(int correctionId, int approvedBy);
    Task RejectAsync(int correctionId, int approvedBy);
    Task<IEnumerable<Correction>> GetPendingAsync();
    Task<IEnumerable<Correction>> GetByRecordAsync(long attendanceId);
}
