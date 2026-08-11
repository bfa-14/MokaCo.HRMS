using MokaCo.HRMS.Model.Workflow;

namespace MokaCo.HRMS.Repository.Workflow;

public interface IExitPermissionRepository
{
    Task<ExitPermissionCreated?> CreateAsync(int employeeId, int raisedByUserId, DateTime exitDate, TimeSpan fromTime, TimeSpan toTime, string reason, bool convertToLeave, string? title);
    Task<IEnumerable<MyExitPermission>> GetForEmployeeAsync(int employeeId, DateTime? fromDate, DateTime? toDate);
    Task<ExitPermissionDetail?> GetByRequestAsync(int requestInstanceId);

    /// <summary>Sweeps approved-but-unapplied permissions into attendance. No arguments = every one whose day now exists.</summary>
    Task<ApplyResult> ApplyToAttendanceAsync(int? exitPermissionId, DateTime? workDate);

    /// <summary>
    /// The TYPED decision (usp_ExitPermission_Decide) — the only path that can reduce the minutes.
    /// A null <paramref name="approvedMinutes"/> approves the figure as it stands; more than it is
    /// refused. The procedure runs the engine first, so a refusal leaves the figure untouched.
    /// </summary>
    Task<ExitPermissionDecisionResult?> DecideAsync(int requestInstanceId, int actedByUserId, int? approvedMinutes, string? comment, bool signedWithPassword);

    Task<IEnumerable<PendingApplication>> GetPendingApplicationAsync();
    Task<PostLeaveResult> PostLeaveUsageAsync(string periodYearMonth, int leaveTypeId, int? postedBy);
}
