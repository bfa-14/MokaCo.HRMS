using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Model.Workflow;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Api.Controllers;

/// <summary>
/// Expense reimbursements — money spent on the company's behalf, claimed back.
///
/// Two rules make this type distinctive, and both live in SQL: approval is refused without a receipt
/// attached, and THE AMOUNT GRANTED ROUTES THE REQUEST — the operations manager may grant anything up
/// to what was claimed, and whether that figure lands above or below the USD threshold decides at
/// that moment whether the Owner is asked or the remaining steps are skipped. The conversion uses the
/// rate frozen at submit, so routing does not move when rates do.
/// </summary>
[ApiController]
[Route("api/expenses")]
[Authorize]
public class ExpensesController : ControllerBase
{
    private readonly IExpenseService _expenses;
    private readonly IWorkflowSupportService _support;
    private readonly ILiveNotifier _live;

    public ExpensesController(
        IExpenseService expenses, IWorkflowSupportService support, ILiveNotifier live)
    {
        _expenses = expenses;
        _support = support;
        _live = live;
    }

    /// <summary>
    /// Raises an expense. REQUEST_RAISE_SELF is the floor; the service enforces WHO it may be raised
    /// FOR, since the employee id travels in the body.
    ///
    /// A currency with NO exchange rate on file is refused by the procedure, by name — resets clear
    /// core.EXCHANGE_RATE, so that is the first thing to check when an LBP claim will not submit.
    /// </summary>
    [HttpPost]
    [HasPermission("REQUEST_RAISE_SELF")]
    public async Task<IActionResult> Create([FromBody] ExpenseCreateRequest request)
    {
        var me = await _support.GetEmployeeByUserIdAsync(User.UserId());
        var caller = new ExpenseCaller(
            User.UserId(),
            me?.EmployeeId,
            User.HasPermission("REQUEST_RAISE_OTHERS"));

        try
        {
            var created = await _expenses.CreateAsync(request, caller);
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
    /// THE TYPED APPROVAL, because the granted amount and the receipt rule both belong to the typed
    /// procedure. Approving through the generic endpoint would approve a claim with no receipt.
    ///
    /// Needs no permission: the database decides who may act at the current step, and its refusal —
    /// like the receipt one — comes back with the message intact.
    /// </summary>
    [HttpPost("{id:int}/decide")]
    public async Task<IActionResult> Decide(int id, [FromBody] ExpenseDecideRequest request)
    {
        try
        {
            var result = await _expenses.DecideAsync(id, User.UserId(), request);
            if (result is null) return NotFound();

            // The granted figure ROUTES the request — it may skip the remaining steps and close it,
            // or stand it up in front of the Owner. Either way the chain other people are looking at
            // has just changed shape, not only advanced.
            await _live.NotifyAsync("workflow", "dashboard");
            return Ok(result);
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>The expense payload — the amount, its USD equivalent and rate, the receipt count and the threshold decision.</summary>
    [HttpGet("{id:int}/payload")]
    public async Task<IActionResult> GetPayload(int id)
    {
        var payload = await _expenses.GetPayloadAsync(id);
        return payload is null ? NotFound() : Ok(payload);
    }
}
