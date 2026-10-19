using System.Data;
using Dapper;
using MokaCo.HRMS.Model.Report;
using MokaCo.HRMS.Repository.Attendance;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.Report;

/// <summary>
/// Dapper access for the printable reports via the report.usp_Report_* stored procedures.
///
/// Every one of these procedures returns TWO result sets — the header, then the rows — so every
/// method here reads BOTH with QueryMultiple. Reading only the first would leave a titled report
/// with no data; reading only the second would leave an anonymous table nobody can date. The
/// procedures are read-only: reports change nothing.
/// </summary>
public class ReportRepository : IReportRepository
{
    private readonly IDbConnectionFactory _factory;
    public ReportRepository(IDbConnectionFactory factory) => _factory = factory;

    /// <summary>
    /// The monthly sheet. UnpaidAbsenceDays — "the deduction", the column HR looks at hardest — is replaced by
    /// the payslip's own short-days figure (QA3 REL-15, <see cref="UnpaidAbsence"/>): the report procedure's
    /// "Absent − leave usage" counted leave twice since script 76, and the procedure is a stale copy (CON-7).
    /// </summary>
    public async Task<ReportResult<MonthlyAttendanceHeader, MonthlyAttendanceRow>> GetMonthlyAttendanceAsync(string periodYearMonth, int? branchId)
    {
        using var db = _factory.Create();
        ReportResult<MonthlyAttendanceHeader, MonthlyAttendanceRow> report;
        // Both result sets are read, and the reader closed, before the connection is asked anything else.
        using (var multi = await db.QueryMultipleAsync(
            "report.usp_Report_MonthlyAttendance",
            new { PeriodYearMonth = periodYearMonth, BranchId = branchId },
            commandType: CommandType.StoredProcedure))
        {
            report = new ReportResult<MonthlyAttendanceHeader, MonthlyAttendanceRow>
            {
                Header = await multi.ReadSingleAsync<MonthlyAttendanceHeader>(),
                Rows = (await multi.ReadAsync<MonthlyAttendanceRow>()).ToList(),
            };
        }
        UnpaidAbsence.Apply(report.Rows, await UnpaidAbsence.ReadAsync(db, periodYearMonth),
            r => r.EmployeeId, (r, days) => r.UnpaidAbsenceDays = days);
        return report;
    }

    public async Task<ReportResult<DailyAttendanceHeader, DailyAttendanceRow>> GetDailyAttendanceAsync(DateTime workDate, int? branchId)
    {
        using var db = _factory.Create();
        using var multi = await db.QueryMultipleAsync(
            "report.usp_Report_DailyAttendance",
            new { WorkDate = workDate, BranchId = branchId },
            commandType: CommandType.StoredProcedure);

        return new ReportResult<DailyAttendanceHeader, DailyAttendanceRow>
        {
            Header = await multi.ReadSingleAsync<DailyAttendanceHeader>(),
            Rows = (await multi.ReadAsync<DailyAttendanceRow>()).ToList(),
        };
    }

    public async Task<ReportResult<LeaveBalanceHeader, LeaveBalanceRow>> GetLeaveBalanceAsync(string asOfYearMonth, int? employeeId, int? branchId)
    {
        using var db = _factory.Create();
        using var multi = await db.QueryMultipleAsync(
            "report.usp_Report_LeaveBalance",
            new { AsOfYearMonth = asOfYearMonth, EmployeeId = employeeId, BranchId = branchId },
            commandType: CommandType.StoredProcedure);

        return new ReportResult<LeaveBalanceHeader, LeaveBalanceRow>
        {
            Header = await multi.ReadSingleAsync<LeaveBalanceHeader>(),
            Rows = (await multi.ReadAsync<LeaveBalanceRow>()).ToList(),
        };
    }
}
