using MokaCo.HRMS.Model.HR;

namespace MokaCo.HRMS.Repository.HR;

public interface IEmployeeRepository
{
    Task<IEnumerable<EmployeeListItem>> GetAllAsync();
    Task<EmployeeProfile?> GetProfileAsync(int employeeId);
    Task<int> CreateAsync(
        int? userId, int branchId, int departmentId, int positionId, string fullName,
        string? nationalId, string? nssfNumber, DateTime hireDate, int? createdBy,
        string? email, string? phoneNumber);
    Task UpdateAsync(
        int employeeId, int branchId, int departmentId, int positionId, string fullName,
        string? nationalId, string? nssfNumber, DateTime hireDate, DateTime? terminationDate, int? modifiedBy,
        string? email, string? phoneNumber);
    Task SoftDeleteAsync(int employeeId, int? modifiedBy);

    // ---- employee <-> user account linking ----
    Task<IEnumerable<EmployeeLoginStatus>> GetLoginStatusAsync(bool onlyMissing);
    /// <summary>Links (or corrects) the account. RAISERRORs — surfaces as SqlException 50000 — when the account is taken or an id is unknown.</summary>
    Task<EmployeeUserLinkResult?> LinkUserAsync(int employeeId, int userId, int? actedBy);
    Task<EmployeeUserUnlinkResult> UnlinkUserAsync(int employeeId, int? actedBy);

    /// <summary>Sets the employee's approval tier (1/2/3). RAISERRORs on an out-of-range value.</summary>
    Task<EmployeeApprovalTier?> SetApprovalTierAsync(int employeeId, int approvalTier);

    /// <summary>Sets who the employee reports to. RAISERRORs on a self-reference or a reporting loop.</summary>
    Task<EmployeeReportsTo?> SetReportsToAsync(int employeeId, int? reportsToEmployeeId);

    /// <summary>The employee's chain of command, bottom-up (Lvl 0 = themselves), each flagged for having a login.</summary>
    Task<IEnumerable<ReportingLineEntry>> GetReportingLineAsync(int employeeId);

    /// <summary>The whole org tree, pre-sorted depth-first — every active employee with parent and depth.</summary>
    Task<IEnumerable<OrgTreeNode>> GetOrgTreeAsync();

    /// <summary>The longest reporting-line chain among current employees — a Line-manager step deeper than this skips for everyone.</summary>
    Task<int> GetOrgMaxDepthAsync();
}
