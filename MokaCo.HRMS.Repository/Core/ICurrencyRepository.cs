using MokaCo.HRMS.Model.Core;

namespace MokaCo.HRMS.Repository.Core;

public interface ICurrencyRepository
{
    Task<IEnumerable<Currency>> GetAllAsync();
    Task UpsertAsync(string currencyCode, string name, int decimalPlaces);

    /// <summary>
    /// Deletes a currency and its exchange rates (core.usp_Currency_Delete). The procedure refuses
    /// with a sentence naming where the code is used when anything still holds it.
    /// </summary>
    Task DeleteAsync(string currencyCode);
}
