using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Services.Payroll;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Api.Controllers;

/// <summary>
/// The payslip DOCUMENT — the one payroll resource a person may read about themselves.
///
/// WHY THIS IS ITS OWN CONTROLLER. Everything else under /api/payroll carries a blanket
/// PAYROLL_RUN requirement declared on the class, which is exactly what you want for a surface
/// where every route exposes the whole company's pay. This route is the single exception, and an
/// exception is safer expressed as a separate class with its own rule than as a hole punched in a
/// class-level gate — a hole that the next route added to that class would silently inherit.
///
/// WHO MAY READ ONE:
///   • a PAYROLL_RUN holder — any payslip, in any state, because preparing the month requires it;
///   • the employee the payslip is ABOUT — but only once the run is APPROVED.
///
/// The second condition is not squeamishness. A draft still changes: regeneration rebuilds every
/// figure on it, and a person who has read a number remembers it as a promise. Approved is the
/// first moment the document means what it says.
///
/// Recording PAYMENT is not here — that stays managerial, on PayrollController.
/// </summary>
[ApiController]
[Route("api/payroll/payslips")]
[Authorize]
public class PayslipsController : ControllerBase
{
    private readonly IPayrollService _payroll;
    private readonly IWorkflowSupportService _support;

    public PayslipsController(IPayrollService payroll, IWorkflowSupportService support)
    {
        _payroll = payroll;
        _support = support;
    }

    /// <summary>
    /// One payslip and its lines.
    ///
    /// The payslip is fetched BEFORE the ownership decision because the decision needs it: whose it
    /// is, and whether its run is approved. A 404 for a payslip that does not exist is answered
    /// first, so the endpoint cannot be used to probe which ids are real.
    /// </summary>
    [HttpGet("{id:int}")]
    public async Task<IActionResult> Get(int id)
    {
        var detail = await _payroll.GetPayslipAsync(id);
        if (detail.Payslip is null)
            return NotFound();

        if (User.HasPermission("PAYROLL_RUN"))
            return Ok(detail);

        // Not managerial: the only payslip readable is this caller's own, and only once locked.
        var me = await _support.GetEmployeeByUserIdAsync(User.UserId());
        var isOwn = me is not null && me.EmployeeId == detail.Payslip.EmployeeId;
        var isApproved = string.Equals(detail.Payslip.RunStatus, "Approved", StringComparison.OrdinalIgnoreCase);

        if (isOwn && isApproved)
            return Ok(detail);

        // ONE MESSAGE FOR BOTH REFUSALS, deliberately. Saying "that payslip is still a draft" to
        // somebody asking about another person's payslip would confirm that the person and the
        // period exist, which is the thing being withheld.
        return StatusCode(403, new { error = "You may only open your own payslips, and only once the month is approved." });
    }
}
