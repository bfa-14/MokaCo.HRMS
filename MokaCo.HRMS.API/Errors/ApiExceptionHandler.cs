using System.Diagnostics;
using Microsoft.AspNetCore.Diagnostics;

namespace MokaCo.HRMS.Api.Errors;

/// <summary>
/// The last stop for an exception no controller caught: every one leaves as { error, traceId } JSON
/// with the status <see cref="ApiErrorMap"/> decides (BUG-03).
///
/// IN EVERY ENVIRONMENT, Development included. The developer exception page used to answer these —
/// a PUT /api/roster/day with an unknown employee came back as a 500 HTML page quoting the foreign
/// key and the stack. It is registered INSIDE that page in the pipeline, so it answers first and the
/// page never sees an API failure; the stack goes to the log, under the reference the client was given.
///
/// Controllers that already turn a specific failure into a specific answer keep doing so — this only
/// sees what they let through.
/// </summary>
public sealed class ApiExceptionHandler(ILogger<ApiExceptionHandler> logger) : IExceptionHandler
{
    public async ValueTask<bool> TryHandleAsync(HttpContext httpContext, Exception exception, CancellationToken cancellationToken)
    {
        // The caller hung up; there is nobody to answer and nothing went wrong on our side.
        if (exception is OperationCanceledException && httpContext.RequestAborted.IsCancellationRequested)
            return true;

        var traceId = Activity.Current?.TraceId.ToString() ?? httpContext.TraceIdentifier;
        var error = ApiErrorMap.Classify(exception, traceId);

        if (error.IsServerFault)
            logger.LogError(exception, "Unhandled exception on {Method} {Path} — reference {TraceId}.",
                httpContext.Request.Method, httpContext.Request.Path, traceId);
        else
            logger.LogInformation("Refused {Method} {Path} with {Status}: {Message} — reference {TraceId}.",
                httpContext.Request.Method, httpContext.Request.Path, error.Status, error.Message, traceId);

        // The response has started (a file download, a stream): the status can no longer change, so
        // let the server abort the connection rather than append JSON to half a body.
        if (httpContext.Response.HasStarted)
            return false;

        httpContext.Response.StatusCode = error.Status;
        await httpContext.Response.WriteAsJsonAsync(new { error = error.Message, traceId }, cancellationToken);
        return true;
    }
}
