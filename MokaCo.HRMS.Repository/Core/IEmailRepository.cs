using MokaCo.HRMS.Model.Core;

namespace MokaCo.HRMS.Repository.Core;

/// <summary>
/// The outbox: fill it, read it, record what happened. Three procedures, no sending — the socket
/// belongs to the worker, and everything below it is rows.
/// </summary>
public interface IEmailRepository
{
    /// <summary>
    /// Writes a mail for every recently CLOSED request whose employee has an address and has not
    /// been written one already — core.usp_Email_QueueClosedRequests.
    ///
    /// SAFE TO CALL EVERY MINUTE FOREVER. The procedure checks NotifyOnRequestClosed itself, only
    /// looks back seven days (so the first ever run does not mail a year of history), and a unique
    /// filtered index on RequestInstanceId means one mail per request even if two callers race.
    /// </summary>
    /// <returns>How many rows this call added — 0 on almost every cycle, which is normal.</returns>
    Task<int> QueueClosedRequestsAsync();

    /// <summary>The next batch to send — the procedure caps it, so a backlog drains steadily.</summary>
    Task<IEnumerable<OutboxEmail>> GetPendingAsync();

    /// <summary>
    /// Records the outcome for ONE mail — core.usp_Email_MarkResult.
    ///
    /// Must be called for a failure as surely as for a success: a mail left Pending after a genuine
    /// rejection is retried every minute for ever, and the log fills with the same error while the
    /// queue never moves.
    /// </summary>
    Task MarkResultAsync(int emailId, bool ok, string? error);
}
