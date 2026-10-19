using MokaCo.HRMS.Model.HR;

namespace MokaCo.HRMS.Services.HR;

public interface ISalaryComponentService
{
    Task<IEnumerable<SalaryComponent>> GetByEmployeeAsync(int employeeId);

    // ── salary administration: the history-preserving path ───────────────────
    Task<IEnumerable<EmployeeSalaryComponent>> GetForEmployeeAsync(int employeeId);
    Task<IEnumerable<EmployeeSalaryComponent>> SetAsync(
        int employeeId, SalaryComponentSetRequest request, int actedByUserId);
    Task<IEnumerable<EmployeeSalaryComponent>> EndAsync(
        int salaryComponentId, SalaryComponentEndRequest request, int actedByUserId);
}
