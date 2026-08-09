using MokaCo.HRMS.Model.Core;

namespace MokaCo.HRMS.Services.Core;

public interface ICurrencyService
{
    Task<IEnumerable<Currency>> GetAllAsync();
    Task UpsertAsync(string currencyCode, string name, int decimalPlaces);
}
