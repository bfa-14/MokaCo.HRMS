using MokaCo.HRMS.Model.Workflow;

namespace MokaCo.HRMS.Repository.Workflow;

/// <summary>The small cross-cutting reads the workflow UI needs: who-am-I, and the branch-manager posts.</summary>
public interface IWorkflowSupportRepository
{
    /// <summary>The employee behind a user, or null for an account with no employee record.</summary>
    Task<MyEmployee?> GetEmployeeByUserIdAsync(int userId);

    Task<IEnumerable<BranchWithManager>> GetBranchesWithManagerAsync();
    Task<BranchManagerSet?> SetBranchManagerAsync(int branchId, int? managerEmployeeId, int? modifiedBy);
}
