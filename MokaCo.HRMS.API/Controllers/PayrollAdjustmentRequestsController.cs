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
/// DECISIONS ARE APPROVE OR REJECT, and the decide body carries no figure. A correction is a precise
/// claim; an approver who believes a different number rejects and says why, and HR raises it again.
/// That is a deliberate design choice, not a missing feature — the chain has no CanAdjust step.
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

    public PayrollAdjustmentRequestsController(
        IPayrollAdjustmentService adjustments, IWorkflowSupportService support)
    {
        _adjustments = adjustments;
        _support = support;
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
            return created is null
                ? BadRequest(new { error = "The request could not be created." })
                : Ok(created);
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
    /// Needs no permission: the database decides who may act at the current step, and its refusal
    /// comes back as a 403 with the message intact.
    /// </summary>
    [HttpPost("{id:int}/decide")]
    public async Task<IActionResult> Decide(int id, [FromBody] PayrollAdjustmentDecideRequest request)
    {
        try
        {
            var result = await _adjustments.DecideAsync(id, User.UserId(), request);
            return result is null ? NotFound() : Ok(result);
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
