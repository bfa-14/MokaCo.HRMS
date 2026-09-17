using MokaCo.HRMS.Model.HR;
using MokaCo.HRMS.Repository.HR;

namespace MokaCo.HRMS.Services.HR;

/// <summary>Leave-type administration (thin wrapper over the repository).</summary>
public class LeaveTypeService : ILeaveTypeService
{
    private readonly ILeaveTypeRepository _repo;
    public LeaveTypeService(ILeaveTypeRepository repo) => _repo = repo;

    public Task<IEnumerable<LeaveType>> GetAllAsync() => _repo.GetAllAsync();

    public Task<IEnumerable<LeaveRelationEntitlement>> GetRelationEntitlementsAsync()
        => _repo.GetRelationEntitlementsAsync();
    public Task<int> CreateAsync(string name, bool isPaid, bool carryOver)
        => _repo.CreateAsync(name, isPaid, carryOver);
    public Task UpdateAsync(int leaveTypeId, string name, bool isPaid, bool carryOver)
        => _repo.UpdateAsync(leaveTypeId, name, isPaid, carryOver);

    public Task<LeavePolicy> GetPolicyAsync() => _repo.GetPolicyAsync();

    /// <summary>
    /// THE PRESERVE RULE. A policy field arriving null on an UPDATE means "leave it alone", so the
    /// stored row is read first and the null coalesced against it.
    ///
    /// Without this, the older leave-types screen — which knows only the four original fields —
    /// would clear RequiresCertificate, the service gate, the notice period and the fixed
    /// entitlement every time someone renamed a type there. On a CREATE there is nothing to
    /// preserve, so nulls fall through to the procedure's own defaults.
    /// </summary>
    public async Task<LeaveType?> UpsertAsync(int? leaveTypeId, LeaveTypeUpsertRequest request)
    {
        LeaveType? existing = null;
        if (leaveTypeId is int id)
            existing = (await _repo.GetAllAsync()).FirstOrDefault(t => t.LeaveTypeId == id);

        // FixedEntitlementDays is the one field where null is a real value ("no fixed entitlement"),
        // so clearing it takes an explicit flag rather than an omitted field.
        var fixedDays = request.ClearFixedEntitlement
            ? null
            : request.FixedEntitlementDays ?? existing?.FixedEntitlementDays;

        return await _repo.UpsertAsync(
            leaveTypeId,
            request.Name,
            request.IsPaid,
            request.CarryOver,
            request.RequiresCertificate ?? existing?.RequiresCertificate ?? false,
            request.MinServiceMonthsToUse ?? existing?.MinServiceMonthsToUse ?? 0,
            request.NoticePreferredDays ?? existing?.NoticePreferredDays ?? 0,
            fixedDays,
            request.IsDiscretionary ?? existing?.IsDiscretionary ?? false,
            request.IsActive);
    }

    public Task SetAccrualTierAsync(int leaveTypeId, LeaveAccrualTierRequest request)
        => _repo.SetAccrualTierAsync(leaveTypeId, request.MinServiceYears, request.AnnualDays);

    public Task DeleteAccrualTierAsync(int leaveTypeId, int minServiceYears)
        => _repo.DeleteAccrualTierAsync(leaveTypeId, minServiceYears);

    public Task SetPayTierAsync(int leaveTypeId, LeavePayTierRequest request)
        => _repo.SetPayTierAsync(leaveTypeId, request.MinServiceYears, request.FullPayDays, request.HalfPayDays);

    public Task DeletePayTierAsync(int leaveTypeId, int minServiceYears)
        => _repo.DeletePayTierAsync(leaveTypeId, minServiceYears);

    public Task SetRelationAsync(int leaveTypeId, LeaveRelationRequest request)
        => _repo.SetRelationAsync(leaveTypeId, request.Relation.Trim(), request.Days);

    public Task DeleteRelationAsync(int leaveTypeId, string relation)
        => _repo.DeleteRelationAsync(leaveTypeId, relation);

    public Task DeleteAsync(int leaveTypeId)
        => ReferenceDataSqlErrors.MapAsync(() => _repo.DeleteAsync(leaveTypeId));

    public Task SetActiveAsync(int leaveTypeId, bool isActive)
        => ReferenceDataSqlErrors.MapAsync(() => _repo.SetActiveAsync(leaveTypeId, isActive));
}
