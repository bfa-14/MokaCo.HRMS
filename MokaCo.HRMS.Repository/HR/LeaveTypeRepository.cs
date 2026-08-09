using System.Data;
using Dapper;
using MokaCo.HRMS.Model.HR;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.HR;

/// <summary>Dapper access for leave types via the hr.usp_LeaveType_* stored procedures.</summary>
public class LeaveTypeRepository : ILeaveTypeRepository
{
    private readonly IDbConnectionFactory _factory;
    public LeaveTypeRepository(IDbConnectionFactory factory) => _factory = factory;

    public async Task<IEnumerable<LeaveType>> GetAllAsync()
    {
        using var db = _factory.Create();
        return await db.QueryAsync<LeaveType>(
            "hr.usp_LeaveType_GetAll",
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<LeaveRelationEntitlement>> GetRelationEntitlementsAsync()
    {
        using var db = _factory.Create();
        return await db.QueryAsync<LeaveRelationEntitlement>(
            "hr.usp_LeaveRelationEntitlement_GetAll",
            commandType: CommandType.StoredProcedure);
    }

    public async Task<LeavePolicy> GetPolicyAsync()
    {
        using var db = _factory.Create();
        using var grid = await db.QueryMultipleAsync(
            "hr.usp_LeavePolicy_GetAll",
            commandType: CommandType.StoredProcedure);

        // Read in the procedure's own order: types, accrual tiers, pay tiers, relations. Each grid
        // must be consumed before the next, so these cannot be reordered or made lazy.
        return new LeavePolicy
        {
            Types = (await grid.ReadAsync<LeaveType>()).ToList(),
            AccrualTiers = (await grid.ReadAsync<LeaveAccrualTier>()).ToList(),
            PayTiers = (await grid.ReadAsync<LeavePayTier>()).ToList(),
            Relations = (await grid.ReadAsync<LeaveRelationEntitlement>()).ToList(),
        };
    }

    public async Task<LeaveType?> UpsertAsync(
        int? leaveTypeId, string name, bool isPaid, bool carryOver,
        bool requiresCertificate, int minServiceMonthsToUse, int noticePreferredDays,
        decimal? fixedEntitlementDays, bool isDiscretionary)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<LeaveType>(
            "hr.usp_LeaveType_Upsert",
            new
            {
                LeaveTypeId = leaveTypeId,
                Name = name,
                IsPaid = isPaid,
                CarryOver = carryOver,
                RequiresCertificate = requiresCertificate,
                MinServiceMonthsToUse = minServiceMonthsToUse,
                NoticePreferredDays = noticePreferredDays,
                FixedEntitlementDays = fixedEntitlementDays,
                IsDiscretionary = isDiscretionary,
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task SetAccrualTierAsync(int leaveTypeId, int minServiceYears, decimal annualDays)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "hr.usp_LeaveAccrualTier_Set",
            new { LeaveTypeId = leaveTypeId, MinServiceYears = minServiceYears, AnnualDays = annualDays },
            commandType: CommandType.StoredProcedure);
    }

    public async Task DeleteAccrualTierAsync(int leaveTypeId, int minServiceYears)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "hr.usp_LeaveAccrualTier_Delete",
            new { LeaveTypeId = leaveTypeId, MinServiceYears = minServiceYears },
            commandType: CommandType.StoredProcedure);
    }

    public async Task SetPayTierAsync(int leaveTypeId, int minServiceYears, int fullPayDays, int halfPayDays)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "hr.usp_LeavePayTier_Set",
            new
            {
                LeaveTypeId = leaveTypeId,
                MinServiceYears = minServiceYears,
                FullPayDays = fullPayDays,
                HalfPayDays = halfPayDays,
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task DeletePayTierAsync(int leaveTypeId, int minServiceYears)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "hr.usp_LeavePayTier_Delete",
            new { LeaveTypeId = leaveTypeId, MinServiceYears = minServiceYears },
            commandType: CommandType.StoredProcedure);
    }

    public async Task SetRelationAsync(int leaveTypeId, string relation, decimal days)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "hr.usp_LeaveRelation_Set",
            new { LeaveTypeId = leaveTypeId, Relation = relation, Days = days },
            commandType: CommandType.StoredProcedure);
    }

    public async Task DeleteRelationAsync(int leaveTypeId, string relation)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "hr.usp_LeaveRelation_Delete",
            new { LeaveTypeId = leaveTypeId, Relation = relation },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<int> CreateAsync(string name, bool isPaid, bool carryOver)
    {
        using var db = _factory.Create();
        return await db.ExecuteScalarAsync<int>(
            "hr.usp_LeaveType_Create",
            new { Name = name, IsPaid = isPaid, CarryOver = carryOver },
            commandType: CommandType.StoredProcedure);
    }

    public async Task UpdateAsync(int leaveTypeId, string name, bool isPaid, bool carryOver)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "hr.usp_LeaveType_Update",
            new { LeaveTypeId = leaveTypeId, Name = name, IsPaid = isPaid, CarryOver = carryOver },
            commandType: CommandType.StoredProcedure);
    }
}
