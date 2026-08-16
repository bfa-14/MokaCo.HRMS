using MokaCo.HRMS.Model.Core;

namespace MokaCo.HRMS.Services.Core;

public interface IExchangeRateService
{
    Task<IEnumerable<ExchangeRate>> GetAllAsync();
    Task<int> CreateAsync(string fromCurrency, string toCurrency, string rateType, DateTime effectiveDate, decimal rate);
    Task<ExchangeRate?> UpdateAsync(int exchangeRateId, decimal rate, DateTime? effectiveDate);
    Task DeleteAsync(int exchangeRateId);
    Task<ExchangeRate?> GetEffectiveAsync(string fromCurrency, string toCurrency, string rateType, DateTime asOf);
}
