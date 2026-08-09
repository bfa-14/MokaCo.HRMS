using MokaCo.HRMS.Model.HR;

namespace MokaCo.HRMS.Repository.HR;

public interface IDepartmentRepository
{
    Task<IEnumerable<Department>> GetAllAsync();
    Task<int> CreateAsync(string name);
    Task UpdateAsync(int departmentId, string name, bool isActive);
}
