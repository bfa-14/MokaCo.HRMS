using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Model.Workflow;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Api.Controllers;

/// <summary>
/// Overtime — hours beyond the scheduled shift, approved in advance and paid at a multiplier.
///
/// Reading and acting on the request itself stays on /api/requests; only the typed payload, the
/// typed approval and the attendance sweep are here.
/// </summary>
[ApiController]
[Route("api/overtime")]
[Authorize]
public class OvertimeController : ControllerBase
{
    private readonly IOvertimeService _overtime;
    private readonly IWorkflowSupportService _support;

    public OvertimeController(IOvertimeService overtime, IWorkflowSupportService support)
    {
        _overtime = overtime;
        _support = support;
    }

    /// <summary>
    /// Raises an overtime request. REQUEST_RAISE_SELF is the floor; the service enforces WHO it may
    /// be raised FOR, since the employee id travels in the body.
    ///
    /// The response carries the roster context for that day — the shift, or the fact that there was
    /// none — so the form can confirm what was asked for against what was scheduled.
    /// </summary>
    [HttpPost]
    [HasPermission("REQUEST_RAISE_SELF")]
    public async Task<IActionResult> Create([FromBody] OvertimeCreateRequest request)
    {
        var me = await _support.GetEmployeeByUserIdAsync(User.UserId());
        var caller = new OvertimeCaller(
            User.UserId(),
            me?.EmployeeId,
            User.HasPermission("REQUEST_RAISE_OTHERS"));

        try
        {
            var created = await _overtime.CreateAsync(request, caller);
            return created is null ? BadRequest(new { error = "The request could not be created." }) : Ok(created);
        }
        catch (WorkflowException ex)
        {
            // Verbatim — the past-date refusal is the signature message here and says exactly what to fix.
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>
    /// THE TYPED APPROVAL, because the granted MINUTES belong to the typed procedure: it bounds them
    /// at what was requested, and the payable figure later resolves to the lesser of what was
    /// approved and what attendance detected.
    ///
    /// Needs no permission — the database decides who may act at the current step and its refusal is
    /// surfaced as a 403 with the message intact.
    /// </summary>
    [HttpPost("{id:int}/decide")]
    public async Task<IActionResult> Decide(int id, [FromBody] OvertimeDecideRequest request)
    {
        try
        {
            var result = await _overtime.DecideAsync(id, User.UserId(), request);
            return result is null ? NotFound() : Ok(result);
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>
    /// The overtime payload. The worked/detected/payable figures are null until the day is processed
    /// — that is a real state ("awaiting the worked day"), not missing data.
    /// </summary>
    [HttpGet("{id:int}/payload")]
    public async Task<IActionResult> GetPayload(int id)
    {
        var payload = await _overtime.GetPayloadAsync(id);
        return payload is null ? NotFound() : Ok(payload);
    }

    /// <summary>
    /// Sweeps approved overtime into the attendance day it belongs to. Also run nightly at the end of
    /// attendance processing — exposed here so a day can be pushed through by hand. Idempotent.
    /// </summary>
    [HttpPost("apply-to-attendance")]
    [HasPermission("ATTENDANCE_MANAGE")]
    public async Task<IActionResult> ApplyToAttendance([FromBody] OvertimeApplyRequest? request)
        => Ok(await _overtime.ApplyToAttendanceAsync(request?.WorkDate));
}

/// <summary>Which day to sweep. Null sweeps every outstanding day.</summary>
public class OvertimeApplyRequest
{
    public DateTime? WorkDate { get; set; }
}
