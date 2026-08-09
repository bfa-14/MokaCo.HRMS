using MokaCo.HRMS.Model.Workflow;

namespace MokaCo.HRMS.Services.Workflow;

/// <summary>The caller's identity and right to raise for others, as resolved from the token.</summary>
public record ExitPermissionCaller(int UserId, int? EmployeeId, bool HasRaiseOthers);

public interface IExitPermissionService
{
    /// <summary>
    /// Raises an exit permission, enforcing WHO it may be raised FOR: a caller with only
    /// REQUEST_RAISE_SELF may file only against their own employee id; REQUEST_RAISE_OTHERS lifts
    /// that. A mismatch is a 403, never a silent substitution — filing against the wrong person is
    /// worse than a refusal.
    /// </summary>
    Task<ExitPermissionCreated?> CreateAsync(ExitPermissionCreateRequest request, ExitPermissionCaller caller);

    Task<IEnumerable<MyExitPermission>> GetForEmployeeAsync(int employeeId, DateTime? fromDate, DateTime? toDate);
    Task<ExitPermissionDetail?> GetByRequestAsync(int requestInstanceId);
    Task<ApplyResult> ApplyToAttendanceAsync(int? exitPermissionId, DateTime? workDate);
    Task<IEnumerable<PendingApplication>> GetPendingApplicationAsync();
    Task<PostLeaveResult> PostLeaveUsageAsync(PostLeaveRequest request, int? postedBy);
}
