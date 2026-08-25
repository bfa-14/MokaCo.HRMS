using MokaCo.HRMS.Model.HR;

namespace MokaCo.HRMS.Repository.HR;

/// <summary>
/// The two rate tables payroll computes from — income tax brackets and NSSF schemes.
///
/// Both are POLICY tables, so both are read far more often than written, and neither is touched by
/// payroll generation: the generation procedure reads them itself.
/// </summary>
public interface IPayrollTierRepository
{
    Task<IEnumerable<TaxBracket>> GetTaxBracketsAsync();
    Task<TaxBracket?> CreateTaxBracketAsync(TaxBracketUpsertRequest request);
    Task<TaxBracket?> UpdateTaxBracketAsync(int taxBracketId, TaxBracketUpsertRequest request);
    Task DeleteTaxBracketAsync(int taxBracketId);

    Task<IEnumerable<NssfRate>> GetNssfRatesAsync();
    Task<NssfRate?> CreateNssfRateAsync(NssfRateUpsertRequest request);
    Task<NssfRate?> UpdateNssfRateAsync(int nssfRateId, NssfRateUpsertRequest request);
}
