using Microsoft.AspNetCore.Mvc;
using MokaCo.HRMS.Api.Controllers;
using MokaCo.HRMS.Api.Hubs;
using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Repository.Attendance;
using MokaCo.HRMS.Repository.Common;
using MokaCo.HRMS.Services.Attendance;
using MokaCo.HRMS.Services.Workflow;
using Moq;

namespace MokaCo.HRMS.Tests.Attendance;

/// <summary>
/// Script 108: a day with punches that the approved roster does not know. Who may decide it is the
/// PROCEDURE's answer (two permissions read from the role tables at that moment, inside the caller's
/// branches); these tests hold the API to carrying that answer faithfully - the caller's id, the sentence,
/// the status - and to keeping the pages alive on a database that does not have the script yet.
/// </summary>
public class UnrosteredDayTests
{
    private const int Caller = 31;

    private static AttendanceController Controller(Mock<IAttendanceService> attendance, Mock<ILiveNotifier>? live = null) =>
        new(attendance.Object, (live ?? new Mock<ILiveNotifier>()).Object)
        {
            ControllerContext = TestPrincipal.For(userId: Caller),
        };

    private static string? ErrorOf(ObjectResult result)
        => result.Value?.GetType().GetProperty("error")?.GetValue(result.Value)?.ToString();

    /* ---- the status of each refusal the procedures raise ---- */

    [Theory]
    [InlineData("You can only decide days of the branches you manage.")]
    [InlineData("You may not decide a day of today that is not on the roster. It needs its own permission (Role permissions, Attendance).")]
    [InlineData("You may not decide a past day that is not on the roster. It needs its own permission (Role permissions, Attendance).")]
    public void The_wrong_person_asking_is_a_403_with_the_sentence(string message)
    {
        var ex = WorkflowSqlErrors.MapMessage(message);
        Assert.Equal(403, ex.StatusCode);
        Assert.Equal(message, ex.Message);
    }

    [Theory]
    [InlineData("This day is no longer waiting for a decision. Reload the list.")]
    [InlineData("This day is no longer waiting for a decision: it is already dismissed. Reload the list.")]
    [InlineData("This day is no longer waiting for a decision: it has no dismissal to take back. Reload the list.")]
    public void A_day_somebody_else_just_decided_is_a_409(string message)
        => Assert.Equal(409, WorkflowSqlErrors.MapMessage(message).StatusCode);

    [Theory]
    [InlineData("Say why these punches were not work. The note is kept with the decision.")]
    [InlineData("Choose the shift the day was worked on.")]
    [InlineData("This period is paid — raise a payroll adjustment instead.")]
    public void Input_and_paid_period_refusals_stay_400(string message)
        => Assert.Equal(400, WorkflowSqlErrors.MapMessage(message).StatusCode);

    /* ---- the decision endpoint ---- */

    [Fact]
    public async Task A_decision_goes_to_the_procedure_with_the_callers_id_and_refreshes_attendance_and_payroll()
    {
        var attendance = new Mock<IAttendanceService>();
        var live = new Mock<ILiveNotifier>();
        var request = new UnrosteredDayDecisionRequest { EmployeeId = 7, WorkDate = new DateTime(2026, 11, 7), Decision = "Shift", ShiftId = 4 };
        attendance.Setup(a => a.DecideUnrosteredDayAsync(request, Caller))
            .ReturnsAsync(new UnrosteredDayDecisionResult { EmployeeId = 7, WorkDate = request.WorkDate, Decision = "Shift", ShiftAssignmentId = 90, AttendanceId = 1200 });

        var ok = Assert.IsType<OkObjectResult>(await Controller(attendance, live).DecideUnrosteredDay(request));

        Assert.Equal(1200, Assert.IsType<UnrosteredDayDecisionResult>(ok.Value).AttendanceId);
        attendance.Verify(a => a.DecideUnrosteredDayAsync(request, Caller), Times.Once);
        live.Verify(l => l.NotifyAsync("attendance", "payroll", "dashboard"), Times.Once);
    }

    [Theory]
    [InlineData("Excuse", null, null)]          // not one of the three decisions
    [InlineData("Shift", null, null)]           // a shift decision without the shift
    [InlineData("Dismiss", null, null)]         // a dismissal without its reason
    [InlineData("Dismiss", null, "   ")]
    public async Task An_incomplete_decision_never_reaches_the_procedure(string decision, int? shiftId, string? note)
    {
        var attendance = new Mock<IAttendanceService>();
        var request = new UnrosteredDayDecisionRequest { EmployeeId = 7, WorkDate = new DateTime(2026, 11, 7), Decision = decision, ShiftId = shiftId, Note = note };

        Assert.IsType<BadRequestObjectResult>(await Controller(attendance).DecideUnrosteredDay(request));
        attendance.VerifyNoOtherCalls();
    }

    [Fact]
    public async Task The_procedures_refusal_travels_with_its_status_and_its_sentence_and_nothing_is_announced()
    {
        const string NotAllowed = "You may not decide a past day that is not on the roster. It needs its own permission (Role permissions, Attendance).";
        var attendance = new Mock<IAttendanceService>();
        var live = new Mock<ILiveNotifier>();
        attendance.Setup(a => a.DecideUnrosteredDayAsync(It.IsAny<UnrosteredDayDecisionRequest>(), It.IsAny<int?>()))
            .ThrowsAsync(WorkflowSqlErrors.MapMessage(NotAllowed));

        var refused = Assert.IsType<ObjectResult>(await Controller(attendance, live).DecideUnrosteredDay(
            new UnrosteredDayDecisionRequest { EmployeeId = 7, WorkDate = new DateTime(2026, 11, 7), Decision = "RestDay" }));

        Assert.Equal(403, refused.StatusCode);
        Assert.Equal(NotAllowed, ErrorOf(refused));
        live.VerifyNoOtherCalls();
    }

    [Fact]
    public async Task Taking_a_dismissal_back_carries_the_caller_and_a_refusal_keeps_its_sentence()
    {
        var attendance = new Mock<IAttendanceService>();
        var request = new UnrosteredDayReopenRequest { EmployeeId = 7, WorkDate = new DateTime(2026, 11, 7) };

        Assert.IsType<NoContentResult>(await Controller(attendance).ReopenUnrosteredDay(request));
        attendance.Verify(a => a.ReopenUnrosteredDayAsync(request, Caller), Times.Once);

        const string Gone = "This day is no longer waiting for a decision: it has no dismissal to take back. Reload the list.";
        attendance.Setup(a => a.ReopenUnrosteredDayAsync(It.IsAny<UnrosteredDayReopenRequest>(), It.IsAny<int?>()))
            .ThrowsAsync(WorkflowSqlErrors.MapMessage(Gone));
        var refused = Assert.IsType<ObjectResult>(await Controller(attendance).ReopenUnrosteredDay(request));
        Assert.Equal(409, refused.StatusCode);
        Assert.Equal(Gone, ErrorOf(refused));
    }

    /* ---- a database that does not have script 108 yet ---- */

    [Fact]
    public async Task Without_the_script_the_list_is_script_87s_days_all_open_and_nobody_can_decide_them()
    {
        var repo = new Mock<IAttendanceRepository>();
        var from = new DateTime(2026, 11, 1);
        var to = new DateTime(2026, 11, 30);
        repo.Setup(r => r.GetUnrosteredDaysAsync(from, to, 2, null, Caller))
            .ThrowsAsync(new MissingScriptException(Scripts.Unrostered108, "attendance.usp_UnrosteredDay_GetList", MissingScriptException.ProcedureNotFound));
        repo.Setup(r => r.GetWorkedWithoutRosterAsync(from, to, 2, Caller)).ReturnsAsync(new[]
        {
            new WorkedWithoutRoster { EmployeeId = 7, EmployeeName = "Rami", BranchId = 2, BranchName = "Hamra", WorkDate = new DateTime(2026, 11, 7), FirstPunch = new DateTime(2026, 11, 7, 8, 2, 0), LastPunch = new DateTime(2026, 11, 7, 16, 11, 0), PunchCount = 2, WorkedMinutes = 489 },
            new WorkedWithoutRoster { EmployeeId = 9, EmployeeName = "Maya", BranchId = 2, BranchName = "Hamra", WorkDate = new DateTime(2026, 11, 8), FirstPunch = new DateTime(2026, 11, 8, 9, 0, 0), LastPunch = new DateTime(2026, 11, 8, 9, 0, 0), PunchCount = 1, WorkedMinutes = 0 },
        });
        var service = new AttendanceService(repo.Object, Mock.Of<IIngestionRepository>());

        var all = (await service.GetUnrosteredDaysAsync(from, to, 2, null, Caller)).ToList();

        Assert.Equal(2, all.Count);
        Assert.All(all, day => { Assert.Equal("Open", day.State); Assert.False(day.CanDecide); });
        Assert.Equal(489, all[0].WorkedMinutes);
    }

    [Fact]
    public async Task Without_the_script_the_employee_filter_still_narrows_the_list()
    {
        var repo = new Mock<IAttendanceRepository>();
        var day = new DateTime(2026, 11, 7);
        repo.Setup(r => r.GetUnrosteredDaysAsync(day, day, null, 9, Caller))
            .ThrowsAsync(new MissingScriptException(Scripts.Unrostered108, "attendance.usp_UnrosteredDay_GetList", MissingScriptException.ProcedureNotFound));
        repo.Setup(r => r.GetWorkedWithoutRosterAsync(day, day, null, Caller)).ReturnsAsync(new[]
        {
            new WorkedWithoutRoster { EmployeeId = 7, EmployeeName = "Rami", WorkDate = day },
            new WorkedWithoutRoster { EmployeeId = 9, EmployeeName = "Maya", WorkDate = day },
        });
        var service = new AttendanceService(repo.Object, Mock.Of<IIngestionRepository>());

        var only = Assert.Single(await service.GetUnrosteredDaysAsync(day, day, null, 9, Caller));
        Assert.Equal("Maya", only.EmployeeName);
    }
}
