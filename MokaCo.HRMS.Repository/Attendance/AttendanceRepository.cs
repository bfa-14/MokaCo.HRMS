using System.Data;
using Dapper;
using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.Attendance;

/// <summary>
/// Dapper access for processed attendance via the attendance.usp_Attendance_* stored procedures.
/// Every calculation — paired intervals, break handling, day fraction, exit variance — lives in
/// those procedures, so a manual day, a corrected day and a machine-read day are all measured by
/// exactly the same rules. This class must not add arithmetic of its own.
/// </summary>
public class AttendanceRepository : IAttendanceRepository
{
    private readonly IDbConnectionFactory _factory;
    public AttendanceRepository(IDbConnectionFactory factory) => _factory = factory;

    /// <summary>
    /// Turns unprocessed raw punches into employee-day records. Passing no date consumes EVERYTHING
    /// outstanding, which is what the nightly job does. It never touches a manual row, and it leaves
    /// punches on unresolved PINs unprocessed rather than losing them.
    /// </summary>
    public async Task<ProcessResult> ProcessRawLogsAsync(DateTime? workDate)
    {
        using var db = _factory.Create();
        return await db.QuerySingleAsync<ProcessResult>(
            "attendance.usp_Attendance_ProcessRawLogs",
            new { WorkDate = workDate },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>
    /// Writes records for people who were rostered but produced NO punches at all. The processor only
    /// sees days that have punches, so without this a fully-absent employee would have no record and
    /// payroll would never know they were missing. Run it AFTER the processor.
    /// </summary>
    public async Task<MarkAbsenteesResult> MarkAbsenteesAsync(DateTime workDate)
    {
        using var db = _factory.Create();
        return await db.QuerySingleAsync<MarkAbsenteesResult>(
            "attendance.usp_Attendance_MarkAbsentees",
            new { WorkDate = workDate },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>Reclassifies absences that are covered by APPROVED leave, so they are not deducted as if nobody knew.</summary>
    public async Task<MarkLeaveDaysResult> MarkLeaveDaysAsync(string periodYearMonth)
    {
        using var db = _factory.Create();
        return await db.QuerySingleAsync<MarkLeaveDaysResult>(
            "attendance.usp_Attendance_MarkLeaveDays",
            new { PeriodYearMonth = periodYearMonth },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<AttendanceRecord>> GetByDateRangeAsync(DateTime fromDate, DateTime toDate, int? employeeId, int? branchId)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<AttendanceRecord>(
            "attendance.usp_Attendance_GetByDateRange",
            new { FromDate = fromDate, ToDate = toDate, EmployeeId = employeeId, BranchId = branchId },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>
    /// One day plus the PAIRED intervals behind it (two result sets). The intervals are the audit
    /// trail for WorkedMinutes — they are what let a human see WHY the number is what it is.
    /// </summary>
    public async Task<AttendanceDetail?> GetByIdAsync(long attendanceId)
    {
        using var db = _factory.Create();
        using var multi = await db.QueryMultipleAsync(
            "attendance.usp_Attendance_GetById",
            new { AttendanceId = attendanceId },
            commandType: CommandType.StoredProcedure);

        var detail = await multi.ReadSingleOrDefaultAsync<AttendanceDetail>();
        if (detail is null)
            return null;

        detail.Intervals = (await multi.ReadAsync<AttendanceInterval>()).ToList();
        return detail;
    }

    public async Task<IEnumerable<AttendanceRecord>> GetAnomaliesAsync(DateTime fromDate, DateTime toDate)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<AttendanceRecord>(
            "attendance.usp_Attendance_GetAnomalies",
            new { FromDate = fromDate, ToDate = toDate },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<ExitVariance>> GetExitVariancesAsync(DateTime fromDate, DateTime toDate, bool onlyUndecided)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<ExitVariance>(
            "attendance.usp_Attendance_GetExitVariances",
            new { FromDate = fromDate, ToDate = toDate, OnlyUndecided = onlyUndecided },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<AttendanceRecord?> ManualUpsertAsync(ManualAttendanceRequest request)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<AttendanceRecord>(
            "attendance.usp_Attendance_ManualUpsert",
            new
            {
                request.EmployeeId,
                request.WorkDate,
                request.FirstInUtc,
                request.LastOutUtc,
                request.ExitMinutes,
                request.ExitApprovedMins,
                request.Status,
                request.BranchId,
                request.HrNote
            },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>Records what was AUTHORISED. It never overwrites what the punches observed — the procedure keeps the two apart.</summary>
    public async Task<AttendanceRecord?> SetExitApprovalAsync(long attendanceId, int exitApprovedMinutes, int? exitPermissionId, bool alsoSetActual, string? hrNote)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<AttendanceRecord>(
            "attendance.usp_Attendance_SetExitApproval",
            new
            {
                AttendanceId = attendanceId,
                ExitApprovedMinutes = exitApprovedMinutes,
                ExitPermissionId = exitPermissionId,
                AlsoSetActual = alsoSetActual,
                HrNote = hrNote
            },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>HR's ruling on the difference. Until this is set, payroll will not run for the period.</summary>
    public async Task<AttendanceRecord?> SetExitDispositionAsync(long attendanceId, string disposition, int? exitLeaveMinutesOverride, string? hrNote)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<AttendanceRecord>(
            "attendance.usp_Attendance_SetExitDisposition",
            new
            {
                AttendanceId = attendanceId,
                Disposition = disposition,
                ExitLeaveMinutesOverride = exitLeaveMinutesOverride,
                HrNote = hrNote
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<AttendanceRecord?> HrAdjustDayAsync(long attendanceId, int? workedMinutes, decimal? dayFraction, string? status, string hrNote, int? modifiedBy)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<AttendanceRecord>(
            "attendance.usp_Attendance_HrAdjustDay",
            new
            {
                AttendanceId = attendanceId,
                WorkedMinutes = workedMinutes,
                DayFraction = dayFraction,
                Status = status,
                HrNote = hrNote,
                ModifiedBy = modifiedBy
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<PayrollReadiness> GetPayrollReadinessAsync(string periodYearMonth)
    {
        using var db = _factory.Create();
        return await db.QuerySingleAsync<PayrollReadiness>(
            "attendance.usp_Attendance_PayrollReadiness",
            new { PeriodYearMonth = periodYearMonth },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<AttendanceSummary?> GetMonthlySummaryAsync(int employeeId, string periodYearMonth)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<AttendanceSummary>(
            "attendance.usp_Attendance_MonthlySummary",
            new { EmployeeId = employeeId, PeriodYearMonth = periodYearMonth },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<AttendanceSummary>> GetMonthlySummaryAllAsync(string periodYearMonth)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<AttendanceSummary>(
            "attendance.usp_Attendance_MonthlySummary_All",
            new { PeriodYearMonth = periodYearMonth },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<AttendanceBranchSummary>> GetMonthlyByBranchAsync(string periodYearMonth, int? employeeId)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<AttendanceBranchSummary>(
            "attendance.usp_Attendance_MonthlyByBranch",
            new { PeriodYearMonth = periodYearMonth, EmployeeId = employeeId },
            commandType: CommandType.StoredProcedure);
    }
}
