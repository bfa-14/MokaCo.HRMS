using Microsoft.AspNetCore.Mvc;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Services.Attendance;

namespace MokaCo.HRMS.Api.Controllers;

/// <summary>
/// Shift definitions — the thing that gives "late", "a full day" and "overtime" a meaning.
/// Anyone with ATTENDANCE_VIEW may read them; changing one changes how future days are judged, so
/// that needs ATTENDANCE_MANAGE.
/// </summary>
[ApiController]
[Route("api/shifts")]
public class ShiftsController : ControllerBase
{
    private readonly IShiftService _shifts;
    private readonly ILiveNotifier _live;

    public ShiftsController(IShiftService shifts, ILiveNotifier live)
    {
        _shifts = shifts;
        _live = live;
    }

    [HttpGet]
    [HasPermission("ATTENDANCE_VIEW")]
    public async Task<IActionResult> GetAll() => Ok(await _shifts.GetAllAsync());

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

        var id = await _shifts.CreateAsync(request);
        await _live.NotifyAsync("attendance", "dashboard");
        return CreatedAtAction(nameof(GetAll), new { id }, new { shiftId = id });
    }

    [HttpPut("{id:int}")]
    [HasPermission("ATTENDANCE_MANAGE")]
    public async Task<IActionResult> Update(int id, [FromBody] ShiftUpdateRequest request)
    {
        if (request.EndTime < request.StartTime && !request.CrossesMidnight)
            return BadRequest(new { error = "This shift ends before it starts. Tick 'crosses midnight' if it is an overnight shift." });

        await _shifts.UpdateAsync(id, request);
        // Shift times decide what counts as late and as overtime on every day rostered to them.
        await _live.NotifyAsync("attendance", "dashboard");
        return NoContent();
    }
}
