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
    public CurrenciesController(ICurrencyService currencies) => _currencies = currencies;

    [HttpGet]
    [HasPermission("EMP_VIEW")]
    public async Task<IActionResult> GetAll() => Ok(await _currencies.GetAllAsync());

    [HttpPost]
    [HasPermission("EMP_EDIT")]
    public async Task<IActionResult> Upsert([FromBody] CurrencyUpsertRequest request)
    {
        await _currencies.UpsertAsync(request.CurrencyCode, request.Name, request.DecimalPlaces);
        return NoContent();
    }
}
