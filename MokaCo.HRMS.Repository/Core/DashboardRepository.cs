using System.Data;
using Dapper;
using MokaCo.HRMS.Model.Core;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.Core;

/// <summary>
/// The dashboard read — core.usp_Dashboard_Get, TEN result sets, ONE round trip.
///
/// One procedure rather than ten calls because the page is a single statement about a single moment:
/// ten separate reads would let the "waiting on you" count come from one instant and the requests
/// underneath it from another, and the two would disagree in front of the user.
///
/// THE SETS MUST BE READ IN ORDER AND ALL OF THEM. Dapper's GridReader is a forward-only cursor over
/// the open result stream — skipping one shifts every set after it onto the wrong model, silently, and
/// the failure looks like empty cards rather than an error. The order below is the procedure's order;
/// if a set is ever added there, it must be added here in the same position.
///
/// Only <see cref="Dashboard.CompanySnapshot"/> is read as a single-or-default: the procedure emits it
/// for a managerial caller and NOT AT ALL otherwise, which is exactly the distinction the client needs.
/// </summary>
public class DashboardRepository : IDashboardRepository
{
    private readonly IDbConnectionFactory _factory;
    public DashboardRepository(IDbConnectionFactory factory) => _factory = factory;

    public async Task<Dashboard> GetAsync(int userId)
    {
        using var db = _factory.Create();
        using var multi = await db.QueryMultipleAsync(
            "core.usp_Dashboard_Get",
            new { UserId = userId },
            commandType: CommandType.StoredProcedure);

        return new Dashboard
        {
            WaitingOnMe = (await multi.ReadAsync<WaitingOnMeItem>()).ToList(),
            MyRequests = (await multi.ReadAsync<MyOpenRequest>()).ToList(),
            RecentActivity = (await multi.ReadAsync<DashboardActivity>()).ToList(),
            LeaveBalances = (await multi.ReadAsync<DashboardLeaveBalance>()).ToList(),
            CoverageGaps = (await multi.ReadAsync<CoverageGap>()).ToList(),
            CompanySnapshot = await multi.ReadSingleOrDefaultAsync<CompanySnapshot>(),
            StaffingToday = (await multi.ReadAsync<BranchStaffing>()).ToList(),
            OnLeaveToday = (await multi.ReadAsync<OnLeaveToday>()).ToList(),
            WorkflowByType = (await multi.ReadAsync<OpenRequestsByType>()).ToList(),
            MonthMoney = (await multi.ReadAsync<MonthMoneyLine>()).ToList(),
        };
    }
}
