using System.Diagnostics;
using System.Net;
using System.Reflection;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.RateLimiting;
using Moq;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Api.Controllers;
using MokaCo.HRMS.Model.Security;
using MokaCo.HRMS.Repository.Security;
using MokaCo.HRMS.Services.Auth;
using MokaCo.HRMS.Services.Security;

namespace MokaCo.HRMS.Tests.Security;

/// <summary>
/// QA3 SEC-6: a sign-in that is refused costs the same Argon2 verification whatever the reason, so the
/// time of the answer does not tell a stranger which usernames exist; and sign-in is rate limited per
/// address and username.
/// </summary>
public class LoginTimingTests
{
    private const string Decoy = "decoy-hash";
    private const string RealHash = "real-hash";

    private sealed class Harness
    {
        public readonly Mock<IUserRepository> Users = new();
        public readonly Mock<IRefreshTokenRepository> Tokens = new();
        public readonly Mock<IPasswordHasher> Hasher = new();
        public readonly Mock<IJwtTokenService> Jwt = new();
        public readonly AuthService Service;

        public Harness(User? user, bool passwordOk)
        {
            Users.Setup(u => u.GetForLoginAsync("sara")).ReturnsAsync(user);
            Users.Setup(u => u.RegisterLoginFailureAsync(It.IsAny<int>(), It.IsAny<int>(), It.IsAny<int>()))
                 .ReturnsAsync(new LoginFailureResult { FailedLoginAttempts = 1 });
            Users.Setup(u => u.GetPermissionsAsync(It.IsAny<int>())).ReturnsAsync(Array.Empty<PermissionDto>());
            Hasher.SetupGet(h => h.DecoyHash).Returns(Decoy);
            Hasher.Setup(h => h.Verify("pw", RealHash)).Returns(passwordOk);
            Jwt.Setup(j => j.CreateAccessToken(It.IsAny<User>(), It.IsAny<IEnumerable<string>>())).Returns(("access", DateTime.UtcNow.AddMinutes(15)));
            Jwt.Setup(j => j.CreateRefreshToken()).Returns(("raw", "hash"));
            Tokens.Setup(t => t.IssueAsync(It.IsAny<int>(), RealHash, It.IsAny<string>(), It.IsAny<DateTime>(), It.IsAny<string?>()))
                  .ReturnsAsync(new IssuedRefreshToken { RefreshTokenId = 1, UserId = 7 });
            Service = new AuthService(Users.Object, Tokens.Object, Hasher.Object, Jwt.Object, new JwtOptions());
        }

        public Task<AuthResult> Login() => Service.LoginAsync(new LoginRequest { Username = "sara", Password = "pw" }, "10.0.0.1");
    }

    private static User Sara(bool active = true, DateTime? lockoutEnd = null)
        => new() { UserId = 7, Username = "sara", PasswordHash = RealHash, IsActive = active, LockoutEnd = lockoutEnd };

    [Fact]
    public async Task An_unknown_username_still_pays_one_verification_against_the_decoy()
    {
        var h = new Harness(user: null, passwordOk: false);

        var result = await h.Login();

        Assert.Equal(AuthService.InvalidCredentials, result.Error);
        h.Hasher.Verify(x => x.Verify("pw", Decoy), Times.Once());
        h.Users.Verify(u => u.RegisterLoginFailureAsync(It.IsAny<int>(), It.IsAny<int>(), It.IsAny<int>()), Times.Never());
    }

    [Fact]
    public async Task A_locked_account_pays_the_decoy_and_never_checks_the_real_password()
    {
        var h = new Harness(Sara(lockoutEnd: DateTime.UtcNow.AddMinutes(5)), passwordOk: true);

        var result = await h.Login();

        Assert.Equal(AuthService.Locked, result.Error);
        h.Hasher.Verify(x => x.Verify("pw", Decoy), Times.Once());
        h.Hasher.Verify(x => x.Verify(It.IsAny<string>(), RealHash), Times.Never());
    }

    [Fact]
    public async Task A_disabled_account_is_named_only_to_someone_who_knows_its_password()
    {
        var wrong = new Harness(Sara(active: false), passwordOk: false);
        Assert.Equal(AuthService.InvalidCredentials, (await wrong.Login()).Error);
        wrong.Hasher.Verify(x => x.Verify("pw", RealHash), Times.Once());
        wrong.Users.Verify(u => u.RegisterLoginFailureAsync(It.IsAny<int>(), It.IsAny<int>(), It.IsAny<int>()), Times.Never());

        var right = new Harness(Sara(active: false), passwordOk: true);
        Assert.Equal(AuthService.Disabled, (await right.Login()).Error);
        right.Tokens.Verify(t => t.IssueAsync(It.IsAny<int>(), It.IsAny<string>(), It.IsAny<string>(), It.IsAny<DateTime>(), It.IsAny<string?>()), Times.Never());
    }

    [Fact]
    public async Task A_wrong_password_is_counted_and_answered_like_an_unknown_name()
    {
        var h = new Harness(Sara(), passwordOk: false);

        Assert.Equal(AuthService.InvalidCredentials, (await h.Login()).Error);
        h.Users.Verify(u => u.RegisterLoginFailureAsync(7, It.IsAny<int>(), It.IsAny<int>()), Times.Once());
        h.Hasher.Verify(x => x.Verify(It.IsAny<string>(), Decoy), Times.Never());
    }

    [Fact]
    public async Task The_right_password_signs_in()
    {
        var h = new Harness(Sara(), passwordOk: true);

        var result = await h.Login();

        Assert.True(result.Success);
        Assert.Equal("access", result.Tokens!.AccessToken);
        h.Users.Verify(u => u.RegisterLoginSuccessAsync(7), Times.Once());
    }

    /* ---- the real hasher's decoy ---- */

    [Fact]
    public void The_decoy_has_the_cost_parameters_of_a_real_hash_and_matches_nothing()
    {
        var hasher = new Argon2PasswordHasher();
        var real = hasher.Hash("whatever");

        Assert.Equal(real.Split('$')[..3], hasher.DecoyHash.Split('$')[..3]);   // argon2id, v=19, m/t/p
        Assert.Equal(5, hasher.DecoyHash.Split('$').Length);
        Assert.False(hasher.Verify("whatever", hasher.DecoyHash));
        Assert.False(hasher.Verify("", hasher.DecoyHash));
        Assert.Same(hasher.DecoyHash, hasher.DecoyHash);
    }

    /// <summary>
    /// Coarse on purpose: the decoy must cost a real Argon2 run, not fail fast on a malformed hash — which
    /// would be about a thousand times quicker. The two are timed in turns (best of three each) so a busy
    /// test run slows both alike, and the bound leaves room for a loaded machine.
    /// </summary>
    [Fact]
    public void Verifying_against_the_decoy_takes_as_long_as_a_real_verification()
    {
        var hasher = new Argon2PasswordHasher();
        var real = hasher.Hash("correct horse");

        long wrongPassword = long.MaxValue, unknownUser = long.MaxValue;
        for (var i = 0; i < 3; i++)
        {
            var sw = Stopwatch.StartNew();
            hasher.Verify("guess", real);
            wrongPassword = Math.Min(wrongPassword, sw.ElapsedTicks);

            sw.Restart();
            hasher.Verify("guess", hasher.DecoyHash);
            unknownUser = Math.Min(unknownUser, sw.ElapsedTicks);
        }

        Assert.True(unknownUser * 10 > wrongPassword, $"decoy {unknownUser} ticks vs real {wrongPassword} ticks");
    }

    /* ---- the per address + username limit ---- */

    [Fact]
    public void Ten_attempts_a_minute_for_one_name_from_one_address_then_refused()
    {
        using var throttle = new LoginThrottle();

        for (var i = 0; i < LoginThrottle.PerUserPerMinute; i++)
            Assert.True(throttle.TryAcquire("10.0.0.1", "sara"));

        Assert.False(throttle.TryAcquire("10.0.0.1", "sara"));
        Assert.False(throttle.TryAcquire("10.0.0.1", "  SARA "));     // the same account, however it is typed
    }

    [Fact]
    public void The_limit_is_per_name_and_per_address_so_one_person_does_not_lock_out_the_cafe()
    {
        using var throttle = new LoginThrottle();
        for (var i = 0; i < LoginThrottle.PerUserPerMinute; i++)
            throttle.TryAcquire("10.0.0.1", "sara");

        Assert.True(throttle.TryAcquire("10.0.0.1", "rami"));          // a colleague behind the same NAT
        Assert.True(throttle.TryAcquire("10.0.0.2", "sara"));          // the same name from elsewhere
        Assert.True(throttle.TryAcquire(null, "sara"));
    }

    [Fact]
    public void A_huge_username_is_one_bounded_key()
    {
        using var throttle = new LoginThrottle();
        var huge = new string('a', 100_000);

        for (var i = 0; i < LoginThrottle.PerUserPerMinute; i++)
            Assert.True(throttle.TryAcquire("10.0.0.1", huge + i));     // same first 128 characters
        Assert.False(throttle.TryAcquire("10.0.0.1", huge + "x"));
    }

    /* ---- the controller ---- */

    [Fact]
    public async Task The_eleventh_attempt_for_one_name_is_429_and_never_reaches_the_password_check()
    {
        var auth = new Mock<IAuthService>();
        auth.Setup(a => a.LoginAsync(It.IsAny<LoginRequest>(), It.IsAny<string?>())).ReturnsAsync(AuthResult.Fail(AuthService.InvalidCredentials));
        using var throttle = new LoginThrottle();
        var http = new DefaultHttpContext();
        http.Connection.RemoteIpAddress = IPAddress.Parse("10.0.0.9");
        var controller = new AuthController(auth.Object, throttle) { ControllerContext = new ControllerContext { HttpContext = http } };

        for (var i = 0; i < LoginThrottle.PerUserPerMinute; i++)
            Assert.IsType<UnauthorizedObjectResult>(await controller.Login(new LoginRequest { Username = "sara", Password = "x" }));
        var refused = Assert.IsType<ObjectResult>(await controller.Login(new LoginRequest { Username = "sara", Password = "x" }));

        Assert.Equal(StatusCodes.Status429TooManyRequests, refused.StatusCode);
        Assert.Equal("60", http.Response.Headers.RetryAfter.ToString());
        auth.Verify(a => a.LoginAsync(It.IsAny<LoginRequest>(), It.IsAny<string?>()), Times.Exactly(LoginThrottle.PerUserPerMinute));
    }

    [Theory]
    [InlineData(nameof(AuthController.Login), AuthController.LoginRateLimitPolicy)]
    [InlineData(nameof(AuthController.Refresh), AuthController.RefreshRateLimitPolicy)]
    public void Sign_in_and_refresh_carry_their_per_address_limit(string action, string policy)
    {
        var limit = typeof(AuthController).GetMethod(action)!.GetCustomAttribute<EnableRateLimitingAttribute>();
        Assert.Equal(policy, limit?.PolicyName);
    }
}
