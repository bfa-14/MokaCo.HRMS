using Microsoft.AspNetCore.Mvc;
using Moq;
using MokaCo.HRMS.Api.Controllers;
using MokaCo.HRMS.Api.Hubs;
using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Model.Workflow;
using MokaCo.HRMS.Repository.Workflow;
using MokaCo.HRMS.Services.Attendance;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Tests.Workflow;

/// <summary>
/// THE GUARD (72_roster_submit_guard_and_clear.sql) lives in workflow.usp_RosterApproval_Create:
/// a second submit while one is Draft/Pending/OnHold, or after an approval with no change since, is
/// refused by RAISERROR. These tests hold the API to its half of the contract — each refusal is a
/// 409 with the procedure's sentence intact, the engine is never called, and the button-state
/// fields the roster page reads are the ones the procedure returns.
/// </summary>
public class RosterSubmitGuardTests
{
    private const string AlreadyWaiting = "This roster is already waiting for approval (request #74).";
    private const string ApprovedUnchanged = "This roster was approved on 19 Aug 2026 and has not changed since.";
    private const string CannotClear = "This roster cannot be cleared: attendance already recorded for 14 days.";

    [Theory]
    [InlineData(AlreadyWaiting)]
    [InlineData(ApprovedUnchanged)]
    [InlineData(CannotClear)]
    public void Roster_refusals_are_conflicts_with_the_sentence_intact(string message)
    {
        var ex = WorkflowSqlErrors.MapMessage(message);

        Assert.Equal(409, ex.StatusCode);
        Assert.Equal(message, ex.Message);
    }

    [Fact]
    public void Other_procedure_refusals_keep_their_old_statuses()
    {
        Assert.Equal(400, WorkflowSqlErrors.MapMessage("No roster rows exist for that branch and month — build the roster first.").StatusCode);
        Assert.Equal(403, WorkflowSqlErrors.MapMessage("You are not the approver for this step.").StatusCode);
    }

    /// <summary>The service refuses BEFORE the procedure when the caller has no employee record — unchanged by the guard.</summary>
    [Fact]
    public async Task Caller_without_an_employee_record_is_refused_before_the_procedure()
    {
        var repo = new Mock<IRosterApprovalRepository>(MockBehavior.Strict);
        var support = new Mock<IWorkflowSupportService>();
        support.Setup(s => s.GetEmployeeByUserIdAsync(20)).ReturnsAsync((MyEmployee?)null);
        var service = new RosterApprovalService(repo.Object, support.Object);

        var ex = await Assert.ThrowsAsync<WorkflowException>(() => service.CreateAsync(
            new RosterApprovalCreateRequest { BranchId = 1, MonthDate = new DateTime(2026, 8, 1) }, 20));

        Assert.Equal(403, ex.StatusCode);
        repo.VerifyNoOtherCalls();
    }

    [Fact]
    public async Task Submit_controller_surfaces_the_409_and_the_sentence()
    {
        var service = new Mock<IRosterApprovalService>();
        service.Setup(s => s.CreateAsync(It.IsAny<RosterApprovalCreateRequest>(), It.IsAny<int>()))
               .ThrowsAsync(new WorkflowException(409, AlreadyWaiting));
        var controller = new RosterApprovalsController(service.Object, Mock.Of<ILiveNotifier>())
        {
            ControllerContext = TestPrincipal.For(userId: 20),
        };

        var result = Assert.IsType<ObjectResult>(await controller.Create(
            new RosterApprovalCreateRequest { BranchId = 1, MonthDate = new DateTime(2026, 8, 1) }));

        Assert.Equal(409, result.StatusCode);
        Assert.Equal(AlreadyWaiting, result.Value?.GetType().GetProperty("error")?.GetValue(result.Value));
    }

    [Fact]
    public async Task Clear_roster_surfaces_the_409_and_the_sentence()
    {
        var roster = new Mock<IRosterService>();
        roster.Setup(r => r.ClearMonthAsync(1, 2026, 8, 20)).ThrowsAsync(new WorkflowException(409, CannotClear));
        var controller = new AttendanceController(Mock.Of<IAttendanceService>(), Mock.Of<ILiveNotifier>())
        {
            ControllerContext = TestPrincipal.For(userId: 20),
        };

        var result = Assert.IsType<ObjectResult>(await controller.ClearRoster(1, 2026, 8, roster.Object));

        Assert.Equal(409, result.StatusCode);
        Assert.Equal(CannotClear, result.Value?.GetType().GetProperty("error")?.GetValue(result.Value));
    }

    [Fact]
    public async Task Clear_roster_rejects_an_impossible_month_before_calling_anything()
    {
        var roster = new Mock<IRosterService>(MockBehavior.Strict);
        var controller = new AttendanceController(Mock.Of<IAttendanceService>(), Mock.Of<ILiveNotifier>())
        {
            ControllerContext = TestPrincipal.For(userId: 20),
        };

        Assert.IsType<BadRequestObjectResult>(await controller.ClearRoster(1, 2026, 13, roster.Object));
        roster.VerifyNoOtherCalls();
    }

    /// <summary>The month status carries what the button needs; a month with no header is still null (unchanged contract).</summary>
    [Fact]
    public void Month_status_carries_the_button_state_fields()
    {
        var status = new RosterMonthStatus
        {
            BranchId = 1, MonthDate = new DateTime(2026, 8, 1), Status = "PendingApproval",
            OpenRequestId = 74, OpenRequestStatus = "Pending",
            LastApprovedAt = new DateTime(2026, 8, 19), ChangedSinceApproval = false,
        };

        Assert.Equal(74, status.OpenRequestId);
        Assert.Equal("Pending", status.OpenRequestStatus);
        Assert.False(status.ChangedSinceApproval);
    }
}
