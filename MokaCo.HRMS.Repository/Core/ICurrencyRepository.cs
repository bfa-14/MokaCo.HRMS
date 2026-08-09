using MokaCo.HRMS.Model.Core;

namespace MokaCo.HRMS.Repository.Core;

public interface ICurrencyRepository
{
    Task<IEnumerable<Currency>> GetAllAsync();
    Task UpsertAsync(string currencyCode, string name, int decimalPlaces);
}
