using System.Data;
using Dapper;
using MokaCo.HRMS.Model.Core;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.Core;

/// <summary>
/// The system reset. Deliberately the thinnest possible wrapper: every rule that makes this safe —
/// the arming flag, the confirmation phrase, the transaction, the reseeding and the disarm — lives
/// in core.usp_System_ResetTestData, and re-implementing any of it here would create a second
/// definition of "safe" that could drift from the one that actually runs.
/// </summary>
public class SystemRepository : ISystemRepository
{
    private readonly IDbConnectionFactory _factory;
    public SystemRepository(IDbConnectionFactory factory) => _factory = factory;

    public async Task<IEnumerable<SystemResetSummaryRow>> ResetTestDataAsync(string confirm, int actedByUserId)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<SystemResetSummaryRow>(
            "core.usp_System_ResetTestData",
            new { Confirm = confirm, ActedByUserId = actedByUserId },
            commandType: CommandType.StoredProcedure,
            // It deletes across a dozen tables and reseeds each — well past the 30s default on a
            // database with real history behind it.
            commandTimeout: 300);
    }
}
