using MokaCo.HRMS.Model.HR;

namespace MokaCo.HRMS.Services.HR;

public interface ISalaryComponentService
{
    Task<IEnumerable<SalaryComponent>> GetByEmployeeAsync(int employeeId);
    Task<int> CreateAsync(SalaryComponentCreateRequest request);
    Task UpdateAsync(int salaryComponentId, SalaryComponentUpdateRequest request);
    Task DeleteAsync(int salaryComponentId);
}
