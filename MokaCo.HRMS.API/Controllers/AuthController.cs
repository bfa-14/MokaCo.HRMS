using System.Security.Claims;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
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
    private readonly IAuthService _auth;
    public AuthController(IAuthService auth) => _auth = auth;

    private string? Ip => HttpContext.Connection.RemoteIpAddress?.ToString();

    [HttpPost("login")]
    [AllowAnonymous]
    public async Task<IActionResult> Login([FromBody] LoginRequest request)
    {
        var result = await _auth.LoginAsync(request, Ip);
        return result.Success ? Ok(result.Tokens) : Unauthorized(new { error = result.Error });
    }

    [HttpPost("refresh")]
    [AllowAnonymous]
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
