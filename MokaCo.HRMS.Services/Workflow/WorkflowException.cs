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
            var message = ex.Message;

            // "You are not the approver for this step." — the authorisation failure the DB owns.
            if (message.Contains("not the approver", StringComparison.OrdinalIgnoreCase))
                throw new WorkflowException(403, message);

            // Everything else the procedures raise is a request-state or input rule, not a 500.
            throw new WorkflowException(400, message);
        }
    }
}
