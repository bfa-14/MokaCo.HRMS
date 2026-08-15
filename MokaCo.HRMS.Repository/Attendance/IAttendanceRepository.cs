using MokaCo.HRMS.Model.Attendance;

namespace MokaCo.HRMS.Repository.Attendance;

public interface IAttendanceRepository
{
    /* -- the processor -- */
    Task<ProcessResult> ProcessRawLogsAsync(DateTime? workDate);

    /// <summary>
    /// Re-derives ONE day from all of its punches. The companion to a punch-interpretation change:
    /// the ordinary processor is incremental, so a day already built is never revisited when the
    /// rules for reading its punches change.
    /// </summary>
    Task<ProcessResult> ReprocessDayAsync(DateTime workDate);

    Task<MarkAbsenteesResult> MarkAbsenteesAsync(DateTime workDate);
    Task<MarkLeaveDaysResult> MarkLeaveDaysAsync(string periodYearMonth);

    /* -- reads -- */
    Task<IEnumerable<AttendanceRecord>> GetByDateRangeAsync(DateTime fromDate, DateTime toDate, int? employeeId, int? branchId);
    Task<AttendanceDetail?> GetByIdAsync(long attendanceId);
    Task<IEnumerable<AttendanceRecord>> GetAnomaliesAsync(DateTime fromDate, DateTime toDate);
    Task<IEnumerable<ExitVariance>> GetExitVariancesAsync(DateTime fromDate, DateTime toDate, bool onlyUndecided);

    /* -- HR overrides -- */
    Task<AttendanceRecord?> ManualUpsertAsync(ManualAttendanceRequest request);
    Task<AttendanceRecord?> SetExitApprovalAsync(long attendanceId, int exitApprovedMinutes, int? exitPermissionId, bool alsoSetActual, string? hrNote);
    Task<AttendanceRecord?> SetExitDispositionAsync(long attendanceId, string disposition, int? exitLeaveMinutesOverride, string? hrNote);
    Task<AttendanceRecord?> HrAdjustDayAsync(long attendanceId, int? workedMinutes, decimal? dayFraction, string? status, string hrNote, int? modifiedBy);

    /* -- payroll interface -- */
    Task<PayrollReadiness> GetPayrollReadinessAsync(string periodYearMonth);
    Task<AttendanceSummary?> GetMonthlySummaryAsync(int employeeId, string periodYearMonth);
    Task<IEnumerable<AttendanceSummary>> GetMonthlySummaryAllAsync(string periodYearMonth);
    Task<IEnumerable<AttendanceBranchSummary>> GetMonthlyByBranchAsync(string periodYearMonth, int? employeeId);
}
