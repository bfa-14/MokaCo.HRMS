using Microsoft.AspNetCore.Mvc;
using Moq;
using MokaCo.HRMS.Api.Controllers;
using MokaCo.HRMS.Api.Hubs;
using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Model.Workflow;
using MokaCo.HRMS.Repository.Attendance;
using MokaCo.HRMS.Repository.Security;
using MokaCo.HRMS.Repository.Workflow;
using MokaCo.HRMS.Services.Attendance;
using MokaCo.HRMS.Services.Auth;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Tests.Attendance;

/// <summary>
/// QA3 unit C (docs/102_qa3_roster.sql). The rules themselves live in the procedures and are exercised against a
/// database by tests/qa3/roster/*.sql; these hold the API to its half:
///   ROS-14 every roster write and the roster reads pass the CALLER (the procedures refuse a branch the caller does
///          not manage) and that refusal is a 403;
///   ROS-3  copy and apply-patterns need a branch;
///   ROS-2  a ROSTER_APPROVAL that ends Approved is re-derived right away — by the generic approve, a version move
///          and the auto-approval at submission — and a failed re-derivation never fails the approval.
/// </summary>
public class RosterQa3Tests
{
    private const int Caller = 20;

    private static RosterController Controller(Mock<IRosterService> roster)
        => new(roster.Object, Mock.Of<ILiveNotifier>()) { ControllerContext = TestPrincipal.For(userId: Caller) };

    [Fact]
    public async Task Every_roster_write_and_read_passes_the_caller()
    {
        var roster = new Mock<IRosterService>();
        roster.Setup(r => r.GenerateAsync(It.IsAny<RosterGenerateRequest>(), It.IsAny<int?>())).ReturnsAsync(new RosterGenerateResult());
        roster.Setup(r => r.GenerateBulkAsync(It.IsAny<RosterGenerateBulkRequest>(), It.IsAny<int?>())).ReturnsAsync(new RosterBulkResult());
        roster.Setup(r => r.CopyPeriodAsync(It.IsAny<RosterCopyPeriodRequest>(), It.IsAny<int?>())).ReturnsAsync(new RosterGenerateResult());
        roster.Setup(r => r.ApplyPatternAsync(It.IsAny<RosterApplyPatternRequest>(), It.IsAny<int?>())).ReturnsAsync(new RosterGenerateResult());
        roster.Setup(r => r.GetGapsAsync(It.IsAny<DateTime>(), It.IsAny<DateTime>(), It.IsAny<int?>(), It.IsAny<int?>())).ReturnsAsync(Array.Empty<RosterGap>());
        roster.Setup(r => r.GetLeaveDaysAsync(It.IsAny<DateTime>(), It.IsAny<DateTime>(), It.IsAny<int?>(), It.IsAny<int?>())).ReturnsAsync(Array.Empty<RosterLeaveDay>());
        roster.Setup(r => r.RederiveMonthAsync(It.IsAny<int>(), It.IsAny<int>(), It.IsAny<int>(), It.IsAny<int?>())).ReturnsAsync(new RosterRederiveResult());
        var c = Controller(roster);
        var from = new DateTime(2026, 11, 1);
        var to = new DateTime(2026, 11, 30);

        await c.SetDay(new RosterDayRequest { EmployeeId = 1, WorkDate = from, ShiftId = 4 });
        await c.Delete(77);
        await c.Generate(new RosterGenerateRequest { EmployeeId = 1, FromDate = from, ToDate = to, ShiftId = 4, Weekdays = "1111100", BranchId = 3 });
        await c.GenerateBulk(new RosterGenerateBulkRequest { EmployeeIds = [1, 2], FromDate = from, ToDate = to, ShiftId = 4, Weekdays = "1111100", BranchId = 3 });
        await c.CopyPeriod(new RosterCopyPeriodRequest { SourceYearMonth = "2026-10", TargetYearMonth = "2026-11", BranchId = 3 });
        await c.ApplyPattern(new RosterApplyPatternRequest { YearMonth = "2026-11", BranchId = 3 });
        await c.GetGaps(from, to, 3);
        await c.GetLeaveDays(from, to, 3);
        await c.RederiveMonth(new RosterRederiveRequest { BranchId = 3, YearMonth = "2026-11" });

        roster.Verify(r => r.SetDayAsync(It.IsAny<RosterDayRequest>(), Caller), Times.Once);
        roster.Verify(r => r.DeleteAsync(77, Caller), Times.Once);
        roster.Verify(r => r.GenerateAsync(It.Is<RosterGenerateRequest>(g => g.BranchId == 3), Caller), Times.Once);
        roster.Verify(r => r.GenerateBulkAsync(It.Is<RosterGenerateBulkRequest>(g => g.BranchId == 3), Caller), Times.Once);
        roster.Verify(r => r.CopyPeriodAsync(It.Is<RosterCopyPeriodRequest>(g => g.BranchId == 3), Caller), Times.Once);
        roster.Verify(r => r.ApplyPatternAsync(It.Is<RosterApplyPatternRequest>(g => g.BranchId == 3), Caller), Times.Once);
        roster.Verify(r => r.GetGapsAsync(from, to, Caller, 3), Times.Once);
        roster.Verify(r => r.GetLeaveDaysAsync(from, to, 3, Caller), Times.Once);
        roster.Verify(r => r.RederiveMonthAsync(3, 2026, 11, Caller), Times.Once);
    }

    [Fact]
    public async Task Copy_and_apply_patterns_need_a_branch_before_anything_runs()
    {
        var roster = new Mock<IRosterService>(MockBehavior.Strict);
        var c = Controller(roster);

        var copy = Assert.IsType<BadRequestObjectResult>(await c.CopyPeriod(new RosterCopyPeriodRequest { SourceYearMonth = "2026-10", TargetYearMonth = "2026-11" }));
        var apply = Assert.IsType<BadRequestObjectResult>(await c.ApplyPattern(new RosterApplyPatternRequest { YearMonth = "2026-11" }));

        Assert.Contains("one branch", copy.Value?.GetType().GetProperty("error")?.GetValue(copy.Value)?.ToString());
        Assert.Contains("one branch", apply.Value?.GetType().GetProperty("error")?.GetValue(apply.Value)?.ToString());
        roster.VerifyNoOtherCalls();
    }

    /// <summary>The scope refusal of every roster procedure is the auto-roster's sentence: the wrong person asking, a 403.</summary>
    [Fact]
    public async Task A_branch_the_caller_does_not_manage_is_a_403_from_every_roster_door()
    {
        const string NotYours = "You can only plan rosters for the branches you manage.";
        Assert.Equal(403, WorkflowSqlErrors.MapMessage(NotYours).StatusCode);

        var roster = new Mock<IRosterService>();
        roster.Setup(r => r.SetDayAsync(It.IsAny<RosterDayRequest>(), It.IsAny<int?>())).ThrowsAsync(WorkflowSqlErrors.MapMessage(NotYours));
        roster.Setup(r => r.GetMonthAsync(It.IsAny<int>(), It.IsAny<DateTime>(), It.IsAny<int?>())).ThrowsAsync(WorkflowSqlErrors.MapMessage(NotYours));

        var set = Assert.IsType<ObjectResult>(await Controller(roster).SetDay(new RosterDayRequest { EmployeeId = 1, WorkDate = new DateTime(2026, 11, 2), ShiftId = 4 }));
        Assert.Equal(403, set.StatusCode);

        var attendance = new AttendanceController(Mock.Of<IAttendanceService>(), Mock.Of<ILiveNotifier>())
        {
            ControllerContext = TestPrincipal.For(userId: Caller),
        };
        var month = Assert.IsType<ObjectResult>(await attendance.GetRosterMonth(2, new DateTime(2026, 11, 1), roster.Object));
        Assert.Equal(403, month.StatusCode);
        roster.Verify(r => r.GetMonthAsync(2, new DateTime(2026, 11, 1), Caller), Times.Once);
    }

    /// <summary>The guard now names its reason; each one is still the lock's 409, sentence intact (ROS-6).</summary>
    [Theory]
    [InlineData("This day is already in an approved roster and attendance was recorded — correct the attendance record instead.")]
    [InlineData("This day is already in an approved roster and is in the past — it can no longer be changed.")]
    [InlineData("This day is already in an approved roster and is in the past — a generator does not fill it; HR can add the missing day on its own.")]
    [InlineData("This day is already in an approved roster and is in the past — only HR can add the missing day.")]
    public void Each_lock_reason_is_a_conflict_with_its_sentence(string message)
    {
        var ex = WorkflowSqlErrors.MapMessage(message);
        Assert.Equal(409, ex.StatusCode);
        Assert.Equal(message, ex.Message);
    }

    [Theory]
    [InlineData("Choose a branch — copying a month works on one branch at a time.")]
    [InlineData("Barista Two is no longer employed on 15 Nov 2026 — the employment ended on 10 Oct 2026.")]
    [InlineData("That shift is retired — choose an active shift.")]
    public void Input_refusals_stay_bad_requests(string message)
        => Assert.Equal(400, WorkflowSqlErrors.MapMessage(message).StatusCode);

    /* ---- ROS-2: the re-derivation after a roster approval ---- */

    private static RequestService Requests(Mock<IRequestRepository> repo, Mock<IRosterService> roster)
        => new(repo.Object, Mock.Of<IUserRepository>(), Mock.Of<IPasswordHasher>(), roster.Object);

    private static Mock<IRequestRepository> Repo(string typeCode, string statusAfter)
    {
        var repo = new Mock<IRequestRepository>();
        repo.Setup(r => r.GetByIdAsync(41)).ReturnsAsync(new RequestDetail { Header = new RequestHeader { RequestTypeCode = typeCode, Status = "Pending" } });
        // The approval's outcome whatever the repository method's parameter list is (unit A adds one): no argument
        // matchers to go stale on a merge.
        repo.SetReturnsDefault(Task.FromResult<ApproveResult?>(new ApproveResult { RequestInstanceId = 41, Status = statusAfter }));
        return repo;
    }

    [Fact]
    public async Task The_last_signature_on_a_roster_approval_re_derives_its_month()
    {
        var roster = new Mock<IRosterService>();
        var result = await Requests(Repo("ROSTER_APPROVAL", "Approved"), roster).ApproveAsync(41, Caller, "ok");

        Assert.Equal("Approved", result?.Status);
        roster.Verify(r => r.RederiveApprovedRequestAsync(41), Times.Once);
    }

    [Theory]
    [InlineData("ROSTER_APPROVAL", "Pending")]       // a step signed, the chain goes on: nothing is active yet
    [InlineData("QA_SIMPLE_TYPE", "Approved")]       // another type closing: not a roster
    public async Task Nothing_is_re_derived_unless_a_roster_approval_closed_approved(string type, string status)
    {
        var roster = new Mock<IRosterService>(MockBehavior.Strict);
        await Requests(Repo(type, status), roster).ApproveAsync(41, Caller, "ok");
        roster.VerifyNoOtherCalls();
    }

    [Fact]
    public async Task A_version_move_that_closes_the_request_re_derives_too()
    {
        var repo = new Mock<IRequestRepository>();
        repo.SetReturnsDefault(Task.FromResult<MoveVersionResult?>(new MoveVersionResult { RequestInstanceId = 41, Status = "Approved" }));
        var roster = new Mock<IRosterService>();

        await Requests(repo, roster).MoveToVersionAsync(41, new MoveVersionRequest { TargetWorkflowDefinitionId = 9, Reason = "QA3" }, Caller);

        roster.Verify(r => r.RederiveApprovedRequestAsync(41), Times.Once);
    }

    [Theory]
    [InlineData("Approved", 1)]
    [InlineData("Pending", 0)]
    public async Task A_roster_approved_at_submission_is_re_derived_at_once(string status, int calls)
    {
        var repo = new Mock<IRosterApprovalRepository>();
        repo.Setup(r => r.CreateAsync(5, Caller, 2, It.IsAny<DateTime>(), null))
            .ReturnsAsync(new RosterApprovalCreated { RequestInstanceId = 88, Status = status });
        var support = new Mock<IWorkflowSupportService>();
        support.Setup(s => s.GetEmployeeByUserIdAsync(Caller)).ReturnsAsync(new MyEmployee { EmployeeId = 5 });
        var roster = new Mock<IRosterService>();

        await new RosterApprovalService(repo.Object, support.Object, roster.Object)
            .CreateAsync(new RosterApprovalCreateRequest { BranchId = 2, MonthDate = new DateTime(2026, 11, 1) }, Caller);

        roster.Verify(r => r.RederiveApprovedRequestAsync(88), Times.Exactly(calls));
    }

    /// <summary>The approval is committed before the hook runs: a failed re-derivation is logged and left to the nightly run.</summary>
    [Fact]
    public async Task A_failed_re_derivation_never_fails_the_approval()
    {
        var repo = new Mock<IRosterRepository>();
        repo.Setup(r => r.RederiveForRequestAsync(41)).ThrowsAsync(new TimeoutException("the month took too long"));
        var service = new RosterService(repo.Object);

        Assert.False(await service.RederiveApprovedRequestAsync(41));

        repo.Setup(r => r.RederiveForRequestAsync(42)).Returns(Task.CompletedTask);
        Assert.True(await service.RederiveApprovedRequestAsync(42));
    }

    /// <summary>The nightly job carries the safety net (it is resolved from DI with the roster service).</summary>
    [Fact]
    public void The_nightly_job_takes_the_roster_service()
    {
        var ctor = Assert.Single(typeof(MokaCo.HRMS.Api.Jobs.NightlyAttendanceJob).GetConstructors());
        Assert.Contains(ctor.GetParameters(), p => p.ParameterType == typeof(IRosterService));
    }
}
