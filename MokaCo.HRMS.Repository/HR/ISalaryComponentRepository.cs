using MokaCo.HRMS.Model.HR;

namespace MokaCo.HRMS.Repository.HR;

public interface ISalaryComponentRepository
{
    Task<IEnumerable<SalaryComponent>> GetByEmployeeAsync(int employeeId);
    Task<int> CreateAsync(int employeeId, int componentTypeId, decimal amount, string currencyCode, DateTime effectiveFrom, DateTime? effectiveTo);
    Task UpdateAsync(int salaryComponentId, decimal amount, string currencyCode, DateTime effectiveFrom, DateTime? effectiveTo);
    Task DeleteAsync(int salaryComponentId);
}
