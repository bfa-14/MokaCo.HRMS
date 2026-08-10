using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Model.Workflow;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Api.Controllers;

/// <summary>
/// Salary advances raised as REQUESTS — money lent against future pay, with a chain behind it.
///
/// THIS IS NOW THE ONLY DOOR: payroll.usp_Advance_Create refuses and points here, so the ledger row
/// payroll recovers against is written once, by the final approval, and never by a form.
///
/// The type differs from the payroll adjustment in who raises it. An adjustment is HR's instrument,
/// always about somebody else. An advance is normally asked for BY the person who needs it — so the
/// raise-for-others check on the service does real work here, and REQUEST_RAISE_SELF is the right
/// floor on the route.
///
/// DECISIONS CARRY TWO FIGURES: how much is lent, and how fast it comes back. The approver signs
/// both, each signature may only tighten what the last one allowed, and the procedure keeps the
/// monthly deduction inside the approved amount — so cutting a 300 advance to 200 cannot leave a
/// 300/month schedule behind it.
/// </summary>
[ApiController]
[Route("api/salary-advance-requests")]
[Authorize]
public class SalaryAdvanceRequestsController : ControllerBase
{
    private readonly ISalaryAdvanceService _advances;
    private readonly IWorkflowSupportService _support;

    private readonly ILiveNotifier _live;

    public SalaryAdvanceRequestsController(
        ISalaryAdvanceService advances, IWorkflowSupportService support, ILiveNotifier live)
    {
        _advances = advances;
        _support = support;
        _live = live;
    }

    /// <summary>
    /// Asks for an advance. The refusal people meet most is the one-at-a-time rule — an employee
    /// still repaying, or with a request already in flight, cannot open a second — and it arrives
    /// with the procedure's own sentence.
    /// </summary>
    [HttpPost]
    [HasPermission("REQUEST_RAISE_SELF")]
    public async Task<IActionResult> Create([FromBody] SalaryAdvanceCreateRequest request)
    {
        var me = await _support.GetEmployeeByUserIdAsync(User.UserId());
        var caller = new SalaryAdvanceCaller(
            User.UserId(),
            me?.EmployeeId,
            User.HasPermission("REQUEST_RAISE_OTHERS"));

        try
        {
            var created = await _advances.CreateAsync(request, caller);
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
    /// THE TYPED APPROVAL: the final signature writes the advance payroll will recover. Approving
    /// through the generic endpoint would close the request and lend nobody anything.
    ///
    /// The approved amount is required; the monthly deduction is optional, and omitting it means
    /// "keep the standing schedule" rather than "no deduction" — the procedure carries it over and
    /// clamps it. READ THE RESPONSE for both figures: when the caller leaves the monthly out, or
    /// states one the approved amount cannot support, what comes back is what will actually be
    /// deducted, and it is not necessarily what was sent.
    ///
    /// Needs no permission — the database decides who may act at the current step.
    /// </summary>
    [HttpPost("{id:int}/decide")]
    public async Task<IActionResult> Decide(int id, [FromBody] SalaryAdvanceDecideRequest request)
    {
        try
        {
            var result = await _advances.DecideAsync(id, User.UserId(), request);
            if (result is null) return NotFound();

            // The final signature writes the advance the payroll recovers against, so the advances
            // ledger goes stale as well as the request itself.
            await _live.NotifyAsync("workflow", "payroll", "dashboard");
            return Ok(result);
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>
    /// The payload: the ask, and then the LIVE recovery state — remaining balance and settled flag
    /// come from the ledger row itself, so a request approved months ago shows what is still owed
    /// today rather than what was borrowed then.
    /// </summary>
    [HttpGet("{id:int}/payload")]
    public async Task<IActionResult> GetPayload(int id)
    {
        var payload = await _advances.GetPayloadAsync(id);
        return payload is null ? NotFound() : Ok(payload);
    }
}
