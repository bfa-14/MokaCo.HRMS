using MokaCo.HRMS.Model.Security;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Services.Security.Gate;

/// <summary>A Google sign-in that passed: what the page is told, and the cookie value the controller sets for <see cref="Days"/> days.</summary>
public sealed record GateSignInResult(string Email, string? Name, int Days, string CookieValue);

/// <summary>"Sign everyone out" done: the new epoch, and the caller's re-issued cookie when theirs was valid (null otherwise).</summary>
public sealed record GateSignOutEveryoneResult(int Epoch, string? CookieValue, int Days);

/// <summary>
/// The Google sign-in gate (docs/GOOGLE_SIGNIN_GATE.md §3): the per-request check nginx asks for, the
/// gate page's sign-in, and the admin operations behind Settings → Google sign-in. Every refusal is a
/// <see cref="WorkflowException"/> carrying its status and a sentence safe to show; the procedures'
/// own sentences are mapped by WorkflowSqlErrors.
/// </summary>
public interface IGateService
{
    /// <summary>The check: true when the gate is off, or the cookie is valid now and its person is allowed now, with that address, under that client ID.</summary>
    Task<bool> IsAllowedAsync(string? cookieValue, CancellationToken cancellationToken = default);

    Task<GateConfig> GetConfigAsync(string? cookieValue);

    /// <summary>
    /// Verifies the Google ID token and asks usp_Gate_SignIn. Works whether the gate is on or off — it is
    /// also "Test Google sign-in". Refusals: 503 not set up / Google unreachable, 400 invalid token, 403
    /// unverified email or not allowed (the sentence names the email).
    /// </summary>
    Task<GateSignInResult> SignInAsync(string? credential, string? ip, string? userAgent);

    /// <summary>Everything the admin tab shows; the caller's own status is judged against a fresh reading.</summary>
    Task<GateAccessView> GetAdminAsync(string? cookieValue, int? callerUserId);

    /// <summary>
    /// Saves the switch, the client ID and the days. Turning on (or keeping on) is refused unless this
    /// browser holds a valid cookie of a person allowed right now, made with that client ID — 409 — so
    /// the change cannot lock the caller out; the client ID changes only with the switch off (409).
    /// </summary>
    Task SaveSettingsAsync(GateSettingsRequest request, string? cookieValue, int? callerUserId);

    /// <summary>
    /// The admin writes. While the gate is on, one that would shut out the person this browser passes
    /// as — blocking that employee, switching off, removing or re-addressing that extra address — is a
    /// 409; the cookie travels for that judgement only.
    /// </summary>
    Task SetBlockedAsync(int employeeId, bool blocked, string? cookieValue, int? callerUserId);
    Task<int> AddExtraEmailAsync(GateExtraEmailRequest request, int? callerUserId);
    Task UpdateExtraEmailAsync(int gateExtraEmailId, GateExtraEmailRequest request, string? cookieValue, int? callerUserId);
    Task DeleteExtraEmailAsync(int gateExtraEmailId, string? cookieValue, int? callerUserId);

    /// <summary>Moves the epoch on, which ends every gate cookie; the caller's own is re-issued so they stay in.</summary>
    Task<GateSignOutEveryoneResult> SignOutEveryoneAsync(string? cookieValue, int? callerUserId);
}
