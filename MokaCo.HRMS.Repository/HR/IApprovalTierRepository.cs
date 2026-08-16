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
    Task DeleteAsync(int tierNo);
}
