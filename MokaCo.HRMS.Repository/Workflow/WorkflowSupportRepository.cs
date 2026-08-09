using System.Data;
using Dapper;
using MokaCo.HRMS.Model.Workflow;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.Workflow;

/// <summary>Dapper access for the workflow support procedures in the hr schema.</summary>
public class WorkflowSupportRepository : IWorkflowSupportRepository
{
    private readonly IDbConnectionFactory _factory;
    public WorkflowSupportRepository(IDbConnectionFactory factory) => _factory = factory;

    /// <summary>Returns null when the user is not linked to an employee (a pure admin login) — that is not an error.</summary>
    public async Task<MyEmployee?> GetEmployeeByUserIdAsync(int userId)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<MyEmployee>(
            "hr.usp_Employee_GetByUserId",
            new { UserId = userId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<BranchWithManager>> GetBranchesWithManagerAsync()
    {
        using var db = _factory.Create();
        return await db.QueryAsync<BranchWithManager>(
            "hr.usp_Branch_GetAllWithManager",
            commandType: CommandType.StoredProcedure);
    }

    public async Task<BranchManagerSet?> SetBranchManagerAsync(int branchId, int? managerEmployeeId, int? modifiedBy)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<BranchManagerSet>(
            "hr.usp_Branch_SetManager",
            new { BranchId = branchId, ManagerEmployeeId = managerEmployeeId, ModifiedBy = modifiedBy },
            commandType: CommandType.StoredProcedure);
    }
}
