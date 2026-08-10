using System.Data;
using Dapper;
using MokaCo.HRMS.Model.HR;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.HR;

/// <summary>Dapper access for salary components via the hr.usp_SalaryComponent_* stored procedures.</summary>
public class SalaryComponentRepository : ISalaryComponentRepository
{
    private readonly IDbConnectionFactory _factory;
    public SalaryComponentRepository(IDbConnectionFactory factory) => _factory = factory;

    public async Task<IEnumerable<SalaryComponent>> GetByEmployeeAsync(int employeeId)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<SalaryComponent>(
            "hr.usp_SalaryComponent_GetByEmployee",
            new { EmployeeId = employeeId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<int> CreateAsync(int employeeId, int componentTypeId, decimal amount, string currencyCode, DateTime effectiveFrom, DateTime? effectiveTo)
    {
        using var db = _factory.Create();
        return await db.ExecuteScalarAsync<int>(
            "hr.usp_SalaryComponent_Create",
            new
            {
                EmployeeId = employeeId,
                ComponentTypeId = componentTypeId,
                Amount = amount,
                CurrencyCode = currencyCode,
                EffectiveFrom = effectiveFrom,
                EffectiveTo = effectiveTo
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task UpdateAsync(int salaryComponentId, decimal amount, string currencyCode, DateTime effectiveFrom, DateTime? effectiveTo)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "hr.usp_SalaryComponent_Update",
            new
            {
                SalaryComponentId = salaryComponentId,
                Amount = amount,
                CurrencyCode = currencyCode,
                EffectiveFrom = effectiveFrom,
                EffectiveTo = effectiveTo
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task DeleteAsync(int salaryComponentId)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "hr.usp_SalaryComponent_Delete",
            new { SalaryComponentId = salaryComponentId },
            commandType: CommandType.StoredProcedure);
    }

    // ── salary administration: the history-preserving path ───────────────────
    //
    // Set and End both RETURN the employee's rows as they now stand, because the caller's next
    // question is always "so what does this person earn now?" — and answering it from the same
    // transaction that changed it removes any window where the screen and the truth disagree.

    public async Task<IEnumerable<EmployeeSalaryComponent>> GetForEmployeeAsync(int employeeId)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<EmployeeSalaryComponent>(
            "hr.usp_SalaryComponent_GetForEmployee",
            new { EmployeeId = employeeId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<EmployeeSalaryComponent>> SetAsync(
        int employeeId, int componentTypeId, decimal amount, string currencyCode,
        DateTime effectiveFrom, int actedByUserId)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<EmployeeSalaryComponent>(
            "hr.usp_SalaryComponent_Set",
            new
            {
                EmployeeId = employeeId,
                ComponentTypeId = componentTypeId,
                Amount = amount,
                CurrencyCode = currencyCode,
                EffectiveFrom = effectiveFrom.Date,
                ActedByUserId = actedByUserId,
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<EmployeeSalaryComponent>> EndAsync(
        int salaryComponentId, DateTime effectiveTo, int actedByUserId)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<EmployeeSalaryComponent>(
            "hr.usp_SalaryComponent_End",
            new
            {
                SalaryComponentId = salaryComponentId,
                EffectiveTo = effectiveTo.Date,
                ActedByUserId = actedByUserId,
            },
            commandType: CommandType.StoredProcedure);
    }
}
