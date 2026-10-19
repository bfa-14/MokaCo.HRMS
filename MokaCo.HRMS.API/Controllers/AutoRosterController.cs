using Microsoft.AspNetCore.Mvc;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Services.Attendance;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Api.Controllers;

/// <summary>
/// The auto-roster (6/5 rhythm, fair weekends) — docs/AUTO_ROSTER.md §4.
///
/// One action per branch and month drafts the roster; the draft is reviewed and edited in the roster
/// grid and saved in one atomic call. NOTHING IS SAVED ON ITS OWN: preview writes nothing and tells
/// no live screen anything, and only a successful commit moves the attendance screens and the
/// dashboard. The month is then submitted for approval exactly as before.
///
/// Reading is ATTENDANCE_VIEW; every write is ATTENDANCE_MANAGE, as on RosterController. Branch scope
/// (EMP_VIEW_ALL, or the branch's manager) is decided by the procedures, which answer a 403.
/// </summary>
[ApiController]
[Route("api/roster/auto")]
public class AutoRosterController : ControllerBase
{
    private readonly IAutoRosterService _auto;
    private readonly ILiveNotifier _live;

    public AutoRosterController(IAutoRosterService auto, ILiveNotifier live)
    {
        _auto = auto;
        _live = live;
    }

    /// <summary>The drawer's opening state: settings, staff with their rhythm, staffing, holidays, active shifts, last parameters.</summary>
    [HttpGet("setup")]
    [HasPermission("ATTENDANCE_VIEW")]
    public async Task<IActionResult> GetSetup([FromQuery] int branchId, [FromQuery] string? month)
    {
        try
        {
            return Ok(await _auto.GetSetupAsync(branchId, month, User.UserId()));
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>
    /// The draft. A POST because the request carries the drawer's choices and the manager's draft
    /// edits, but it WRITES NOTHING — so it never notifies, however often Regenerate is pressed.
    /// </summary>
    [HttpPost("preview")]
    [HasPermission("ATTENDANCE_MANAGE")]
    public async Task<IActionResult> Preview([FromBody] AutoRosterRequest request)
    {
        try
        {
            return Ok(await _auto.PreviewAsync(request, User.UserId()));
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>
    /// Saves the reviewed draft. A draft that breaks a rule is a 400 that also carries the issues, so
    /// the preview card can point at the cells; a roster that moved since the preview, or a pinned
    /// day, is the procedure's 409. Live screens are told only when something was saved.
    /// </summary>
    [HttpPost("commit")]
    [HasPermission("ATTENDANCE_MANAGE")]
    public async Task<IActionResult> Commit([FromBody] AutoRosterCommitRequest request)
    {
        try
        {
            var result = await _auto.CommitAsync(request, User.UserId());
            await _live.NotifyAsync("attendance", "dashboard");
            return Ok(result);
        }
        catch (AutoRosterRefusedException ex)
        {
            return BadRequest(new { error = ex.Message, issues = ex.Issues });
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>The grid's overlay: which saved days are pinned, and which still hold what the generator wrote.</summary>
    [HttpGet("cells")]
    [HasPermission("ATTENDANCE_VIEW")]
    public async Task<IActionResult> GetCells([FromQuery] int branchId, [FromQuery] DateOnly from, [FromQuery] DateOnly to)
    {
        try
        {
            return Ok(await _auto.GetCellsAsync(branchId, from, to, User.UserId()));
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>"Keep when regenerating". Writes no roster row, but the grid shows the pin, so the attendance screens hear of it.</summary>
    [HttpPut("pin")]
    [HasPermission("ATTENDANCE_MANAGE")]
    public async Task<IActionResult> SetPin([FromBody] RosterPinRequest request)
    {
        try
        {
            await _auto.SetPinAsync(request, User.UserId());
            await _live.NotifyAsync("attendance");
            return NoContent();
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>Minimum / target on duty per weekday for one branch. Replaces the branch's whole set; an empty list clears it.</summary>
    [HttpPut("staffing")]
    [HasPermission("ATTENDANCE_MANAGE")]
    public async Task<IActionResult> SaveStaffing([FromQuery] int branchId, [FromBody] List<StaffingRequirementDto> rows)
    {
        try
        {
            await _auto.SaveStaffingAsync(branchId, rows, User.UserId());
            await _live.NotifyAsync("attendance");
            return NoContent();
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>The drawer's staff list: on rotation, and optionally a new 6/5 anchor ("this week is a 5-day week").</summary>
    [HttpPut("rhythm")]
    [HasPermission("ATTENDANCE_MANAGE")]
    public async Task<IActionResult> SaveRhythm([FromBody] List<RosterRhythmDto> rows)
    {
        try
        {
            await _auto.SaveRhythmAsync(rows, User.UserId());
            await _live.NotifyAsync("attendance");
            return NoContent();
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }
}
