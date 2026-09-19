using Microsoft.Data.SqlClient;
using MokaCo.HRMS.Services.Security;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Api.Errors;

/// <summary>What the client is told about a failure: the status, the sentence, and whether it is OUR fault.</summary>
/// <param name="Status">The HTTP status.</param>
/// <param name="Message">A sentence safe to show. Never SQL text, a constraint name or a stack trace.</param>
/// <param name="IsServerFault">True when the failure is a bug or an outage: logged as an error with the stack.</param>
public readonly record struct ApiError(int Status, string Message, bool IsServerFault);

/// <summary>
/// The one table that decides what an unhandled exception looks like on the wire (BUG-03).
///
/// THE DATABASE'S OWN SENTENCES TRAVEL, ITS INTERNALS DO NOT. A RAISERROR out of a procedure
/// (50000) is a sentence somebody wrote for a user — "Attendance for August 2026 is not ready for
/// payroll…" — and leaves untouched. A constraint violation names the constraint and the table
/// ("FK__SHIFT_ASS__Emplo__…"), so it is REPLACED by a sentence that says the same thing without
/// them. Pure, so the table is tested without a database or a request.
/// </summary>
public static class ApiErrorMap
{
    public const string NotAllowed = "The referenced record does not exist or the value is not allowed.";
    public const string AlreadyExists = "This record already exists.";
    public const string DatabaseTimeout = "The database did not answer in time. Try again.";
    public const string DatabaseBusy = "The database was busy with another change. Try again.";
    public const string UnreadableRequest = "The request could not be read.";

    /// <summary>The sentence of a 500. The reference is the only thing that ties it to the log line.</summary>
    public static string Unexpected(string traceId) => $"Something went wrong. Reference {traceId}";

    public static ApiError Classify(Exception exception, string traceId) => exception switch
    {
        // Already carry a status and a sentence fit to show: unchanged.
        WorkflowException workflow => new(workflow.StatusCode, workflow.Message, false),
        SignatureValidationException signature => new(StatusCodes.Status400BadRequest, signature.Message, false),

        SqlException sql => ForSql(sql.Number, RaisedMessage(sql), traceId),

        // A command timeout that surfaced without its SqlException (a cancelled ADO.NET task).
        TimeoutException => new(StatusCodes.Status503ServiceUnavailable, DatabaseTimeout, true),

        // A body Kestrel could not read (too large, malformed chunking). The framework's own text
        // is about the transport, not the user's data, so it is not repeated.
        BadHttpRequestException bad => new(bad.StatusCode, UnreadableRequest, false),

        _ => new(StatusCodes.Status500InternalServerError, Unexpected(traceId), true),
    };

    /// <summary>The mapping for a SQL Server error number. <paramref name="raisedMessage"/> is only used for 50000.</summary>
    public static ApiError ForSql(int number, string raisedMessage, string traceId) => number switch
    {
        // RAISERROR / THROW 50000: a rule a procedure enforces, in the procedure's own words.
        50000 => new(IsConflict(raisedMessage) ? StatusCodes.Status409Conflict : StatusCodes.Status400BadRequest,
                     raisedMessage, false),

        // FOREIGN KEY / CHECK. The engine's message names the constraint, the table and the column.
        547 => new(StatusCodes.Status400BadRequest, NotAllowed, false),

        // PRIMARY KEY / UNIQUE constraint (2627) and unique index (2601). The message quotes the key value.
        2627 or 2601 => new(StatusCodes.Status409Conflict, AlreadyExists, false),

        // Command or connection timeout.
        -2 => new(StatusCodes.Status503ServiceUnavailable, DatabaseTimeout, true),

        // Chosen as the deadlock victim: nothing was written, and the same request will go through.
        1205 => new(StatusCodes.Status503ServiceUnavailable, DatabaseBusy, true),

        _ => new(StatusCodes.Status500InternalServerError, Unexpected(traceId), true),
    };

    /// <summary>
    /// A refusal that is about the STATE of what already exists, not about the input: the second
    /// primary payroll run, a slot somebody took, a roster waiting for approval, a locked month.
    /// </summary>
    public static bool IsConflict(string message) =>
        message.Contains("already", StringComparison.OrdinalIgnoreCase)
        || message.Contains("taken", StringComparison.OrdinalIgnoreCase)
        || message.Contains("waiting", StringComparison.OrdinalIgnoreCase)
        || message.Contains("locked", StringComparison.OrdinalIgnoreCase)
        // D10: "This period is paid — raise a payroll adjustment instead." The input is fine; the month's state refuses it.
        || message.Contains("is paid", StringComparison.OrdinalIgnoreCase);

    /// <summary>
    /// The procedure's sentence alone. SqlException.Message joins EVERY error of the batch with line
    /// breaks — a RAISERROR followed by "The statement has been terminated." would otherwise show both.
    /// </summary>
    private static string RaisedMessage(SqlException exception)
    {
        foreach (SqlError error in exception.Errors)
            if (error.Number == 50000)
                return error.Message;
        return exception.Message;
    }
}
