using MokaCo.HRMS.Model.HR;

namespace MokaCo.HRMS.Services.HR;

public interface IBranchService
{
    Task<IEnumerable<Branch>> GetAllAsync();
    Task<int> CreateAsync(string name);
    Task UpdateAsync(int branchId, string name, bool isActive);
}
