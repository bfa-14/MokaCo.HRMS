using MokaCo.HRMS.Model.Core;
using MokaCo.HRMS.Repository.Core;

namespace MokaCo.HRMS.Services.Core;

/// <summary>Exchange-rate administration (thin wrapper over the repository).</summary>
public class ExchangeRateService : IExchangeRateService
{
    private readonly IExchangeRateRepository _repo;
    public ExchangeRateService(IExchangeRateRepository repo) => _repo = repo;

    public Task<IEnumerable<ExchangeRate>> GetAllAsync() => _repo.GetAllAsync();

    public Task<int> CreateAsync(string fromCurrency, string toCurrency, string rateType, DateTime effectiveDate, decimal rate)
        => _repo.CreateAsync(fromCurrency, toCurrency, rateType, effectiveDate, rate);

    public Task<ExchangeRate?> GetEffectiveAsync(string fromCurrency, string toCurrency, string rateType, DateTime asOf)
        => _repo.GetEffectiveAsync(fromCurrency, toCurrency, rateType, asOf);
}
