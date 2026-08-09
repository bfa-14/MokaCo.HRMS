using MokaCo.HRMS.Model.Workflow;
using MokaCo.HRMS.Repository.Workflow;

namespace MokaCo.HRMS.Services.Workflow;

/// <summary>Who-am-I and branch-manager administration (thin wrapper over the repository).</summary>
public class WorkflowSupportService : IWorkflowSupportService
{
    private readonly IWorkflowSupportRepository _repo;
    public WorkflowSupportService(IWorkflowSupportRepository repo) => _repo = repo;

    public Task<MyEmployee?> GetEmployeeByUserIdAsync(int userId) => _repo.GetEmployeeByUserIdAsync(userId);

    public Task<IEnumerable<BranchWithManager>> GetBranchesWithManagerAsync() => _repo.GetBranchesWithManagerAsync();

    public Task<BranchManagerSet?> SetBranchManagerAsync(int branchId, SetBranchManagerRequest request, int? modifiedBy)
        => _repo.SetBranchManagerAsync(branchId, request.ManagerEmployeeId, modifiedBy);
}
