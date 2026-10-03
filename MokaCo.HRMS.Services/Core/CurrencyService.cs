using MokaCo.HRMS.Model.Core;
using MokaCo.HRMS.Repository.Core;

namespace MokaCo.HRMS.Services.Core;

/// <summary>Currency administration (thin wrapper over the repository).</summary>
public class CurrencyService : ICurrencyService
{
    private readonly ICurrencyRepository _repo;
    public CurrencyService(ICurrencyRepository repo) => _repo = repo;

    public Task<IEnumerable<Currency>> GetAllAsync() => _repo.GetAllAsync();

    public Task UpsertAsync(string currencyCode, string name, int decimalPlaces)
        => _repo.UpsertAsync(currencyCode, name, decimalPlaces);

    public Task DeleteAsync(string currencyCode) => _repo.DeleteAsync(currencyCode.Trim().ToUpperInvariant());
}
