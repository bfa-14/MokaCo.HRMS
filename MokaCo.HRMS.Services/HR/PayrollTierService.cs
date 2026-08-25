using MokaCo.HRMS.Model.HR;
using MokaCo.HRMS.Repository.HR;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Services.HR;

/// <summary>
/// The payroll rate tables.
///
/// EVERY WRITE GOES THROUGH WorkflowSqlErrors, and every rule these tables have lives in the
/// procedures rather than here. The procedures already validate the ranges (rates 0..1, a ceiling
/// above zero when a scheme is ceilinged, a bracket's ceiling above its floor) and RAISERROR a
/// sentence that names what is wrong; re-checking the same rules in C# would give two authorities
/// that can disagree, and the one further from the data would win. So the database decides and this
/// layer's whole job is turning its refusal into a 400 with the text intact.
/// </summary>
public class PayrollTierService : IPayrollTierService
{
    private readonly IPayrollTierRepository _repo;
    public PayrollTierService(IPayrollTierRepository repo) => _repo = repo;

    public Task<IEnumerable<TaxBracket>> GetTaxBracketsAsync() => _repo.GetTaxBracketsAsync();

    public Task<TaxBracket?> CreateTaxBracketAsync(TaxBracketUpsertRequest request)
        => WorkflowSqlErrors.MapAsync(() => _repo.CreateTaxBracketAsync(request));

    public Task<TaxBracket?> UpdateTaxBracketAsync(int taxBracketId, TaxBracketUpsertRequest request)
        => WorkflowSqlErrors.MapAsync(() => _repo.UpdateTaxBracketAsync(taxBracketId, request));

    public Task DeleteTaxBracketAsync(int taxBracketId)
        => WorkflowSqlErrors.MapAsync(async () =>
        {
            await _repo.DeleteTaxBracketAsync(taxBracketId);
            return true;
        });

    public Task<IEnumerable<NssfRate>> GetNssfRatesAsync() => _repo.GetNssfRatesAsync();

    public Task<NssfRate?> CreateNssfRateAsync(NssfRateUpsertRequest request)
        => WorkflowSqlErrors.MapAsync(() => _repo.CreateNssfRateAsync(request));

    public Task<NssfRate?> UpdateNssfRateAsync(int nssfRateId, NssfRateUpsertRequest request)
        => WorkflowSqlErrors.MapAsync(() => _repo.UpdateNssfRateAsync(nssfRateId, request));
}
