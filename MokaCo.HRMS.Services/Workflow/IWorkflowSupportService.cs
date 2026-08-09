using MokaCo.HRMS.Model.Workflow;

namespace MokaCo.HRMS.Services.Workflow;

public interface IWorkflowSupportService
{
    Task<MyEmployee?> GetEmployeeByUserIdAsync(int userId);
    Task<IEnumerable<BranchWithManager>> GetBranchesWithManagerAsync();
    Task<BranchManagerSet?> SetBranchManagerAsync(int branchId, SetBranchManagerRequest request, int? modifiedBy);
}
