using MokaCo.HRMS.Model.HR;

namespace MokaCo.HRMS.Repository.HR;

public interface ISalaryComponentRepository
{
    Task<IEnumerable<SalaryComponent>> GetByEmployeeAsync(int employeeId);

    /// <summary>
    /// The salary administration read: current rows AND history, one call.
    /// </summary>
    Task<IEnumerable<EmployeeSalaryComponent>> GetForEmployeeAsync(int employeeId);

    /// <summary>
    /// Sets a component's value FROM a date. Not an edit: the procedure closes the standing row the
    /// day before and opens a new one, so a month already paid keeps saying what it paid.
    ///
    /// It refuses a date inside a locked month, naming the earliest date that would work; it refuses
    /// a non-standing component type; and it is HR's act — the procedure checks the role itself.
    /// Returns the employee's rows as they now stand.
    /// </summary>
    Task<IEnumerable<EmployeeSalaryComponent>> SetAsync(
        int employeeId, int componentTypeId, decimal amount, string currencyCode,
        DateTime effectiveFrom, int actedByUserId);

    /// <summary>
    /// Closes a standing row on a date. Refuses a row already closed, an end before the start, and
    /// any date inside a locked month — the component was paid, and history stays as it was paid.
    /// </summary>
    Task<IEnumerable<EmployeeSalaryComponent>> EndAsync(
        int salaryComponentId, DateTime effectiveTo, int actedByUserId);
    Task<int> CreateAsync(int employeeId, int componentTypeId, decimal amount, string currencyCode, DateTime effectiveFrom, DateTime? effectiveTo);
    Task UpdateAsync(int salaryComponentId, decimal amount, string currencyCode, DateTime effectiveFrom, DateTime? effectiveTo);
    Task DeleteAsync(int salaryComponentId);
}
