using System.Data;
using Dapper;
using MokaCo.HRMS.Model.HR;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.HR;

/// <summary>
/// Dapper access for the leave ledger via the hr.usp_LeaveLedger_* / hr.usp_LeaveBalance_Get
/// stored procedures. Balances are derived (GetBalance), never written directly.
/// </summary>
public class LeaveLedgerRepository : ILeaveLedgerRepository
{
    private readonly IDbConnectionFactory _factory;
    public LeaveLedgerRepository(IDbConnectionFactory factory) => _factory = factory;

    public async Task<IEnumerable<LeaveLedgerEntry>> GetByEmployeeAsync(int employeeId, string? periodYearMonth)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<LeaveLedgerEntry>(
            "hr.usp_LeaveLedger_GetByEmployee",
            new { EmployeeId = employeeId, PeriodYearMonth = periodYearMonth },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>
    /// Everybody's approved leave days in a range, one row per employee-day. Backed by
    /// hr.usp_LeaveLedger_GetDaysInRange, which derives leave from 'Usage' movements using the same
    /// rule attendance.usp_Attendance_MarkLeaveDays uses — the roster and the processor must never
    /// disagree about who was on leave.
    /// </summary>
    public async Task<IEnumerable<LeaveDay>> GetLeaveDaysInRangeAsync(DateTime fromDate, DateTime toDate)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<LeaveDay>(
            "hr.usp_LeaveLedger_GetDaysInRange",
            new { FromDate = fromDate, ToDate = toDate },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<int> PostMovementAsync(
        int employeeId, int leaveTypeId, string movementType, decimal days, DateTime effectiveDate,
        int? leaveRequestId, string? note, int? createdBy)
    {
        using var db = _factory.Create();
        return await db.ExecuteScalarAsync<int>(
            "hr.usp_LeaveLedger_PostMovement",
            new
            {
                EmployeeId = employeeId,
                LeaveTypeId = leaveTypeId,
                MovementType = movementType,
                Days = days,
                EffectiveDate = effectiveDate,
                LeaveRequestId = leaveRequestId,
                Note = note,
                CreatedBy = createdBy
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task DeleteAsync(int leaveLedgerId)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "hr.usp_LeaveLedger_Delete",
            new { LeaveLedgerId = leaveLedgerId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<LeaveBalance>> GetBalanceAsync(int employeeId, string? periodYearMonth)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<LeaveBalance>(
            "hr.usp_LeaveBalance_Get",
            new { EmployeeId = employeeId, PeriodYearMonth = periodYearMonth },
            commandType: CommandType.StoredProcedure);
    }
}
