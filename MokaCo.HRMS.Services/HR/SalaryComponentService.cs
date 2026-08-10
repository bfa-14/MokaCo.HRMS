using MokaCo.HRMS.Model.HR;
using MokaCo.HRMS.Repository.HR;
using MokaCo.HRMS.Services.Workflow;

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

    // ── salary administration ────────────────────────────────────────────────
    //
    // Nothing is validated here. The rules that matter are the ones a person has to LEARN — that a
    // change cannot start inside a locked month, that computed components are not assigned by hand,
    // that a change closes the old row rather than editing it — and each of the procedure's
    // refusals teaches its own rule in a sentence. Restating any of them here would produce a worse
    // sentence and a second opinion that can drift.

    public Task<IEnumerable<EmployeeSalaryComponent>> GetForEmployeeAsync(int employeeId)
        => _repo.GetForEmployeeAsync(employeeId);

    /// <summary>
    /// The locked-through refusal is the one that teaches the whole model: it names the earliest
    /// date that would work, so the fix is in the message.
    /// </summary>
    public Task<IEnumerable<EmployeeSalaryComponent>> SetAsync(
        int employeeId, SalaryComponentSetRequest request, int actedByUserId)
        => WorkflowSqlErrors.MapAsync(() => _repo.SetAsync(
            employeeId, request.ComponentTypeId, request.Amount,
            request.CurrencyCode?.Trim() ?? string.Empty,
            request.EffectiveFrom, actedByUserId));

    public Task<IEnumerable<EmployeeSalaryComponent>> EndAsync(
        int salaryComponentId, SalaryComponentEndRequest request, int actedByUserId)
        => WorkflowSqlErrors.MapAsync(() => _repo.EndAsync(
            salaryComponentId, request.EffectiveTo, actedByUserId));
}
