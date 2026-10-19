using MokaCo.HRMS.Model.Attendance;

namespace MokaCo.HRMS.Services.Attendance;

public interface IRosterService
{
    Task<IEnumerable<ShiftAssignment>> GetAsync(DateTime fromDate, DateTime toDate, int? employeeId, int? branchId = null, int? callerUserId = null);
    /* QA3 (ROS-14): every write carries the caller. The procedures refuse a branch the caller does not manage unless
       they hold EMP_VIEW_ALL ("You can only plan rosters for the branches you manage." - a 403). */
    Task<int> SetDayAsync(RosterDayRequest request, int? callerUserId);
    Task DeleteAsync(int shiftAssignmentId, int? callerUserId);
    Task<RosterGenerateResult> GenerateAsync(RosterGenerateRequest request, int? callerUserId);
    Task<RosterBulkResult> GenerateBulkAsync(RosterGenerateBulkRequest request, int? callerUserId);
    Task<RosterGenerateResult> CopyPeriodAsync(RosterCopyPeriodRequest request, int? callerUserId);
    Task<RosterGenerateResult> ApplyPatternAsync(RosterApplyPatternRequest request, int? callerUserId);

    /// <summary>QA3 (ROS-8, ROS-10): branchId = one branch by the branch of the day; public holidays are not gaps.</summary>
    Task<IEnumerable<RosterGap>> GetGapsAsync(DateTime fromDate, DateTime toDate, int? callerUserId, int? branchId);

    /// <summary>QA3 (ROS-4 / LEV-5): approved leave by employee-day, from the leave requests — the roster page's overlay.</summary>
    Task<IEnumerable<RosterLeaveDay>> GetLeaveDaysAsync(DateTime fromDate, DateTime toDate, int? branchId, int? callerUserId);

    /// <summary>QA3 (ROS-14): where a branch-month stands, for a caller who may see that branch. Null = no header yet.</summary>
    Task<RosterMonthStatus?> GetMonthAsync(int branchId, DateTime monthDate, int? callerUserId);

    /// <summary>QA3 (REL-16): derive a branch-month's completed days again from its roster as it stands.</summary>
    Task<RosterRederiveResult> RederiveMonthAsync(int branchId, int year, int month, int? callerUserId);

    /// <summary>
    /// QA3 (ROS-2): called right after a request ended Approved. When it is a ROSTER_APPROVAL in force, its branch-month
    /// is derived again from the approved roster (any other request: nothing). NEVER THROWS — the approval is already
    /// committed and must not read as failed; a failure is logged and the nightly safety net re-derives the month.
    /// Returns false when it failed.
    /// </summary>
    Task<bool> RederiveApprovedRequestAsync(int requestInstanceId);

    /// <summary>QA3 (ROS-2): the nightly safety net — every month approved since it was last re-derived.</summary>
    Task<RosterRederivePendingResult> RederivePendingMonthsAsync();
    Task<IEnumerable<ShiftPattern>> GetPatternsAsync(int employeeId);

    /// <summary>The weekly template as SEVEN rows, whatever is on file — see IRosterRepository.</summary>
    Task<IEnumerable<EmployeePatternDay>> GetEmployeePatternAsync(int employeeId);
    Task SavePatternsAsync(int employeeId, IEnumerable<ShiftPatternUpsertRequest> days);
    Task DeletePatternsAsync(int employeeId);

    /// <summary>
    /// Clears one branch-month of roster. Refused (WorkflowException 409, procedure's sentence) while a
    /// roster request is pending/on hold/approved for it, or once attendance exists on any of its days.
    /// </summary>
    Task<RosterClearResult> ClearMonthAsync(int branchId, int year, int month, int? userId);
}
