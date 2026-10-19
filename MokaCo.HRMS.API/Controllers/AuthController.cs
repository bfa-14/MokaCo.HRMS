using System.Security.Claims;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.RateLimiting;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Model.Security;
using MokaCo.HRMS.Services.Security;

namespace MokaCo.HRMS.Api.Controllers;

/*
 * DELIBERATELY SILENT — no NotifyAsync anywhere in this controller, and that is the answer, not a
 * gap. Login, refresh and logout write only refresh-token rows, which no screen displays and no
 * live topic covers. Signalling here would wake every subscribed page on every sign-in for nothing.
 * Recorded so the periodic "which mutating actions do not notify?" sweep stops rediscovering it.
 */
[ApiController]
[Route("api/auth")]
public class AuthController : ControllerBase
{
    /// <summary>
    /// Program.cs policies, per client address (QA3 SEC-6): sign-in 60 a minute for every username
    /// together (a whole café is one NAT address), refresh 120 a minute (a refused refresh signs the
    /// person out, so it is the more generous one). The per-username half of the sign-in limit is
    /// <see cref="LoginThrottle"/>.
    /// </summary>
    public const string LoginRateLimitPolicy = "auth-login";
    public const string RefreshRateLimitPolicy = "auth-refresh";

    public const string TooManyAttempts = "Too many sign-in attempts. Wait a minute and try again.";

    private readonly IAuthService _auth;
    private readonly LoginThrottle _throttle;

    public AuthController(IAuthService auth, LoginThrottle throttle)
    {
        _auth = auth;
        _throttle = throttle;
    }

    private string? Ip => HttpContext.Connection.RemoteIpAddress?.ToString();

    [HttpPost("login")]
    [AllowAnonymous]
    [EnableRateLimiting(LoginRateLimitPolicy)]
    public async Task<IActionResult> Login([FromBody] LoginRequest request)
    {
        // Before the password is even looked at: the refusal costs no Argon2 and no database.
        if (!_throttle.TryAcquire(Ip, request.Username))
        {
            Response.Headers.RetryAfter = "60";
            return StatusCode(StatusCodes.Status429TooManyRequests, new { error = TooManyAttempts });
        }

        var result = await _auth.LoginAsync(request, Ip);
        return result.Success ? Ok(result.Tokens) : Unauthorized(new { error = result.Error });
    }

    [HttpPost("refresh")]
    [AllowAnonymous]
    [EnableRateLimiting(RefreshRateLimitPolicy)]
    public async Task<IActionResult> Refresh([FromBody] RefreshRequest request)
    {
        var result = await _auth.RefreshAsync(request.RefreshToken, Ip);
        return result.Success ? Ok(result.Tokens) : Unauthorized(new { error = result.Error });
    }

    [HttpPost("logout")]
    [Authorize]
    public async Task<IActionResult> Logout([FromBody] RefreshRequest request)
    {
        await _auth.LogoutAsync(request.RefreshToken);
        return NoContent();
    }

    [HttpGet("me")]
    [Authorize]
    public async Task<IActionResult> Me()
    {
        var idClaim = User.FindFirstValue(ClaimTypes.NameIdentifier)
                      ?? User.FindFirstValue("sub");
        if (idClaim is null || !int.TryParse(idClaim, out var userId))
            return Unauthorized();

        var me = await _auth.GetCurrentUserAsync(userId);
        return me is null ? Unauthorized() : Ok(me);
    }
}
