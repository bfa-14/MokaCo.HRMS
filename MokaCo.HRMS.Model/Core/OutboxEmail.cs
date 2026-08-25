namespace MokaCo.HRMS.Model.Core;

/// <summary>
/// One mail waiting to go out — core.usp_Email_GetPending.
///
/// THE OUTBOX IS THE POINT, not an implementation detail. A request closing and the mail about it
/// leaving are two different events that fail in different ways: the approval must commit whether or
/// not a mail server is reachable, and a mail server that is down at 09:00 must not lose the news.
/// So the closing writes a ROW, and sending is a separate, retryable act against that row.
///
/// The body is composed in SQL, beside the data it describes, which is why nothing here formats
/// anything: this type carries an addressed, finished message that only needs a socket.
/// </summary>
public class OutboxEmail
{
    public int EmailId { get; set; }
    public string ToAddress { get; set; } = string.Empty;
    public string Subject { get; set; } = string.Empty;
    public string Body { get; set; } = string.Empty;

    /// <summary>
    /// 'Email' or 'WhatsApp' — WHICH TRANSPORT, and therefore which half of the worker runs.
    ///
    /// The queueing procedure writes one row per channel per request, so a person with both an
    /// address and a number gets two rows that succeed and fail independently. That is the point:
    /// a bounced email must not suppress the WhatsApp message, and neither retries the other.
    /// </summary>
    public string Channel { get; set; } = "Email";

    /// <summary>
    /// 'en' or 'ar', copied from the employee at queue time — not read live.
    ///
    /// FROZEN ON PURPOSE. The body was composed in this language; asking for a WhatsApp template in
    /// a different one than the text it carries would send an Arabic sentence through an English
    /// template. Somebody changing their preference later changes their NEXT message, not this one.
    /// </summary>
    public string Lang { get; set; } = "en";

    /// <summary>
    /// The request this message is about, or null for anything queued outside the request flow.
    /// It is what the PDF is built from — no request, no attachment, and the mail still goes.
    /// </summary>
    public int? RequestInstanceId { get; set; }
}

/// <summary>
/// What core.usp_Email_QueueForRequest hands back after queueing one mail by hand — the row it
/// wrote and the address it is addressed to.
///
/// THE ADDRESS IS THE POINT OF RETURNING ANYTHING. The person pressing "Email the employee" is
/// almost never the employee, and "Queued" on its own does not tell them whether it is going to the
/// address they meant. Naming it back closes that loop before the mail leaves, while correcting a
/// wrong address on the employee page and pressing the button again still costs nothing.
/// </summary>
public class QueuedEmail
{
    public int EmailId { get; set; }
    public string ToAddress { get; set; } = string.Empty;
}

/// <summary>
/// Where this request's mail got to — the outbox row, read back for the screen that queued it.
///
/// ONE ROW PER REQUEST PER CHANNEL, guaranteed by the unique index UX_EMAIL_OUTBOX_RequestChannel.
/// So this is read as a LIST — an Email row and a WhatsApp row for the same request are two separate
/// messages with two separate outcomes, and collapsing them to one status would have to lie about
/// one of them.
///
/// AN EMPTY LIST IS A STATE, AND IT IS THE COMMON ONE — nothing has ever been queued for this
/// request. The API answers 204 for it rather than inventing a status meaning "none", because no
/// mail is the absence of the record, not a value it could hold.
/// </summary>
public class RequestEmailStatus
{
    /// <summary>'Email' or 'WhatsApp' — one row per channel, so the screen says which one it means.</summary>
    public string Channel { get; set; } = "Email";

    /// <summary>Pending, Sent or Failed — core.EMAIL_OUTBOX.Status, unabridged.</summary>
    public string Status { get; set; } = string.Empty;

    /// <summary>
    /// How many sends have been attempted. Shown against the ceiling of 3 while a row is still
    /// Pending — "attempt 2/3" is the difference between a message that is retrying and one that is
    /// simply sitting there, which the status alone cannot tell you.
    /// </summary>
    public int AttemptCount { get; set; }

    /// <summary>Why the send failed, as the mail server said it. Null unless Status is Failed.</summary>
    public string? Error { get; set; }

    /// <summary>When it actually left. Null until it does.</summary>
    public DateTime? SentUtc { get; set; }
}
