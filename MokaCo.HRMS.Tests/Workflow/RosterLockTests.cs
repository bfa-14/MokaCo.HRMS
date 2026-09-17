using System.Reflection;
using Microsoft.AspNetCore.Mvc;
using Moq;
using MokaCo.HRMS.Api.Controllers;
using MokaCo.HRMS.Api.Hubs;
using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Repository.Workflow;
using MokaCo.HRMS.Services.Attendance;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Tests.Workflow;

/// <summary>
/// THE LOCK (75_roster_approval_applies_and_locks.sql) lives in attendance.usp_Roster_AssertEditable,
/// in front of every assignment writer. These tests hold the API to its half of the contract: each
/// refusal is a 409 with the procedure's sentence intact, from every roster write endpoint, and the
/// nightly reconciler knows the ROSTER_APPROVAL marker. The end-to-end behaviour (past day of an
/// approved month → 409, future day → 200 + ChangedSinceApproval, pending month read-only) is
/// exercised against the database by tests/qa/api-tests.mjs phase1 (R3g, R4c–R4e).
/// </summary>
public class RosterLockTests
{
    private const string PastOrRecorded =
        "This day is already in an approved roster and attendance was recorded — correct the attendance record instead.";
    private const string WaitingForApproval =
        "Waiting for approval — request #123. Withdraw or wait for the decision before editing.";

    [Theory]
    [InlineData(PastOrRecorded)]
    [InlineData(WaitingForApproval)]
    public void Lock_refusals_are_conflicts_with_the_sentence_intact(string message)
    {
        var ex = WorkflowSqlErrors.MapMessage(message);

        Assert.Equal(409, ex.StatusCode);
        Assert.Equal(message, ex.Message);
    }

    /// <summary>The employee check the guard does first is an input error, not a conflict.</summary>
    [Fact]
    public void Unknown_employee_stays_a_bad_request()
        => Assert.Equal(400, WorkflowSqlErrors.MapMessage("Employee not found.").StatusCode);

    private static RosterController Controller(Mock<IRosterService> roster)
        => new(roster.Object, Mock.Of<ILiveNotifier>()) { ControllerContext = TestPrincipal.For(userId: 20) };

    private static void AssertConflict(IActionResult result, string message)
    {
        var obj = Assert.IsType<ObjectResult>(result);
        Assert.Equal(409, obj.StatusCode);
        Assert.Equal(message, obj.Value?.GetType().GetProperty("error")?.GetValue(obj.Value));
    }

    [Fact]
    public async Task Set_day_surfaces_the_409_and_the_sentence()
    {
        var roster = new Mock<IRosterService>();
        roster.Setup(r => r.SetDayAsync(It.IsAny<RosterDayRequest>())).ThrowsAsync(new WorkflowException(409, PastOrRecorded));

        var result = await Controller(roster).SetDay(new RosterDayRequest
        {
            EmployeeId = 1, WorkDate = new DateTime(2026, 8, 20), ShiftId = null, IsRestDay = true,
        });

        AssertConflict(result, PastOrRecorded);
    }

    [Fact]
    public async Task Delete_surfaces_the_409_and_the_sentence()
    {
        var roster = new Mock<IRosterService>();
        roster.Setup(r => r.DeleteAsync(77)).ThrowsAsync(new WorkflowException(409, WaitingForApproval));

        AssertConflict(await Controller(roster).Delete(77), WaitingForApproval);
    }

    [Fact]
    public async Task Generators_surface_the_409_and_the_sentence()
    {
        var roster = new Mock<IRosterService>();
        roster.Setup(r => r.GenerateAsync(It.IsAny<RosterGenerateRequest>())).ThrowsAsync(new WorkflowException(409, WaitingForApproval));
        roster.Setup(r => r.GenerateBulkAsync(It.IsAny<RosterGenerateBulkRequest>())).ThrowsAsync(new WorkflowException(409, WaitingForApproval));
        roster.Setup(r => r.CopyPeriodAsync(It.IsAny<RosterCopyPeriodRequest>())).ThrowsAsync(new WorkflowException(409, PastOrRecorded));
        roster.Setup(r => r.ApplyPatternAsync(It.IsAny<RosterApplyPatternRequest>())).ThrowsAsync(new WorkflowException(409, PastOrRecorded));
        var controller = Controller(roster);

        AssertConflict(await controller.Generate(new RosterGenerateRequest
        {
            EmployeeId = 1, FromDate = new DateTime(2026, 8, 1), ToDate = new DateTime(2026, 8, 31), ShiftId = 1, Weekdays = "1111100",
        }), WaitingForApproval);
        AssertConflict(await controller.GenerateBulk(new RosterGenerateBulkRequest
        {
            EmployeeIds = new List<int> { 1, 2 }, FromDate = new DateTime(2026, 8, 1), ToDate = new DateTime(2026, 8, 31), ShiftId = 1, Weekdays = "1111100",
        }), WaitingForApproval);
        AssertConflict(await controller.CopyPeriod(new RosterCopyPeriodRequest { SourceYearMonth = "2026-07", TargetYearMonth = "2026-08" }), PastOrRecorded);
        AssertConflict(await controller.ApplyPattern(new RosterApplyPatternRequest { YearMonth = "2026-08" }), PastOrRecorded);
    }

    /// <summary>A refusal must leave the live screens alone — nothing changed, so nothing to push.</summary>
    [Fact]
    public async Task A_refused_write_does_not_notify_the_live_screens()
    {
        var roster = new Mock<IRosterService>();
        roster.Setup(r => r.SetDayAsync(It.IsAny<RosterDayRequest>())).ThrowsAsync(new WorkflowException(409, PastOrRecorded));
        var live = new Mock<ILiveNotifier>(MockBehavior.Strict);
        var controller = new RosterController(roster.Object, live.Object) { ControllerContext = TestPrincipal.For(userId: 20) };

        await controller.SetDay(new RosterDayRequest { EmployeeId = 1, WorkDate = new DateTime(2026, 8, 20), IsRestDay = true });

        live.VerifyNoOtherCalls();
    }

    /// <summary>
    /// The nightly reconciler's work list must include a ROSTER_APPROVAL whose month never activated
    /// (Approved AND AppliedAt IS NULL) — the very state BUG-01 left request 59 in.
    /// </summary>
    [Fact]
    public void Reconciler_sweeps_unapplied_roster_approvals()
    {
        var field = typeof(RequestRepository).GetField("UnappliedEffectsSql", BindingFlags.NonPublic | BindingFlags.Static);
        var sql = Assert.IsType<string>(field?.GetRawConstantValue());

        Assert.Contains("rt.Code = 'ROSTER_APPROVAL'", sql);
        Assert.Contains("workflow.ROSTER_APPROVAL", sql);
        Assert.Matches(@"ROSTER_APPROVAL[\s\S]*AppliedAt\s+IS NULL", sql);
    }
}
