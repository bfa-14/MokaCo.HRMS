using System.Security.Claims;
using Microsoft.AspNetCore.Mvc;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Services.Attendance;

namespace MokaCo.HRMS.Api.Controllers;

/// <summary>
/// Corrections to processed days — HR ONLY (ATTENDANCE_CORRECT), because every one of them changes
/// what somebody is paid.
///
/// A correction is a LOGGED change, not an edit. It records the old values, the new values, who
/// asked, who approved and why. The raw punches from the machine are NEVER overwritten, so "what the
/// device recorded" and "what HR concluded" both survive — which is the only reason a disputed
/// payslip can be settled a year later.
///
/// The pending queue is readable with ATTENDANCE_VIEW, because a pending correction means the
/// month's figures are about to change and payroll needs to see that.
/// </summary>
[ApiController]
[Route("api/attendance/corrections")]
public class AttendanceCorrectionsController : ControllerBase
{
    private readonly ICorrectionService _corrections;
    public AttendanceCorrectionsController(ICorrectionService corrections) => _corrections = corrections;

    private int CurrentUserId =>
        int.Parse(User.FindFirstValue(ClaimTypes.NameIdentifier) ?? User.FindFirstValue("sub")!);

    /// <summary>The queue. While anything sits here, payroll is blocked for that period.</summary>
    [HttpGet("pending")]
    [HasPermission("ATTENDANCE_VIEW")]
    public async Task<IActionResult> GetPending() => Ok(await _corrections.GetPendingAsync());

    [HttpGet("by-record/{attendanceId:long}")]
    [HasPermission("ATTENDANCE_VIEW")]
    public async Task<IActionResult> GetByRecord(long attendanceId)
        => Ok(await _corrections.GetByRecordAsync(attendanceId));

    /// <summary>Requests a change. The requester comes from the JWT, never from the body — a correction must name whoever actually asked for it.</summary>
    [HttpPost]
    [HasPermission("ATTENDANCE_CORRECT")]
    public async Task<IActionResult> Create([FromBody] CorrectionCreateRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.Reason))
            return BadRequest(new { error = "A reason is required — a correction without one is an unexplained change to somebody's pay." });

        var id = await _corrections.CreateAsync(request, CurrentUserId);
        return CreatedAtAction(nameof(GetPending), new { id }, new { correctionId = id });
    }

    /// <summary>
    /// Applies the new values and RECOMPUTES the day against the rostered shift, by exactly the same
    /// rules as any other day. It then marks the record manual, so tonight's processor run cannot
    /// quietly undo the decision.
    /// </summary>
    [HttpPost("{id:int}/approve")]
    [HasPermission("ATTENDANCE_CORRECT")]
    public async Task<IActionResult> Approve(int id)
    {
        var result = await _corrections.ApproveAsync(id, CurrentUserId);
        return result is null ? NotFound(new { error = "No pending correction with that id." }) : Ok(result);
    }

    [HttpPost("{id:int}/reject")]
    [HasPermission("ATTENDANCE_CORRECT")]
    public async Task<IActionResult> Reject(int id)
    {
        await _corrections.RejectAsync(id, CurrentUserId);
        return NoContent();
    }
}
