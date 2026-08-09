using MokaCo.HRMS.Model.HR;

namespace MokaCo.HRMS.Repository.HR;

public interface IBranchRepository
{
    Task<IEnumerable<Branch>> GetAllAsync();
    Task<int> CreateAsync(string name);
    Task UpdateAsync(int branchId, string name, bool isActive);
}
