using System.Data;
using Dapper;
using MokaCo.HRMS.Model.HR;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.HR;

/// <summary>
/// Dapper access for the yearly leave opening — hr.usp_LeaveYear_Open, and nothing else.
///
/// Every rule belongs to the procedure: who is eligible, what the entitlement is, how a part year
/// is pro-rated, whether last year carries or expires, and who has already been opened. Nothing
/// here re-implements or second-guesses any of it; this calls it and returns its summary rows.
/// </summary>
public class LeaveYearRepository : ILeaveYearRepository
{
    private readonly IDbConnectionFactory _factory;
    public LeaveYearRepository(IDbConnectionFactory factory) => _factory = factory;

    public async Task<IEnumerable<LeaveYearOpenSummary>> OpenAsync(int year, int actedByUserId)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<LeaveYearOpenSummary>(
            "hr.usp_LeaveYear_Open",
            new { Year = year, ActedByUserId = actedByUserId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<LeaveCarryOverExpired> ExpireCarryOverAsync()
    {
        using var db = _factory.Create();
        return await db.QuerySingleAsync<LeaveCarryOverExpired>(
            "hr.usp_LeaveCarryOver_Expire", commandType: CommandType.StoredProcedure);
    }

    public async Task<int> ApplyDueBranchTransfersAsync()
    {
        using var db = _factory.Create();
        return await db.ExecuteScalarAsync<int>(
            "hr.usp_EmployeeBranch_ApplyDue", commandType: CommandType.StoredProcedure);
    }
}
