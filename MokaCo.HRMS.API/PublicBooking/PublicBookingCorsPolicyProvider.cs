using Microsoft.AspNetCore.Cors.Infrastructure;
using Microsoft.Extensions.Options;
using MokaCo.HRMS.Api.Controllers;

namespace MokaCo.HRMS.Api.PublicBooking;

/// <summary>
/// Builds the public booking CORS policy PER REQUEST from core.SETTING BookingCorsOrigins, and
/// hands every other policy back to the framework's own provider untouched.
///
/// WHY A PROVIDER AND NOT AddPolicy. A policy registered with AddCors is built once, at startup;
/// the website's origin is edited on the Settings page and must take effect without a restart.
/// <see cref="ICorsPolicyProvider"/> is consulted on every request — including the OPTIONS
/// preflight, which the CORS middleware answers before MVC runs — and the values behind it are
/// cached for a minute by <see cref="PublicBookingGate"/>, so "per request" costs a lookup.
///
/// NO AllowCredentials: these endpoints are anonymous, and it is the flag that makes an over-broad
/// origin list dangerous. GET and POST are the whole surface. AN EMPTY LIST MATCHES NO ORIGIN.
/// </summary>
public sealed class PublicBookingCorsPolicyProvider : ICorsPolicyProvider
{
    private readonly DefaultCorsPolicyProvider _framework;
    private readonly IPublicBookingGate _gate;

    public PublicBookingCorsPolicyProvider(IOptions<CorsOptions> options, IPublicBookingGate gate)
    {
        // Constructed rather than injected: registering this type as ICorsPolicyProvider replaces
        // the default registration, so asking the container for one would ask for this.
        _framework = new DefaultCorsPolicyProvider(options);
        _gate = gate;
    }

    public async Task<CorsPolicy?> GetPolicyAsync(HttpContext context, string? policyName)
    {
        if (!string.Equals(policyName, PublicBookingController.BookingCorsPolicy, StringComparison.Ordinal))
            return await _framework.GetPolicyAsync(context, policyName);

        var snapshot = await _gate.CurrentAsync(context.RequestAborted);

        return new CorsPolicyBuilder()
            .WithOrigins(snapshot.Origins)
            .AllowAnyHeader()
            .WithMethods("GET", "POST")
            .SetPreflightMaxAge(PublicBookingGate.CacheFor)
            .Build();
    }
}
