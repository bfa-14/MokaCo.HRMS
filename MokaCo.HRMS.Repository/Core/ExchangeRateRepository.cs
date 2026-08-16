using System.Data;
using Dapper;
using MokaCo.HRMS.Model.Core;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.Core;

/// <summary>Dapper access for exchange rates via the core.usp_ExchangeRate_* stored procedures.</summary>
public class ExchangeRateRepository : IExchangeRateRepository
{
    private readonly IDbConnectionFactory _factory;
    public ExchangeRateRepository(IDbConnectionFactory factory) => _factory = factory;

    public async Task<IEnumerable<ExchangeRate>> GetAllAsync()
    {
        using var db = _factory.Create();
        return await db.QueryAsync<ExchangeRate>(
            "core.usp_ExchangeRate_GetAll",
            commandType: CommandType.StoredProcedure);
    }

    public async Task<int> CreateAsync(string fromCurrency, string toCurrency, string rateType, DateTime effectiveDate, decimal rate)
    {
        using var db = _factory.Create();
        return await db.ExecuteScalarAsync<int>(
            "core.usp_ExchangeRate_Create",
            new
            {
                FromCurrency = fromCurrency,
                ToCurrency = toCurrency,
                RateType = rateType,
                EffectiveDate = effectiveDate,
                Rate = rate
            },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>
    /// Corrects a rate's figure, and optionally the date it takes effect.
    ///
    /// Returns the stored row, so the caller shows what the database holds rather than an echo of
    /// what it sent — the procedure is where the uniqueness of (pair, type, date) is decided.
    /// </summary>
    public async Task<ExchangeRate?> UpdateAsync(int exchangeRateId, decimal rate, DateTime? effectiveDate)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<ExchangeRate>(
            "core.usp_ExchangeRate_Update",
            new
            {
                ExchangeRateId = exchangeRateId,
                Rate = rate,
                EffectiveDate = effectiveDate
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task DeleteAsync(int exchangeRateId)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "core.usp_ExchangeRate_Delete",
            new { ExchangeRateId = exchangeRateId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<ExchangeRate?> GetEffectiveAsync(string fromCurrency, string toCurrency, string rateType, DateTime asOf)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<ExchangeRate>(
            "core.usp_ExchangeRate_GetEffective",
            new
            {
                FromCurrency = fromCurrency,
                ToCurrency = toCurrency,
                RateType = rateType,
                AsOf = asOf
            },
            commandType: CommandType.StoredProcedure);
    }
}
