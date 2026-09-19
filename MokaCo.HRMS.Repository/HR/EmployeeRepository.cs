using System.Data;
using Dapper;
using MokaCo.HRMS.Model.HR;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.HR;

/// <summary>Dapper access for employees via the hr.usp_Employee_* stored procedures.</summary>
public class EmployeeRepository : IEmployeeRepository
{
    private readonly IDbConnectionFactory _factory;
    public EmployeeRepository(IDbConnectionFactory factory) => _factory = factory;

    public async Task<IEnumerable<EmployeeListItem>> GetAllAsync()
    {
        using var db = _factory.Create();
        return await db.QueryAsync<EmployeeListItem>(
            "hr.usp_Employee_GetAll",
            commandType: CommandType.StoredProcedure);
    }

    public async Task<EmployeeProfile?> GetProfileAsync(int employeeId)
    {
        using var db = _factory.Create();
        using var multi = await db.QueryMultipleAsync(
            "hr.usp_Employee_GetProfile",
            new { EmployeeId = employeeId },
            commandType: CommandType.StoredProcedure);

        var profile = await multi.ReadSingleOrDefaultAsync<EmployeeProfile>();
        if (profile is null)
            return null;

        profile.SalaryComponents = (await multi.ReadAsync<SalaryComponentLine>()).ToList();
        return profile;
    }

    public async Task<int> CreateAsync(
        int? userId, int branchId, int departmentId, int positionId, string fullName,
        string? nationalId, string? nssfNumber, DateTime hireDate, int? createdBy,
        string? email, string? phoneNumber, string? preferredLanguage)
    {
        using var db = _factory.Create();
        return await db.ExecuteScalarAsync<int>(
            "hr.usp_Employee_Create",
            new
            {
                UserId = userId,
                BranchId = branchId,
                DepartmentId = departmentId,
                PositionId = positionId,
                FullName = fullName,
                NationalId = nationalId,
                NssfNumber = nssfNumber,
                HireDate = hireDate,
                CreatedBy = createdBy,
                Email = email,
                PhoneNumber = phoneNumber,
                PreferredLanguage = preferredLanguage
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task UpdateAsync(
        int employeeId, int branchId, int departmentId, int positionId, string fullName,
        string? nationalId, string? nssfNumber, DateTime hireDate, DateTime? terminationDate, int? modifiedBy,
        string? email, string? phoneNumber, string? preferredLanguage, DateTime? branchEffectiveFrom)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "hr.usp_Employee_Update",
            new
            {
                EmployeeId = employeeId,
                BranchId = branchId,
                DepartmentId = departmentId,
                PositionId = positionId,
                FullName = fullName,
                NationalId = nationalId,
                NssfNumber = nssfNumber,
                HireDate = hireDate,
                TerminationDate = terminationDate,
                ModifiedBy = modifiedBy,
                Email = email,
                PhoneNumber = phoneNumber,
                PreferredLanguage = preferredLanguage,
                // Only read by the procedure when the branch changes: the transfer's effective date (SQL 85, D7).
                BranchEffectiveFrom = branchEffectiveFrom?.Date
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<EmployeeBranchHistoryRow>> GetBranchHistoryAsync(int employeeId)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<EmployeeBranchHistoryRow>(
            "hr.usp_EmployeeBranchHistory_Get",
            new { EmployeeId = employeeId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task CancelFutureTransferAsync(int employeeBranchHistoryId, int? actedByUserId)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "hr.usp_EmployeeBranchHistory_CancelFuture",
            new { EmployeeBranchHistoryId = employeeBranchHistoryId, ActedByUserId = actedByUserId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task SoftDeleteAsync(int employeeId, int? modifiedBy)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "hr.usp_Employee_SoftDelete",
            new { EmployeeId = employeeId, ModifiedBy = modifiedBy },
            commandType: CommandType.StoredProcedure);
    }

    // ---- employee <-> user account linking ----

    public async Task<IEnumerable<EmployeeLoginStatus>> GetLoginStatusAsync(bool onlyMissing)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<EmployeeLoginStatus>(
            "hr.usp_Employee_GetLoginStatus",
            new { OnlyMissing = onlyMissing },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<EmployeeUserLinkResult?> LinkUserAsync(int employeeId, int userId, int? actedBy)
    {
        using var db = _factory.Create();
        // The procedure RAISERRORs (not found / already linked to someone else) — that surfaces as a
        // SqlException the service maps to a 400 with the message intact; on success it returns one row.
        return await db.QuerySingleOrDefaultAsync<EmployeeUserLinkResult>(
            "hr.usp_Employee_LinkUser",
            new { EmployeeId = employeeId, UserId = userId, ActedBy = actedBy },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<EmployeeUserUnlinkResult> UnlinkUserAsync(int employeeId, int? actedBy)
    {
        using var db = _factory.Create();
        // The procedure never raises — it always returns exactly one row describing what the unlink cost.
        return await db.QuerySingleAsync<EmployeeUserUnlinkResult>(
            "hr.usp_Employee_UnlinkUser",
            new { EmployeeId = employeeId, ActedBy = actedBy },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<EmployeeApprovalTier?> SetApprovalTierAsync(int employeeId, int approvalTier)
    {
        using var db = _factory.Create();
        // Validates 1..3 and RAISERRORs otherwise; on success returns the employee's new tier row.
        return await db.QuerySingleOrDefaultAsync<EmployeeApprovalTier>(
            "hr.usp_Employee_SetApprovalTier",
            new { EmployeeId = employeeId, ApprovalTier = approvalTier },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<EmployeeReportsTo?> SetReportsToAsync(int employeeId, int? reportsToEmployeeId)
    {
        using var db = _factory.Create();
        // RAISERRORs on a self-reference or a loop; on success returns the new manager + any login warning.
        return await db.QuerySingleOrDefaultAsync<EmployeeReportsTo>(
            "hr.usp_Employee_SetReportsTo",
            new { EmployeeId = employeeId, ReportsToEmployeeId = reportsToEmployeeId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<ReportingLineEntry>> GetReportingLineAsync(int employeeId)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<ReportingLineEntry>(
            "hr.usp_Employee_GetReportingLine",
            new { EmployeeId = employeeId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<OrgTreeNode>> GetOrgTreeAsync()
    {
        using var db = _factory.Create();
        // Pre-sorted depth-first by the procedure — the caller renders in the order it comes back.
        return await db.QueryAsync<OrgTreeNode>(
            "hr.usp_Employee_GetOrgTree",
            commandType: CommandType.StoredProcedure);
    }

    public async Task<int> GetOrgMaxDepthAsync()
    {
        using var db = _factory.Create();
        // Single scalar: the deepest ReportsTo chain among current employees, 0 when nobody reports to anyone.
        return await db.ExecuteScalarAsync<int>(
            "hr.usp_Org_GetMaxDepth",
            commandType: CommandType.StoredProcedure);
    }
}
