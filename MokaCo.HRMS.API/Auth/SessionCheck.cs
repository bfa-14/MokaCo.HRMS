using System.Security.Claims;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using MokaCo.HRMS.Services.Auth;
using MokaCo.HRMS.Services.Security;

namespace MokaCo.HRMS.Api.Auth;

/// <summary>
/// THE JWT HANDLER'S LAST WORD ON A TOKEN (QA3 SEC-5). The signature and lifetime are already good;
/// this asks <see cref="ISessionGuard"/> whether the account's sessions were ended since the token was
/// issued (a password change, a disable) and refuses it if so. A refusal is the handler's own: 401 with
/// WWW-Authenticate, which the web client reads as "token rejected" — it tries the refresh token, which
/// was revoked too, and goes to the login page.
/// </summary>
public static class SessionCheck
{
    public const string Ended = "This session has ended. Please sign in again.";

    public static async Task OnTokenValidated(TokenValidatedContext context)
    {
        var principal = context.Principal;
        var sub = principal?.FindFirstValue(ClaimTypes.NameIdentifier) ?? principal?.FindFirstValue("sub");
        if (!int.TryParse(sub, out var userId))
        {
            context.Fail("The token names no user.");
            return;
        }

        Guid? stamp = Guid.TryParse(principal!.FindFirstValue(JwtTokenService.SessionStampClaim), out var parsed) ? parsed : null;
        var guard = context.HttpContext.RequestServices.GetRequiredService<ISessionGuard>();
        if (!await guard.IsCurrentAsync(userId, stamp, context.HttpContext.RequestAborted))
            context.Fail(Ended);
    }
}
