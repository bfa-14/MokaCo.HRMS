using MokaCo.HRMS.Model.HR;

namespace MokaCo.HRMS.Services.HR;

public interface IDepartmentService
{
    Task<IEnumerable<Department>> GetAllAsync();
    Task<int> CreateAsync(string name);
    Task UpdateAsync(int departmentId, string name, bool isActive);
}
