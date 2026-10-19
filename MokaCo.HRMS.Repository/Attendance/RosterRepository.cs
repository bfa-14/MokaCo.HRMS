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

    public async Task<IEnumerable<ShiftAssignment>> GetByDateRangeAsync(DateTime fromDate, DateTime toDate, int? employeeId, int? branchId = null, int? callerUserId = null)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<ShiftAssignment>(
            "attendance.usp_ShiftAssignment_GetByDateRange",
            new { FromDate = fromDate, ToDate = toDate, EmployeeId = employeeId, BranchId = branchId, CallerUserId = callerUserId },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>
    /// Sets ONE employee-day — what a click on a single calendar cell calls. QA3 (ROS-6): a missing past day of an
    /// approved month added by HR is derived by the procedure in the same call.
    /// </summary>
    public async Task<int> UpsertDayAsync(int employeeId, DateTime workDate, int? shiftId, bool isRestDay, int? callerUserId = null)
    {
        using var db = _factory.Create();
        return await db.ExecuteScalarAsync<int>(
            "attendance.usp_ShiftAssignment_Upsert",
            new { EmployeeId = employeeId, WorkDate = workDate, ShiftId = shiftId, IsRestDay = isRestDay, CallerUserId = callerUserId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task DeleteAsync(int shiftAssignmentId, int? callerUserId = null)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "attendance.usp_ShiftAssignment_Delete",
            new { ShiftAssignmentId = shiftAssignmentId, CallerUserId = callerUserId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<RosterGenerateResult> GenerateRangeAsync(int employeeId, DateTime fromDate, DateTime toDate, int shiftId, string weekdays, bool overwrite,
        int? callerUserId = null, int? branchId = null)
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
                Overwrite = overwrite,
                CallerUserId = callerUserId,
                BranchId = branchId
            },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>
    /// @EmployeeIds is a comma-separated list ('10,11,12') — the procedure splits and loops it. QA3 (ROS-13): the
    /// procedure captures the per-employee results, so its one result set is EmployeesProcessed + RowsInserted.
    /// </summary>
    public async Task<RosterBulkResult> GenerateRangeBulkAsync(string employeeIds, DateTime fromDate, DateTime toDate, int shiftId, string weekdays, bool overwrite,
        int? callerUserId = null, int? branchId = null)
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
                Overwrite = overwrite,
                CallerUserId = callerUserId,
                BranchId = branchId
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<RosterGenerateResult> CopyPeriodAsync(string sourceYearMonth, string targetYearMonth, int? employeeId, bool overwrite,
        int? branchId, int? callerUserId = null)
    {
        using var db = _factory.Create();
        return await db.QuerySingleAsync<RosterGenerateResult>(
            "attendance.usp_ShiftAssignment_CopyPeriod",
            new
            {
                SourceYearMonth = sourceYearMonth,
                TargetYearMonth = targetYearMonth,
                EmployeeId = employeeId,
                Overwrite = overwrite,
                BranchId = branchId,
                CallerUserId = callerUserId
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<RosterGenerateResult> ApplyPatternForMonthAsync(string yearMonth, int? employeeId, bool overwrite,
        int? branchId, int? callerUserId = null)
    {
        using var db = _factory.Create();
        return await db.QuerySingleAsync<RosterGenerateResult>(
            "attendance.usp_ShiftAssignment_ApplyPatternForMonth",
            new { YearMonth = yearMonth, EmployeeId = employeeId, Overwrite = overwrite, BranchId = branchId, CallerUserId = callerUserId },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>Employee-days with NO roster row. The processor cannot judge these, so they block payroll.</summary>
    public async Task<IEnumerable<RosterGap>> GetGapsAsync(DateTime fromDate, DateTime toDate, int? callerUserId = null, int? branchId = null)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<RosterGap>(
            "attendance.usp_ShiftAssignment_GetGaps",
            new { FromDate = fromDate, ToDate = toDate, CallerUserId = callerUserId, BranchId = branchId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<RosterLeaveDay>> GetLeaveDaysAsync(DateTime fromDate, DateTime toDate, int? branchId, int? callerUserId)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<RosterLeaveDay>(
            "attendance.usp_Roster_GetLeaveDays",
            new { FromDate = fromDate, ToDate = toDate, BranchId = branchId, CallerUserId = callerUserId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<RosterMonthStatus?> GetMonthAsync(int branchId, DateTime monthDate, int? callerUserId)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<RosterMonthStatus>(
            "attendance.usp_RosterMonth_Get",
            new { BranchId = branchId, MonthDate = monthDate.Date, CallerUserId = callerUserId },
            commandType: CommandType.StoredProcedure);
    }

    /* THE RE-DERIVATIONS run ComputeDay over a whole branch-month (a few hundred employee-days), well past Dapper's
       30-second default on a busy month: five minutes for one month, unbounded for the nightly sweep. */
    private const int RederiveMonthTimeoutSeconds = 300;

    public async Task RederiveForRequestAsync(int requestInstanceId)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "attendance.usp_Roster_RederiveForRequest",
            new { RequestInstanceId = requestInstanceId },
            commandType: CommandType.StoredProcedure,
            commandTimeout: RederiveMonthTimeoutSeconds);
    }

    public async Task<int> RederiveMonthAsync(int branchId, int year, int month, int? callerUserId)
    {
        using var db = _factory.Create();
        var p = new DynamicParameters(new { BranchId = branchId, Year = year, Month = month, CallerUserId = callerUserId });
        p.Add("DaysRederived", dbType: DbType.Int32, direction: ParameterDirection.Output);
        await db.ExecuteAsync("attendance.usp_Roster_RederiveMonth", p,
            commandType: CommandType.StoredProcedure, commandTimeout: RederiveMonthTimeoutSeconds);
        return p.Get<int?>("DaysRederived") ?? 0;
    }

    public async Task<RosterRederivePendingResult> RederivePendingAsync()
    {
        using var db = _factory.Create();
        return await db.QuerySingleAsync<RosterRederivePendingResult>(
            "attendance.usp_Roster_RederivePending",
            commandType: CommandType.StoredProcedure,
            commandTimeout: 0);
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

    public async Task<RosterClearResult> ClearMonthAsync(int branchId, int year, int month, int? userId)
    {
        using var db = _factory.Create();
        return await db.QuerySingleAsync<RosterClearResult>(
            "attendance.usp_Roster_Clear",
            new { BranchId = branchId, Year = year, Month = month, UserId = userId },
            commandType: CommandType.StoredProcedure);
    }
}
