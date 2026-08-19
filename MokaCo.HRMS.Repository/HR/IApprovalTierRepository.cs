using MokaCo.HRMS.Model.HR;

namespace MokaCo.HRMS.Repository.HR;

/// <summary>
/// The seniority dictionary — hr.APPROVAL_TIER, read by every screen that prints a tier.
/// </summary>
public interface IApprovalTierRepository
{
    Task<IEnumerable<ApprovalTier>> GetAllAsync();
    Task<ApprovalTier?> CreateAsync(int tierNo, string name, string? nameAr);
    Task<ApprovalTier?> SetNameAsync(int tierNo, string name, string? nameAr);

    /// <summary>
    /// Sets the basic-salary band for a tier. Either bound may be null, meaning "no bound" rather
    /// than "leave alone". The procedure refuses a min above a max and an unknown currency, by
    /// RAISERROR — those sentences reach the user unchanged.
    /// </summary>
    Task<ApprovalTier?> SetSalaryRangeAsync(
        int tierNo, decimal? minBasicSalary, decimal? maxBasicSalary, string salaryCurrency);

    Task DeleteAsync(int tierNo);
}
