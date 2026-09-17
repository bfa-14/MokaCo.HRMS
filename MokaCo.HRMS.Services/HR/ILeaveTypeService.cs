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

    /// <summary>
    /// Deletes an unused row. A row anything references is refused with a
    /// <see cref="MokaCo.HRMS.Services.Workflow.WorkflowException"/> carrying 409 and the sentence
    /// to show ("Cannot delete 'X': it is used by … . Deactivate it instead."); unknown id → 404.
    /// </summary>
    Task DeleteAsync(int leaveTypeId);

    /// <summary>Activates / deactivates without deleting. Unknown id → WorkflowException 404.</summary>
    Task SetActiveAsync(int leaveTypeId, bool isActive);
}
