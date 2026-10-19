using Moq;
using MokaCo.HRMS.Model.Security;
using MokaCo.HRMS.Model.Workflow;
using MokaCo.HRMS.Repository.Security;
using MokaCo.HRMS.Repository.Workflow;
using MokaCo.HRMS.Services.Auth;
using MokaCo.HRMS.Services.Security;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Tests.Security;

/// <summary>
/// QA3 (item 10): a password asked again after sign-in — a decision's signature, the current password of a
/// change — counts against the login lockout, a locked account is refused without checking, and a right
/// one clears the count without counting as a sign-in.
/// </summary>
public class SignaturePasswordAttemptTests
{
    private static (Mock<IUserRepository> Users, Mock<IPasswordHasher> Hasher) Account(int failed = 0, DateTime? lockoutEnd = null, DateTime? lockAfterThisFailure = null)
    {
        var users = new Mock<IUserRepository>();
        users.Setup(u => u.GetByIdAsync(7)).ReturnsAsync(new User { UserId = 7, PasswordHash = "h", IsActive = true, FailedLoginAttempts = failed, LockoutEnd = lockoutEnd });
        users.Setup(u => u.RegisterLoginFailureAsync(7, It.IsAny<int>(), It.IsAny<int>()))
             .ReturnsAsync(new LoginFailureResult { FailedLoginAttempts = failed + 1, LockoutEnd = lockAfterThisFailure });
        var hasher = new Mock<IPasswordHasher>();
        hasher.Setup(h => h.Verify("right", "h")).Returns(true);
        return (users, hasher);
    }

    [Fact]
    public async Task A_wrong_password_is_counted_like_a_failed_sign_in()
    {
        var (users, hasher) = Account();

        Assert.Equal(PasswordVerdict.Wrong, await AccountPassword.CheckAsync(users.Object, hasher.Object, 7, "guess"));
        users.Verify(u => u.RegisterLoginFailureAsync(7, It.IsAny<int>(), It.IsAny<int>()), Times.Once());
    }

    [Fact]
    public async Task The_failure_that_reaches_the_limit_locks()
    {
        var (users, hasher) = Account(failed: 4, lockAfterThisFailure: DateTime.UtcNow.AddMinutes(15));

        Assert.Equal(PasswordVerdict.Locked, await AccountPassword.CheckAsync(users.Object, hasher.Object, 7, "guess"));
    }

    [Fact]
    public async Task A_locked_account_is_refused_without_looking_at_the_password()
    {
        var (users, hasher) = Account(failed: 5, lockoutEnd: DateTime.UtcNow.AddMinutes(10));

        Assert.Equal(PasswordVerdict.Locked, await AccountPassword.CheckAsync(users.Object, hasher.Object, 7, "right"));
        hasher.Verify(h => h.Verify(It.IsAny<string>(), It.IsAny<string>()), Times.Never());
        users.Verify(u => u.RegisterLoginFailureAsync(It.IsAny<int>(), It.IsAny<int>(), It.IsAny<int>()), Times.Never());
    }

    [Fact]
    public async Task A_right_password_clears_the_count_without_being_a_sign_in()
    {
        var (users, hasher) = Account(failed: 3);

        Assert.Equal(PasswordVerdict.Ok, await AccountPassword.CheckAsync(users.Object, hasher.Object, 7, "right"));
        users.Verify(u => u.ClearLoginFailuresAsync(7), Times.Once());
        users.Verify(u => u.RegisterLoginSuccessAsync(It.IsAny<int>()), Times.Never());      // that one stamps LastLoginAt
    }

    [Fact]
    public async Task Nothing_to_clear_writes_nothing()
    {
        var (users, hasher) = Account();

        Assert.Equal(PasswordVerdict.Ok, await AccountPassword.CheckAsync(users.Object, hasher.Object, 7, "right"));
        users.Verify(u => u.ClearLoginFailuresAsync(It.IsAny<int>()), Times.Never());
    }

    [Fact]
    public async Task An_unknown_account_is_neither_checked_nor_counted()
    {
        var users = new Mock<IUserRepository>();
        var hasher = new Mock<IPasswordHasher>();

        Assert.Equal(PasswordVerdict.Unknown, await AccountPassword.CheckAsync(users.Object, hasher.Object, 7, "right"));
        users.Verify(u => u.RegisterLoginFailureAsync(It.IsAny<int>(), It.IsAny<int>(), It.IsAny<int>()), Times.Never());
    }

    /* ---- the callers ---- */

    private static DecisionSignatureService Signatures(Mock<IUserRepository> users, Mock<IPasswordHasher> hasher)
    {
        var requests = new Mock<IRequestRepository>();
        requests.Setup(r => r.GetSignatureRequirementAsync(42, 7)).ReturnsAsync(new SignatureRequirement { SignatureRequired = true });
        return new DecisionSignatureService(requests.Object, users.Object, hasher.Object);
    }

    [Fact]
    public async Task A_typed_decisions_wrong_signature_is_counted_and_a_locked_account_cannot_sign()
    {
        var (users, hasher) = Account();
        var wrong = await Assert.ThrowsAsync<WorkflowException>(() => Signatures(users, hasher).VerifyAsync(42, 7, "guess"));
        Assert.Equal((401, "That password is not correct."), (wrong.StatusCode, wrong.Message));
        users.Verify(u => u.RegisterLoginFailureAsync(7, It.IsAny<int>(), It.IsAny<int>()), Times.Once());

        var (lockedUsers, lockedHasher) = Account(failed: 5, lockoutEnd: DateTime.UtcNow.AddMinutes(10));
        var locked = await Assert.ThrowsAsync<WorkflowException>(() => Signatures(lockedUsers, lockedHasher).VerifyAsync(42, 7, "right"));
        Assert.Equal((401, AuthService.Locked), (locked.StatusCode, locked.Message));

        var (okUsers, okHasher) = Account();
        Assert.True(await Signatures(okUsers, okHasher).VerifyAsync(42, 7, "right"));
    }

    [Fact]
    public async Task A_decisions_wrong_signature_on_the_generic_path_is_counted_too()
    {
        var (users, hasher) = Account();
        var repo = new Mock<IRequestRepository>();
        repo.Setup(r => r.GetByIdAsync(42)).ReturnsAsync(new RequestDetail { Header = new RequestHeader { RequestInstanceId = 42, RequestTypeCode = "ROSTER_APPROVAL" } });
        repo.Setup(r => r.GetSignatureRequirementAsync(42, 7)).ReturnsAsync(new SignatureRequirement { SignatureRequired = true });
        var service = new RequestService(repo.Object, users.Object, hasher.Object);

        var ex = await Assert.ThrowsAsync<WorkflowException>(() => service.ApproveAsync(42, 7, comment: null, password: "guess"));

        Assert.Equal(401, ex.StatusCode);
        users.Verify(u => u.RegisterLoginFailureAsync(7, It.IsAny<int>(), It.IsAny<int>()), Times.Once());
        repo.Verify(r => r.ApproveAsync(It.IsAny<int>(), It.IsAny<int>(), It.IsAny<string?>(), It.IsAny<string?>(), It.IsAny<bool>()), Times.Never());
    }

    [Fact]
    public async Task A_leave_decisions_wrong_signature_is_counted_and_a_locked_account_cannot_sign()
    {
        LeaveRequestService Service(Mock<IUserRepository> users, Mock<IPasswordHasher> hasher, Mock<ILeaveRequestRepository> leave)
        {
            var requests = new Mock<IRequestRepository>();
            requests.Setup(r => r.GetSignatureRequirementAsync(42, 7)).ReturnsAsync(new SignatureRequirement { SignatureRequired = true });
            return new LeaveRequestService(leave.Object, requests.Object, users.Object, hasher.Object);
        }

        var (users, hasher) = Account();
        var leave = new Mock<ILeaveRequestRepository>();
        var wrong = await Assert.ThrowsAsync<WorkflowException>(() =>
            Service(users, hasher, leave).DecideAsync(42, 7, new LeaveRequestDecideRequest { Password = "guess" }));
        Assert.Equal((401, "That password is not correct."), (wrong.StatusCode, wrong.Message));
        users.Verify(u => u.RegisterLoginFailureAsync(7, It.IsAny<int>(), It.IsAny<int>()), Times.Once());
        leave.Verify(r => r.DecideAsync(It.IsAny<int>(), It.IsAny<int>(), It.IsAny<decimal?>(), It.IsAny<string?>(), It.IsAny<bool>(), It.IsAny<bool>()), Times.Never());

        var (lockedUsers, lockedHasher) = Account(failed: 5, lockoutEnd: DateTime.UtcNow.AddMinutes(10));
        var locked = await Assert.ThrowsAsync<WorkflowException>(() =>
            Service(lockedUsers, lockedHasher, leave).DecideAsync(42, 7, new LeaveRequestDecideRequest { Password = "right" }));
        Assert.Equal((401, AuthService.Locked), (locked.StatusCode, locked.Message));
        lockedHasher.Verify(h => h.Verify(It.IsAny<string>(), It.IsAny<string>()), Times.Never());
    }

    [Fact]
    public async Task The_password_change_form_counts_wrong_current_passwords_and_refuses_a_locked_account()
    {
        var (users, hasher) = Account();
        var service = new UserService(users.Object, hasher.Object, Mock.Of<ISessionGuard>());

        var wrong = await service.ChangePasswordAsync(7, new ChangePasswordRequest { CurrentPassword = "guess", NewPassword = "N3w-passw0rd" });
        Assert.Equal("The current password is incorrect.", wrong.Error);
        users.Verify(u => u.RegisterLoginFailureAsync(7, It.IsAny<int>(), It.IsAny<int>()), Times.Once());

        var (lockedUsers, lockedHasher) = Account(failed: 5, lockoutEnd: DateTime.UtcNow.AddMinutes(10));
        var locked = await new UserService(lockedUsers.Object, lockedHasher.Object, Mock.Of<ISessionGuard>())
            .ChangePasswordAsync(7, new ChangePasswordRequest { CurrentPassword = "right", NewPassword = "N3w-passw0rd" });
        Assert.Equal(AuthService.Locked, locked.Error);
        lockedUsers.Verify(u => u.ChangePasswordAsync(It.IsAny<int>(), It.IsAny<string>()), Times.Never());
    }
}
