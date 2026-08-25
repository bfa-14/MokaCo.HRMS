using System.Security.Claims;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Data.SqlClient;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Services.HR;

namespace MokaCo.HRMS.Api.Controllers;

/// <summary>
/// THE YEARLY LEAVE OPENING — the only path by which entitlement reaches the ledger. One run grants
/// every eligible employee their entitlement for the year (pro-rated for anyone hired within it)
/// and settles what is left of the last one, carried forward or expired by the leave type's rule.
///
/// There is no monthly accrual any more, and no api/leave/accrual: entitlement is the tier grid on
/// the leave-policy page, and this is what turns it into movements. The grid itself is edited
/// through LeaveTypesController — the policy and the act of granting it stay separate.
/// </summary>
[ApiController]
[Route("api/leave")]
public class LeaveYearController : ControllerBase
{
    private readonly ILeaveYearService _leaveYear;
    private readonly ILiveNotifier _live;

    public LeaveYearController(ILeaveYearService leaveYear, ILiveNotifier live)
    {
        _leaveYear = leaveYear;
        _live = live;
    }

    private int CurrentUserId =>
        int.Parse(User.FindFirstValue(ClaimTypes.NameIdentifier) ?? User.FindFirstValue("sub")!);

    /// <summary>
    /// Opens the leave year, returning the procedure's own per-type summary of what it did.
    ///
    /// SAFE TO RUN TWICE. The procedure skips employees already opened for the year, so a repeat
    /// call reports zero employees rather than granting anyone a second entitlement — which is what
    /// makes this usable as a recovery path when a run is interrupted.
    ///
    /// LEAVE_POLICY_MANAGE, the same trust that sets the tier grid the entitlement comes from:
    /// whoever decides what a year is worth is who may grant it.
    /// </summary>
    [HttpPost("year-open")]
    [HasPermission("LEAVE_POLICY_MANAGE")]
    public async Task<IActionResult> OpenYear([FromQuery] int year)
    {
        // A typo'd year is worth catching before it reaches a procedure that would open one.
        if (year < 2000 || year > 2100)
            return BadRequest(new { error = "Year is out of range." });

        try
        {
            var summary = await _leaveYear.OpenAsync(year, CurrentUserId);
            // Every employee's balance moved at once, so every screen showing one is now stale.
            await _live.NotifyAsync("hr", "dashboard");
            return Ok(summary);
        }
        catch (SqlException ex) when (ex.Number == 50000)
        {
            // The procedure's own refusal — "leave year 2025 has not been opened yet", "the year is
            // already closed". That sentence names what to do next, so it travels verbatim.
            return BadRequest(new { error = ex.Message });
        }
    }
}
