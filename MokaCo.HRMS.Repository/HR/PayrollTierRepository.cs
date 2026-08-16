using System.Data;
using Dapper;
using MokaCo.HRMS.Model.HR;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.HR;

/// <summary>
/// Dapper access for the payroll rate tables via the hr.usp_TaxBracket_* and hr.usp_NssfRate_*
/// stored procedures. Procedure calls only — no inline SQL, as everywhere else in this layer.
///
/// The _Create and _Update procedures SELECT the affected row back, so the caller gets the stored
/// values rather than an echo of what it sent. That matters here: the procedures validate and the
/// database is where a rate's final shape is decided.
/// </summary>
public class PayrollTierRepository : IPayrollTierRepository
{
    private readonly IDbConnectionFactory _factory;
    public PayrollTierRepository(IDbConnectionFactory factory) => _factory = factory;

    /* ── income tax brackets ─────────────────────────────────────────────────────────────────── */

    public async Task<IEnumerable<TaxBracket>> GetTaxBracketsAsync()
    {
        using var db = _factory.Create();
        return await db.QueryAsync<TaxBracket>(
            "hr.usp_TaxBracket_GetAll",
            commandType: CommandType.StoredProcedure);
    }

    public async Task<TaxBracket?> CreateTaxBracketAsync(TaxBracketUpsertRequest request)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<TaxBracket>(
            "hr.usp_TaxBracket_Create",
            new
            {
                request.MinAnnual,
                request.MaxAnnual,
                request.Rate,
                request.CurrencyCode,
                request.EffectiveFrom,
                request.EffectiveTo,
                request.Note,
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<TaxBracket?> UpdateTaxBracketAsync(int taxBracketId, TaxBracketUpsertRequest request)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<TaxBracket>(
            "hr.usp_TaxBracket_Update",
            new
            {
                TaxBracketId = taxBracketId,
                request.MinAnnual,
                request.MaxAnnual,
                request.Rate,
                request.CurrencyCode,
                request.EffectiveFrom,
                request.EffectiveTo,
                request.Note,
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task DeleteTaxBracketAsync(int taxBracketId)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "hr.usp_TaxBracket_Delete",
            new { TaxBracketId = taxBracketId },
            commandType: CommandType.StoredProcedure);
    }

    /* ── NSSF schemes ────────────────────────────────────────────────────────────────────────────
       No delete, deliberately: a scheme version is what an already-generated run computed from, and
       removing it would leave those figures unexplained. A rate that changes gets a NEW version. */

    public async Task<IEnumerable<NssfRate>> GetNssfRatesAsync()
    {
        using var db = _factory.Create();
        return await db.QueryAsync<NssfRate>(
            "hr.usp_NssfRate_GetAll",
            commandType: CommandType.StoredProcedure);
    }

    public async Task<NssfRate?> CreateNssfRateAsync(NssfRateUpsertRequest request)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<NssfRate>(
            "hr.usp_NssfRate_Create",
            new
            {
                request.Scheme,
                request.EmployeeRate,
                request.EmployerRate,
                request.IsCeilinged,
                request.CeilingAmount,
                request.EffectiveFrom,
                request.EffectiveTo,
                request.Note,
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<NssfRate?> UpdateNssfRateAsync(int nssfRateId, NssfRateUpsertRequest request)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<NssfRate>(
            "hr.usp_NssfRate_Update",
            new
            {
                NssfRateId = nssfRateId,
                request.Scheme,
                request.EmployeeRate,
                request.EmployerRate,
                request.IsCeilinged,
                request.CeilingAmount,
                request.EffectiveFrom,
                request.EffectiveTo,
                request.Note,
            },
            commandType: CommandType.StoredProcedure);
    }
}
