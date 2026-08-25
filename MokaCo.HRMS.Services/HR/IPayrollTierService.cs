using MokaCo.HRMS.Model.HR;

namespace MokaCo.HRMS.Services.HR;

public interface IPayrollTierService
{
    Task<IEnumerable<TaxBracket>> GetTaxBracketsAsync();
    Task<TaxBracket?> CreateTaxBracketAsync(TaxBracketUpsertRequest request);
    Task<TaxBracket?> UpdateTaxBracketAsync(int taxBracketId, TaxBracketUpsertRequest request);
    Task DeleteTaxBracketAsync(int taxBracketId);

    Task<IEnumerable<NssfRate>> GetNssfRatesAsync();
    Task<NssfRate?> CreateNssfRateAsync(NssfRateUpsertRequest request);
    Task<NssfRate?> UpdateNssfRateAsync(int nssfRateId, NssfRateUpsertRequest request);
}
