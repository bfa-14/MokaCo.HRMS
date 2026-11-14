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

    /// <summary>
    /// REFERENCE LISTS (shift times, branch, department and position names, pay components, currencies, leave
    /// types): readable with the list's own code (EMP_VIEW / ATTENDANCE_VIEW) OR with REQUEST_RAISE_SELF, because
    /// the request forms of every employee fill their dropdowns from them. Without the second code an Employee
    /// role saw empty lists and could not raise the request. Writing them keeps its own permission.
    /// </summary>
    public static bool MayReadReference(this ClaimsPrincipal user, string listCode)
        => user.HasPermission(listCode) || user.HasPermission("REQUEST_RAISE_SELF");
}
