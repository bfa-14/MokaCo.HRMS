using System.Text.RegularExpressions;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.ModelBinding;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Model.Payroll;
using MokaCo.HRMS.Services.Payroll;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Api.Controllers;

/// <summary>
/// Payroll — runs, payslips, advances and adjustments.
///
/// THREE TRUSTS, ONE PER ACTION (QA3 PAY-12 / WEB-4). There is no class-level gate any more:
///   • every READ answers to PAYROLL_VIEW — the runs, a run's payslips, readiness, the payment and
///     statutory sheets, advances, adjustments, an employee's payslip history;
///   • every WRITE that prepares payroll answers to PAYROLL_RUN — create, generate, send to review,
///     cancel, reschedule an advance, delete a pre-request adjustment;
///   • the acts that turn figures into money answer to PAYROLL_APPROVE — approving (and the procedure
///     then admits the Owner alone), recording a payment, the company-wide bulk adjustment.
/// PAYROLL_VIEW is granted by script 103 to every role that held PAYROLL_RUN or PAYROLL_APPROVE, so
/// nobody who could read payroll before loses it. A barista still cannot read the company's pay by
/// typing a URL: none of these codes is theirs.
///
/// EVERY REFUSAL IS THE DATABASE'S. The procedures own the rules and raise sentences written for the
/// person who hit them; the service maps those to a 400 with the message intact, and the actions
/// below return them verbatim. Nothing is re-checked here first — a guess that agrees with SQL today
/// is a guess that can disagree with it tomorrow.
/// </summary>
[ApiController]
[Route("api/payroll")]
public class PayrollController : ControllerBase
{
    private readonly IPayrollService _payroll;
    private readonly ILiveNotifier _live;

    public PayrollController(IPayrollService payroll, ILiveNotifier live)
    {
        _payroll = payroll;
        _live = live;
    }

    /// <summary>Every write here changes a run's figures, and the dashboard's payroll line with them.</summary>
    private Task NotifyPayrollAsync() => _live.NotifyAsync("payroll", "dashboard");

    // ───────────────────────────────── runs ─────────────────────────────────

    /// <summary>Every payroll run, newest period first.</summary>
    [HttpGet("runs")]
    [HasPermission("PAYROLL_VIEW")]
    public async Task<IActionResult> GetRuns() => Ok(await _payroll.GetRunsAsync());

    /// <summary>
    /// Opens a run for a period and FREEZES the exchange rates into it.
    ///
    /// The attendance gate is checked by the procedure itself, so this cannot be talked past: a month
    /// with unprocessed punches or undecided variances is refused here even if the readiness panel
    /// was never opened. The creator is the token's user, never a number from the body.
    /// </summary>
    [HttpPost("runs")]
    [HasPermission("PAYROLL_RUN")]
    public async Task<IActionResult> CreateRun([FromBody] PayrollRunCreateRequest request)
    {
        try
        {
            var created = await _payroll.CreateRunAsync(request, User.UserId());
            if (created is null)
                return BadRequest(new { error = "The payroll run could not be created." });

            await NotifyPayrollAsync();
            return Ok(created);
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
    [HasPermission("PAYROLL_VIEW")]
    public async Task<IActionResult> GetRun(int id)
    {
        var detail = await _payroll.GetRunAsync(id);
        return detail.Header is null ? NotFound() : Ok(detail);
    }

    /// <summary>Every payslip in the run, for the grid and its export.</summary>
    [HttpGet("runs/{id:int}/payslips")]
    [HasPermission("PAYROLL_VIEW")]
    public async Task<IActionResult> GetRunPayslips(int id) => Ok(await _payroll.GetRunPayslipsAsync(id));

    /// <summary>
    /// Rebuilds the run's payslips from the data as it stands. Repeatable while the run is open —
    /// add a tip, regenerate, and the tip is there. A LOCKED RUN REFUSES, and that refusal carries
    /// the sentence that says where corrections go instead.
    ///
    /// ONE ROUTE, TWO GENERATORS. The service reads the run's own RunType and sends a Supplemental
    /// to the off-cycle generator instead. The type is never taken from the caller: getting it wrong
    /// would rebuild the whole company into an off-cycle run. Both paths sit behind the same
    /// PAYROLL_RUN gate on this controller, so the permission story does not fork either.
    /// </summary>
    [HttpPost("runs/{id:int}/generate")]
    [HasPermission("PAYROLL_RUN")]
    public async Task<IActionResult> Generate(int id)
    {
        try
        {
            var result = await _payroll.GenerateAsync(id, User.UserId());
            if (result is null) return NotFound();

            // Covers the supplemental generator too — the service routes on the run's own type,
            // so both paths arrive here and both make every open run page stale.
            await NotifyPayrollAsync();
            return Ok(result);
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>Moves a generated draft to review. An ungenerated run is refused, and says so.</summary>
    [HttpPost("runs/{id:int}/send-to-review")]
    [HasPermission("PAYROLL_RUN")]
    public async Task<IActionResult> SendToReview(int id)
    {
        try
        {
            var result = await _payroll.SendToReviewAsync(id, User.UserId());
            if (result is null) return NotFound();

            await NotifyPayrollAsync();
            return Ok(result);
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>
    /// APPROVES AND LOCKS — the one irreversible act in the module.
    ///
    /// In a single transaction the run is claimed (only from Review, and only as it was checked — a
    /// second approval finds nothing to claim), expenses are marked reimbursed, advance balances are
    /// reduced, adjustments consumed, separation settlements stamped and leave payouts settled in the
    /// leave ledger. Before that the procedure refuses a run whose inputs changed since it was
    /// generated, a month whose attendance is not ready, and — unless <c>allowEarlyLock</c> says the
    /// Owner means it — a primary whose last day is not over yet.
    ///
    /// PAYROLL_APPROVE gets a caller this far; the procedure then admits the Owner alone.
    /// </summary>
    [HttpPost("runs/{id:int}/approve")]
    [HasPermission("PAYROLL_APPROVE")]
    public async Task<IActionResult> Approve(int id,
        [FromBody(EmptyBodyBehavior = EmptyBodyBehavior.Allow)] PayrollRunApproveRequest? request)
    {
        try
        {
            var result = await _payroll.ApproveAsync(id, User.UserId(), request?.AllowEarlyLock ?? false);
            if (result is null) return NotFound();

            // Approval also stamps expenses, reduces advances and consumes adjustments, so the
            // workflow side of those requests is stale too.
            await _live.NotifyAsync("payroll", "workflow", "dashboard");
            return Ok(result);
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
    [HasPermission("PAYROLL_RUN")]
    public async Task<IActionResult> Cancel(int id, [FromBody] PayrollRunCancelRequest request)
    {
        try
        {
            var result = await _payroll.CancelAsync(id, User.UserId(), request);
            if (result is null) return NotFound();

            await NotifyPayrollAsync();
            return Ok(result);
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
    [HasPermission("PAYROLL_VIEW")]
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
    [HasPermission("PAYROLL_VIEW")]
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

    /// <summary>
    /// What changed since the run was generated — the run page's "out of date" banner (QA3 PAY-5 /
    /// REL-3). The same comparison Approve makes before it locks: each payslip's inputs (attendance,
    /// roster, leave, salary, overtime, tips, expenses, adjustments, advances, settlements) and the
    /// run-wide ones (settings, NSSF / tax, types, holidays, roster approvals) against the data now.
    /// </summary>
    [HttpGet("runs/{id:int}/staleness")]
    [HasPermission("PAYROLL_VIEW")]
    public async Task<IActionResult> GetStaleness(int id)
    {
        var staleness = await _payroll.GetStalenessAsync(id);
        return staleness is null ? NotFound() : Ok(staleness);
    }

    // ─────────────────────────────── payslips ───────────────────────────────
    //
    // READING one payslip lives on PayslipsController, not here: it is the single payroll route an
    // ordinary employee may reach (their own, once the run is approved). Recording payment stays
    // below, because that is managerial whoever the payslip belongs to.

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
            if (result is null) return NotFound();

            await NotifyPayrollAsync();
            return Ok(result);
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    // ─────────────────────────────── advances ───────────────────────────────

    /// <summary>Advances, open ones by default — the ones with a balance still to come off.</summary>
    [HttpGet("advances")]
    [HasPermission("PAYROLL_VIEW")]
    public async Task<IActionResult> GetAdvances([FromQuery] int? employeeId, [FromQuery] bool openOnly = true)
        => Ok(await _payroll.GetAdvancesAsync(employeeId, openOnly));

    // THERE IS NO POST HERE ANY MORE. An advance is a request — see
    // SalaryAdvanceRequestsController — and payroll.usp_Advance_Create refuses outright, pointing
    // at the request type. The route was removed rather than left to relay that refusal.

    /// <summary>
    /// Reschedules what comes off each month. The BALANCE is not touched — only future runs are.
    /// A settled advance refuses.
    /// </summary>
    [HttpPut("advances/{id:int}/monthly")]
    [HasPermission("PAYROLL_RUN")]
    public async Task<IActionResult> UpdateAdvanceMonthly(int id, [FromBody] SalaryAdvanceMonthlyRequest request)
    {
        try
        {
            var result = await _payroll.UpdateAdvanceMonthlyAsync(id, request, User.UserId());
            if (result is null) return NotFound();

            await NotifyPayrollAsync();
            return Ok(result);
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
    [HasPermission("PAYROLL_VIEW")]
    public async Task<IActionResult> GetAdjustments([FromQuery] string? period)
    {
        if (string.IsNullOrWhiteSpace(period) || !PeriodPattern.IsMatch(period))
            return BadRequest(new { error = "The period must look like 2026-09." });

        return Ok(await _payroll.GetAdjustmentsAsync(period));
    }

    // THERE IS NO POST FOR ONE EMPLOYEE. A single adjustment is a request now — see
    // PayrollAdjustmentRequestsController — and payroll.usp_Adjustment_Create refuses outright,
    // pointing at the request type. That route was removed rather than left to relay the refusal:
    // a documented endpoint that can only ever fail is a lie about what the API offers.

    /// <summary>
    /// One adjustment for EVERY active employee — the company-wide bonus, the across-the-board
    /// correction, the month everyone is given the same thing.
    ///
    /// WHY THIS IS NOT A REQUEST. The chain exists so that one person's pay is not changed without
    /// a second signature. Applied here it would mean one request per head — two hundred approvals
    /// for a single decision that was already taken once — so the trust is spent on the ACT instead:
    /// PAYROLL_APPROVE, the same permission that locks a run and records a payment. HR may prepare
    /// payroll and may raise an adjustment request; HR may not give the whole company a bonus.
    ///
    /// THE PERIOD IS SHAPE-CHECKED, and this is not a business rule being re-decided in C#. The
    /// procedure casts @TargetPeriod + '-01' to a date to work out who was still employed; a period
    /// of "Sept" fails that cast as a CONVERSION error, which is a 500 — a bug report for something
    /// that is simply a malformed field. Every rule that is actually about payroll — the amount, the
    /// reason, the component, the currency — is left to the procedure and arrives as its own words.
    ///
    /// THE ANSWER IS A COUNT OF ROWS WRITTEN, not of employees asked about: the procedure skips
    /// anyone who already carries this component, period and reason, so running it twice reports
    /// zero the second time rather than paying everybody twice.
    /// </summary>
    [HttpPost("adjustments/bulk")]
    [HasPermission("PAYROLL_APPROVE")]
    public async Task<IActionResult> CreateAdjustmentsBulk([FromBody] PayrollAdjustmentBulkRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.TargetPeriod) || !PeriodPattern.IsMatch(request.TargetPeriod))
            return BadRequest(new { error = "The target period must look like 2026-09." });

        try
        {
            var result = await _payroll.CreateAdjustmentsBulkAsync(request, User.UserId());
            if (result is null)
                return BadRequest(new { error = "The adjustments could not be created." });

            await NotifyPayrollAsync();
            return Ok(result);
        }
        catch (WorkflowException ex)
        {
            // Verbatim: "A reason is required - it appears on every payslip line."
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>
    /// Removes an adjustment, which by now means: refuses, and says which kind of "no" it is.
    ///
    /// A CONSUMED row is history — counter it. An UNCONSUMED row that a request authorised is not
    /// deletable either, because it is the residue of signatures; rejecting or countering the
    /// request is the way back. What remains deletable is only the pre-request rows, written when a
    /// reason and a creator were the whole story. Both refusals are the procedure's own words.
    /// </summary>
    [HttpDelete("adjustments/{id:int}")]
    [HasPermission("PAYROLL_RUN")]
    public async Task<IActionResult> DeleteAdjustment(int id)
    {
        try
        {
            var result = await _payroll.DeleteAdjustmentAsync(id, User.UserId());
            if (result is null || result.Deleted == 0) return NotFound();

            await NotifyPayrollAsync();
            return NoContent();
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
    [HasPermission("PAYROLL_VIEW")]
    public async Task<IActionResult> GetComponentTypes() => Ok(await _payroll.GetComponentTypesAsync());

    // ──────────────────────────── reports & lookups ─────────────────────────

    /// <summary>
    /// The statutory sheet for a run — per employee: wage base, NSSF employee and employer shares,
    /// income tax. This is what goes to the NSSF and the tax office.
    ///
    /// Every figure is in the run's PRIMARY currency, converted at the rate frozen into the run.
    /// That is the one place payroll deliberately merges currencies, and it is legitimate for the
    /// same reason the comparable net is: a contribution base is a single legal number, and the
    /// rate that produced it is printed on the run beside it.
    /// </summary>
    [HttpGet("runs/{id:int}/statutory-report")]
    [HasPermission("PAYROLL_VIEW")]
    public async Task<IActionResult> GetStatutoryReport(int id)
        => Ok(await _payroll.GetStatutoryReportAsync(id));

    /// <summary>
    /// One employee's payslips across every run — the HR tab. Includes DRAFT runs, unlike the
    /// employee's own view, because preparing a month means looking at the month being prepared.
    /// </summary>
    [HttpGet("employees/{id:int}/payslips")]
    [HasPermission("PAYROLL_VIEW")]
    public async Task<IActionResult> GetEmployeePayslips(int id)
        => Ok(await _payroll.GetPayslipsForEmployeeAsync(id));

    // "Was this request ever paid?" (GET /api/payroll/lines/lookup) lives on PayslipsController: the
    // person who raised the request may ask it about their own payslip (QA3 WEB-15).
}
