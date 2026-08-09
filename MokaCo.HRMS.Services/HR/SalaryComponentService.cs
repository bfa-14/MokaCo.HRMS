using MokaCo.HRMS.Model.HR;
using MokaCo.HRMS.Repository.HR;

namespace MokaCo.HRMS.Services.HR;

/// <summary>Salary-component administration (thin wrapper over the repository).</summary>
public class SalaryComponentService : ISalaryComponentService
{
    private readonly ISalaryComponentRepository _repo;
    public SalaryComponentService(ISalaryComponentRepository repo) => _repo = repo;

    public Task<IEnumerable<SalaryComponent>> GetByEmployeeAsync(int employeeId)
        => _repo.GetByEmployeeAsync(employeeId);

    public Task<int> CreateAsync(SalaryComponentCreateRequest request)
        => _repo.CreateAsync(
            request.EmployeeId, request.ComponentTypeId, request.Amount,
            request.CurrencyCode, request.EffectiveFrom, request.EffectiveTo);

    public Task UpdateAsync(int salaryComponentId, SalaryComponentUpdateRequest request)
        => _repo.UpdateAsync(
            salaryComponentId, request.Amount, request.CurrencyCode,
            request.EffectiveFrom, request.EffectiveTo);

    public Task DeleteAsync(int salaryComponentId) => _repo.DeleteAsync(salaryComponentId);
}
