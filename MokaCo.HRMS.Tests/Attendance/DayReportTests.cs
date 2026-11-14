using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Repository.Attendance;
using MokaCo.HRMS.Services.Attendance;
using MokaCo.HRMS.Services.Workflow;
using Moq;

namespace MokaCo.HRMS.Tests.Attendance;

/// <summary>Script 110: "something is wrong with this day" - who is refused with which status, and the accept path.</summary>
public class DayReportTests
{
    [Theory]
    [InlineData("You can only report your own days, or the days of the branches you manage.", 403)]
    [InlineData("You can only decide reports of the branches you manage.", 403)]
    [InlineData("You can only withdraw a report you sent.", 403)]
    [InlineData("Somebody else decides a report about your own day.", 403)]
    [InlineData("This report is no longer open. Reload the list.", 409)]
    [InlineData("A report for this day is already waiting for HR. Withdraw it first to send a new one.", 409)]
    [InlineData("Say what is wrong with the day. HR reads it before deciding.", 400)]
    public void Refusals_carry_their_status(string message, int status)
        => Assert.Equal(status, WorkflowSqlErrors.MapMessage(message).StatusCode);

    private static DayReportHeader Report(long? attendanceId = 7, string status = "Open", bool times = true) => new()
    {
        ReportId = 3, EmployeeId = 5, WorkDate = new DateTime(2026, 11, 13), Status = status, AttendanceId = attendanceId,
        ReportedByUserId = 9, Message = "Forgot to punch out",
        ClaimedOut = times ? new DateTime(2026, 11, 13, 23, 0, 0) : null,
    };

    private static (DayReportService Service, Mock<IDayReportRepository> Repo) Service(DayReportHeader? report)
    {
        var repo = new Mock<IDayReportRepository>();
        repo.Setup(r => r.GetAsync(3)).ReturnsAsync(report);
        repo.Setup(r => r.AcceptAsync(It.IsAny<DayReportHeader>(), It.IsAny<string?>(), 1))
            .ReturnsAsync(new DayReportDecisionResult { ReportId = 3, Status = "Accepted", CorrectionId = 11 });
        return (new DayReportService(repo.Object, new Mock<IWorkflowSupportService>().Object), repo);
    }

    [Fact]
    public async Task Accept_runs_the_correction_transaction()
    {
        var (service, repo) = Service(Report());
        var result = await service.DecideAsync(3, new DayReportDecisionRequest { Accept = true }, 1);
        Assert.Equal(11, result.CorrectionId);
        repo.Verify(r => r.AcceptAsync(It.Is<DayReportHeader>(h => h.ReportId == 3), null, 1), Times.Once);
    }

    [Fact]
    public async Task A_day_without_a_record_cannot_be_accepted()
    {
        var (service, repo) = Service(Report(attendanceId: null));
        var ex = await Assert.ThrowsAsync<WorkflowException>(() => service.DecideAsync(3, new DayReportDecisionRequest { Accept = true }, 1));
        Assert.Equal(409, ex.StatusCode);
        repo.Verify(r => r.AcceptAsync(It.IsAny<DayReportHeader>(), It.IsAny<string?>(), It.IsAny<int>()), Times.Never);
    }

    [Fact]
    public async Task A_report_without_times_cannot_be_accepted()
    {
        var (service, _) = Service(Report(times: false));
        var ex = await Assert.ThrowsAsync<WorkflowException>(() => service.DecideAsync(3, new DayReportDecisionRequest { Accept = true }, 1));
        Assert.Equal(400, ex.StatusCode);
    }

    [Fact]
    public async Task A_closed_report_is_a_conflict()
    {
        var (service, _) = Service(Report(status: "Accepted"));
        var ex = await Assert.ThrowsAsync<WorkflowException>(() => service.DecideAsync(3, new DayReportDecisionRequest { Accept = true }, 1));
        Assert.Equal(409, ex.StatusCode);
    }

    [Fact]
    public async Task An_account_without_an_employee_reports_nothing_of_its_own()
    {
        var repo = new Mock<IDayReportRepository>();
        var support = new Mock<IWorkflowSupportService>();
        support.Setup(s => s.GetEmployeeByUserIdAsync(1)).ReturnsAsync((MokaCo.HRMS.Model.Workflow.MyEmployee?)null);
        var service = new DayReportService(repo.Object, support.Object);
        var ex = await Assert.ThrowsAsync<WorkflowException>(() =>
            service.CreateAsync(new DayReportCreateRequest { WorkDate = DateTime.Today, Message = "x" }, 1));
        Assert.Equal(400, ex.StatusCode);
    }
}
