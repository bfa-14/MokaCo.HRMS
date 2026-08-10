using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Data.SqlClient;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Model.Core;
using MokaCo.HRMS.Repository.Core;

namespace MokaCo.HRMS.Api.Controllers;

/// <summary>
/// System-wide operations. One endpoint, and it is the most destructive thing the application can
/// do, so everything about it is deliberate.
/// </summary>
[ApiController]
[Route("api/system")]
[Authorize]
public class SystemController : ControllerBase
{
    private readonly ISystemRepository _system;
    private readonly ILiveNotifier _live;

    public SystemController(ISystemRepository system, ILiveNotifier live)
    {
        _system = system;
        _live = live;
    }

    /// <summary>
    /// Deletes every request, attendance record and employee. Users, roles, chains, branches and
    /// leave policy remain.
    ///
    /// GATED ON SYSTEM_RESET, held by Admin and Owner alone. A permission rather than a role check
    /// because the token carries permission claims and no roles — and because the grant then stays
    /// visible on the role-permissions screen instead of being compiled in.
    ///
    /// THE CALLER IS NOT TRUSTED WITH ANY PART OF THE SAFETY. The arming flag and the exact phrase
    /// are both checked by the procedure, which returns before opening its transaction, so a refused
    /// call changes nothing. Its refusals come back verbatim: "System reset is not armed…" tells the
    /// user precisely what to do, and no rewording here could do better.
    ///
    /// The acting user comes from the TOKEN, never the body — a reset is signed by whoever is logged
    /// in, and the procedure refuses an unknown or inactive one.
    /// </summary>
    [HttpPost("reset")]
    [HasPermission("SYSTEM_RESET")]
    public async Task<IActionResult> Reset([FromBody] SystemResetRequest request)
    {
        try
        {
            var summary = await _system.ResetTestDataAsync(request.Confirm ?? string.Empty, User.UserId());
            // EVERY topic: this deletes and renumbers test data wholesale, so every open page is
            // showing rows that no longer exist.
            await _live.NotifyAsync("workflow", "payroll", "attendance", "hr", "dashboard");
            return Ok(summary);
        }
        catch (SqlException ex) when (ex.Number == 50000)
        {
            // Not armed, or the phrase does not match. Both are the user's to fix, and both leave
            // the data untouched — a 400 with the sentence intact.
            return BadRequest(new { error = ex.Message });
        }
    }
}
