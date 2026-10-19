using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Repository.Attendance;
using MokaCo.HRMS.Repository.Common;
using MokaCo.HRMS.Repository.Report;
using MokaCo.HRMS.Tests.Attendance;

namespace MokaCo.HRMS.Tests.Payroll;

/// <summary>
/// QA3 REL-15: the summaries' "unpaid absence days" is replaced by the payslip's own short-days figure; an employee
/// the procedure does not list had nothing short, and reads 0 — never the stale "Absent − leave usage".
/// </summary>
[Collection(DatabaseCollection.Name)]
public class UnpaidAbsenceTests
{
    [Fact]
    public void Apply_WritesTheShortDays_AndZeroForSomebodyWithNone()
    {
        var rows = new List<AttendanceSummary>
        {
            new() { EmployeeId = 1, UnpaidAbsenceDays = 0m },     // the stale formula: 2 absences - 3 leave days
            new() { EmployeeId = 2, UnpaidAbsenceDays = 4m },     // a figure the payslip does not deduct
        };
        UnpaidAbsence.Apply(rows, new Dictionary<int, decimal> { [1] = 2m }, r => r.EmployeeId, (r, d) => r.UnpaidAbsenceDays = d);
        Assert.Equal(2m, rows[0].UnpaidAbsenceDays);
        Assert.Equal(0m, rows[1].UnpaidAbsenceDays);
    }

    /// <summary>
    /// The repositories read the summary or the report and THEN the figure, on one connection: the report's two result
    /// sets must be consumed and its reader closed first. Against the database, in a month with nothing in it.
    /// </summary>
    [DbFact]
    public async Task TheSummariesAndTheReport_ReadTheFigureAfterTheirOwnResults()
    {
        var factory = new SqlConnectionFactory(DbFactAttribute.ConnectionString);
        var all = (await new AttendanceRepository(factory).GetMonthlySummaryAllAsync("2099-11")).ToList();
        Assert.All(all, r => Assert.Equal(0m, r.UnpaidAbsenceDays));
        var report = await new ReportRepository(factory).GetMonthlyAttendanceAsync("2099-11", null);
        Assert.NotNull(report.Header);
        Assert.All(report.Rows, r => Assert.Equal(0m, r.UnpaidAbsenceDays));
    }
}
