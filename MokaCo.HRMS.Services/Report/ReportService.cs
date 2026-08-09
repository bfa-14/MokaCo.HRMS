using MokaCo.HRMS.Model.Report;
using MokaCo.HRMS.Repository.Report;

namespace MokaCo.HRMS.Services.Report;

/// <summary>
/// The printable reports (thin wrapper over the repository).
///
/// There is genuinely no orchestration to do: each report is one stored procedure that already
/// computes its own header and rows, and reporting reads nothing it then has to reconcile. The
/// service exists to keep the layering honest — controllers never touch a repository directly —
/// not because it has logic to hold.
/// </summary>
public class ReportService : IReportService
{
    private readonly IReportRepository _repo;
    public ReportService(IReportRepository repo) => _repo = repo;

    public Task<ReportResult<MonthlyAttendanceHeader, MonthlyAttendanceRow>> GetMonthlyAttendanceAsync(string periodYearMonth, int? branchId)
        => _repo.GetMonthlyAttendanceAsync(periodYearMonth, branchId);

    public Task<ReportResult<DailyAttendanceHeader, DailyAttendanceRow>> GetDailyAttendanceAsync(DateTime workDate, int? branchId)
        => _repo.GetDailyAttendanceAsync(workDate, branchId);

    public Task<ReportResult<LeaveBalanceHeader, LeaveBalanceRow>> GetLeaveBalanceAsync(string asOfYearMonth, int? employeeId, int? branchId)
        => _repo.GetLeaveBalanceAsync(asOfYearMonth, employeeId, branchId);
}
