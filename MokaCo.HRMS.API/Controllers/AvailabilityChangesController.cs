using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Model.Workflow;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Api.Controllers;

/// <summary>
/// Standing availability changes — a rewrite of somebody's DEFAULT WEEK from a date onwards.
///
/// Not an absence: leave takes named days off, this changes which weekdays the person works at all,
/// and at final approval it rewrites attendance.EMPLOYEE_SHIFT_PATTERN. That is why it goes through
/// this typed endpoint rather than the engine's generic /approve — approving through the engine alone
/// would approve a request that never changed anything.
///
/// It does NOT rewrite roster days already published past the effective date. Those are reported as
/// conflicts, and fixing them is a deliberate act on the roster.
/// </summary>
[ApiController]
[Route("api/availability-changes")]
[Authorize]
public class AvailabilityChangesController : ControllerBase
{
    private readonly IAvailabilityService _availability;
    private readonly IWorkflowSupportService _support;
    private readonly ILiveNotifier _live;

    public AvailabilityChangesController(
        IAvailabilityService availability, IWorkflowSupportService support, ILiveNotifier live)
    {
        _availability = availability;
        _support = support;
        _live = live;
    }

    /// <summary>
    /// Raises one. REQUEST_RAISE_SELF is the floor — the same permission every other request type
    /// needs — and the service enforces WHO it may be raised FOR, since the employee id is in the body.
    ///
    /// ONLY THE CHANGED DAYS ARE SENT. A day absent from the list is one nobody asked to change, and
    /// it stays exactly as it is when the pattern is rewritten.
    /// </summary>
    [HttpPost]
    [HasPermission("REQUEST_RAISE_SELF")]
    public async Task<IActionResult> Create([FromBody] AvailabilityCreateRequest request)
    {
        var me = await _support.GetEmployeeByUserIdAsync(User.UserId());
        var caller = new AvailabilityCaller(
            User.UserId(),
            me?.EmployeeId,
            User.HasPermission("REQUEST_RAISE_OTHERS"));

        try
        {
            var created = await _availability.CreateAsync(request, caller);
            if (created is null)
                return BadRequest(new { error = "The request could not be created." });

            await _live.NotifyAsync("workflow", "dashboard");
            return Ok(created);
        }
        catch (WorkflowException ex)
        {
            // VERBATIM. The four refusals here each say exactly what to do — a past effective date, a
            // whole week marked unavailable, an employee who already has one waiting, an unknown
            // shift — and rewording any of them would lose the instruction.
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>
    /// THE TYPED APPROVAL, because closing this request Approved is what rewrites the weekly pattern.
    /// The procedure guards on AppliedAt so it happens exactly once.
    ///
    /// `days` optionally RESTATES the request — a full replacement set, and only at a step whose
    /// CanAdjust allows it; the engine refuses it otherwise. Omit it to approve as asked.
    ///
    /// Needs no permission: the database decides who may act at the current step, and its refusal is
    /// surfaced with the message intact.
    /// </summary>
    [HttpPost("{id:int}/decide")]
    public async Task<IActionResult> Decide(int id, [FromBody] AvailabilityDecideRequest request)
    {
        try
        {
            var result = await _availability.DecideAsync(id, User.UserId(), request);
            if (result is null) return NotFound();

            // The final approval REWRITES THE WEEKLY PATTERN, so this is not only a request closing:
            // the roster the attendance screens draw from has changed underneath them.
            await _live.NotifyAsync("workflow", "attendance", "dashboard");
            return Ok(result);
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>
    /// The header and the requested days, as two halves of one payload. 404 when the request is not
    /// an availability change.
    /// </summary>
    [HttpGet("{id:int}/payload")]
    public async Task<IActionResult> GetPayload(int id)
    {
        var payload = await _availability.GetPayloadAsync(id);
        return payload.Header is null ? NotFound() : Ok(payload);
    }

    /// <summary>
    /// Rostered days that contradict the change: this person is scheduled on a weekday they asked to
    /// drop, on or after the effective date.
    ///
    /// An EMPTY LIST IS THE GOOD ANSWER, and a normal one. Rows here keep their shifts — approving
    /// rewrites the template, not days somebody already published — so this is the manual fix list.
    /// </summary>
    [HttpGet("{id:int}/conflicts")]
    public async Task<IActionResult> GetConflicts(int id)
        => Ok(await _availability.GetConflictsAsync(id));
}
