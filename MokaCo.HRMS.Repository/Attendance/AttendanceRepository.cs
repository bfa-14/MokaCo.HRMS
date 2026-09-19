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

        // The result set keeps its one column (INSERT-EXEC callers rely on that shape); the count of days that had
        // already been processed — late-arriving punches — comes back through an OUTPUT parameter (SQL 83, D6).
        var parameters = new DynamicParameters();
        parameters.Add("WorkDate", workDate, DbType.Date);
        parameters.Add("LateDaysOut", dbType: DbType.Int32, direction: ParameterDirection.Output);

        var result = await db.QuerySingleAsync<ProcessResult>(
            "attendance.usp_Attendance_ProcessRawLogs", parameters, commandType: CommandType.StoredProcedure);
        result.LateDaysReprocessed = parameters.Get<int?>("LateDaysOut") ?? 0;
        return result;
    }

    /// <summary>
    /// RE-derives one day from ALL of its punches, rather than only the unconsumed ones.
    ///
    /// This is the companion to a settings change. <see cref="ProcessRawLogsAsync"/> is incremental
    /// by design — it consumes what is outstanding — so a day already processed under one
    /// interpretation is never revisited when that interpretation changes. Switching punch direction
    /// to Alternate, or adjusting the debounce window, therefore means nothing to yesterday until
    /// this is run against it.
    ///
    /// Manual and corrected rows stay untouched: a human's decision about a day outranks any amount
    /// of re-derivation.
    /// </summary>
    public async Task<ProcessResult> ReprocessDayAsync(DateTime workDate)
    {
        using var db = _factory.Create();
        return await db.QuerySingleAsync<ProcessResult>(
            "attendance.usp_Attendance_ReprocessDay",
            new { WorkDate = workDate.Date },
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

    public async Task<IEnumerable<AttendanceAnomaly>> GetAnomaliesAsync(DateTime fromDate, DateTime toDate, bool onlyUndecided, int? branchId)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<AttendanceAnomaly>(
            "attendance.usp_Attendance_GetAnomalies",
            new { FromDate = fromDate, ToDate = toDate, OnlyUndecided = onlyUndecided, BranchId = branchId },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>
    /// HR's ruling on one anomaly. The procedure stores it and re-derives the day itself (ComputeDay,
    /// or the manual path for a manual day / a correction), so the figures that come back already
    /// carry the decision. Its refusals arrive as SqlException 50000 with the sentence to show.
    /// </summary>
    public async Task<AnomalyDecisionResult?> DecideAnomalyAsync(long anomalyId, string decision, DateTime? correctedTimeUtc, string? note, int? decidedByUserId)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<AnomalyDecisionResult>(
            "attendance.usp_Anomaly_Decide",
            new
            {
                AnomalyId = anomalyId,
                Decision = decision,
                CorrectedTimeUtc = correctedTimeUtc,
                Note = note,
                DecidedByUserId = decidedByUserId
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<AnomalyDecideAllResult> DecideAllAnomaliesAsync(string periodYearMonth, string decision, int? branchId, string? note, int? decidedByUserId)
    {
        using var db = _factory.Create();
        return await db.QuerySingleAsync<AnomalyDecideAllResult>(
            "attendance.usp_Anomaly_DecideAll",
            new
            {
                PeriodYearMonth = periodYearMonth,
                Decision = decision,
                BranchId = branchId,
                Note = note,
                DecidedByUserId = decidedByUserId
            },
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

    public async Task<RosterMonthStatus?> GetRosterMonthAsync(int branchId, DateTime monthDate)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<RosterMonthStatus>(
            "attendance.usp_RosterMonth_Get",
            new
            {
                BranchId = branchId,
                /* Normalised the same way RosterApprovalRepository normalises it. The status of a
                   month and the request raised on it must be looked up under one date, or the
                   banner reads Draft for a month that is actually pending. */
                MonthDate = new DateTime(monthDate.Year, monthDate.Month, 1),
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<WorkedWithoutRoster>> GetWorkedWithoutRosterAsync(DateTime fromDate, DateTime toDate, int? branchId)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<WorkedWithoutRoster>(
            "attendance.usp_Attendance_GetWorkedWithoutRoster",
            new { FromDate = fromDate.Date, ToDate = toDate.Date, BranchId = branchId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<QuarantinedDeviceUser>> GetDeviceQuarantineAsync(int? branchId)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<QuarantinedDeviceUser>(
            "attendance.usp_DevicePunchQuarantine_GetAll",
            new { BranchId = branchId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<QuarantineMapResult> MapQuarantinedDeviceUserAsync(QuarantineMapRequest request, int actedByUserId)
    {
        using var db = _factory.Create();
        return await db.QuerySingleAsync<QuarantineMapResult>(
            "attendance.usp_DevicePunchQuarantine_MapToEmployee",
            new { request.DeviceId, EnrollPin = request.EnrollPin.Trim(), request.EmployeeId, ActedByUserId = actedByUserId },
            commandType: CommandType.StoredProcedure);
    }
}
