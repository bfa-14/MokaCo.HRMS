using MokaCo.HRMS.Model.Workflow;

namespace MokaCo.HRMS.Repository.Workflow;

public interface IExitPermissionRepository
{
    Task<ExitPermissionCreated?> CreateAsync(int employeeId, int raisedByUserId, DateTime exitDate, TimeSpan fromTime, TimeSpan toTime, string reason, bool convertToLeave, string? title);
    Task<IEnumerable<MyExitPermission>> GetForEmployeeAsync(int employeeId, DateTime? fromDate, DateTime? toDate);
    Task<ExitPermissionDetail?> GetByRequestAsync(int requestInstanceId);

    /// <summary>Sweeps approved-but-unapplied permissions into attendance. No arguments = every one whose day now exists.</summary>
    Task<ApplyResult> ApplyToAttendanceAsync(int? exitPermissionId, DateTime? workDate);

    Task<IEnumerable<PendingApplication>> GetPendingApplicationAsync();
    Task<PostLeaveResult> PostLeaveUsageAsync(string periodYearMonth, int leaveTypeId, int? postedBy);
}
