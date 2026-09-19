using MokaCo.HRMS.Model.HR;

namespace MokaCo.HRMS.Services.HR;

public interface IEmployeeService
{
    Task<IEnumerable<EmployeeListItem>> GetAllAsync();
    Task<EmployeeProfile?> GetProfileAsync(int employeeId);
    Task<int> CreateAsync(EmployeeCreateRequest request, int? createdBy);
    Task UpdateAsync(int employeeId, EmployeeUpdateRequest request, int? modifiedBy);

    /// <summary>D7: the branches an employee has belonged to, newest first.</summary>
    Task<IEnumerable<EmployeeBranchHistoryRow>> GetBranchHistoryAsync(int employeeId);

    /// <summary>D7: withdraws a transfer recorded ahead of its date. The procedure refuses one that has already taken effect.</summary>
    Task CancelFutureTransferAsync(int employeeBranchHistoryId, int? actedByUserId);
    Task SoftDeleteAsync(int employeeId, int? modifiedBy);

    // ---- employee <-> user account linking ----
    Task<IEnumerable<EmployeeLoginStatus>> GetLoginStatusAsync(bool onlyMissing);
    Task<EmployeeUserLinkResult?> LinkUserAsync(int employeeId, int userId, int? actedBy);
    Task<EmployeeUserUnlinkResult> UnlinkUserAsync(int employeeId, int? actedBy);

    /// <summary>Sets the employee's approval tier (1/2/3), which picks the chain their requests follow.</summary>
    Task<EmployeeApprovalTier?> SetApprovalTierAsync(int employeeId, int approvalTier);

    /// <summary>Sets who the employee reports to. A self-reference or a loop comes back as a WorkflowException.</summary>
    Task<EmployeeReportsTo?> SetReportsToAsync(int employeeId, int? reportsToEmployeeId);

    /// <summary>The employee's chain of command, bottom-up, each flagged for having a login.</summary>
    Task<IEnumerable<ReportingLineEntry>> GetReportingLineAsync(int employeeId);

    /// <summary>The whole org tree, pre-sorted depth-first.</summary>
    Task<IEnumerable<OrgTreeNode>> GetOrgTreeAsync();

    /// <summary>The deepest reporting-line chain among current employees — the builder warns past it.</summary>
    Task<int> GetOrgMaxDepthAsync();
}
