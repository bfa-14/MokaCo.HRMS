using Moq;
using MokaCo.HRMS.Model.Workflow;
using MokaCo.HRMS.Repository.Security;
using MokaCo.HRMS.Repository.Workflow;
using MokaCo.HRMS.Services.Auth;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Tests.Workflow;

/// <summary>
/// The generic POST /requests/{id}/approve must REFUSE a request type whose final approval has side
/// effects, because workflow.usp_Request_Approve only moves the chain: it would close the request
/// while the leave ledger, the advance row or the roster silently never happened.
/// </summary>
public class GenericApproveDispatchTests
{
    private readonly Mock<IRequestRepository> _repo = new(MockBehavior.Strict);
    private readonly Mock<IUserRepository> _users = new(MockBehavior.Loose);
    private readonly Mock<IPasswordHasher> _hasher = new(MockBehavior.Loose);

    private RequestService Service() => new(_repo.Object, _users.Object, _hasher.Object);

    private void GivenRequestOfType(int id, string typeCode) =>
        _repo.Setup(r => r.GetByIdAsync(id)).ReturnsAsync(new RequestDetail
        {
            Header = new RequestHeader { RequestInstanceId = id, RequestTypeCode = typeCode },
            Steps = new List<RequestStep>(),
            History = new List<SignatureLogEntry>(),
            Reversals = new List<RequestReversal>(),
        });

    [Theory]
    [InlineData("LEAVE_REQUEST")]
    [InlineData("SALARY_ADVANCE")]
    [InlineData("PAYROLL_ADJUSTMENT")]
    [InlineData("OVERTIME")]
    [InlineData("SHIFT_SWAP")]
    [InlineData("EXPENSE_REIMBURSEMENT")]
    [InlineData("TIP_DISTRIBUTION")]
    [InlineData("SEPARATION")]
    [InlineData("ONBOARDING")]
    [InlineData("AVAILABILITY_CHANGE")]
    [InlineData("EXIT_PERMISSION")]
    public async Task Typed_request_is_refused_with_409(string typeCode)
    {
        GivenRequestOfType(7, typeCode);

        var ex = await Assert.ThrowsAsync<WorkflowException>(
            () => Service().ApproveAsync(7, actedByUserId: 20, comment: null));

        Assert.Equal(409, ex.StatusCode);
        Assert.Equal("Use the typed decide endpoint for this request type.", ex.Message);

        // and nothing was written: the engine was never called
        _repo.Verify(r => r.ApproveAsync(It.IsAny<int>(), It.IsAny<int>(), It.IsAny<string?>(),
                                         It.IsAny<string?>(), It.IsAny<bool>()), Times.Never);
    }

    /// <summary>The refusal must come BEFORE the signature check — no point demanding a password for a call that was never going to be honoured.</summary>
    [Fact]
    public async Task Typed_request_is_refused_without_asking_for_a_signature()
    {
        GivenRequestOfType(7, "LEAVE_REQUEST");

        await Assert.ThrowsAsync<WorkflowException>(
            () => Service().ApproveAsync(7, actedByUserId: 20, comment: null, changeSummary: null, password: null));

        _repo.Verify(r => r.GetSignatureRequirementAsync(It.IsAny<int>(), It.IsAny<int>()), Times.Never);
    }

    /// <summary>An untyped/simple type keeps the plain engine behaviour — the dispatch must not refuse everything.</summary>
    [Fact]
    public async Task Untyped_request_still_goes_through_the_engine()
    {
        GivenRequestOfType(9, "SOME_SIMPLE_TYPE");
        _repo.Setup(r => r.GetSignatureRequirementAsync(9, 20))
             .ReturnsAsync((SignatureRequirement?)null);          // nothing demands a password here
        _repo.Setup(r => r.ApproveAsync(9, 20, null, null, false))
             .ReturnsAsync(new ApproveResult { RequestInstanceId = 9, Status = "Approved" });

        var result = await Service().ApproveAsync(9, actedByUserId: 20, comment: null);

        Assert.NotNull(result);
        Assert.Equal("Approved", result!.Status);
        _repo.Verify(r => r.ApproveAsync(9, 20, null, null, false), Times.Once);
    }

    /// <summary>A request that does not exist is still a 404, not a 409.</summary>
    [Fact]
    public async Task Missing_request_returns_null()
    {
        _repo.Setup(r => r.GetByIdAsync(404)).ReturnsAsync((RequestDetail?)null);

        Assert.Null(await Service().ApproveAsync(404, actedByUserId: 20, comment: null));
    }
}
