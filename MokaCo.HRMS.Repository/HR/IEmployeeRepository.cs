using MokaCo.HRMS.Model.HR;

namespace MokaCo.HRMS.Repository.HR;

public interface IEmployeeRepository
{
    /// <summary>BUG-04: <paramref name="callerUserId"/> is the signed-in user — without EMP_VIEW_ALL the procedure returns only their own rows and the branches they manage. Null = the system itself, unscoped.</summary>
    Task<IEnumerable<EmployeeListItem>> GetAllAsync(int? callerUserId = null);
    Task<EmployeeProfile?> GetProfileAsync(int employeeId);
    Task<int> CreateAsync(
        int? userId, int branchId, int departmentId, int positionId, string fullName,
        string? nationalId, string? nssfNumber, DateTime hireDate, int? createdBy,
        string? email, string? phoneNumber, string? preferredLanguage, int? approvalTier);
    Task UpdateAsync(
        int employeeId, int branchId, int departmentId, int positionId, string fullName,
        string? nationalId, string? nssfNumber, DateTime hireDate, DateTime? terminationDate, int? modifiedBy,
        string? email, string? phoneNumber, string? preferredLanguage, DateTime? branchEffectiveFrom);
    Task<IEnumerable<EmployeeBranchHistoryRow>> GetBranchHistoryAsync(int employeeId);
    /// <summary>hr.usp_EmployeeBranchHistory_CancelFuture: a transfer that has not taken effect yet is withdrawn; one that has is refused.</summary>
    Task CancelFutureTransferAsync(int employeeBranchHistoryId, int? actedByUserId);
    Task SoftDeleteAsync(int employeeId, int? modifiedBy);

    // ---- employee <-> user account linking ----
    Task<IEnumerable<EmployeeLoginStatus>> GetLoginStatusAsync(bool onlyMissing);
    /// <summary>Links (or corrects) the account. RAISERRORs — surfaces as SqlException 50000 — when the account is taken or an id is unknown.</summary>
    Task<EmployeeUserLinkResult?> LinkUserAsync(int employeeId, int userId, int? actedBy);
    Task<EmployeeUserUnlinkResult> UnlinkUserAsync(int employeeId, int? actedBy);

    /// <summary>Sets the employee's approval tier, a tier of hr.APPROVAL_TIER. RAISERRORs on a tier the dictionary does not have.</summary>
    Task<EmployeeApprovalTier?> SetApprovalTierAsync(int employeeId, int approvalTier);

    /// <summary>Sets who the employee reports to. RAISERRORs on a self-reference or a reporting loop.</summary>
    Task<EmployeeReportsTo?> SetReportsToAsync(int employeeId, int? reportsToEmployeeId);

    /// <summary>The employee's chain of command, bottom-up (Lvl 0 = themselves), each flagged for having a login.</summary>
    Task<IEnumerable<ReportingLineEntry>> GetReportingLineAsync(int employeeId);

    /// <summary>The whole org tree, pre-sorted depth-first — every active employee with parent and depth.</summary>
    Task<IEnumerable<OrgTreeNode>> GetOrgTreeAsync();

    /// <summary>The longest reporting-line chain among current employees — a Line-manager step deeper than this skips for everyone.</summary>
    Task<int> GetOrgMaxDepthAsync();

    /// <summary>
    /// QA3 REL-4: hr.usp_Employee_ApplyDueTerminations — the day after a termination date the login is disabled, the
    /// branch-manager post vacated and the device PINs unmapped, once per termination; one summary row.
    /// </summary>
    Task<TerminationSweepResult> ApplyDueTerminationsAsync();

    /// <summary>
    /// QA3 WEB-2: hr.usp_Employee_GetSwapCounterparts — the requester (IsRequester) and the active colleagues of their
    /// branch in the same position. RAISERRORs when the caller may not ask for this employee.
    /// </summary>
    Task<IEnumerable<SwapCounterpartRow>> GetSwapCounterpartsAsync(int employeeId, int? callerUserId);
}
