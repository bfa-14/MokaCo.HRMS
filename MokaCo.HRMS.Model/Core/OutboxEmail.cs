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
}
