using System.Security.Cryptography;
using System.Text;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Filters;

namespace MokaCo.HRMS.Api.PublicBooking;

/// <summary>
/// Marks the actions that STOP WORKING when core.SETTING BookingWebsiteEnabled = '0' — quoting and
/// taking a booking. THE READS DELIBERATELY STAY UP: a paused site still has a rooms page to render
/// and a confirmation page to show somebody who booked yesterday. Release and cancel keep working
/// too — a guest walking away from a slot needs it freed whether or not new bookings are taken.
/// </summary>
[AttributeUsage(AttributeTargets.Method)]
public sealed class PausesWithWebsiteAttribute : Attribute;

/// <summary>
/// Marks the ONE action the access gate lets through without an origin or a key: GET /verify, the
/// payment gateway's return trip. It is a TOP-LEVEL BROWSER REDIRECT from the gateway's page, so it
/// carries no Origin header and no X-Booking-Key, and the gate would answer 401 to a guest who has
/// just paid. It is safe to leave open because it takes nothing from the caller but a reference in
/// the booking pattern, is idempotent, and decides only from what the API itself asks the gateway
/// server-side; it keeps its rate limit. Anything else must never carry this attribute.
/// </summary>
[AttributeUsage(AttributeTargets.Method)]
public sealed class GatewayReturnAttribute : Attribute;

/// <summary>
/// Decides whether a caller may talk to the public booking API at all, before any action runs —
/// IN THIS ORDER (an action marked <see cref="GatewayReturnAttribute"/> skips all of it):
///   1. BookingWebsiteEnabled = '0' and the action <see cref="PausesWithWebsiteAttribute"/> →
///      503 { error: "Online booking is paused. Book over WhatsApp.", code: "paused" }. Before the
///      access check on purpose: "we are not taking bookings" is a truer answer than "who are you".
///   2. The Origin header names an origin in BookingCorsOrigins → allowed. A browser makes that
///      header and script cannot forge it; the CORS policy built from the same list is what lets
///      the browser read the answer.
///   3. X-Booking-Key equals BookingApiKey, and the setting is NOT EMPTY → allowed. Servers and
///      curl send no Origin; this is their door. An empty key disables the door.
///   4. Otherwise 401 { error: "Not allowed.", code: "unauthorized" } — ONE answer for every
///      refusal, so a caller is not told which half of the door to keep working on.
/// </summary>
public sealed class PublicBookingAccessAttribute : ActionFilterAttribute
{
    public const string ApiKeyHeader = "X-Booking-Key";

    public override async Task OnActionExecutionAsync(ActionExecutingContext context, ActionExecutionDelegate next)
    {
        if (context.ActionDescriptor.EndpointMetadata.OfType<GatewayReturnAttribute>().Any())
        {
            await next();
            return;
        }

        var gate = context.HttpContext.RequestServices.GetRequiredService<IPublicBookingGate>();
        var snapshot = await gate.CurrentAsync(context.HttpContext.RequestAborted);

        if (!snapshot.WebsiteEnabled && Pauses(context))
        {
            context.Result = Refusal(StatusCodes.Status503ServiceUnavailable, "Online booking is paused. Book over WhatsApp.", "paused");
            return;
        }

        if (snapshot.AllowsOrigin(context.HttpContext.Request.Headers.Origin.ToString()))
        {
            await next();
            return;
        }

        if (KeyMatches(snapshot.ApiKey, context.HttpContext.Request.Headers[ApiKeyHeader].ToString()))
        {
            await next();
            return;
        }

        context.Result = Refusal(StatusCodes.Status401Unauthorized, "Not allowed.", "unauthorized");
    }

    private static ObjectResult Refusal(int status, string error, string code)
        => new(new { error, code }) { StatusCode = status };

    private static bool Pauses(ActionExecutingContext context)
        => context.ActionDescriptor.EndpointMetadata.OfType<PausesWithWebsiteAttribute>().Any();

    /// <summary>
    /// Constant-time, and only when a key has actually been configured. String == returns as soon
    /// as two bytes differ, which makes its duration a measurement of how much of the key a caller
    /// has right. Different lengths are rejected first — FixedTimeEquals needs equal lengths — which
    /// leaks the key's length and nothing else.
    /// </summary>
    public static bool KeyMatches(string configured, string presented)
    {
        if (string.IsNullOrEmpty(configured) || string.IsNullOrEmpty(presented))
            return false;

        var expected = Encoding.UTF8.GetBytes(configured);
        var actual = Encoding.UTF8.GetBytes(presented);

        return expected.Length == actual.Length && CryptographicOperations.FixedTimeEquals(expected, actual);
    }
}
