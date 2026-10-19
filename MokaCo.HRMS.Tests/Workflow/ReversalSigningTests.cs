using Microsoft.AspNetCore.Mvc;
using Moq;
using MokaCo.HRMS.Api.Controllers;
using MokaCo.HRMS.Api.Hubs;
using MokaCo.HRMS.Model.Security;
using MokaCo.HRMS.Model.Workflow;
using MokaCo.HRMS.Repository.Security;
using MokaCo.HRMS.Repository.Workflow;
using MokaCo.HRMS.Services.Auth;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Tests.Workflow;

/// <summary>
/// QA3 unit A, the API's half of the workflow-engine fixes (script 101 holds the database half):
///   WF-14 — each half of a GM + Owner reopen is SIGNED: the password is required, verified here before
///           the procedure runs, and the verified fact is what the procedure is told;
///   WF-3  — a wrong password on a retract is a 400 (the client signs out on a 401);
///   WF-2  — the step the approver was looking at travels to the procedure, and a lost race is a 409;
///   WF-10 — a version move that would approve the request travels with its confirmation;
///   WEB-13 — the hub's type filter has a list any signed-in user may read;
///   and the suspicion that a refusal reached the screen glued to the errors raised after it.
/// </summary>
public class ReversalSigningTests
{
    private const string Hash = "stored-hash";

    private readonly Mock<IRequestRepository> _repo = new(MockBehavior.Strict);
    private readonly Mock<IUserRepository> _users = new(MockBehavior.Loose);
    private readonly Mock<IPasswordHasher> _hasher = new(MockBehavior.Loose);

    public ReversalSigningTests()
    {
        _users.Setup(u => u.GetByIdAsync(20)).ReturnsAsync(new User { UserId = 20, PasswordHash = Hash });
        _hasher.Setup(h => h.Verify("right", Hash)).Returns(true);
        _hasher.Setup(h => h.Verify(It.Is<string>(p => p != "right"), Hash)).Returns(false);
    }

    private RequestService Service() => new(_repo.Object, _users.Object, _hasher.Object);

    /* ---- WF-14: the GM + Owner reopen is signed at each half ---- */

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    public async Task Reopen_without_a_password_is_a_400_and_nothing_runs(string? password)
    {
        var ex = await Assert.ThrowsAsync<WorkflowException>(
            () => Service().ReopenAsync(5, actedByUserId: 20, reason: "Wrong employee.", password: password));

        Assert.Equal(400, ex.StatusCode);
        Assert.Equal("Reopening a closed request must be signed with your password.", ex.Message);
        _repo.VerifyNoOtherCalls();
    }

    [Fact]
    public async Task Reopen_with_a_wrong_password_is_a_400_and_nothing_runs()
    {
        var ex = await Assert.ThrowsAsync<WorkflowException>(
            () => Service().ReopenAsync(5, actedByUserId: 20, reason: "Wrong employee.", password: "wrong"));

        Assert.Equal(400, ex.StatusCode);
        Assert.Equal("That password is not correct.", ex.Message);
        _repo.VerifyNoOtherCalls();
    }

    [Fact]
    public async Task Reopen_with_the_right_password_tells_the_procedure_it_was_signed()
    {
        _repo.Setup(r => r.ReopenAsync(5, 20, "Wrong employee.", true))
             .ReturnsAsync(new ReopenResult { State = "AwaitingSecond", FirstSignRole = "Owner" });

        var result = await Service().ReopenAsync(5, actedByUserId: 20, reason: "Wrong employee.", password: "right");

        Assert.Equal("AwaitingSecond", result!.State);
        _repo.Verify(r => r.ReopenAsync(5, 20, "Wrong employee.", true), Times.Once);
    }

    [Fact]
    public async Task Reopen_controller_carries_the_password_from_the_body()
    {
        var service = new Mock<IRequestService>(MockBehavior.Strict);
        service.Setup(s => s.ReopenAsync(5, 20, "Wrong employee.", "right"))
               .ReturnsAsync(new ReopenResult { State = "Reopened", RequestInstanceId = 5, Status = "Pending", CurrentStepNo = 1 });
        var controller = new WorkflowController(Mock.Of<IDefinitionService>(), service.Object, Mock.Of<ILiveNotifier>())
        {
            ControllerContext = TestPrincipal.For(userId: 20),
        };

        var result = Assert.IsType<OkObjectResult>(await controller.Reopen(5,
            new ReasonRequest { Reason = "  Wrong employee. ", Password = "right" }));

        Assert.Equal("Reopened", Assert.IsType<ReopenResult>(result.Value).State);
    }

    /* ---- WF-3: a mistyped password on a retract does not sign the user out ---- */

    [Fact]
    public async Task Retract_with_a_wrong_password_is_a_400_not_a_401()
    {
        _repo.Setup(r => r.GetStepsAsync(5, 20)).ReturnsAsync(new List<RequestStep>
        {
            new() { StepNo = 1, Status = "Approved", ActedAt = DateTime.UtcNow, SignedWithPassword = true },
        });

        var ex = await Assert.ThrowsAsync<WorkflowException>(
            () => Service().RetractLastDecisionAsync(5, actedByUserId: 20, reason: "Mistake.", password: "wrong"));

        Assert.Equal(400, ex.StatusCode);
        _repo.Verify(r => r.RetractLastDecisionAsync(It.IsAny<int>(), It.IsAny<int>(), It.IsAny<string>(), It.IsAny<bool>()), Times.Never);
    }

    /* ---- WF-2: the step the approver saw travels with the decision ---- */

    [Fact]
    public async Task Approve_sends_the_step_the_approver_was_looking_at()
    {
        _repo.Setup(r => r.GetByIdAsync(9)).ReturnsAsync(new RequestDetail
        {
            Header = new RequestHeader { RequestInstanceId = 9, RequestTypeCode = "SOME_SIMPLE_TYPE" },
            Steps = new List<RequestStep>(),
            History = new List<SignatureLogEntry>(),
            Reversals = new List<RequestReversal>(),
        });
        _repo.Setup(r => r.GetSignatureRequirementAsync(9, 20)).ReturnsAsync((SignatureRequirement?)null);
        _repo.Setup(r => r.ApproveAsync(9, 20, null, null, false, 2))
             .ReturnsAsync(new ApproveResult { RequestInstanceId = 9, Status = "Pending" });

        await Service().ApproveAsync(9, actedByUserId: 20, comment: null, changeSummary: null, password: null, expectedStepNo: 2);

        _repo.Verify(r => r.ApproveAsync(9, 20, null, null, false, 2), Times.Once);
    }

    /* ---- WF-10: the move's confirmation travels to the procedure ---- */

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Move_to_version_carries_the_confirmation(bool confirm)
    {
        _repo.Setup(r => r.MoveToVersionAsync(5, null, 20, "New chain.", confirm))
             .ReturnsAsync(new MoveVersionResult { RequestInstanceId = 5, Status = confirm ? "Approved" : "Pending" });

        await Service().MoveToVersionAsync(5, new MoveVersionRequest { Reason = "New chain.", ConfirmClose = confirm }, actedByUserId: 20);

        _repo.Verify(r => r.MoveToVersionAsync(5, null, 20, "New chain.", confirm), Times.Once);
    }

    /* ---- the error translation ---- */

    [Fact]
    public void Only_the_procedures_own_sentence_reaches_the_screen()
    {
        var ex = WorkflowSqlErrors.Translate(new[]
        {
            (50000, "There is no decision to retract."),
            (266, "Transaction count after EXECUTE indicates a mismatching number of BEGIN and COMMIT statements. Previous count = 1, current count = 0."),
        });

        Assert.NotNull(ex);
        Assert.Equal(400, ex!.StatusCode);
        Assert.Equal("There is no decision to retract.", ex.Message);
    }

    [Fact]
    public void A_wrapper_sentence_after_the_refusal_is_dropped_too()
    {
        var ex = WorkflowSqlErrors.Translate(new[]
        {
            (50000, "You are not the approver for this step."),
            (50000, "The exit permission could not be decided."),
        });

        Assert.Equal(403, ex!.StatusCode);
        Assert.Equal("You are not the approver for this step.", ex.Message);
    }

    [Fact]
    public void A_lost_race_is_a_conflict_with_the_reload_sentence()
    {
        var raised = WorkflowSqlErrors.Translate(new[] { (50000, WorkflowSqlErrors.DecidedAMomentAgo) });
        Assert.Equal(409, raised!.StatusCode);
        Assert.Equal("This step was decided a moment ago — reload.", raised.Message);

        var deadlock = WorkflowSqlErrors.Translate(new[]
        {
            (1205, "Transaction (Process ID 61) was deadlocked on lock resources with another process and has been chosen as the deadlock victim. Rerun the transaction."),
        });
        Assert.Equal(409, deadlock!.StatusCode);
        Assert.Equal(WorkflowSqlErrors.DecidedAMomentAgo, deadlock.Message);
    }

    [Fact]
    public void A_real_failure_is_not_translated()
    {
        Assert.Null(WorkflowSqlErrors.Translate(new[]
        {
            (547, "The DELETE statement conflicted with the REFERENCE constraint \"FK_X\"."),
            (3621, "The statement has been terminated."),
        }));
        Assert.Null(WorkflowSqlErrors.Translate(Array.Empty<(int, string)>()));
    }

    [Fact]
    public void Reversal_refusals_keep_their_statuses()
    {
        Assert.Equal(409, WorkflowSqlErrors.MapMessage(
            "Moving this request to version 3 leaves no step to sign - it would be approved at once. Confirm the move to approve it.").StatusCode);
        Assert.Equal(403, WorkflowSqlErrors.MapMessage(
            "You already signed this reopen - the other of the General Manager and the Owner must countersign it.").StatusCode);
        Assert.Equal(403, WorkflowSqlErrors.MapMessage(
            "Reopening a closed request needs the General Manager and the Owner.").StatusCode);
        Assert.Equal(400, WorkflowSqlErrors.MapMessage(
            "A cancelled request is reopened by HR (Reopen request), not by the GM and the Owner.").StatusCode);
    }

    /* ---- WEB-13: the hub's type filter ---- */

    [Fact]
    public async Task Active_request_types_leave_out_the_inactive_ones()
    {
        var repo = new Mock<IDefinitionRepository>();
        repo.Setup(r => r.GetRequestTypesAsync()).ReturnsAsync(new List<RequestType>
        {
            new() { RequestTypeId = 1, Code = "LEAVE_REQUEST", Name = "Leave", Description = "Days off.", IsActive = true },
            new() { RequestTypeId = 2, Code = "OLD_TYPE", Name = "Old", IsActive = false },
        });

        var types = (await new DefinitionService(repo.Object).GetActiveRequestTypesAsync()).ToList();

        var only = Assert.Single(types);
        Assert.Equal("LEAVE_REQUEST", only.Code);
        Assert.Equal("Leave", only.Name);
    }
}
