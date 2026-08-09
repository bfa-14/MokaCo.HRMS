using MokaCo.HRMS.Model.Attendance;

namespace MokaCo.HRMS.Services.Attendance;

public interface IAttendanceService
{
    Task<ProcessResult> ProcessAsync(DateTime? workDate);
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
}
