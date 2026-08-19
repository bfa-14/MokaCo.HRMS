using MokaCo.HRMS.Model.Attendance;

namespace MokaCo.HRMS.Services.Attendance;

public interface IAttendanceService
{
    Task<ProcessResult> ProcessAsync(DateTime? workDate);

    /// <summary>
    /// Re-derives ONE day under the current punch-interpretation settings. The ordinary processor
    /// is incremental, so a day already built is never revisited when the rules for reading its
    /// punches change — this is what makes such a change reach yesterday.
    /// </summary>
    Task<ProcessResult> ReprocessDayAsync(DateTime workDate);

    Task<MarkAbsenteesResult> MarkAbsenteesAsync(DateTime workDate);
    Task<MarkLeaveDaysResult> MarkLeaveDaysAsync(string periodYearMonth);

    Task<IEnumerable<AttendanceRecord>> GetAsync(DateTime fromDate, DateTime toDate, int? employeeId, int? branchId);
    Task<AttendanceDetail?> GetByIdAsync(long attendanceId);
    Task<IEnumerable<AttendanceRecord>> GetAnomaliesAsync(DateTime fromDate, DateTime toDate);
    Task<IEnumerable<RawLog>> GetRawAsync(int employeeId, DateTime workDate);
    Task<IEnumerable<ExitVariance>> GetExitVariancesAsync(DateTime fromDate, DateTime toDate, bool onlyUndecided);

    Task<AttendanceRecord?> ManualUpsertAsync(ManualAttendanceRequest request);
    Task<AttendanceRecord?> SetExitApprovalAsync(long attendanceId, ExitApprovalRequest request);
    Task<AttendanceRecord?> SetExitDispositionAsync(long attendanceId, ExitDispositionRequest request);
    Task<AttendanceRecord?> AdjustDayAsync(long attendanceId, HrAdjustDayRequest request, int? modifiedBy);

    Task<PayrollReadiness> GetPayrollReadinessAsync(string periodYearMonth);
    Task<AttendanceSummary?> GetSummaryAsync(int employeeId, string periodYearMonth);
    Task<IEnumerable<AttendanceSummary>> GetSummaryAllAsync(string periodYearMonth);
    Task<IEnumerable<AttendanceBranchSummary>> GetSummaryByBranchAsync(string periodYearMonth, int? employeeId);

    /// <summary>
    /// Where one branch-month of roster has got to — Draft, Pending or Approved. NULL when no row
    /// exists yet, which is the ordinary state of a month nobody has put up for approval.
    /// </summary>
    Task<RosterMonthStatus?> GetRosterMonthAsync(int branchId, DateTime monthDate);
}
