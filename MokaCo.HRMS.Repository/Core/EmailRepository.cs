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

    /// <summary>
    /// QuerySingleOrDefault, not QuerySingle: the procedure RAISERRORs and RETURNs on every refusal,
    /// so a call that is going to fail produces no result set at all. The refusal arrives here as a
    /// SqlException either way — but QuerySingle would replace that message with "sequence contains
    /// no elements" if the shape ever changed, and the message is the entire value of the failure.
    /// </summary>
    /// <summary>
    /// [Status] is bracketed because it is a reserved word in enough dialects to be worth never
    /// thinking about again; SentUtc and Error come back as they are stored.
    /// </summary>
    private const string StatusSql = @"
SELECT Channel, [Status], AttemptCount, Error, SentUtc
FROM core.EMAIL_OUTBOX
WHERE RequestInstanceId = @RequestInstanceId
ORDER BY Channel;";

    /// <summary>
    /// Ordered by CHANNEL rather than by id, so Email always reads above WhatsApp however the rows
    /// happened to be inserted — a status block that reorders itself between visits reads as though
    /// something changed.
    /// </summary>
    public async Task<IEnumerable<RequestEmailStatus>> GetStatusForRequestAsync(int requestInstanceId)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<RequestEmailStatus>(
            StatusSql,
            new { RequestInstanceId = requestInstanceId });
    }

    public async Task<QueuedEmail?> QueueForRequestAsync(int requestInstanceId, int? queuedByUserId)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<QueuedEmail>(
            "core.usp_Email_QueueForRequest",
            new { RequestInstanceId = requestInstanceId, QueuedByUserId = queuedByUserId },
            commandType: CommandType.StoredProcedure);
    }
}
