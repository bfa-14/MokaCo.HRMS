using MokaCo.HRMS.Model.HR;

namespace MokaCo.HRMS.Repository.HR;

public interface ILeaveTypeRepository
{
    Task<IEnumerable<LeaveType>> GetAllAsync();

    /// <summary>
    /// Every (leave type, relation) entitlement. Returned whole rather than per type: it is a handful
    /// of rows, and the form needs to know which types ask for a relation AT ALL before one is picked.
    /// </summary>
    Task<IEnumerable<LeaveRelationEntitlement>> GetRelationEntitlementsAsync();

    Task<int> CreateAsync(string name, bool isPaid, bool carryOver);
    Task UpdateAsync(int leaveTypeId, string name, bool isPaid, bool carryOver);

    /* ---- the whole policy: one read, and the writes behind the leave-policy screen ---- */

    /// <summary>The four result sets of hr.usp_LeavePolicy_GetAll: types, accrual tiers, pay tiers, relations.</summary>
    Task<LeavePolicy> GetPolicyAsync();

    /// <summary>
    /// Creates (leaveTypeId null) or updates a leave type. Returns the row as stored, so the caller
    /// binds from the SAVE rather than re-reading. RAISERRORs on a duplicate name.
    /// </summary>
    Task<LeaveType?> UpsertAsync(
        int? leaveTypeId, string name, bool isPaid, bool carryOver,
        bool requiresCertificate, int minServiceMonthsToUse, int noticePreferredDays,
        decimal? fixedEntitlementDays, bool isDiscretionary);

    Task SetAccrualTierAsync(int leaveTypeId, int minServiceYears, decimal annualDays);
    Task DeleteAccrualTierAsync(int leaveTypeId, int minServiceYears);

    Task SetPayTierAsync(int leaveTypeId, int minServiceYears, int fullPayDays, int halfPayDays);
    Task DeletePayTierAsync(int leaveTypeId, int minServiceYears);

    Task SetRelationAsync(int leaveTypeId, string relation, decimal days);
    Task DeleteRelationAsync(int leaveTypeId, string relation);
}
