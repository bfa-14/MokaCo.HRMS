using MokaCo.HRMS.Model.Attendance;

namespace MokaCo.HRMS.Repository.Attendance;

public interface IRosterRepository
{
    /// <summary>branchId (optional, SQL 85): the rows of ONE branch, by the branch each employee belonged to on the work date.</summary>
    Task<IEnumerable<ShiftAssignment>> GetByDateRangeAsync(DateTime fromDate, DateTime toDate, int? employeeId, int? branchId = null, int? callerUserId = null);
    /* QA3 (ROS-14): every writer takes the caller; the procedures refuse a branch the caller does not manage unless
       they hold EMP_VIEW_ALL. Null = the system itself. */
    Task<int> UpsertDayAsync(int employeeId, DateTime workDate, int? shiftId, bool isRestDay, int? callerUserId = null);
    Task DeleteAsync(int shiftAssignmentId, int? callerUserId = null);

    Task<RosterGenerateResult> GenerateRangeAsync(int employeeId, DateTime fromDate, DateTime toDate, int shiftId, string weekdays, bool overwrite,
        int? callerUserId = null, int? branchId = null);
    Task<RosterBulkResult> GenerateRangeBulkAsync(string employeeIds, DateTime fromDate, DateTime toDate, int shiftId, string weekdays, bool overwrite,
        int? callerUserId = null, int? branchId = null);
    /// <summary>QA3 (ROS-3): one branch — the procedure refuses a null branch.</summary>
    Task<RosterGenerateResult> CopyPeriodAsync(string sourceYearMonth, string targetYearMonth, int? employeeId, bool overwrite,
        int? branchId, int? callerUserId = null);
    /// <summary>QA3 (ROS-3): one branch — the procedure refuses a null branch.</summary>
    Task<RosterGenerateResult> ApplyPatternForMonthAsync(string yearMonth, int? employeeId, bool overwrite,
        int? branchId, int? callerUserId = null);

    /// <summary>QA3 (ROS-8, ROS-10): branchId = one branch by the branch of the day; holidays are not gaps.</summary>
    Task<IEnumerable<RosterGap>> GetGapsAsync(DateTime fromDate, DateTime toDate, int? callerUserId = null, int? branchId = null);

    /// <summary>
    /// QA3 (ROS-4 / LEV-5): attendance.usp_Roster_GetLeaveDays — one row per employee-day of APPROVED leave, from the
    /// leave requests, branch of the day, caller-scoped.
    /// </summary>
    Task<IEnumerable<RosterLeaveDay>> GetLeaveDaysAsync(DateTime fromDate, DateTime toDate, int? branchId, int? callerUserId);

    /// <summary>QA3 (ROS-14): attendance.usp_RosterMonth_Get with the caller — null when the month has no header yet.</summary>
    Task<RosterMonthStatus?> GetMonthAsync(int branchId, DateTime monthDate, int? callerUserId);

    /// <summary>
    /// QA3 (ROS-2): attendance.usp_Roster_RederiveForRequest — after a ROSTER_APPROVAL request ended Approved, its
    /// branch-month is derived again from the approved roster (a no-op for any other request). Long-running.
    /// </summary>
    Task RederiveForRequestAsync(int requestInstanceId);

    /// <summary>QA3 (REL-16): attendance.usp_Roster_RederiveMonth for one branch-month; returns the days derived.</summary>
    Task<int> RederiveMonthAsync(int branchId, int year, int month, int? callerUserId);

    /// <summary>QA3 (ROS-2): the nightly safety net — attendance.usp_Roster_RederivePending.</summary>
    Task<RosterRederivePendingResult> RederivePendingAsync();

    Task<IEnumerable<ShiftPattern>> GetPatternsAsync(int employeeId);

    /// <summary>
    /// The employee's weekly template as SEVEN ROWS, whatever is on file — the shape a form that
    /// offers a whole week has to start from. GetPatternsAsync returns only the rows that exist, so a
    /// form built on it would silently offer a three-day week to somebody with three configured days.
    /// </summary>
    Task<IEnumerable<EmployeePatternDay>> GetEmployeePatternAsync(int employeeId);

    Task UpsertPatternAsync(int employeeId, byte dayOfWeek, int? shiftId, bool isRestDay);
    Task DeletePatternsAsync(int employeeId);

    /// <summary>
    /// attendance.usp_Roster_Clear — deletes the branch's assignment rows for the month (and the
    /// ROSTER_MONTH header). RAISERRORs when a Pending/OnHold/Approved roster request exists or
    /// attendance was already recorded on any of those days; the sentence says which.
    /// </summary>
    Task<RosterClearResult> ClearMonthAsync(int branchId, int year, int month, int? userId);
}
