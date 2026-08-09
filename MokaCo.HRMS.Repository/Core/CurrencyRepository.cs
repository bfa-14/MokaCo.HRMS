using System.Data;
using Dapper;
using MokaCo.HRMS.Model.Core;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.Core;

/// <summary>Dapper access for currencies via the core.usp_Currency_* stored procedures.</summary>
public class CurrencyRepository : ICurrencyRepository
{
    private readonly IDbConnectionFactory _factory;
    public CurrencyRepository(IDbConnectionFactory factory) => _factory = factory;

    public async Task<IEnumerable<Currency>> GetAllAsync()
    {
        using var db = _factory.Create();
        return await db.QueryAsync<Currency>(
            "core.usp_Currency_GetAll",
            commandType: CommandType.StoredProcedure);
    }

    public async Task UpsertAsync(string currencyCode, string name, int decimalPlaces)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "core.usp_Currency_Upsert",
            new { CurrencyCode = currencyCode, Name = name, DecimalPlaces = decimalPlaces },
            commandType: CommandType.StoredProcedure);
    }
}
