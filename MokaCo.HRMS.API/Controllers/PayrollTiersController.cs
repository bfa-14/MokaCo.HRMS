using Microsoft.AspNetCore.Mvc;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Model.HR;
using MokaCo.HRMS.Services.HR;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Api.Controllers;

/// <summary>
/// The rate tables payroll computes from — income tax brackets and NSSF schemes.
///
/// PAYROLL_RUN throughout, matching PayrollController's class-level gate: these values decide every
/// contribution and every tax line on every payslip, so reading them is the same trust as running
/// the payroll they feed.
///
/// Nothing here recomputes anything. A run already generated keeps the figures it was generated
/// with; changing a rate affects the NEXT run, which is why NSSF schemes are versioned rather than
/// edited in place and why this controller offers no NSSF delete.
/// </summary>
[ApiController]
[Route("api/payroll")]
[HasPermission("PAYROLL_RUN")]
public class PayrollTiersController : ControllerBase
{
    private readonly IPayrollTierService _tiers;
    private readonly ILiveNotifier _live;

    public PayrollTiersController(IPayrollTierService tiers, ILiveNotifier live)
    {
        _tiers = tiers;
        _live = live;
    }

    /* ── income tax brackets ─────────────────────────────────────────────────────────────────── */

    [HttpGet("tax-brackets")]
    public async Task<IActionResult> GetTaxBrackets() => Ok(await _tiers.GetTaxBracketsAsync());

    [HttpPost("tax-brackets")]
    public async Task<IActionResult> CreateTaxBracket([FromBody] TaxBracketUpsertRequest request)
    {
        try
        {
            var created = await _tiers.CreateTaxBracketAsync(request);
            await _live.NotifyAsync("payroll");
            return Ok(created);
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    [HttpPut("tax-brackets/{id:int}")]
    public async Task<IActionResult> UpdateTaxBracket(int id, [FromBody] TaxBracketUpsertRequest request)
    {
        try
        {
            var updated = await _tiers.UpdateTaxBracketAsync(id, request);
            if (updated is null) return NotFound();

            await _live.NotifyAsync("payroll");
            return Ok(updated);
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    [HttpDelete("tax-brackets/{id:int}")]
    public async Task<IActionResult> DeleteTaxBracket(int id)
    {
        try
        {
            await _tiers.DeleteTaxBracketAsync(id);
            await _live.NotifyAsync("payroll");
            return NoContent();
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /* ── NSSF schemes ────────────────────────────────────────────────────────────────────────── */

    [HttpGet("nssf-rates")]
    public async Task<IActionResult> GetNssfRates() => Ok(await _tiers.GetNssfRatesAsync());

    [HttpPost("nssf-rates")]
    public async Task<IActionResult> CreateNssfRate([FromBody] NssfRateUpsertRequest request)
    {
        try
        {
            var created = await _tiers.CreateNssfRateAsync(request);
            await _live.NotifyAsync("payroll");
            return Ok(created);
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    [HttpPut("nssf-rates/{id:int}")]
    public async Task<IActionResult> UpdateNssfRate(int id, [FromBody] NssfRateUpsertRequest request)
    {
        try
        {
            var updated = await _tiers.UpdateNssfRateAsync(id, request);
            if (updated is null) return NotFound();

            await _live.NotifyAsync("payroll");
            return Ok(updated);
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }
}
