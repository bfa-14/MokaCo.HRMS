using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Model.Workflow;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Api.Controllers;

/// <summary>
/// New-hire onboarding — the hire decision and the paperwork that must follow it.
///
/// THIS TYPE IS SHAPED DIFFERENTLY FROM THE OTHERS, in two ways that the UI has to match:
///   • There is no employee. The candidate is nobody in the system at submit time; the hr.EMPLOYEE
///     record is CREATED by the first approval, and its id comes back on that decision.
///   • The last approval is REFUSED while any required checklist item is undone, with a message
///     naming every outstanding one. That refusal is the point of the type — it is what stops a hire
///     being signed off with no contract on file — so it is surfaced verbatim and never pre-empted.
/// </summary>
[ApiController]
[Route("api/onboardings")]
[Authorize]
public class OnboardingsController : ControllerBase
{
    private readonly IOnboardingService _onboardings;
    private readonly IRequestService _requests;
    private readonly IWorkflowSupportService _support;

    public OnboardingsController(
        IOnboardingService onboardings, IRequestService requests, IWorkflowSupportService support)
    {
        _onboardings = onboardings;
        _requests = requests;
        _support = support;
    }

    /// <summary>
    /// Raises a hire. REQUEST_RAISE_SELF is the floor, as for every other type.
    ///
    /// There is deliberately NO raise-for-others check: an onboarding names a candidate, not an
    /// existing employee, so there is nobody to raise it on behalf of. The procedure takes the
    /// requester from the token.
    /// </summary>
    [HttpPost]
    [HasPermission("REQUEST_RAISE_SELF")]
    public async Task<IActionResult> Create([FromBody] OnboardingCreateRequest request)
    {
        try
        {
            var created = await _onboardings.CreateAsync(request, User.UserId());
            return created is null ? BadRequest(new { error = "The request could not be created." }) : Ok(created);
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>
    /// THE TYPED APPROVAL, because two things happen here that the engine knows nothing about: the
    /// employee record is created at the hire decision, and the closing signature is refused while
    /// required checklist items are outstanding.
    ///
    /// Needs no permission — the database decides who may act at the current step.
    /// </summary>
    [HttpPost("{id:int}/decide")]
    public async Task<IActionResult> Decide(int id, [FromBody] OnboardingDecideRequest request)
    {
        try
        {
            var result = await _onboardings.DecideAsync(id, User.UserId(), request);
            return result is null ? NotFound() : Ok(result);
        }
        catch (WorkflowException ex)
        {
            // "The onboarding is not finished. Still outstanding: Tax registration; Bank details
            // recorded." — the message names the work, so it reaches the user unchanged.
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>
    /// Ticks or unticks one checklist item and returns the WHOLE list, already in order.
    ///
    /// WHO MAY TICK: the approver at the current step, or HR. The first half is answered by the
    /// engine itself — usp_Step_GetAvailableDecisions returns nothing to somebody whose step it is
    /// not — rather than by a second rule here that could drift from it. The second half is EMP_EDIT,
    /// the people-record permission (Admin, HR, Owner), because the paperwork is HR's work whatever
    /// the chain says and they must not be locked out of it between steps.
    ///
    /// Once the request closes, the procedure refuses regardless of who is asking.
    /// </summary>
    [HttpPost("{id:int}/tasks/{code}")]
    public async Task<IActionResult> SetTask(int id, string code, [FromBody] OnboardingSetTaskRequest request)
    {
        var mayEdit = User.HasPermission("EMP_EDIT");
        if (!mayEdit)
        {
            var me = await _support.GetEmployeeByUserIdAsync(User.UserId());
            var caller = new RequestCaller(User.UserId(), me?.EmployeeId, User.HasPermission("REQUEST_VIEW_ALL"));
            try
            {
                // A non-empty set is the engine's own "this step is yours".
                var decisions = await _requests.GetAvailableDecisionsAsync(id, caller);
                mayEdit = decisions.Any();
            }
            catch (WorkflowException ex)
            {
                // "You do not have access to this request." — the visibility refusal, kept as it is.
                return StatusCode(ex.StatusCode, new { error = ex.Message });
            }
        }

        try
        {
            return Ok(await _onboardings.SetTaskAsync(id, code, request, User.UserId(), mayEdit));
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>
    /// The header and the checklist, as two halves of one payload. 404 when the request is not an
    /// onboarding.
    /// </summary>
    [HttpGet("{id:int}/payload")]
    public async Task<IActionResult> GetPayload(int id)
    {
        var payload = await _onboardings.GetPayloadAsync(id);
        return payload.Header is null ? NotFound() : Ok(payload);
    }
}
