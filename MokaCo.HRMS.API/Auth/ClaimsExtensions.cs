using System.Security.Claims;

namespace MokaCo.HRMS.Api.Auth;

/// <summary>
/// Reads the caller's identity and rights from the token.
///
/// The JWT carries one "perm" claim per permission code (the same claims the policy provider gates
/// on). Some authorisation rules are too data-dependent for a policy — "may this person see THIS
/// request?" — so the controller reads the claims directly and hands the answer to the service.
/// </summary>
public static class ClaimsExtensions
{
    /// <summary>The signed-in user's id. The token writes it as 'sub'; JwtBearer usually remaps it to NameIdentifier.</summary>
    public static int UserId(this ClaimsPrincipal user)
        => int.Parse(user.FindFirstValue(ClaimTypes.NameIdentifier) ?? user.FindFirstValue("sub")!);

    /// <summary>Whether the caller holds a permission code, read from the "perm" claims.</summary>
    public static bool HasPermission(this ClaimsPrincipal user, string code)
        => user.HasClaim("perm", code);
}
