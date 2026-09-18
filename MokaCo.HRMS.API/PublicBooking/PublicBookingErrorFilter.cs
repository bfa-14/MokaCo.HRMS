using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Filters;
using Microsoft.Data.SqlClient;

namespace MokaCo.HRMS.Api.PublicBooking;

/// <summary>
/// Every failure out of the public booking controller leaves as { error, code } and nothing else.
///
/// A PROCEDURE'S REFUSAL (SqlException 50000) becomes the status and code <see cref="BookingRefusals"/>
/// decides, with the procedure's own sentence as the message. ANYTHING ELSE — a connection failure,
/// a deadlock, a bug — is logged in full here and leaves as a 500 with a sentence a guest can act on.
/// The exception text never reaches the wire: in Development the framework's exception page would
/// otherwise print the stack trace, and a public endpoint must not leak it.
/// </summary>
public sealed class PublicBookingErrorFilter : ExceptionFilterAttribute
{
    public override void OnException(ExceptionContext context)
    {
        if (context.Exception is SqlException { Number: 50000 } refusal)
        {
            var (status, code) = BookingRefusals.Classify(refusal.Message);
            context.Result = new ObjectResult(new { error = refusal.Message, code }) { StatusCode = status };
            context.ExceptionHandled = true;
            return;
        }

        var logger = context.HttpContext.RequestServices.GetRequiredService<ILogger<PublicBookingErrorFilter>>();
        logger.LogError(context.Exception, "Public booking request {Method} {Path} failed.",
            context.HttpContext.Request.Method, context.HttpContext.Request.Path);

        context.Result = new ObjectResult(new
        {
            error = "Something went wrong on our side. Try again in a moment, or WhatsApp us.",
            code = "server_error",
        })
        {
            StatusCode = StatusCodes.Status500InternalServerError,
        };
        context.ExceptionHandled = true;
    }
}
