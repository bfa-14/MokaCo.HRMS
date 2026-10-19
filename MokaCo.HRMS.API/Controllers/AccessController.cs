using Microsoft.AspNetCore.Mvc;
using Microsoft.Net.Http.Headers;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Model.Security;
using MokaCo.HRMS.Services.Security.Gate;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Api.Controllers;

/// <summary>
/// Settings → Google sign-in — docs/GOOGLE_SIGNIN_GATE.md §3: the switch, the client ID and the days,
/// who may open the HRMS, the extra Google accounts, the sign-in log and "sign everyone out".
///
/// Every action is ACCESS_MANAGE (Admin and Owner). The four Google* settings change ONLY here — the
/// generic PUT api/settings/{key} refuses them — because only this path carries the no-lock-out guard:
/// the switch goes on only for a caller whose own browser has already passed Google sign-in.
///
/// The caller's gate cookie travels with these calls (same host, Path=/), which is how the guards and
/// "Verified in this browser as …" know about it: no change made here may shut out the browser making it.
/// </summary>
[ApiController]
[Route("api/access")]
public class AccessController : ControllerBase
{
    private readonly IGateService _gate;

    public AccessController(IGateService gate) => _gate = gate;

    private string? GateCookieValue => Request.Cookies[GateCookieOptions.Name];

    /// <summary>The whole tab: settings, this browser's status, people, extra addresses, the last 100 attempts.</summary>
    [HttpGet]
    [HasPermission("ACCESS_MANAGE")]
    public async Task<IActionResult> Get()
    {
        try
        {
            return Ok(await _gate.GetAdminAsync(GateCookieValue, User.UserId()));
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>On needs the client ID and a verified caller (409 otherwise); the procedure checks the ID's shape and the days.</summary>
    [HttpPut("settings")]
    [HasPermission("ACCESS_MANAGE")]
    public async Task<IActionResult> SaveSettings([FromBody] GateSettingsRequest request)
    {
        try
        {
            await _gate.SaveSettingsAsync(request, GateCookieValue, User.UserId());
            return NoContent();
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>
    /// Switches Google sign-in off (or back on) for one employee. Blocking yourself is refused: by the
    /// procedure for the employee linked to your login, by the service for the one this browser passes as.
    /// </summary>
    [HttpPut("people/{employeeId:int}/blocked")]
    [HasPermission("ACCESS_MANAGE")]
    public async Task<IActionResult> SetBlocked(int employeeId, [FromBody] GateBlockedRequest request)
    {
        try
        {
            await _gate.SetBlockedAsync(employeeId, request.Blocked, GateCookieValue, User.UserId());
            return NoContent();
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    [HttpPost("extras")]
    [HasPermission("ACCESS_MANAGE")]
    public async Task<IActionResult> AddExtraEmail([FromBody] GateExtraEmailRequest request)
    {
        try
        {
            var id = await _gate.AddExtraEmailAsync(request, User.UserId());
            return CreatedAtAction(nameof(Get), null, new { gateExtraEmailId = id });
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>The address this browser signed in with cannot be switched off or changed while the gate is on (409).</summary>
    [HttpPut("extras/{id:int}")]
    [HasPermission("ACCESS_MANAGE")]
    public async Task<IActionResult> UpdateExtraEmail(int id, [FromBody] GateExtraEmailRequest request)
    {
        try
        {
            await _gate.UpdateExtraEmailAsync(id, request, GateCookieValue, User.UserId());
            return NoContent();
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>Nor removed (409).</summary>
    [HttpDelete("extras/{id:int}")]
    [HasPermission("ACCESS_MANAGE")]
    public async Task<IActionResult> DeleteExtraEmail(int id)
    {
        try
        {
            await _gate.DeleteExtraEmailAsync(id, GateCookieValue, User.UserId());
            return NoContent();
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>Ends every gate cookie; the caller's own, if it was valid, comes back with the new epoch.</summary>
    [HttpPost("signout-everyone")]
    [HasPermission("ACCESS_MANAGE")]
    public async Task<IActionResult> SignOutEveryone()
    {
        try
        {
            var result = await _gate.SignOutEveryoneAsync(GateCookieValue, User.UserId());
            if (result.CookieValue is not null)
                Response.Headers.Append(HeaderNames.SetCookie, GateCookieOptions.SetCookie(result.CookieValue, result.Days));
            return Ok(new { epoch = result.Epoch });
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }
}
