using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Services.Payroll;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Api.Controllers;

/// <summary>
/// The payslip DOCUMENT — the one payroll resource a person may read about themselves.
///
/// WHY THIS IS ITS OWN CONTROLLER. Everything else under /api/payroll needs a payroll code on every
/// route (PAYROLL_VIEW to read), which is exactly what you want for a surface where every route
/// exposes the whole company's pay. These routes are the exception — they also answer the employee
/// a payslip is about — and an exception is safer as a separate class with its own rule.
///
/// WHO MAY READ ONE:
///   • a PAYROLL_VIEW holder — any payslip, in any state, because preparing and checking the month
///     requires it (QA3 PAY-12: PAYROLL_VIEW, not PAYROLL_RUN, is the read trust);
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
    /// "WHERE IS MY SALARY THIS MONTH" — one row, or null.
    ///
    /// AUTHENTICATION ONLY, NO PAYROLL PERMISSION, for the same reason as /api/me/payslips:
    /// everybody is paid, so everybody must be able to ask. The scoping is not a permission but the
    /// procedure, which resolves the employee from the TOKEN's user id — there is no id in the URL,
    /// so there is nothing to change in order to ask about somebody else.
    ///
    /// NULL IS A REAL ANSWER. No row means the month has not been generated, and the card that
    /// reads this says "not prepared yet" — it is not a 404, because the caller and the question are
    /// both perfectly valid.
    ///
    /// Absolute route: this is self-service, not part of the /api/payroll/payslips management
    /// surface this controller otherwise serves.
    /// </summary>
    [HttpGet("/api/payslips/my-status")]
    public async Task<IActionResult> MyStatus()
        => Ok(await _payroll.GetMyStatusAsync(User.UserId()));

    /// <summary>
    /// The caller's own payslips.
    ///
    /// The SAME list as GET /api/me/payslips, over the same procedure and the same model — this is
    /// an alias at the address the salary screens ask for, not a second implementation. Approved
    /// runs only, and an account not linked to an employee gets an empty list.
    /// </summary>
    [HttpGet("/api/payslips/mine")]
    public async Task<IActionResult> Mine()
        => Ok(await _payroll.GetMyPayslipsAsync(User.UserId()));

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

        if (User.HasPermission("PAYROLL_VIEW"))
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

    /// <summary>
    /// "Was this request ever paid?" — one (sourceType, sourceId) pair, answered from the payslip
    /// lines. 200 with the payslip and its period, or 404 when nothing has paid it yet.
    ///
    /// 404 IS THE POINT, not a failure: the request pages render their "Paid in …" badge only on a
    /// hit, so the absent case has to be cheap and unambiguous.
    ///
    /// WHO MAY ASK (QA3 WEB-15). A PAYROLL_VIEW holder about any line. Anybody else only about a line
    /// on THEIR OWN payslip of an APPROVED run — the person who raised an advance or an expense may see
    /// that it was paid, and follow the link to the payslip, which opens for them on the same rule.
    /// Every other answer is the same 404 as "not paid yet": it says nothing about whose pay it was.
    /// </summary>
    [HttpGet("/api/payroll/lines/lookup")]
    public async Task<IActionResult> LookupLine([FromQuery] string? sourceType, [FromQuery] int? sourceId)
    {
        if (string.IsNullOrWhiteSpace(sourceType) || sourceId is not int id)
            return BadRequest(new { error = "sourceType and sourceId are both required." });

        var hit = await _payroll.LookupLineAsync(sourceType.Trim(), id);
        if (hit is null)
            return NotFound();
        if (User.HasPermission("PAYROLL_VIEW"))
            return Ok(hit);

        var detail = await _payroll.GetPayslipAsync(hit.PayslipId);
        var me = await _support.GetEmployeeByUserIdAsync(User.UserId());
        var isOwn = detail.Payslip is not null && me is not null && me.EmployeeId == detail.Payslip.EmployeeId;
        var isApproved = detail.Payslip is not null
            && string.Equals(detail.Payslip.RunStatus, "Approved", StringComparison.OrdinalIgnoreCase);
        return isOwn && isApproved ? Ok(hit) : NotFound();
    }
}
