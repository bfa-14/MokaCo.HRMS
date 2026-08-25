using MokaCo.HRMS.Model.HR;

namespace MokaCo.HRMS.Services.HR;

public interface IApprovalTierService
{
    Task<IEnumerable<ApprovalTier>> GetAllAsync();
    Task<ApprovalTier?> CreateAsync(int tierNo, string name, string? nameAr);
    Task<ApprovalTier?> SetNameAsync(int tierNo, string name, string? nameAr);

    /// <summary>
    /// Sets the basic-salary band for a tier. Either bound may be null, meaning "no bound". The
    /// procedure's refusals (min above max, unknown currency) arrive as 400s with the text intact.
    /// </summary>
    Task<ApprovalTier?> SetSalaryRangeAsync(
        int tierNo, decimal? minBasicSalary, decimal? maxBasicSalary, string salaryCurrency);

    Task DeleteAsync(int tierNo);
}
