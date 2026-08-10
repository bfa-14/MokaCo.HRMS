using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Model.Workflow;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Api.Controllers;

/// <summary>
/// Payroll adjustments raised as REQUESTS — a correction with a chain behind it.
///
/// THIS IS NOW THE ONLY DOOR. payroll.usp_Adjustment_Create refuses outright and points here, so
/// there is no second path by which money can be added to a payslip: HR states the claim, the Owner
/// signs it, and the FINAL approval is what writes the ledger row the next Generate consumes.
///
/// THE APPROVER SIGNS A FIGURE, not just an outcome. The decide body carries the approved amount,
/// and it is that number — not the amount originally claimed — that reaches the payslip. Each
/// signature may TIGHTEN what the one before it allowed and can never raise it, so a chain converges
/// downwards; granting more than an earlier approver did means rejecting and raising again.
///
/// THE LOCK IS CHECKED TWICE, at create and at the final approval, because a period can lock while
/// the request is in flight. The second refusal arrives BEFORE any signature is written, so the
/// request is left intact and can be rejected and re-raised for the next open period.
/// </summary>
[ApiController]
[Route("api/payroll-adjustment-requests")]
[Authorize]
public class PayrollAdjustmentRequestsController : ControllerBase
{
    private readonly IPayrollAdjustmentService _adjustments;
    private readonly IWorkflowSupportService _support;
    private readonly ILiveNotifier _live;

    public PayrollAdjustmentRequestsController(
        IPayrollAdjustmentService adjustments, IWorkflowSupportService support, ILiveNotifier live)
    {
        _adjustments = adjustments;
        _support = support;
        _live = live;
    }

    /// <summary>
    /// Raises the correction. REQUEST_RAISE_SELF is the floor; the service enforces WHO it may be
    /// raised FOR, since the employee id travels in the body.
    ///
    /// In practice this is always raised on somebody else's behalf — it is HR's instrument — so the
    /// caller will normally hold REQUEST_RAISE_OTHERS. The permission on the route is deliberately
    /// the low one: what may be raised, and for whom, is settled by the service and the chain, not by
    /// a second guess here.
    /// </summary>
    [HttpPost]
    [HasPermission("REQUEST_RAISE_SELF")]
    public async Task<IActionResult> Create([FromBody] PayrollAdjustmentCreateRequest request)
    {
        var me = await _support.GetEmployeeByUserIdAsync(User.UserId());
        var caller = new PayrollAdjustmentCaller(
            User.UserId(),
            me?.EmployeeId,
            User.HasPermission("REQUEST_RAISE_OTHERS"));

        try
        {
            var created = await _adjustments.CreateAsync(request, caller);
            if (created is null)
                return BadRequest(new { error = "The request could not be created." });

            // A new request appears in an approver's inbox and in the dashboard's counts. Signalled
            // only here, on the success path — a refusal changed nothing and must wake nobody.
            await _live.NotifyAsync("workflow", "dashboard");
            return Ok(created);
        }
        catch (WorkflowException ex)
        {
            // Verbatim — "The 2026-08 run is already approved and locked - target the next open
            // period instead." names both the problem and the fix.
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>
    /// THE TYPED APPROVAL, because the ledger write belongs to the typed procedure. Approving through
    /// the generic endpoint would move the chain without ever creating the adjustment.
    ///
    /// The body carries the approved amount, which is REQUIRED — a signature with no figure attached
    /// is not a decision about money. What is refused, and why, is the procedure's to say: whether
    /// the figure exceeds what was requested, and whether it exceeds what an earlier approver already
    /// allowed. Those refusals reach the caller verbatim, because the approver needs to read the
    /// actual number that constrains them, not a paraphrase.
    ///
    /// Needs no permission: the database decides who may act at the current step, and its refusal
    /// comes back as a 403 with the message intact.
    /// </summary>
    [HttpPost("{id:int}/decide")]
    public async Task<IActionResult> Decide(int id, [FromBody] PayrollAdjustmentDecideRequest request)
    {
        try
        {
            var result = await _adjustments.DecideAsync(id, User.UserId(), request);
            if (result is null) return NotFound();

            // "payroll" as well as "workflow": the FINAL approval writes the ledger row the next
            // generate consumes, so the adjustments page and the run behind it both go stale.
            await _live.NotifyAsync("workflow", "payroll", "dashboard");
            return Ok(result);
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>
    /// The payload — the claim, and how far it has travelled: waiting, then the ledger row it created,
    /// then the payslip that consumed it.
    /// </summary>
    [HttpGet("{id:int}/payload")]
    public async Task<IActionResult> GetPayload(int id)
    {
        var payload = await _adjustments.GetPayloadAsync(id);
        return payload is null ? NotFound() : Ok(payload);
    }
}
