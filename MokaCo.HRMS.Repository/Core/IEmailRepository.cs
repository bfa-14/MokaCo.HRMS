using MokaCo.HRMS.Model.Core;

namespace MokaCo.HRMS.Repository.Core;

/// <summary>
/// The outbox: fill it, read it, record what happened. Four procedures and one read, no sending —
/// the socket belongs to the worker, and everything below it is rows.
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

    /// <summary>
    /// Queues the closing mail for ONE request on demand — core.usp_Email_QueueForRequest.
    ///
    /// THE MANUAL TWIN of QueueClosedRequestsAsync, and the only way to mail a request the automatic
    /// pass will not touch: one closed more than seven days ago, one CANCELLED (which the automatic
    /// pass skips deliberately), or one whose employee had no address at the time and has one now.
    ///
    /// IT IS ALSO THE RESEND. The procedure deletes any existing mail for the request first, so
    /// calling it twice replaces rather than duplicates — a second press cannot mail the employee
    /// the same decision twice.
    ///
    /// REFUSES BY RAISERROR (SqlException 50000) when the request is still open or the employee has
    /// no address. Both sentences name the fix, so they are meant to reach the user unaltered.
    /// </summary>
    /// <returns>The row written and the address it is addressed to.</returns>
    Task<QueuedEmail?> QueueForRequestAsync(int requestInstanceId, int? queuedByUserId);

    /// <summary>
    /// Every message queued for this request — one per channel — or an empty list when none was.
    ///
    /// A LIST, NOT A ROW. v2 queues an Email row and a WhatsApp row for the same request; they
    /// succeed and fail independently and the screen shows a line for each. Reading one row here
    /// would silently pick whichever the index returned first and call it "the" status.
    ///
    /// A PLAIN SELECT rather than a procedure, because there is no rule in it: four columns ordered
    /// by channel. A procedure here would add a name to remember and decide nothing.
    /// </summary>
    Task<IEnumerable<RequestEmailStatus>> GetStatusForRequestAsync(int requestInstanceId);
}
