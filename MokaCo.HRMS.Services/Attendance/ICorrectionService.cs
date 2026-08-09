using MokaCo.HRMS.Model.Attendance;

namespace MokaCo.HRMS.Services.Attendance;

public interface ICorrectionService
{
    Task<int> CreateAsync(CorrectionCreateRequest request, int requestedBy);
    Task<CorrectionApplyResult?> ApproveAsync(int correctionId, int approvedBy);
    Task RejectAsync(int correctionId, int approvedBy);
    Task<IEnumerable<Correction>> GetPendingAsync();
    Task<IEnumerable<Correction>> GetByRecordAsync(long attendanceId);
}
