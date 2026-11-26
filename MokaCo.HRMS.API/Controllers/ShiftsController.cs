using Microsoft.AspNetCore.Mvc;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Services.Attendance;

namespace MokaCo.HRMS.Api.Controllers;

/// <summary>
/// Shift definitions — the thing that gives "late", "a full day" and "overtime" a meaning.
/// Anyone with ATTENDANCE_VIEW may read them; changing one changes how days are judged, so
/// that needs ATTENDANCE_MANAGE. A shift's hours are DATED (script 117): PUT takes the day new hours start
/// (and optionally the day they end - the hours before then come back), GET {id}/hours is the history,
/// DELETE {id}/hours/{shiftHoursId} takes one change back. GET {id}/changes is the change log (script 122): every
/// change to the shift, with who made it and the before and after, kept for good.
/// </summary>
[ApiController]
[Route("api/shifts")]
// No class-level permission: it would AND with every action, and the list is read by the employee request forms
// (ATTENDANCE_VIEW or REQUEST_RAISE_SELF, checked in GetAll). Every write carries ATTENDANCE_MANAGE itself.
[Microsoft.AspNetCore.Authorization.Authorize]
public class ShiftsController : ControllerBase
{
    private readonly IShiftService _shifts;
    private readonly ILiveNotifier _live;

    public ShiftsController(IShiftService shifts, ILiveNotifier live)
    {
        _shifts = shifts;
        _live = live;
    }

    /// <summary>The shifts: ATTENDANCE_VIEW, or REQUEST_RAISE_SELF - the availability-change form names them.</summary>
    [HttpGet]
    public async Task<IActionResult> GetAll()
        => User.MayReadReference("ATTENDANCE_VIEW") ? Ok(await _shifts.GetAllAsync()) : Forbid();

    [HttpPost]
    [HasPermission("ATTENDANCE_MANAGE")]
    public async Task<IActionResult> Create([FromBody] ShiftCreateRequest request)
    {
        if (request.EndTime == request.StartTime)
            return BadRequest(new { error = "A shift cannot start and end at the same time." });

        // An overnight shift is legitimate, but it MUST be declared — otherwise its length computes
        // as negative and everyone on it looks like they worked a minus number of hours.
        if (request.EndTime < request.StartTime && !request.CrossesMidnight)
            return BadRequest(new { error = "This shift ends before it starts. Tick 'crosses midnight' if it is an overnight shift." });

        var id = await _shifts.CreateAsync(request, User.UserId());
        await _live.NotifyAsync("attendance", "dashboard");
        return CreatedAtAction(nameof(GetAll), new { id }, new { shiftId = id });
    }

    [HttpPut("{id:int}")]
    [HasPermission("ATTENDANCE_MANAGE")]
    public async Task<IActionResult> Update(int id, [FromBody] ShiftUpdateRequest request)
    {
        // The same checks as Create. Script 117: the hours of a shift that has been worked change FROM A DAY
        // (EffectiveFrom; today when none is sent), never for the days before it - a paid day keeps its hours (409).
        if (request.EndTime == request.StartTime)
            return BadRequest(new { error = "A shift cannot start and end at the same time." });

        if (request.EndTime < request.StartTime && !request.CrossesMidnight)
            return BadRequest(new { error = "This shift ends before it starts. Tick 'crosses midnight' if it is an overnight shift." });

        await _shifts.UpdateAsync(id, request, User.UserId());
        // Shift times decide what counts as late and as overtime on every day rostered to them.
        await _live.NotifyAsync("attendance", "dashboard");
        return NoContent();
    }

    /// <summary>The shift's hours over time, oldest first: each row with the days it applies to.</summary>
    [HttpGet("{id:int}/hours")]
    [HasPermission("ATTENDANCE_VIEW")]
    public async Task<IActionResult> GetHours(int id) => Ok(await _shifts.GetHoursAsync(id));

    /// <summary>
    /// The shift's change log, newest first: created, hours changed or taken back, renamed, switched off or on, and the
    /// days a change could not work out again. The same permission as the hours history.
    /// </summary>
    [HttpGet("{id:int}/changes")]
    [HasPermission("ATTENDANCE_VIEW")]
    public async Task<IActionResult> GetChanges(int id) => Ok(await _shifts.GetChangesAsync(id));

    /// <summary>Takes one change of hours back (not the shift's first hours); the days it covered are derived again.</summary>
    [HttpDelete("{id:int}/hours/{shiftHoursId:int}")]
    [HasPermission("ATTENDANCE_MANAGE")]
    public async Task<IActionResult> DeleteHours(int id, int shiftHoursId)
    {
        var rows = await _shifts.GetHoursAsync(id);
        if (rows.All(r => r.ShiftHoursId != shiftHoursId))
            return NotFound(new { error = "That change of hours was not found for this shift." });

        var result = await _shifts.DeleteHoursAsync(shiftHoursId, User.UserId());
        await _live.NotifyAsync("attendance", "dashboard");
        return Ok(result);
    }
}
