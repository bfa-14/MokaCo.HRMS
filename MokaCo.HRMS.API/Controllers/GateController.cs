using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.RateLimiting;
using Microsoft.Net.Http.Headers;
using MokaCo.HRMS.Model.Security;
using MokaCo.HRMS.Services.Security.Gate;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Api.Controllers;

/// <summary>
/// The Google sign-in gate's front door — docs/GOOGLE_SIGNIN_GATE.md §3.
///
/// ANONYMOUS, every action: the people who reach these have not signed in to the HRMS yet, and nginx's
/// check carries no JWT. Every answer is Cache-Control: no-store — a cached "allowed" would outlive a block.
///
///   GET/HEAD check     nginx auth_request asks this for EVERY request to the HRMS host: 204 pass, 401 gate.
///   GET      config    what the gate page needs before it draws Google's button.
///   POST     google    the ID token from Google's button → the gate cookie (rate-limited per IP).
///   POST     signout   forgets this browser's gate cookie.
/// </summary>
[ApiController]
[Route("api/gate")]
[AllowAnonymous]
public class GateController : ControllerBase
{
    public const string SignInRateLimitPolicy = "gate-signin";

    /// <summary>The raw request line nginx forwards with the check ($request_uri).</summary>
    public const string OriginalUriHeader = "X-Original-URI";

    private readonly IGateService _gate;
    private readonly ILogger<GateController> _logger;

    public GateController(IGateService gate, ILogger<GateController> logger)
    {
        _gate = gate;
        _logger = logger;
    }

    private string? GateCookieValue => Request.Cookies[GateCookieOptions.Name];

    /// <summary>
    /// 204 or 401 and NOTHING ELSE, with no body: auth_request turns any other status into a 500 for
    /// the visitor. So nothing here may throw past the catch — a fault is logged and answered 401 (the
    /// gate page, which also asks for a sign-in and says nothing about the fault).
    ///
    /// The 401 is written by hand: an [ApiController] turns Unauthorized() into a ProblemDetails body.
    /// </summary>
    [HttpGet("check")]
    [HttpHead("check")]
    public async Task<IActionResult> Check()
    {
        NoStore();
        try
        {
            // One header, or the path is not trusted: two would arrive joined with a comma.
            var originalUri = Request.Headers[OriginalUriHeader];
            if (GatePaths.IsExempt(originalUri.Count == 1 ? originalUri[0] : null)
                || await _gate.IsAllowedAsync(GateCookieValue, HttpContext.RequestAborted))
                return NoContent();
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "The Google sign-in check failed; answering 401.");
        }

        Response.StatusCode = StatusCodes.Status401Unauthorized;
        return new EmptyResult();
    }

    [HttpGet("config")]
    public async Task<IActionResult> GetConfig()
    {
        NoStore();
        return Ok(await _gate.GetConfigAsync(GateCookieValue));
    }

    /// <summary>
    /// Works whether the gate is on or off — Settings' "Test Google sign-in" uses it to prove the setup
    /// before anybody depends on it. A refusal keeps the cookie the browser already has.
    /// </summary>
    [HttpPost("google")]
    [EnableRateLimiting(SignInRateLimitPolicy)]
    public async Task<IActionResult> SignInWithGoogle([FromBody] GateGoogleSignInRequest? request)
    {
        NoStore();
        try
        {
            var result = await _gate.SignInAsync(
                request?.Credential,
                HttpContext.Connection.RemoteIpAddress?.ToString(),
                Request.Headers.UserAgent.ToString());

            Response.Headers.Append(HeaderNames.SetCookie, GateCookieOptions.SetCookie(result.CookieValue, result.Days));
            return Ok(new { email = result.Email, name = result.Name, days = result.Days });
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    [HttpPost("signout")]
    public IActionResult SignOutBrowser()
    {
        NoStore();
        Response.Headers.Append(HeaderNames.SetCookie, GateCookieOptions.Expired);
        return NoContent();
    }

    private void NoStore() => Response.Headers.CacheControl = "no-store";
}
