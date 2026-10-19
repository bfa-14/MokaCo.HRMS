using System.Reflection;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Logging;
using Moq;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Api.Controllers;
using MokaCo.HRMS.Api.Hubs;
using MokaCo.HRMS.Model.HR;
using MokaCo.HRMS.Model.Workflow;
using MokaCo.HRMS.Repository.HR;
using MokaCo.HRMS.Services.HR;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Tests.HR;

/// <summary>
/// QA3 unit D, the C# half: a leave decision tells the attendance and HR screens too (WEB-16); the leave year can be
/// undone through the API with the trust that opens it (LEV-9); a carry-over expiry setting that is not MM-DD reaches the
/// job's log (LEV-6); the dead leave-type create/update that could not work are gone (CON-10).
/// </summary>
public class LeaveQa3Tests
{
    private const int Caller = 20;

    private static object? Field(object? value, string name) => value?.GetType().GetProperty(name)?.GetValue(value);

    private static (LeaveRequestsController Controller, Mock<ILeaveRequestService> Leave, List<string[]> Notified) LeaveController()
    {
        var leave = new Mock<ILeaveRequestService>(MockBehavior.Strict);
        var support = new Mock<IWorkflowSupportService>(MockBehavior.Strict);
        support.Setup(s => s.GetEmployeeByUserIdAsync(Caller)).ReturnsAsync(new MyEmployee { EmployeeId = 7, UserId = Caller });
        var notified = new List<string[]>();
        var live = new Mock<ILiveNotifier>(MockBehavior.Strict);
        live.Setup(l => l.NotifyAsync(It.IsAny<string[]>())).Callback<string[]>(t => notified.Add(t)).Returns(Task.CompletedTask);
        var controller = new LeaveRequestsController(leave.Object, support.Object, live.Object) { ControllerContext = TestPrincipal.For(userId: Caller) };
        return (controller, leave, notified);
    }

    /* ---- WEB-16: what a leave decision changes, the screens hear about ---- */

    [Fact]
    public async Task A_decision_notifies_attendance_and_hr_as_well_as_workflow_and_dashboard()
    {
        var (controller, leave, notified) = LeaveController();
        leave.Setup(l => l.DecideAsync(5, Caller, It.IsAny<LeaveRequestDecideRequest>()))
             .ReturnsAsync(new LeaveRequestDecideResult { RequestInstanceId = 5, Status = "Approved", DaysApproved = 3 });

        var result = await controller.Decide(5, new LeaveRequestDecideRequest());

        Assert.IsType<OkObjectResult>(result);
        var topics = Assert.Single(notified);
        Assert.Equal(new[] { "attendance", "dashboard", "hr", "workflow" }, topics.OrderBy(t => t, StringComparer.Ordinal));
    }

    [Fact]
    public async Task A_request_the_chain_approved_at_once_notifies_like_a_decision()
    {
        var (controller, leave, notified) = LeaveController();
        leave.Setup(l => l.CreateAsync(It.IsAny<LeaveRequestCreateRequest>(), It.IsAny<LeaveRequestCaller>()))
             .ReturnsAsync(new LeaveRequestCreated { RequestInstanceId = 9, Status = "Approved" });

        await controller.Create(new LeaveRequestCreateRequest { EmployeeId = 7, LeaveTypeId = 1 });

        Assert.Contains("attendance", Assert.Single(notified));
        Assert.Contains("hr", notified[0]);
    }

    [Fact]
    public async Task A_pending_request_tells_only_the_workflow_and_the_dashboard()
    {
        var (controller, leave, notified) = LeaveController();
        leave.Setup(l => l.CreateAsync(It.IsAny<LeaveRequestCreateRequest>(), It.IsAny<LeaveRequestCaller>()))
             .ReturnsAsync(new LeaveRequestCreated { RequestInstanceId = 9, Status = "Pending" });

        await controller.Create(new LeaveRequestCreateRequest { EmployeeId = 7, LeaveTypeId = 1 });

        Assert.Equal(new[] { "dashboard", "workflow" }, Assert.Single(notified).OrderBy(t => t, StringComparer.Ordinal));
    }

    /* ---- LEV-9: the undo endpoint ---- */

    private static (LeaveYearController Controller, Mock<ILeaveYearService> Year, Mock<ILiveNotifier> Live) YearController()
    {
        var year = new Mock<ILeaveYearService>(MockBehavior.Strict);
        var live = new Mock<ILiveNotifier>(MockBehavior.Strict);
        var controller = new LeaveYearController(year.Object, live.Object) { ControllerContext = TestPrincipal.For(userId: Caller) };
        return (controller, year, live);
    }

    [Fact]
    public void The_undo_is_a_POST_beside_the_opening_and_needs_the_same_permission()
    {
        var undo = typeof(LeaveYearController).GetMethod(nameof(LeaveYearController.UndoYear))!;
        var open = typeof(LeaveYearController).GetMethod(nameof(LeaveYearController.OpenYear))!;

        Assert.Equal("year-undo", undo.GetCustomAttribute<HttpPostAttribute>()!.Template);
        Assert.Equal(open.GetCustomAttribute<HasPermissionAttribute>()!.Policy, undo.GetCustomAttribute<HasPermissionAttribute>()!.Policy);
        Assert.Equal(HasPermissionAttribute.Prefix + "LEAVE_POLICY_MANAGE", undo.GetCustomAttribute<HasPermissionAttribute>()!.Policy);
    }

    [Fact]
    public async Task The_undo_returns_what_it_took_back_and_tells_the_hr_screens()
    {
        var (controller, year, live) = YearController();
        year.Setup(y => y.UndoAsync(2026, 12, Caller)).ReturnsAsync(new LeaveYearUndoSummary { EmployeesUndone = 1, MovementsRemoved = 3 });
        live.Setup(l => l.NotifyAsync("hr", "dashboard")).Returns(Task.CompletedTask);

        var result = await controller.UndoYear(2026, 12);

        var ok = Assert.IsType<OkObjectResult>(result);
        Assert.Equal(3, Assert.IsType<LeaveYearUndoSummary>(ok.Value).MovementsRemoved);
        live.Verify(l => l.NotifyAsync("hr", "dashboard"), Times.Once);
    }

    [Fact]
    public async Task A_typo_year_is_refused_before_the_procedure_is_asked()
    {
        var (controller, year, _) = YearController();

        var result = await controller.UndoYear(20266);

        var bad = Assert.IsType<BadRequestObjectResult>(result);
        Assert.Equal("Year is out of range.", Field(bad.Value, "error"));
        year.Verify(y => y.UndoAsync(It.IsAny<int>(), It.IsAny<int?>(), It.IsAny<int>()), Times.Never);
    }

    /* ---- LEV-6: a carry-over expiry setting that is not MM-DD reaches the log ---- */

    private sealed class CapturingLogger<T> : ILogger<T>
    {
        public List<(LogLevel Level, string Message)> Entries { get; } = new();
        public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;
        public bool IsEnabled(LogLevel logLevel) => true;
        public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception, Func<TState, Exception?, string> formatter)
            => Entries.Add((logLevel, formatter(state, exception)));
    }

    [Fact]
    public async Task A_setting_that_is_not_MMDD_is_logged_as_a_warning()
    {
        var repo = new Mock<ILeaveYearRepository>(MockBehavior.Strict);
        const string problem = "LeaveCarryOverExpiresOn \"13-45\" is not a MM-DD date (for example 03-31); carried-over leave was not expired.";
        repo.Setup(r => r.ExpireCarryOverAsync()).ReturnsAsync(new LeaveCarryOverExpired { SettingProblem = problem });
        var logger = new CapturingLogger<LeaveYearService>();

        var result = await new LeaveYearService(repo.Object, logger).ExpireCarryOverAsync();

        Assert.Equal(problem, result.SettingProblem);
        var entry = Assert.Single(logger.Entries);
        Assert.Equal(LogLevel.Warning, entry.Level);
        Assert.Contains(problem, entry.Message);
    }

    [Fact]
    public async Task An_ordinary_night_logs_nothing_from_the_service()
    {
        var repo = new Mock<ILeaveYearRepository>(MockBehavior.Strict);
        repo.Setup(r => r.ExpireCarryOverAsync()).ReturnsAsync(new LeaveCarryOverExpired { EmployeesExpired = 2, DaysExpired = 7 });
        var logger = new CapturingLogger<LeaveYearService>();

        await new LeaveYearService(repo.Object, logger).ExpireCarryOverAsync();

        Assert.Empty(logger.Entries);
    }

    /* ---- CON-10: the leave-type create/update that omitted @AccrualPerMonth are gone ---- */

    [Theory]
    [InlineData(typeof(ILeaveTypeRepository))]
    [InlineData(typeof(ILeaveTypeService))]
    public void Only_the_upsert_creates_or_updates_a_leave_type(Type contract)
    {
        Assert.Null(contract.GetMethod("CreateAsync"));
        Assert.Null(contract.GetMethod("UpdateAsync"));
        Assert.NotNull(contract.GetMethod("UpsertAsync"));
    }

    /* ---- LEV-2: the request model no longer claims the dates are never trimmed ---- */

    [Fact]
    public void The_partial_approval_contract_is_on_the_payload()
    {
        Assert.NotNull(typeof(LeaveRequestPayload).GetProperty(nameof(LeaveRequestPayload.ApprovedToDate)));
        Assert.NotNull(typeof(LeaveRequestPayload).GetProperty(nameof(LeaveRequestPayload.PaidSnapshot)));
        Assert.NotNull(typeof(MyLeaveRequest).GetProperty(nameof(MyLeaveRequest.ApprovedToDate)));
        Assert.NotNull(typeof(LeaveLedgerEntry).GetProperty(nameof(LeaveLedgerEntry.CanDelete)));
    }
}
