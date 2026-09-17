using MokaCo.HRMS.Model.HR;
using MokaCo.HRMS.Repository.HR;

namespace MokaCo.HRMS.Services.HR;

/// <summary>Branch administration (thin wrapper over the repository).</summary>
public class BranchService : IBranchService
{
    private readonly IBranchRepository _repo;
    public BranchService(IBranchRepository repo) => _repo = repo;

    public Task<IEnumerable<Branch>> GetAllAsync() => _repo.GetAllAsync();
    public Task<int> CreateAsync(string name) => _repo.CreateAsync(name);
    public Task UpdateAsync(int branchId, string name, bool isActive) => _repo.UpdateAsync(branchId, name, isActive);

    public Task DeleteAsync(int branchId)
        => ReferenceDataSqlErrors.MapAsync(() => _repo.DeleteAsync(branchId));

    public Task SetActiveAsync(int branchId, bool isActive)
        => ReferenceDataSqlErrors.MapAsync(() => _repo.SetActiveAsync(branchId, isActive));
}
