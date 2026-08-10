using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Model.Workflow;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Api.Controllers;

/// <summary>
/// Separations — resignation, termination, end of contract, retirement.
///
/// THE RULE THIS TYPE ENFORCES: the Operations manager prepares the settlement, and the Owner's final
/// sign-off is REFUSED while it is unprepared. That refusal is the point of the type — it is what
/// stops employment being ended with nobody having worked out what is owed — so it is surfaced
/// verbatim and never pre-empted by hiding a button.
///
/// AND WHAT A SIGNATURE DOES HERE IS IRREVERSIBLE. At final approval the employee's TerminationDate
/// is written and every remaining leave balance is paid out and zeroed from the ledger. Both are
/// idempotent in SQL, and neither can be undone from this application — which the UI is required to
/// say plainly before anybody signs.
/// </summary>
[ApiController]
[Route("api/separations")]
[Authorize]
public class SeparationsController : ControllerBase
{
    private readonly ISeparationService _separations;
    private readonly IRequestService _requests;
    private readonly IWorkflowSupportService _support;
    private readonly ILiveNotifier _live;

    public SeparationsController(
        ISeparationService separations, IRequestService requests,
        IWorkflowSupportService support, ILiveNotifier live)
    {
        _separations = separations;
        _requests = requests;
        _support = support;
        _live = live;
    }

    /// <summary>
    /// The figures the form shows BEFORE anyone commits: service, the notice tier and any shortfall,
    /// a provisional indemnity where a basic is on file, and the leave still on the ledger.
    ///
    /// Reads nothing and changes nothing — the dates are hypotheses being tried out, which is why
    /// they are query parameters and why both are optional. Gated on EMP_VIEW: it exposes somebody's
    /// pay and service, which is not a self-service fact.
    /// </summary>
    [HttpGet("context")]
    [HasPermission("EMP_VIEW")]
    public async Task<IActionResult> GetContext(
        [FromQuery] int employeeId,
        [FromQuery] DateTime? lastWorkingDate,
        [FromQuery] DateTime? noticeGivenDate)
    {
        var context = await _separations.GetContextAsync(employeeId, lastWorkingDate, noticeGivenDate);
        return context.Header is null ? NotFound(new { error = "Employee not found." }) : Ok(context);
    }

    /// <summary>
    /// Raises one. REQUEST_RAISE_SELF is the floor; the service enforces WHO it may be raised FOR,
    /// which is the line between resigning (yourself) and terminating somebody (needs the extra
    /// permission).
    /// </summary>
    [HttpPost]
    [HasPermission("REQUEST_RAISE_SELF")]
    public async Task<IActionResult> Create([FromBody] SeparationCreateRequest request)
    {
        var me = await _support.GetEmployeeByUserIdAsync(User.UserId());
        var caller = new SeparationCaller(
            User.UserId(), me?.EmployeeId, User.HasPermission("REQUEST_RAISE_OTHERS"));

        try
        {
            var created = await _separations.CreateAsync(request, caller);
            if (created is null)
                return BadRequest(new { error = "The request could not be created." });

            // A raised separation is waiting on its first approver THIS MOMENT. Without this the
            // request only reached their To-handle when they happened to reload — which is the whole
            // class of bug this signal exists to prevent.
            await _live.NotifyAsync("workflow", "dashboard");
            return Ok(created);
        }
        catch (WorkflowException ex)
        {
            // "This employee already has a termination date on file." and the in-progress guard both
            // reach the user unchanged — each names the exact reason this cannot proceed.
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>
    /// Saves the preparer's figures and returns them with the total the PROCEDURE computes — so the
    /// screen never has to agree with the server about what the settlement comes to.
    ///
    /// WHO MAY PREPARE: the approver at the current step, or HR. The first half is answered by the
    /// engine itself (usp_Step_GetAvailableDecisions returns nothing to somebody whose step it is
    /// not) rather than by a second rule that could drift from it; the second is EMP_EDIT, the
    /// people-record permission, because the paperwork is HR's work whatever the chain says.
    ///
    /// Once the request closes the procedure refuses regardless of who is asking.
    /// </summary>
    [HttpPut("{id:int}/settlement")]
    public async Task<IActionResult> SetSettlement(int id, [FromBody] SeparationSettlementRequest request)
    {
        var mayEdit = User.HasPermission("EMP_EDIT");
        if (!mayEdit)
        {
            var me = await _support.GetEmployeeByUserIdAsync(User.UserId());
            var caller = new RequestCaller(User.UserId(), me?.EmployeeId, User.HasPermission("REQUEST_VIEW_ALL"));
            try
            {
                var decisions = await _requests.GetAvailableDecisionsAsync(id, caller);
                mayEdit = decisions.Any();
            }
            catch (WorkflowException ex)
            {
                return StatusCode(ex.StatusCode, new { error = ex.Message });
            }
        }

        try
        {
            var saved = await _separations.SetSettlementAsync(id, User.UserId(), request, mayEdit);
            if (saved is null) return NotFound();

            // The settlement is what UNBLOCKS the final sign-off. The Owner sitting on the request
            // page is looking at the refusal that says it is unprepared; preparing it changes what
            // they can do, so they must be told rather than left to discover it by reloading.
            await _live.NotifyAsync("workflow", "dashboard");
            return Ok(saved);
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>
    /// THE TYPED APPROVAL, because the closing signature is refused on an unprepared settlement and,
    /// once given, ends the employment and clears the leave ledger.
    ///
    /// Needs no permission — the database decides who may act at the current step.
    /// </summary>
    [HttpPost("{id:int}/decide")]
    public async Task<IActionResult> Decide(int id, [FromBody] SeparationDecideRequest request)
    {
        try
        {
            var result = await _separations.DecideAsync(id, User.UserId(), request);
            if (result is null) return NotFound();

            // The final approval ENDS THE EMPLOYMENT and zeroes the leave ledger, so this is not
            // only a request moving on: headcount, staffing and leave balances all just changed.
            // 'hr' is signalled for the same reason, ahead of any page subscribing to it.
            await _live.NotifyAsync("workflow", "dashboard", "hr");
            return Ok(result);
        }
        catch (WorkflowException ex)
        {
            // "The settlement has not been prepared. Enter the final figures before signing off."
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>Everything the panel and the printed document need, in one row. 404 when the request is not a separation.</summary>
    [HttpGet("{id:int}/payload")]
    public async Task<IActionResult> GetPayload(int id)
    {
        var payload = await _separations.GetPayloadAsync(id);
        return payload is null ? NotFound() : Ok(payload);
    }
}
