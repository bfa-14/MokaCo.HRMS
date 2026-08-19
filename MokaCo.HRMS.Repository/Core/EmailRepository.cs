using System.Data;
using Dapper;
using MokaCo.HRMS.Model.Core;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.Core;

/// <summary>Dapper access to the mail outbox via the core.usp_Email_* stored procedures.</summary>
public class EmailRepository : IEmailRepository
{
    private readonly IDbConnectionFactory _factory;
    public EmailRepository(IDbConnectionFactory factory) => _factory = factory;

    /// <summary>
    /// The procedure returns its row count as a result set — but returns NOTHING AT ALL when the
    /// NotifyOnRequestClosed setting is off, because it RETURNs before the SELECT. QuerySingleOrDefault
    /// over an int? is what makes both shapes readable; QuerySingle would throw on the switched-off
    /// case, which is a perfectly ordinary state and not an error.
    /// </summary>
    public async Task<int> QueueClosedRequestsAsync()
    {
        using var db = _factory.Create();
        var queued = await db.QuerySingleOrDefaultAsync<int?>(
            "core.usp_Email_QueueClosedRequests",
            commandType: CommandType.StoredProcedure);
        return queued ?? 0;
    }

    public async Task<IEnumerable<OutboxEmail>> GetPendingAsync()
    {
        using var db = _factory.Create();
        return await db.QueryAsync<OutboxEmail>(
            "core.usp_Email_GetPending",
            commandType: CommandType.StoredProcedure);
    }

    public async Task MarkResultAsync(int emailId, bool ok, string? error)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "core.usp_Email_MarkResult",
            new { EmailId = emailId, Ok = ok, Error = error },
            commandType: CommandType.StoredProcedure);
    }
}
