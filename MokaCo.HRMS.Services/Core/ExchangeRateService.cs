using MokaCo.HRMS.Model.Core;
using MokaCo.HRMS.Repository.Core;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Services.Core;

/// <summary>
/// Exchange-rate administration.
///
/// EVERY WRITE IS MAPPED, INCLUDING CREATE. The procedures enforce one rate per (pair, type, date)
/// and refuse a duplicate with a sentence that names the clash — "An Official rate for USD → LBP on
/// 2026-08-16 already exists". That message IS the value of the refusal: it tells the user the row
/// is already there and to edit it rather than add another. Unmapped, it surfaced as a 500 and the
/// user saw a generic failure — which is why create is wrapped here now, not only the two new verbs.
/// </summary>
public class ExchangeRateService : IExchangeRateService
{
    private readonly IExchangeRateRepository _repo;
    public ExchangeRateService(IExchangeRateRepository repo) => _repo = repo;

    public Task<IEnumerable<ExchangeRate>> GetAllAsync() => _repo.GetAllAsync();

    public Task<int> CreateAsync(string fromCurrency, string toCurrency, string rateType, DateTime effectiveDate, decimal rate)
        => WorkflowSqlErrors.MapAsync(
            () => _repo.CreateAsync(fromCurrency, toCurrency, rateType, effectiveDate, rate));

    public Task<ExchangeRate?> UpdateAsync(int exchangeRateId, decimal rate, DateTime? effectiveDate)
        => WorkflowSqlErrors.MapAsync(() => _repo.UpdateAsync(exchangeRateId, rate, effectiveDate));

    public Task DeleteAsync(int exchangeRateId)
        => WorkflowSqlErrors.MapAsync(async () =>
        {
            await _repo.DeleteAsync(exchangeRateId);
            return true;
        });

    public Task<ExchangeRate?> GetEffectiveAsync(string fromCurrency, string toCurrency, string rateType, DateTime asOf)
        => _repo.GetEffectiveAsync(fromCurrency, toCurrency, rateType, asOf);
}
