using System.Data;
using Dapper;
using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.Attendance;

/// <summary>
/// Dapper access for the roster via attendance.usp_ShiftAssignment_* and usp_ShiftPattern_*.
/// The four generators exist because HR must never type a roster day by day; every one of them is
/// safe to re-run, and with Overwrite off they only fill in the days that are missing.
/// </summary>
public class RosterRepository : IRosterRepository
{
    private readonly IDbConnectionFactory _factory;
    public RosterRepository(IDbConnectionFactory factory) => _factory = factory;

    public async Task<IEnumerable<ShiftAssignment>> GetByDateRangeAsync(DateTime fromDate, DateTime toDate, int? employeeId)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<ShiftAssignment>(
            "attendance.usp_ShiftAssignment_GetByDateRange",
            new { FromDate = fromDate, ToDate = toDate, EmployeeId = employeeId },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>Sets ONE employee-day — what a click on a single calendar cell calls.</summary>
    public async Task<int> UpsertDayAsync(int employeeId, DateTime workDate, int? shiftId, bool isRestDay)
    {
        using var db = _factory.Create();
        return await db.ExecuteScalarAsync<int>(
            "attendance.usp_ShiftAssignment_Upsert",
            new { EmployeeId = employeeId, WorkDate = workDate, ShiftId = shiftId, IsRestDay = isRestDay },
            commandType: CommandType.StoredProcedure);
    }

    public async Task DeleteAsync(int shiftAssignmentId)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "attendance.usp_ShiftAssignment_Delete",
            new { ShiftAssignmentId = shiftAssignmentId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<RosterGenerateResult> GenerateRangeAsync(int employeeId, DateTime fromDate, DateTime toDate, int shiftId, string weekdays, bool overwrite)
    {
        using var db = _factory.Create();
        return await db.QuerySingleAsync<RosterGenerateResult>(
            "attendance.usp_ShiftAssignment_GenerateRange",
            new
            {
                EmployeeId = employeeId,
                FromDate = fromDate,
                ToDate = toDate,
                ShiftId = shiftId,
                Weekdays = weekdays,
                Overwrite = overwrite
            },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>@EmployeeIds is a comma-separated list ('10,11,12') — the procedure splits and loops it.</summary>
    public async Task<RosterBulkResult> GenerateRangeBulkAsync(string employeeIds, DateTime fromDate, DateTime toDate, int shiftId, string weekdays, bool overwrite)
    {
        using var db = _factory.Create();
        return await db.QuerySingleAsync<RosterBulkResult>(
            "attendance.usp_ShiftAssignment_GenerateRange_Bulk",
            new
            {
                EmployeeIds = employeeIds,
                FromDate = fromDate,
                ToDate = toDate,
                ShiftId = shiftId,
                Weekdays = weekdays,
                Overwrite = overwrite
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<RosterGenerateResult> CopyPeriodAsync(string sourceYearMonth, string targetYearMonth, int? employeeId, bool overwrite)
    {
        using var db = _factory.Create();
        return await db.QuerySingleAsync<RosterGenerateResult>(
            "attendance.usp_ShiftAssignment_CopyPeriod",
            new
            {
                SourceYearMonth = sourceYearMonth,
                TargetYearMonth = targetYearMonth,
                EmployeeId = employeeId,
                Overwrite = overwrite
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<RosterGenerateResult> ApplyPatternForMonthAsync(string yearMonth, int? employeeId, bool overwrite)
    {
        using var db = _factory.Create();
        return await db.QuerySingleAsync<RosterGenerateResult>(
            "attendance.usp_ShiftAssignment_ApplyPatternForMonth",
            new { YearMonth = yearMonth, EmployeeId = employeeId, Overwrite = overwrite },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>Employee-days with NO roster row. The processor cannot judge these, so they block payroll.</summary>
    public async Task<IEnumerable<RosterGap>> GetGapsAsync(DateTime fromDate, DateTime toDate)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<RosterGap>(
            "attendance.usp_ShiftAssignment_GetGaps",
            new { FromDate = fromDate, ToDate = toDate },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<ShiftPattern>> GetPatternsAsync(int employeeId)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<ShiftPattern>(
            "attendance.usp_ShiftPattern_GetByEmployee",
            new { EmployeeId = employeeId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<EmployeePatternDay>> GetEmployeePatternAsync(int employeeId)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<EmployeePatternDay>(
            "attendance.usp_EmployeePattern_Get",
            new { EmployeeId = employeeId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task UpsertPatternAsync(int employeeId, byte dayOfWeek, int? shiftId, bool isRestDay)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "attendance.usp_ShiftPattern_Upsert",
            new { EmployeeId = employeeId, DayOfWeek = dayOfWeek, ShiftId = shiftId, IsRestDay = isRestDay },
            commandType: CommandType.StoredProcedure);
    }

    public async Task DeletePatternsAsync(int employeeId)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "attendance.usp_ShiftPattern_Delete",
            new { EmployeeId = employeeId },
            commandType: CommandType.StoredProcedure);
    }
}
