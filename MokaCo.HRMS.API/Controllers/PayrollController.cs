using System.Text.RegularExpressions;
using Microsoft.AspNetCore.Mvc;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Model.Payroll;
using MokaCo.HRMS.Services.Payroll;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Api.Controllers;

/// <summary>
/// Payroll — runs, payslips, advances and adjustments.
///
/// WHO MAY BE HERE AT ALL. Every route on this controller carries PAYROLL_RUN, held by the
/// managerial roles (Owner, General Manager, OperationsManager, HR, Admin) and by nobody else. This
/// is not a view gate: a barista must not be able to read the company's pay figures by typing a URL,
/// so the refusal is server-side and the hidden menu item is only a courtesy on top of it.
///
/// THE TWO ROUTES THAT ASK FOR MORE. Approving a run and recording a payment are the acts that turn
/// figures into money, and both carry PAYROLL_APPROVE instead — Owner, General Manager and
/// Operations Manager (and Admin, who holds every permission). HR may prepare a run and read every
/// payslip in it; HR may not lock it or say it has been paid.
///
/// EVERY REFUSAL IS THE DATABASE'S. The procedures own the rules and raise sentences written for the
/// person who hit them; the service maps those to a 400 with the message intact, and the actions
/// below return them verbatim. Nothing is re-checked here first — a guess that agrees with SQL today
/// is a guess that can disagree with it tomorrow.
/// </summary>
[ApiController]
[Route("api/payroll")]
[HasPermission("PAYROLL_RUN")]
public class PayrollController : ControllerBase
{
    private readonly IPayrollService _payroll;
    public PayrollController(IPayrollService payroll) => _payroll = payroll;

    // ───────────────────────────────── runs ─────────────────────────────────

    /// <summary>Every payroll run, newest period first.</summary>
    [HttpGet("runs")]
    public async Task<IActionResult> GetRuns() => Ok(await _payroll.GetRunsAsync());

    /// <summary>
    /// Opens a run for a period and FREEZES the exchange rates into it.
    ///
    /// The attendance gate is checked by the procedure itself, so this cannot be talked past: a month
    /// with unprocessed punches or undecided variances is refused here even if the readiness panel
    /// was never opened. The creator is the token's user, never a number from the body.
    /// </summary>
    [HttpPost("runs")]
    public async Task<IActionResult> CreateRun([FromBody] PayrollRunCreateRequest request)
    {
        try
        {
            var created = await _payroll.CreateRunAsync(request, User.UserId());
            return created is null
                ? BadRequest(new { error = "The payroll run could not be created." })
                : Ok(created);
        }
        catch (WorkflowException ex)
        {
            // Verbatim: "Attendance for 2026-08 is not ready for payroll…" names what to fix.
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>
    /// The run page in one call — header, frozen rates, totals, history.
    ///
    /// The rates are part of the answer, not a footnote: a comparable total without the rate that
    /// produced it is a number nobody can check.
    /// </summary>
    [HttpGet("runs/{id:int}")]
    public async Task<IActionResult> GetRun(int id)
    {
        var detail = await _payroll.GetRunAsync(id);
        return detail.Header is null ? NotFound() : Ok(detail);
    }

    /// <summary>Every payslip in the run, for the grid and its export.</summary>
    [HttpGet("runs/{id:int}/payslips")]
    public async Task<IActionResult> GetRunPayslips(int id) => Ok(await _payroll.GetRunPayslipsAsync(id));

    /// <summary>
    /// Rebuilds the run's payslips from the data as it stands. Repeatable while the run is open —
    /// add a tip, regenerate, and the tip is there. A LOCKED RUN REFUSES, and that refusal carries
    /// the sentence that says where corrections go instead.
    /// </summary>
    [HttpPost("runs/{id:int}/generate")]
    public async Task<IActionResult> Generate(int id)
    {
        try
        {
            var result = await _payroll.GenerateAsync(id, User.UserId());
            return result is null ? NotFound() : Ok(result);
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>Moves a generated draft to review. An ungenerated run is refused, and says so.</summary>
    [HttpPost("runs/{id:int}/send-to-review")]
    public async Task<IActionResult> SendToReview(int id)
    {
        try
        {
            var result = await _payroll.SendToReviewAsync(id, User.UserId());
            return result is null ? NotFound() : Ok(result);
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>
    /// APPROVES AND LOCKS — the one irreversible act in the module.
    ///
    /// In a single transaction the run is stamped, expenses are marked reimbursed, advance balances
    /// are reduced and adjustments are consumed. Calling it twice cannot double-apply any of that:
    /// the second call is refused before the side effects run.
    ///
    /// PAYROLL_APPROVE, not PAYROLL_RUN. HR prepares; Owner, General Manager and Operations Manager
    /// commit.
    /// </summary>
    [HttpPost("runs/{id:int}/approve")]
    [HasPermission("PAYROLL_APPROVE")]
    public async Task<IActionResult> Approve(int id)
    {
        try
        {
            var result = await _payroll.ApproveAsync(id, User.UserId());
            return result is null ? NotFound() : Ok(result);
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>
    /// Cancels an open run, with a reason that is required — a run that vanished for no stated
    /// reason is worse than one that was never opened. An APPROVED run refuses: it is history.
    /// </summary>
    [HttpPost("runs/{id:int}/cancel")]
    public async Task<IActionResult> Cancel(int id, [FromBody] PayrollRunCancelRequest request)
    {
        try
        {
            var result = await _payroll.CancelAsync(id, User.UserId(), request);
            return result is null ? NotFound() : Ok(result);
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>
    /// What to pay whom — approved runs only. The procedure refuses a draft, because a draft still
    /// changes and a payment sheet that changes is not a payment sheet.
    /// </summary>
    [HttpGet("runs/{id:int}/payment-sheet")]
    public async Task<IActionResult> GetPaymentSheet(int id)
    {
        try
        {
            return Ok(await _payroll.GetPaymentSheetAsync(id));
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>
    /// The attendance gate for a period — six counts and a verdict.
    ///
    /// Read on its own so the run page can EXPLAIN the refusal before anyone runs into it. The
    /// procedure that creates a run performs this same check itself, so this endpoint informs; it
    /// does not authorise.
    ///
    /// THE SHAPE CHECK BELOW IS NOT A BUSINESS RULE, and is the one thing in this controller that
    /// looks at an input before the database does. usp_Attendance_PayrollReadiness does not validate
    /// its parameter the way the run procedures validate theirs — it CASTs '{period}-01' straight to
    /// a date — so "2026-13" came back a 500 with a SQL conversion error, and an ABSENT period came
    /// back worse: every count computed against a null range is zero, so the answer was IsReady true
    /// for a month nobody named. A query string is typed by hand, so this is the boundary that has
    /// to hold it. The wording is the create procedure's own, so both refusals read the same.
    /// </summary>
    [HttpGet("readiness")]
    public async Task<IActionResult> GetReadiness([FromQuery] string? period)
    {
        if (string.IsNullOrWhiteSpace(period) || !PeriodPattern.IsMatch(period))
            return BadRequest(new { error = "The period must look like 2026-08." });

        var readiness = await _payroll.GetReadinessAsync(period);
        return readiness is null ? NotFound() : Ok(readiness);
    }

    /// <summary>Mirrors the LIKE mask the payroll procedures use: four digits, a dash, a real month.</summary>
    private static readonly Regex PeriodPattern =
        new(@"^\d{4}-(0[1-9]|1[0-2])$", RegexOptions.Compiled);

    // ─────────────────────────────── payslips ───────────────────────────────

    /// <summary>
    /// One payslip and its lines. Request-backed lines carry the RequestInstanceId of the request
    /// that produced them, so every figure on the document can be followed back to its origin.
    /// </summary>
    [HttpGet("payslips/{id:int}")]
    public async Task<IActionResult> GetPayslip(int id)
    {
        var detail = await _payroll.GetPayslipAsync(id);
        return detail.Payslip is null ? NotFound() : Ok(detail);
    }

    /// <summary>
    /// Records that a payslip was paid — method, reference, and the moment. Approved runs only.
    ///
    /// PAYROLL_APPROVE: saying money left the company is the same class of act as locking the run
    /// that decided how much.
    /// </summary>
    [HttpPost("payslips/{id:int}/payment")]
    [HasPermission("PAYROLL_APPROVE")]
    public async Task<IActionResult> SetPayment(int id, [FromBody] PayslipPaymentRequest request)
    {
        try
        {
            var result = await _payroll.SetPaymentAsync(id, request, User.UserId());
            return result is null ? NotFound() : Ok(result);
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    // ─────────────────────────────── advances ───────────────────────────────

    /// <summary>Advances, open ones by default — the ones with a balance still to come off.</summary>
    [HttpGet("advances")]
    public async Task<IActionResult> GetAdvances([FromQuery] int? employeeId, [FromQuery] bool openOnly = true)
        => Ok(await _payroll.GetAdvancesAsync(employeeId, openOnly));

    /// <summary>
    /// Records an advance and its repayment schedule. The bounds — above zero, no more per month
    /// than the advance itself, a real employee, a known currency — are the procedure's, each with
    /// its own sentence.
    /// </summary>
    [HttpPost("advances")]
    public async Task<IActionResult> CreateAdvance([FromBody] SalaryAdvanceCreateRequest request)
    {
        try
        {
            var created = await _payroll.CreateAdvanceAsync(request, User.UserId());
            return created is null
                ? BadRequest(new { error = "The advance could not be created." })
                : Ok(created);
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>
    /// Reschedules what comes off each month. The BALANCE is not touched — only future runs are.
    /// A settled advance refuses.
    /// </summary>
    [HttpPut("advances/{id:int}/monthly")]
    public async Task<IActionResult> UpdateAdvanceMonthly(int id, [FromBody] SalaryAdvanceMonthlyRequest request)
    {
        try
        {
            var result = await _payroll.UpdateAdvanceMonthlyAsync(id, request, User.UserId());
            return result is null ? NotFound() : Ok(result);
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    // ────────────────────────────── adjustments ─────────────────────────────

    /// <summary>
    /// Everything aimed at one period, applied or not.
    ///
    /// Shape-checked for the same reason as readiness: the procedure matches the period as a plain
    /// equality, so a typo or a missing parameter would come back as an EMPTY LIST — which reads as
    /// "nothing is queued for September" rather than as "you asked the wrong question".
    /// </summary>
    [HttpGet("adjustments")]
    public async Task<IActionResult> GetAdjustments([FromQuery] string? period)
    {
        if (string.IsNullOrWhiteSpace(period) || !PeriodPattern.IsMatch(period))
            return BadRequest(new { error = "The period must look like 2026-09." });

        return Ok(await _payroll.GetAdjustmentsAsync(period));
    }

    // THERE IS NO POST HERE ANY MORE. An adjustment is a request now — see
    // PayrollAdjustmentRequestsController — and payroll.usp_Adjustment_Create refuses outright,
    // pointing at the request type. The route was removed rather than left to relay that refusal:
    // a documented endpoint that can only ever fail is a lie about what the API offers.

    /// <summary>
    /// Removes an adjustment, which by now means: refuses, and says which kind of "no" it is.
    ///
    /// A CONSUMED row is history — counter it. An UNCONSUMED row that a request authorised is not
    /// deletable either, because it is the residue of signatures; rejecting or countering the
    /// request is the way back. What remains deletable is only the pre-request rows, written when a
    /// reason and a creator were the whole story. Both refusals are the procedure's own words.
    /// </summary>
    [HttpDelete("adjustments/{id:int}")]
    public async Task<IActionResult> DeleteAdjustment(int id)
    {
        try
        {
            var result = await _payroll.DeleteAdjustmentAsync(id, User.UserId());
            return result is null || result.Deleted == 0 ? NotFound() : NoContent();
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    // ─────────────────────────────── reference ──────────────────────────────

    /// <summary>
    /// The pay-component catalogue for the adjustment form, IsStanding included.
    ///
    /// Not /api/component-types: that route is gated on EMP_VIEW — which the General Manager and
    /// Operations Manager roles do not hold — and its procedure omits IsStanding, the flag that says
    /// whether a component is assigned to a person or produced by a run.
    /// </summary>
    [HttpGet("component-types")]
    public async Task<IActionResult> GetComponentTypes() => Ok(await _payroll.GetComponentTypesAsync());
}
