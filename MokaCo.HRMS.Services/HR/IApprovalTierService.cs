using MokaCo.HRMS.Model.HR;

namespace MokaCo.HRMS.Services.HR;

public interface IApprovalTierService
{
    Task<IEnumerable<ApprovalTier>> GetAllAsync();
    Task<ApprovalTier?> CreateAsync(int tierNo, string name, string? nameAr);
    Task<ApprovalTier?> SetNameAsync(int tierNo, string name, string? nameAr);
    Task DeleteAsync(int tierNo);
}
