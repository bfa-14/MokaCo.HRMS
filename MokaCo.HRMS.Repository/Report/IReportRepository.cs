using MokaCo.HRMS.Model.Report;

namespace MokaCo.HRMS.Repository.Report;

public interface IReportRepository
{
    Task<ReportResult<MonthlyAttendanceHeader, MonthlyAttendanceRow>> GetMonthlyAttendanceAsync(string periodYearMonth, int? branchId);
    Task<ReportResult<DailyAttendanceHeader, DailyAttendanceRow>> GetDailyAttendanceAsync(DateTime workDate, int? branchId);
    Task<ReportResult<LeaveBalanceHeader, LeaveBalanceRow>> GetLeaveBalanceAsync(string asOfYearMonth, int? employeeId, int? branchId);

    /// <summary>report.usp_Report_WorkedTime_Days (script 113): the standard day and month, and one row per employee per
    /// day of their employment in the period (the branch of that day, a public holiday's name).</summary>
    Task<(WorkedTimeStandard Standard, IEnumerable<WorkedTimeEmployeeDay> Days)> GetWorkedTimeDaysAsync(DateTime from, DateTime to, int? branchId, int? employeeId);
}
