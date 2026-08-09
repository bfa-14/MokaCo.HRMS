using MokaCo.HRMS.Model.Report;

namespace MokaCo.HRMS.Services.Report;

public interface IReportService
{
    Task<ReportResult<MonthlyAttendanceHeader, MonthlyAttendanceRow>> GetMonthlyAttendanceAsync(string periodYearMonth, int? branchId);
    Task<ReportResult<DailyAttendanceHeader, DailyAttendanceRow>> GetDailyAttendanceAsync(DateTime workDate, int? branchId);
    Task<ReportResult<LeaveBalanceHeader, LeaveBalanceRow>> GetLeaveBalanceAsync(string asOfYearMonth, int? employeeId, int? branchId);
}
