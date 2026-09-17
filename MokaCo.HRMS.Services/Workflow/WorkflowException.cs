using Microsoft.Data.SqlClient;

namespace MokaCo.HRMS.Services.Workflow;

/// <summary>
/// A workflow rule the caller broke, carrying the HTTP status the controller should return and a
/// message safe to show. Used for both the two C#-enforced authorisation rules and the errors the
/// stored procedures raise.
/// </summary>
public class WorkflowException : Exception
{
    public int StatusCode { get; }

    public WorkflowException(int statusCode, string message) : base(message)
        => StatusCode = statusCode;
}

/// <summary>
/// Translates the SQL errors the request procedures raise into clean HTTP responses.
///
/// This is the ONLY place approver authorisation is "handled" in C# — and it does not RE-CHECK
/// anything. usp_Request_Approve/Reject/Cancel decide for themselves whether the caller may act and
/// raise a message when they may not; this turns that message into the right status code, message
/// intact, so the database stays the single authority on who may sign.
/// </summary>
public static class WorkflowSqlErrors
{
    /// <summary>
    /// Runs a repository call and maps any SQL-raised workflow error to a <see cref="WorkflowException"/>.
    /// A message about being the wrong approver is a 403; a rule violation (closed request, missing
    /// reason, unpublished chain) is a 400. Anything unrecognised is left to bubble as a real 500.
    /// </summary>
    public static async Task<T> MapAsync<T>(Func<Task<T>> call)
    {
        try
        {
            return await call();
        }
        catch (SqlException ex) when (ex.Number == 50000)
        {
            throw MapMessage(ex.Message);
        }
    }

    /// <summary>
    /// The status a procedure's refusal maps to, decided from its wording alone — public so the rules
    /// can be tested without a database. The message travels untouched in every case.
    /// </summary>
    public static WorkflowException MapMessage(string message)
    {
        // "You are not the approver for this step." — the authorisation failure the DB owns.
        if (message.Contains("not the approver", StringComparison.OrdinalIgnoreCase))
            return new WorkflowException(403, message);

        // The reversals' authorisation failures, which are the same KIND of answer: not a bad
        // request, but the wrong person asking. Matched on the procedures' own wording so the
        // status is right; the message still travels untouched, because each one names the path
        // that WOULD work (the GM + Owner route, or the other of the two).
        if (message.Contains("may retract it", StringComparison.OrdinalIgnoreCase)
            || message.Contains("needs the General Manager and the Owner", StringComparison.OrdinalIgnoreCase)
            || message.Contains("already signed the reopen", StringComparison.OrdinalIgnoreCase))
            return new WorkflowException(403, message);

        // A CONFLICT with what already exists, not a bad request: a roster already waiting for
        // approval, one approved and unchanged since, or a clear blocked by an approval or by
        // attendance already recorded (72_roster_submit_guard_and_clear.sql). The UI shows the
        // sentence and disables the button; 409 tells it which of the two happened.
        if (message.StartsWith("This roster is already waiting", StringComparison.OrdinalIgnoreCase)
            || message.StartsWith("This roster was approved on", StringComparison.OrdinalIgnoreCase)
            || message.StartsWith("This roster cannot be cleared", StringComparison.OrdinalIgnoreCase))
            return new WorkflowException(409, message);

        // The roster lock (75_roster_approval_applies_and_locks.sql): a day of an approved month
        // that is already in the past or already judged by attendance, or a month with a roster
        // approval still open. Same kind of answer — the state of the month refuses the edit.
        if (message.StartsWith("This day is already in an approved roster", StringComparison.OrdinalIgnoreCase)
            || message.StartsWith("Waiting for approval", StringComparison.OrdinalIgnoreCase))
            return new WorkflowException(409, message);

        // Everything else the procedures raise is a request-state or input rule, not a 500.
        return new WorkflowException(400, message);
    }
}
