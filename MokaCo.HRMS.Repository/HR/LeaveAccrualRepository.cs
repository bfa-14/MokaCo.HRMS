using System.Data;
using Dapper;
using MokaCo.HRMS.Model.HR;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.HR;

/// <summary>
/// Read queries backing the monthly leave-accrual run. These are simple SELECTs with no
/// dedicated stored procedure, so they use inline SQL (same convention as the inline CRUD
/// in the Security feature). Posting the accrual reuses hr.usp_LeaveLedger_PostMovement
/// through <see cref="ILeaveLedgerRepository"/>.
/// </summary>
public class LeaveAccrualRepository : ILeaveAccrualRepository
{
    private readonly IDbConnectionFactory _factory;
    public LeaveAccrualRepository(IDbConnectionFactory factory) => _factory = factory;

    public async Task<IEnumerable<ActiveEmployeeForAccrual>> GetActiveEmployeesForAccrual(DateOnly asOfDate)
    {
        const string sql = @"
            SELECT EmployeeId, HireDate
            FROM hr.EMPLOYEE
            WHERE IsDeleted = 0
              AND (TerminationDate IS NULL OR TerminationDate >= @AsOf)
            ORDER BY EmployeeId;";
        using var db = _factory.Create();
        return await db.QueryAsync<ActiveEmployeeForAccrual>(
            sql,
            new { AsOf = asOfDate.ToDateTime(TimeOnly.MinValue) });
    }

    public async Task<IEnumerable<AccruingLeaveType>> GetAccruingLeaveTypes()
    {
        const string sql = @"
            SELECT LeaveTypeId, AccrualPerMonth
            FROM hr.LEAVE_TYPE
            WHERE AccrualPerMonth > 0
            ORDER BY LeaveTypeId;";
        using var db = _factory.Create();
        return await db.QueryAsync<AccruingLeaveType>(sql);
    }

    public async Task<bool> HasAccrualForPeriod(int employeeId, int leaveTypeId, string periodYearMonth)
    {
        const string sql = @"
            SELECT CASE WHEN EXISTS (
                SELECT 1 FROM hr.LEAVE_LEDGER
                WHERE EmployeeId = @EmployeeId
                  AND LeaveTypeId = @LeaveTypeId
                  AND PeriodYearMonth = @Period
                  AND MovementType = 'Accrual'
            ) THEN 1 ELSE 0 END;";
        using var db = _factory.Create();
        var exists = await db.ExecuteScalarAsync<int>(
            sql,
            new { EmployeeId = employeeId, LeaveTypeId = leaveTypeId, Period = periodYearMonth });
        return exists > 0;
    }
}
