using Microsoft.AspNetCore.Mvc;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Model.Core;
using MokaCo.HRMS.Services.Core;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Api.Controllers;

[ApiController]
[Route("api/exchange-rates")]
public class ExchangeRatesController : ControllerBase
{
    private readonly IExchangeRateService _rates;
    private readonly ILiveNotifier _live;

    public ExchangeRatesController(IExchangeRateService rates, ILiveNotifier live)
    {
        _rates = rates;
        _live = live;
    }

    [HttpGet]
    [HasPermission("EMP_VIEW")]
    public async Task<IActionResult> GetAll() => Ok(await _rates.GetAllAsync());

    [HttpGet("effective")]
    [HasPermission("EMP_VIEW")]
    public async Task<IActionResult> GetEffective(
        [FromQuery] string from, [FromQuery] string to,
        [FromQuery] string rateType, [FromQuery] DateTime asOf)
    {
        var rate = await _rates.GetEffectiveAsync(from, to, rateType, asOf);
        return rate is null ? NotFound() : Ok(rate);
    }

    [HttpPost]
    [HasPermission("CORE_MANAGE")]
    public async Task<IActionResult> Create([FromBody] ExchangeRateCreateRequest request)
    {
        try
        {
            var id = await _rates.CreateAsync(
                request.FromCurrency, request.ToCurrency, request.RateType,
                request.EffectiveDate, request.Rate);
            // A new rate changes what every foreign-currency figure converts to.
            await _live.NotifyAsync("payroll", "dashboard");
            return CreatedAtAction(nameof(GetAll), new { id }, new { exchangeRateId = id });
        }
        catch (WorkflowException ex)
        {
            // The duplicate-rate refusal names the pair, the type and the date, and tells the user
            // to edit the existing row. It must reach the form intact — see ExchangeRateService.
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>
    /// Corrects a rate's figure, and optionally the date it takes effect. The pair and the type are
    /// fixed — see ExchangeRateUpdateRequest for why.
    /// </summary>
    [HttpPut("{id:int}")]
    [HasPermission("CORE_MANAGE")]
    public async Task<IActionResult> Update(int id, [FromBody] ExchangeRateUpdateRequest request)
    {
        try
        {
            var updated = await _rates.UpdateAsync(id, request.Rate, request.EffectiveDate);
            if (updated is null) return NotFound();

            await _live.NotifyAsync("payroll", "dashboard");
            return Ok(updated);
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    [HttpDelete("{id:int}")]
    [HasPermission("CORE_MANAGE")]
    public async Task<IActionResult> Delete(int id)
    {
        try
        {
            await _rates.DeleteAsync(id);
            await _live.NotifyAsync("payroll", "dashboard");
            return NoContent();
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }
}
