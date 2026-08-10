using Microsoft.AspNetCore.Mvc;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Model.Core;
using MokaCo.HRMS.Services.Core;

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
    [HasPermission("EMP_EDIT")]
    public async Task<IActionResult> Create([FromBody] ExchangeRateCreateRequest request)
    {
        var id = await _rates.CreateAsync(
            request.FromCurrency, request.ToCurrency, request.RateType,
            request.EffectiveDate, request.Rate);
        // A new rate changes what every foreign-currency figure converts to.
        await _live.NotifyAsync("payroll", "dashboard");
        return CreatedAtAction(nameof(GetAll), new { id }, new { exchangeRateId = id });
    }
}
