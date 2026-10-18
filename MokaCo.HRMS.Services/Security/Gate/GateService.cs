using MokaCo.HRMS.Model.Security;
using MokaCo.HRMS.Repository.Security;
using MokaCo.HRMS.Services.Auth;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Services.Security.Gate;

/// <summary>
/// The gate around its pure pieces: <see cref="GateCookie"/> says whether a cookie is ours and current,
/// <see cref="IGateState"/> what the settings and the allowed list are now, the procedures who a Google
/// email belongs to. This class joins them and words the answers.
///
/// A COOKIE IS NEVER ENOUGH ON ITS OWN: it passes only while its person is in the allowed list of the
/// moment, with the address it was made for, under the client ID it was made with — so blocking
/// somebody, an employee leaving, a disabled HRMS login or a corrected Gmail closes the door within the
/// state's 20 seconds, whatever cookie is still in their browser.
///
/// NO ADMIN CHANGE MAY LOCK OUT THE ADMIN MAKING IT (G6). Turning the switch on needs this browser to
/// have passed Google with the client ID being turned on; while the gate is on, blocking the employee
/// this browser passes as, or switching off, removing or re-addressing its extra address, is refused.
/// </summary>
public sealed class GateService : IGateService
{
    public const string NotSetUp = "Google sign-in is not set up yet. Ask the administrator.";
    public const string InvalidToken = "Google could not confirm this sign-in — try again.";
    public const string UnverifiedEmail = "This Google account's email is not verified.";
    public const string GoogleUnreachable = "Google could not be reached — try again in a minute.";
    public const string VerifyFirst = "Sign in with Google in this browser first (Test Google sign-in), so turning this on can't lock you out.";
    public const string ClientIdLocked = "Turn Google sign-in off to change the client ID.";
    public const string ClientIdUntested = "Save the new client ID first, then test Google sign-in with it.";

    /// <summary>The refusals that keep an admin from shutting out the browser they are using (409, like <see cref="VerifyFirst"/>).</summary>
    public const string BlockSelf = "You can't block yourself — you would lose access.";
    public const string OwnAddressOff = "You can't switch off the address you signed in with — you would lose access.";
    public const string OwnAddressChanged = "You can't change the address you signed in with — you would lose access.";
    public const string OwnAddressRemoved = "You can't remove the address you signed in with — you would lose access.";

    /// <summary>The procedure's own sentences, checked here too so the order is blank ID → days → lock-out guard.</summary>
    public const string ClientIdMissing = "Enter the Google client ID before turning Google sign-in on.";
    public const string DaysOutOfRange = "Keep a Google sign-in between 1 and 365 days.";
    public const string EmailMissing = "Enter a full Google email address.";

    private readonly IGateRepository _repo;
    private readonly IGateState _state;
    private readonly IGoogleTokenValidator _google;
    private readonly TimeProvider _time;
    private readonly byte[] _key;

    public GateService(IGateRepository repo, IGateState state, IGoogleTokenValidator google, JwtOptions jwt, TimeProvider time)
    {
        _repo = repo;
        _state = state;
        _google = google;
        _time = time;
        _key = GateCookie.DeriveKey(jwt.SecretKey);
    }

    private long Now => _time.GetUtcNow().ToUnixTimeSeconds();

    /* ---- the check and the gate page ---- */

    public async Task<bool> IsAllowedAsync(string? cookieValue, CancellationToken cancellationToken = default)
    {
        var state = await _state.CurrentAsync(cancellationToken);
        return !state.Required || Verified(cookieValue, state, state.Days) is not null;
    }

    /// <summary>
    /// The name is not in the cookie (§3 keeps it to person, email, times and epoch), so it is not known
    /// here; the page shows the email.
    /// </summary>
    public async Task<GateConfig> GetConfigAsync(string? cookieValue)
    {
        var state = await _state.CurrentAsync();
        var person = Verified(cookieValue, state, state.Days);

        return new GateConfig
        {
            Required = state.Required,
            ClientId = state.ClientId.Length == 0 ? null : state.ClientId,
            Days = state.Days,
            SignedIn = person is not null,
            Email = person?.Email,
            Name = null,
        };
    }

    public async Task<GateSignInResult> SignInAsync(string? credential, string? ip, string? userAgent)
    {
        var state = await _state.CurrentAsync();
        if (state.ClientId.Length == 0)
            throw new WorkflowException(503, NotSetUp);

        var google = await _google.ValidateAsync(credential, state.ClientId);
        switch (google.Status)
        {
            case GoogleTokenStatus.Ok: break;
            case GoogleTokenStatus.Unverified: throw new WorkflowException(403, UnverifiedEmail);
            case GoogleTokenStatus.Unreachable: throw new WorkflowException(503, GoogleUnreachable);
            default: throw new WorkflowException(400, InvalidToken);
        }

        var email = google.Email!;
        var row = await WorkflowSqlErrors.MapAsync(() => _repo.SignInAsync(email, Cut(google.Subject, 255), Cut(ip, 45), Cut(userAgent, 300)));

        switch (row.Outcome)
        {
            case GateSignInOutcome.Allowed:
                break;
            case GateSignInOutcome.NotFound:
                throw new WorkflowException(403, $"{email} is not on the HRMS list. Ask the administrator to put this Gmail on your employee record.");
            case GateSignInOutcome.Blocked:
                throw new WorkflowException(403, $"Google sign-in is switched off for {email}. Ask the administrator.");
            case GateSignInOutcome.NoUser:
                throw new WorkflowException(403, $"{email} belongs to an employee without an active HRMS login. Ask the administrator.");
            case GateSignInOutcome.Left:
                throw new WorkflowException(403, $"{email} belongs to an employee who has left.");
            default:
                // A cookie is only ever issued for an outcome this class knows. Anything else is a fault.
                throw new InvalidOperationException($"usp_Gate_SignIn answered an unknown outcome '{row.Outcome}'.");
        }

        var kind = (row.Kind ?? string.Empty).Trim().ToLowerInvariant();
        if (kind is not ("e" or "x") || row.PersonId is not > 0)
            throw new InvalidOperationException("usp_Gate_SignIn allowed a sign-in without naming the person.");

        // Allowed by the procedure but not yet in the cached list as such (a login created, or a Gmail
        // corrected, a few seconds ago): read again, so the page's reload is not refused for 20 seconds.
        if (!state.Allows(kind, row.PersonId.Value, row.EmailNorm))
            _state.Invalidate();

        var cookie = GateCookie.Issue(
            GateCookie.Create(kind, row.PersonId.Value, email, row.EmailNorm, state.ClientId, Now, state.Days, state.Epoch), _key);
        return new GateSignInResult(email, row.DisplayName ?? google.Name, state.Days, cookie);
    }

    /* ---- the admin side ---- */

    public async Task<GateAccessView> GetAdminAsync(string? cookieValue, int? callerUserId)
    {
        var data = await WorkflowSqlErrors.MapAsync(() => _repo.GetAdminAsync(callerUserId));
        var fresh = await _state.GetFreshAsync();
        var person = Verified(cookieValue, fresh, fresh.Days);

        return new GateAccessView
        {
            Settings = data.Settings,
            Caller = new GateCaller
            {
                Verified = person is not null,
                Email = person?.Email,
                Name = person is null ? null : NameOf(person, data),
            },
            People = data.People,
            Extras = data.Extras,
            Recent = data.Recent,
        };
    }

    /// <summary>
    /// THE NO-LOCK-OUT GUARD (G6), whenever the switch is to be on — turning it on, or saving while it
    /// is on. The caller's cookie is judged against a reading made NOW and against the days being
    /// saved, if fewer: a cookie that the new settings would end is not proof that the caller gets in.
    ///
    /// THE CLIENT ID DOES NOT CHANGE WITH THE SWITCH ON. A cookie proves a sign-in with the ID it was made
    /// with, nothing about a new one; a mistyped ID would leave the admin in on their cookie and shut out
    /// everyone else. So a new ID is saved with the switch off — every cookie made with the old one stops
    /// passing then (harmless while off) — and the switch goes on only after a test sign-in with it.
    /// </summary>
    public async Task SaveSettingsAsync(GateSettingsRequest request, string? cookieValue, int? callerUserId)
    {
        if (request is null)
            throw new WorkflowException(400, "Send the Google sign-in settings.");

        var clientId = request.ClientId?.Trim() ?? string.Empty;

        if (request.Required)
        {
            if (clientId.Length == 0)
                throw new WorkflowException(400, ClientIdMissing);
            if (request.Days is < 1 or > 365)
                throw new WorkflowException(400, DaysOutOfRange);

            var fresh = await _state.GetFreshAsync();
            if (!string.Equals(clientId, fresh.ClientId, StringComparison.Ordinal))
                throw new WorkflowException(409, fresh.Required ? ClientIdLocked : ClientIdUntested);
            if (Verified(cookieValue, fresh, Math.Min(fresh.Days, request.Days)) is null)
                throw new WorkflowException(409, VerifyFirst);
        }

        await WorkflowSqlErrors.MapAsync(async () =>
        {
            await _repo.SaveSettingsAsync(request.Required, clientId, request.Days, callerUserId);
            return true;
        });
        _state.Invalidate();
    }

    /// <summary>The procedure refuses blocking the employee linked to the caller's HRMS login; this also refuses the one this browser passes the gate as.</summary>
    public async Task SetBlockedAsync(int employeeId, bool blocked, string? cookieValue, int? callerUserId)
    {
        if (blocked)
            await RefuseLockingOutCallerAsync(cookieValue, caller => caller.Kind == "e" && caller.PersonId == employeeId ? BlockSelf : null);

        await WorkflowSqlErrors.MapAsync(async () =>
        {
            await _repo.SetBlockedAsync(employeeId, blocked, callerUserId);
            return true;
        });
        _state.Invalidate();
    }

    /// <summary>A new address is always active; the procedure checks the address and refuses a second row for the same Gmail.</summary>
    public async Task<int> AddExtraEmailAsync(GateExtraEmailRequest request, int? callerUserId)
    {
        if (request is null)
            throw new WorkflowException(400, EmailMissing);

        var id = await WorkflowSqlErrors.MapAsync(() =>
            _repo.SaveExtraEmailAsync(null, request.Email?.Trim(), NullIfBlank(request.Note), isActive: true, callerUserId));
        _state.Invalidate();
        return id;
    }

    /// <summary>
    /// The address this browser passes the gate with keeps its switch on and its address: a change to
    /// the note, or a re-spelling of the same Google account, is fine.
    /// </summary>
    public async Task UpdateExtraEmailAsync(int gateExtraEmailId, GateExtraEmailRequest request, string? cookieValue, int? callerUserId)
    {
        if (request is null)
            throw new WorkflowException(400, EmailMissing);

        await RefuseLockingOutCallerAsync(cookieValue, caller =>
            caller.Kind != "x" || caller.PersonId != gateExtraEmailId ? null
            : !request.IsActive ? OwnAddressOff
            : caller.EmailNorm is not null && !string.Equals(GateEmail.Normalize(request.Email), caller.EmailNorm, StringComparison.Ordinal) ? OwnAddressChanged
            : null);

        await WorkflowSqlErrors.MapAsync(() =>
            _repo.SaveExtraEmailAsync(gateExtraEmailId, request.Email?.Trim(), NullIfBlank(request.Note), request.IsActive, callerUserId));
        _state.Invalidate();
    }

    public async Task DeleteExtraEmailAsync(int gateExtraEmailId, string? cookieValue, int? callerUserId)
    {
        await RefuseLockingOutCallerAsync(cookieValue, caller => caller.Kind == "x" && caller.PersonId == gateExtraEmailId ? OwnAddressRemoved : null);

        await WorkflowSqlErrors.MapAsync(async () =>
        {
            await _repo.DeleteExtraEmailAsync(gateExtraEmailId, callerUserId);
            return true;
        });
        _state.Invalidate();
    }

    /// <summary>
    /// The caller's cookie is judged BEFORE the epoch moves (against a fresh reading); if it was valid,
    /// a new one with the new epoch goes back, so the admin who pressed the button is not the first
    /// person shown the gate page.
    /// </summary>
    public async Task<GateSignOutEveryoneResult> SignOutEveryoneAsync(string? cookieValue, int? callerUserId)
    {
        var before = await _state.GetFreshAsync();
        var person = Verified(cookieValue, before, before.Days);

        var epoch = await WorkflowSqlErrors.MapAsync(() => _repo.SignOutEveryoneAsync(callerUserId));
        _state.Invalidate();

        var cookie = person is null
            ? null
            : GateCookie.Issue(GateCookie.Create(person.Kind, person.PersonId, person.Email, person.EmailNorm, before.ClientId, Now, before.Days, epoch), _key);
        return new GateSignOutEveryoneResult(epoch, cookie, before.Days);
    }

    /* ---- helpers ---- */

    /// <summary>The cookie's payload when it is valid under <paramref name="state"/> with <paramref name="days"/> and <paramref name="state"/> admits it; otherwise null.</summary>
    private GateCookiePayload? Verified(string? cookieValue, GateSnapshot state, int days)
        => GateCookie.TryRead(cookieValue, _key, Now, days, state.Epoch, out var payload) && state.Admits(payload)
            ? payload
            : null;

    /// <summary>
    /// While the gate is on (judged on a reading made now), refuses with 409 the sentence
    /// <paramref name="refusal"/> gives for the person this browser passes as; null lets the change go.
    /// A browser that passes as nobody has nothing to lose. With the gate off nothing is locked: turning
    /// it on needs a fresh proof anyway.
    /// </summary>
    private async Task RefuseLockingOutCallerAsync(string? cookieValue, Func<GateCookiePayload, string?> refusal)
    {
        var fresh = await _state.GetFreshAsync();
        if (!fresh.Required)
            return;

        var caller = Verified(cookieValue, fresh, fresh.Days);
        if (caller is not null && refusal(caller) is { } sentence)
            throw new WorkflowException(409, sentence);
    }

    /// <summary>The name the admin tab shows for the caller: the employee's full name, or the extra address's note (else the address).</summary>
    private static string? NameOf(GateCookiePayload person, GateAdminData data) => person.Kind == "e"
        ? data.People.FirstOrDefault(p => p.EmployeeId == person.PersonId)?.FullName
        : data.Extras.FirstOrDefault(x => x.GateExtraEmailId == person.PersonId) is { } extra
            ? NullIfBlank(extra.Note) ?? extra.Email
            : null;

    private static string? NullIfBlank(string? text) => string.IsNullOrWhiteSpace(text) ? null : text.Trim();

    /// <summary>The log's columns are narrow (IP 45, user agent 300); a longer value is cut, never refused.</summary>
    private static string? Cut(string? text, int length)
        => string.IsNullOrEmpty(text) ? null : text.Length <= length ? text : text[..length];
}
