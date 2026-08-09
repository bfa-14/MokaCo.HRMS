using MokaCo.HRMS.Model.HR;

namespace MokaCo.HRMS.Services.HR;

public interface ILeaveTypeService
{
    Task<IEnumerable<LeaveType>> GetAllAsync();

    /// <summary>Every (leave type, relation) entitlement — which types ask for a relation, and each one's day cap.</summary>
    Task<IEnumerable<LeaveRelationEntitlement>> GetRelationEntitlementsAsync();

    Task<int> CreateAsync(string name, bool isPaid, bool carryOver);
    Task UpdateAsync(int leaveTypeId, string name, bool isPaid, bool carryOver);

    /// <summary>The whole leave policy in one read — types with their accrual tiers, pay tiers and relations.</summary>
    Task<LeavePolicy> GetPolicyAsync();

    /// <summary>
    /// Creates (leaveTypeId null) or updates a leave type. A policy field left NULL on an update
    /// keeps its stored value — see <see cref="LeaveTypeUpsertRequest"/> for why that matters.
    /// </summary>
    Task<LeaveType?> UpsertAsync(int? leaveTypeId, LeaveTypeUpsertRequest request);

    Task SetAccrualTierAsync(int leaveTypeId, LeaveAccrualTierRequest request);
    Task DeleteAccrualTierAsync(int leaveTypeId, int minServiceYears);

    Task SetPayTierAsync(int leaveTypeId, LeavePayTierRequest request);
    Task DeletePayTierAsync(int leaveTypeId, int minServiceYears);

    Task SetRelationAsync(int leaveTypeId, LeaveRelationRequest request);
    Task DeleteRelationAsync(int leaveTypeId, string relation);
}
