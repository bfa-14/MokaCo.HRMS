using MokaCo.HRMS.Model.Core;

namespace MokaCo.HRMS.Services.Core;

/// <summary>
/// Outgoing mail, from the caller's side: queue one by hand. The automatic queueing and the sending
/// both belong to the worker, which talks to the repository directly — a background service has no
/// caller to serve and nothing to translate for.
/// </summary>
public interface IEmailService
{
    /// <summary>
    /// Queues (or re-queues) the closing mail for one request — core.usp_Email_QueueForRequest.
    ///
    /// RESEND IS THE SAME CALL. The procedure deletes any previous mail for the request before
    /// writing the new one, so pressing the button twice means one mail with today's body, not two
    /// describing the same decision.
    ///
    /// REFUSALS ARE THE DATABASE'S AND TRAVEL UNTOUCHED as SqlException 50000 — the request is still
    /// open, or the employee has no address. Both name what to do about them, so the API turns them
    /// into a 400 with the sentence intact rather than replacing it with a status of its own.
    /// </summary>
    Task<QueuedEmail?> QueueForRequestAsync(int requestInstanceId, int? queuedByUserId);

    /// <summary>
    /// Every message queued for this request, one per channel — Sent, Failed with the server's
    /// reason, or still Pending with the attempts so far. Empty when nothing was ever queued for it,
    /// which is the ordinary state of most requests.
    /// </summary>
    Task<IEnumerable<RequestEmailStatus>> GetStatusForRequestAsync(int requestInstanceId);
}
