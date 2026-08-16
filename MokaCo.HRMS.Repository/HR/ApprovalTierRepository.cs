using System.Data;
using Dapper;
using MokaCo.HRMS.Model.HR;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.HR;

/// <summary>
/// Dapper access for the approval-tier dictionary via hr.usp_ApprovalTier_*.
///
/// The DELETE is guarded IN THE PROCEDURE, not here: it refuses when employees or workflow
/// definitions still point at the tier, and the message it raises NAMES who. That message is the
/// whole value of the refusal, so it travels to the user untouched — see PayrollTierService.
/// </summary>
public class ApprovalTierRepository : IApprovalTierRepository
{
    private readonly IDbConnectionFactory _factory;
    public ApprovalTierRepository(IDbConnectionFactory factory) => _factory = factory;

    public async Task<IEnumerable<ApprovalTier>> GetAllAsync()
    {
        using var db = _factory.Create();
        return await db.QueryAsync<ApprovalTier>(
            "hr.usp_ApprovalTier_GetAll",
            commandType: CommandType.StoredProcedure);
    }

    public async Task<ApprovalTier?> CreateAsync(int tierNo, string name, string? nameAr)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<ApprovalTier>(
            "hr.usp_ApprovalTier_Create",
            new { TierNo = tierNo, Name = name, NameAr = nameAr },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<ApprovalTier?> SetNameAsync(int tierNo, string name, string? nameAr)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<ApprovalTier>(
            "hr.usp_ApprovalTier_SetName",
            new { TierNo = tierNo, Name = name, NameAr = nameAr },
            commandType: CommandType.StoredProcedure);
    }

    public async Task DeleteAsync(int tierNo)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "hr.usp_ApprovalTier_Delete",
            new { TierNo = tierNo },
            commandType: CommandType.StoredProcedure);
    }
}
