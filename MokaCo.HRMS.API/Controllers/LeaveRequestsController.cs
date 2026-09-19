using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Model.Workflow;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Api.Controllers;

/// <summary>
/// Leave requests — the SECOND concrete request type, on the same shape as exit permissions. Raising
/// one submits it into the workflow engine; approving it through <c>decide</c> may grant fewer days
/// than were asked for and, at final approval, posts the usage to the leave ledger.
///
/// Reading and acting on the request itself (chain, notes, reject, hold, cancel) is NOT here — that
/// is the generic /api/requests surface, which knows nothing about leave. Only the typed payload and
/// the typed approval live here.
/// </summary>
[ApiController]
[Route("api/leave-requests")]
[Authorize]
public class LeaveRequestsController : ControllerBase
{
    private readonly ILeaveRequestService _leave;
    private readonly IWorkflowSupportService _support;
    private readonly ILiveNotifier _live;

    public LeaveRequestsController(
        ILeaveRequestService leave, IWorkflowSupportService support, ILiveNotifier live)
    {
        _leave = leave;
        _support = support;
        _live = live;
    }

    /// <summary>
    /// Raises a leave request. REQUEST_RAISE_SELF is the floor; the service enforces WHO it may be
    /// raised FOR, since the employee id travels in the body.
    ///
    /// THE OVERLAP REFUSAL comes back as a 400 with the database's own sentence, which names the
    /// clashing dates and their status. It is the whole value of the refusal — never replace it with
    /// a generic failure.
    /// </summary>
    /// <summary>
    /// "N working days" BEFORE the request is raised (D2): the same count the procedure will store — the employee's
    /// rostered working days in the range, less the public holidays of their branch; 0.5 for a half day. A user may
    /// ask about themselves; asking about somebody else needs REQUEST_RAISE_OTHERS, as raising for them does.
    /// </summary>
    [HttpGet("working-days")]
    [HasPermission("REQUEST_RAISE_SELF")]
    public async Task<IActionResult> GetWorkingDays(
        [FromQuery] int employeeId, [FromQuery] DateTime from, [FromQuery] DateTime to,
        [FromQuery] int? leaveTypeId = null, [FromQuery] string? halfDay = null)
    {
        if (from > to)
            return BadRequest(new { error = "The end date is before the start date." });

        var me = await _support.GetEmployeeByUserIdAsync(User.UserId());
        if (me?.EmployeeId != employeeId && !User.HasPermission("REQUEST_RAISE_OTHERS"))
            return Forbid();

        try
        {
            return Ok(await _leave.CountWorkingDaysAsync(employeeId, leaveTypeId, from, to, halfDay));
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    [HttpPost]
    [HasPermission("REQUEST_RAISE_SELF")]
    public async Task<IActionResult> Create([FromBody] LeaveRequestCreateRequest request)
    {
        var me = await _support.GetEmployeeByUserIdAsync(User.UserId());
        var caller = new LeaveRequestCaller(
            User.UserId(),
            me?.EmployeeId,
            User.HasPermission("REQUEST_RAISE_OTHERS"));

        try
        {
            var created = await _leave.CreateAsync(request, caller);
            if (created is null)
                return BadRequest(new { error = "The request could not be created." });

            await _live.NotifyAsync("workflow", "dashboard");
            return Ok(created);
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>
    /// THE TYPED APPROVAL. Approving a leave request goes through here rather than the generic
    /// /approve, because the granted day count belongs to the typed procedure — it bounds the figure
    /// at what was requested and posts the ledger movement exactly once, when the request closes.
    ///
    /// Needs no permission: the database decides whether this caller is the approver at the current
    /// step and refuses otherwise, and that refusal is surfaced as a 403 with its message intact.
    /// </summary>
    [HttpPost("{id:int}/decide")]
    public async Task<IActionResult> Decide(int id, [FromBody] LeaveRequestDecideRequest request)
    {
        try
        {
            var result = await _leave.DecideAsync(id, User.UserId(), request);
            if (result is null) return NotFound();

            // The final approval posts the ledger movement, so the leave balances on the dashboard
            // move with the request itself.
            await _live.NotifyAsync("workflow", "dashboard");
            return Ok(result);
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>The leave payload behind a request, with the employee's current balance for that type.</summary>
    [HttpGet("{id:int}/payload")]
    public async Task<IActionResult> GetPayload(int id)
    {
        var payload = await _leave.GetPayloadAsync(id);
        return payload is null ? NotFound() : Ok(payload);
    }
}
