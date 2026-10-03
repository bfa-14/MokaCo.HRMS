using Microsoft.AspNetCore.Mvc;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Model.Core;
using MokaCo.HRMS.Services.Core;

namespace MokaCo.HRMS.Api.Controllers;

[ApiController]
[Route("api/currencies")]
public class CurrenciesController : ControllerBase
{
    private readonly ICurrencyService _currencies;
    private readonly ILiveNotifier _live;

    public CurrenciesController(ICurrencyService currencies, ILiveNotifier live)
    {
        _currencies = currencies;
        _live = live;
    }

    [HttpGet]
    [HasPermission("EMP_VIEW")]
    public async Task<IActionResult> GetAll() => Ok(await _currencies.GetAllAsync());

    [HttpPost]
    [HasPermission("CORE_MANAGE")]
    public async Task<IActionResult> Upsert([FromBody] CurrencyUpsertRequest request)
    {
        await _currencies.UpsertAsync(request.CurrencyCode, request.Name, request.DecimalPlaces);
        // DecimalPlaces decides how every amount in that currency is rendered and rounded.
        await _live.NotifyAsync("payroll", "dashboard");
        return NoContent();
    }

    /// <summary>
    /// Deletes a currency nothing uses, with its exchange rates. A currency still held anywhere —
    /// a salary component, a payroll run, a room, a setting — is refused by the procedure with a
    /// sentence naming where, which the error handler returns as a 409.
    /// </summary>
    [HttpDelete("{code:length(3)}")]
    [HasPermission("CORE_MANAGE")]
    public async Task<IActionResult> Delete(string code)
    {
        await _currencies.DeleteAsync(code);
        await _live.NotifyAsync("payroll", "dashboard");
        return NoContent();
    }
}
