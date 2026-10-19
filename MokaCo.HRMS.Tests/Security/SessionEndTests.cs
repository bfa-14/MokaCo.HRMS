using System.IdentityModel.Tokens.Jwt;
using System.Security.Claims;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging.Abstractions;
using Moq;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Model.Security;
using MokaCo.HRMS.Repository.Security;
using MokaCo.HRMS.Services.Auth;
using MokaCo.HRMS.Services.Security;

namespace MokaCo.HRMS.Tests.Security;

/// <summary>
/// QA3 SEC-5: a password change or a disable ends every session of the account — the refresh tokens are
/// revoked (script 105) and the access tokens already handed out stop working (their session stamp is
/// no longer the account's).
/// </summary>
public class SessionEndTests
{
    private static readonly DateTimeOffset T0 = new(2026, 10, 19, 9, 0, 0, TimeSpan.Zero);
    private static readonly Guid Stamp = Guid.Parse("6f9619ff-8b86-d011-b42d-00cf4fc964ff");

    private sealed class Clock(DateTimeOffset start) : TimeProvider
    {
        public DateTimeOffset Now = start;
        public override DateTimeOffset GetUtcNow() => Now;
    }

    private static (SessionGuard Guard, Mock<IUserRepository> Users, Clock Clock) Guard(User? user)
    {
        var users = new Mock<IUserRepository>();
        users.Setup(u => u.GetByIdAsync(7)).ReturnsAsync(user);
        var scopes = new ServiceCollection().AddScoped(_ => users.Object).BuildServiceProvider().GetRequiredService<IServiceScopeFactory>();
        var clock = new Clock(T0);
        return (new SessionGuard(scopes, NullLogger<SessionGuard>.Instance, clock), users, clock);
    }

    private static User Rami(bool active = true, Guid? stamp = null)
        => new() { UserId = 7, Username = "rami", PasswordHash = "h", IsActive = active, SessionStamp = stamp };

    /* ---- the guard ---- */

    [Fact]
    public async Task A_token_with_the_accounts_stamp_passes_and_any_other_is_refused()
    {
        var (guard, _, _) = Guard(Rami(stamp: Stamp));

        Assert.True(await guard.IsCurrentAsync(7, Stamp));
        Assert.False(await guard.IsCurrentAsync(7, Guid.NewGuid()));
        Assert.False(await guard.IsCurrentAsync(7, null));     // issued before the account's sessions were first ended
    }

    [Fact]
    public async Task An_account_whose_sessions_were_never_ended_accepts_a_token_without_a_stamp()
    {
        var (guard, _, _) = Guard(Rami(stamp: null));

        Assert.True(await guard.IsCurrentAsync(7, null));
        Assert.False(await guard.IsCurrentAsync(7, Stamp));
    }

    [Fact]
    public async Task A_disabled_or_missing_account_opens_nothing()
    {
        Assert.False(await Guard(Rami(active: false)).Guard.IsCurrentAsync(7, null));
        Assert.False(await Guard(null).Guard.IsCurrentAsync(7, null));
    }

    [Fact]
    public async Task The_account_is_read_once_per_window_and_again_after_it()
    {
        var (guard, users, clock) = Guard(Rami());

        await guard.IsCurrentAsync(7, null);
        clock.Now = T0 + SessionGuard.CacheFor - TimeSpan.FromSeconds(1);
        await guard.IsCurrentAsync(7, null);
        users.Verify(u => u.GetByIdAsync(7), Times.Once());

        clock.Now = T0 + SessionGuard.CacheFor;
        await guard.IsCurrentAsync(7, null);
        users.Verify(u => u.GetByIdAsync(7), Times.Exactly(2));
    }

    [Fact]
    public async Task Forget_makes_the_next_request_read_the_account_again()
    {
        var (guard, users, _) = Guard(Rami(stamp: null));
        Assert.True(await guard.IsCurrentAsync(7, null));

        users.Setup(u => u.GetByIdAsync(7)).ReturnsAsync(Rami(stamp: Stamp));     // the sessions were just ended
        guard.Forget(7);

        Assert.False(await guard.IsCurrentAsync(7, null));
        users.Verify(u => u.GetByIdAsync(7), Times.Exactly(2));
    }

    [Fact]
    public async Task A_reading_that_was_under_way_when_the_sessions_ended_is_not_kept()
    {
        var (guard, users, _) = Guard(null);
        var first = true;
        users.Setup(u => u.GetByIdAsync(7)).ReturnsAsync(() =>
        {
            if (!first)
                return Rami(stamp: Stamp);
            first = false;
            guard.Forget(7);                // the change lands while this read is in flight
            return Rami(stamp: null);
        });

        await guard.IsCurrentAsync(7, null);                 // answered from the old reading: it was in flight
        Assert.False(await guard.IsCurrentAsync(7, null));   // but not cached: read again, and refused
    }

    [Fact]
    public async Task A_database_that_does_not_answer_signs_nobody_out()
    {
        var (guard, users, clock) = Guard(Rami(stamp: Stamp));
        Assert.True(await guard.IsCurrentAsync(7, Stamp));

        users.Setup(u => u.GetByIdAsync(7)).ThrowsAsync(new TimeoutException("SQL down"));
        clock.Now = T0 + SessionGuard.CacheFor;
        Assert.True(await guard.IsCurrentAsync(7, Stamp));           // the last good reading
        Assert.False(await guard.IsCurrentAsync(7, Guid.NewGuid()));  // ...which still refuses an old token

        var (cold, coldUsers, _) = Guard(null);
        coldUsers.Setup(u => u.GetByIdAsync(7)).ThrowsAsync(new TimeoutException("SQL down"));
        Assert.True(await cold.IsCurrentAsync(7, null));             // nothing to judge by: let it through
    }

    [Fact]
    public async Task After_a_failed_read_the_database_is_asked_again_only_after_a_pause()
    {
        var (guard, users, clock) = Guard(null);
        users.Setup(u => u.GetByIdAsync(7)).ThrowsAsync(new TimeoutException("SQL down"));

        await guard.IsCurrentAsync(7, null);
        await guard.IsCurrentAsync(7, null);
        users.Verify(u => u.GetByIdAsync(7), Times.Once());

        clock.Now = T0 + SessionGuard.RetryAfterFailure;
        await guard.IsCurrentAsync(7, null);
        users.Verify(u => u.GetByIdAsync(7), Times.Exactly(2));
    }

    /* ---- the token ---- */

    [Fact]
    public void The_access_token_carries_the_stamp_it_was_issued_under()
    {
        var jwt = new JwtTokenService(new JwtOptions { Issuer = "i", Audience = "a", SecretKey = new string('k', 48) });

        var stamped = new JwtSecurityTokenHandler().ReadJwtToken(jwt.CreateAccessToken(Rami(stamp: Stamp), []).token);
        var plain = new JwtSecurityTokenHandler().ReadJwtToken(jwt.CreateAccessToken(Rami(stamp: null), []).token);

        Assert.Equal(Stamp, Guid.Parse(stamped.Claims.Single(c => c.Type == JwtTokenService.SessionStampClaim).Value));
        Assert.DoesNotContain(plain.Claims, c => c.Type == JwtTokenService.SessionStampClaim);
    }

    /* ---- sign-in and refresh ---- */

    private sealed class Auth
    {
        public readonly Mock<IUserRepository> Users = new();
        public readonly Mock<IRefreshTokenRepository> Tokens = new();
        public readonly Mock<IPasswordHasher> Hasher = new();
        public readonly Mock<IJwtTokenService> Jwt = new();
        public readonly AuthService Service;
        public User? SignedWith;

        public Auth()
        {
            Users.Setup(u => u.GetPermissionsAsync(It.IsAny<int>())).ReturnsAsync(Array.Empty<PermissionDto>());
            Hasher.Setup(h => h.Verify("pw", "h")).Returns(true);
            Jwt.Setup(j => j.CreateRefreshToken()).Returns(("raw", "new-hash"));
            Jwt.Setup(j => j.HashRefreshToken("old")).Returns("old-hash");
            Jwt.Setup(j => j.CreateAccessToken(It.IsAny<User>(), It.IsAny<IEnumerable<string>>()))
               .Callback((User u, IEnumerable<string> _) => SignedWith = new User { UserId = u.UserId, SessionStamp = u.SessionStamp })
               .Returns(("access", T0.UtcDateTime));
            Service = new AuthService(Users.Object, Tokens.Object, Hasher.Object, Jwt.Object, new JwtOptions());
        }
    }

    [Fact]
    public async Task A_refresh_signs_the_new_access_token_with_the_stamp_read_by_the_rotation_not_a_later_one()
    {
        var a = new Auth();
        a.Tokens.Setup(t => t.RotateAsync("old-hash", "new-hash", It.IsAny<DateTime>(), "10.0.0.1"))
                .ReturnsAsync(new IssuedRefreshToken { RefreshTokenId = 2, UserId = 7, SessionStamp = Stamp });
        a.Users.Setup(u => u.GetByIdAsync(7)).ReturnsAsync(Rami(stamp: Guid.NewGuid()));   // a change that landed after the rotation

        var result = await a.Service.RefreshAsync("old", "10.0.0.1");

        Assert.True(result.Success);
        Assert.Equal(Stamp, a.SignedWith!.SessionStamp);
    }

    [Fact]
    public async Task A_refused_rotation_issues_nothing()
    {
        var a = new Auth();
        a.Tokens.Setup(t => t.RotateAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<DateTime>(), It.IsAny<string?>()))
                .ReturnsAsync((IssuedRefreshToken?)null);

        Assert.False((await a.Service.RefreshAsync("old", null)).Success);
        Assert.Null(a.SignedWith);
    }

    [Fact]
    public async Task A_sign_in_whose_password_changed_during_the_check_gets_no_session()
    {
        var a = new Auth();
        a.Users.Setup(u => u.GetForLoginAsync("rami")).ReturnsAsync(Rami());
        a.Tokens.Setup(t => t.IssueAsync(7, "h", "new-hash", It.IsAny<DateTime>(), It.IsAny<string?>()))
                .ReturnsAsync((IssuedRefreshToken?)null);

        var result = await a.Service.LoginAsync(new LoginRequest { Username = "rami", Password = "pw" }, null);

        Assert.Equal(AuthService.InvalidCredentials, result.Error);
        Assert.Null(a.SignedWith);
        a.Users.Verify(u => u.RegisterLoginSuccessAsync(It.IsAny<int>()), Times.Never());   // not a sign-in
    }

    [Fact]
    public async Task A_sign_in_is_issued_against_the_checked_hash_and_signed_with_the_issued_stamp()
    {
        var a = new Auth();
        a.Users.Setup(u => u.GetForLoginAsync("rami")).ReturnsAsync(Rami());
        a.Tokens.Setup(t => t.IssueAsync(7, "h", "new-hash", It.IsAny<DateTime>(), It.IsAny<string?>()))
                .ReturnsAsync(new IssuedRefreshToken { RefreshTokenId = 3, UserId = 7, SessionStamp = Stamp });

        var result = await a.Service.LoginAsync(new LoginRequest { Username = "rami", Password = "pw" }, null);

        Assert.True(result.Success);
        Assert.Equal(Stamp, a.SignedWith!.SessionStamp);
    }

    /* ---- what ends the sessions ---- */

    private static (UserService Service, Mock<IUserRepository> Users, Mock<ISessionGuard> Sessions) Users()
    {
        var users = new Mock<IUserRepository>();
        var hasher = new Mock<IPasswordHasher>();
        hasher.Setup(h => h.Verify("old-pw", "h")).Returns(true);
        hasher.Setup(h => h.Hash(It.IsAny<string>())).Returns("h2");
        users.Setup(u => u.GetByIdAsync(7)).ReturnsAsync(Rami());
        users.Setup(u => u.ChangePasswordAsync(7, "h2")).ReturnsAsync(1);
        var sessions = new Mock<ISessionGuard>();
        return (new UserService(users.Object, hasher.Object, sessions.Object), users, sessions);
    }

    [Fact]
    public async Task A_changed_password_ends_every_session_of_the_account()
    {
        var (service, users, sessions) = Users();

        var result = await service.ChangePasswordAsync(7, new ChangePasswordRequest { CurrentPassword = "old-pw", NewPassword = "N3w-passw0rd" });

        Assert.True(result.Success);
        users.Verify(u => u.EndSessionsAsync(7), Times.Once());
        sessions.Verify(s => s.Forget(7), Times.Once());
    }

    [Fact]
    public async Task A_refused_password_change_ends_nothing()
    {
        var (service, users, sessions) = Users();

        Assert.False((await service.ChangePasswordAsync(7, new ChangePasswordRequest { CurrentPassword = "wrong", NewPassword = "N3w-passw0rd" })).Success);
        Assert.False((await service.ChangePasswordAsync(7, new ChangePasswordRequest { CurrentPassword = "old-pw", NewPassword = "short" })).Success);
        users.Verify(u => u.EndSessionsAsync(It.IsAny<int>()), Times.Never());
        sessions.Verify(s => s.Forget(It.IsAny<int>()), Times.Never());
    }

    [Theory]
    [InlineData(false, 1, true)]     // disabled: its sessions end
    [InlineData(true, 1, false)]     // enabled: nothing to end
    [InlineData(false, 0, false)]    // no such user: nothing happened
    public async Task Disabling_an_account_ends_its_sessions(bool isActive, int rows, bool ends)
    {
        var (service, users, sessions) = Users();
        users.Setup(u => u.SetActiveAsync(7, isActive, 1)).ReturnsAsync(rows);

        await service.SetActiveAsync(7, isActive, modifiedBy: 1);

        users.Verify(u => u.EndSessionsAsync(7), ends ? Times.Once() : Times.Never());
        sessions.Verify(s => s.Forget(7), ends ? Times.Once() : Times.Never());
    }

    /* ---- the JWT handler hook ---- */

    private static async Task<TokenValidatedContext> Validate(bool current, params Claim[] claims)
    {
        var guard = new Mock<ISessionGuard>();
        guard.Setup(g => g.IsCurrentAsync(It.IsAny<int>(), It.IsAny<Guid?>(), It.IsAny<CancellationToken>())).ReturnsAsync(current);
        var http = new DefaultHttpContext { RequestServices = new ServiceCollection().AddSingleton(guard.Object).BuildServiceProvider() };
        var context = new TokenValidatedContext(http, new AuthenticationScheme(JwtBearerDefaults.AuthenticationScheme, null, typeof(JwtBearerHandler)), new JwtBearerOptions())
        {
            Principal = new ClaimsPrincipal(new ClaimsIdentity(claims, "jwt")),
        };
        await SessionCheck.OnTokenValidated(context);
        return context;
    }

    [Fact]
    public async Task The_handler_refuses_a_token_whose_session_has_ended_and_keeps_one_that_is_current()
    {
        var ended = await Validate(current: false, new Claim(ClaimTypes.NameIdentifier, "7"));
        Assert.NotNull(ended.Result?.Failure);

        var current = await Validate(current: true, new Claim(ClaimTypes.NameIdentifier, "7"), new Claim(JwtTokenService.SessionStampClaim, Stamp.ToString("N")));
        Assert.Null(current.Result);

        var anonymous = await Validate(current: true);
        Assert.NotNull(anonymous.Result?.Failure);
    }
}
