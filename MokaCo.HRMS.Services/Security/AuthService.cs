using MokaCo.HRMS.Model.Security;
using MokaCo.HRMS.Repository.Common;
using MokaCo.HRMS.Repository.Security;
using MokaCo.HRMS.Services.Auth;
using MokaCo.HRMS.Services.Core;

namespace MokaCo.HRMS.Services.Security;

/// <summary>
/// Orchestrates login/refresh/logout. Verifies passwords with Argon2id, applies
/// lockout, issues JWT + refresh tokens, and resolves the current user's permissions.
/// The DB never sees a plaintext password; verification happens here.
/// </summary>
public class AuthService : IAuthService
{
    private readonly IUserRepository _users;
    private readonly IRefreshTokenRepository _tokens;
    private readonly IPasswordHasher _hasher;
    private readonly IJwtTokenService _jwt;
    private readonly JwtOptions _opt;
    private readonly MissingScriptWarning? _missingScript;

    public AuthService(IUserRepository users, IRefreshTokenRepository tokens,
                       IPasswordHasher hasher, IJwtTokenService jwt, JwtOptions opt,
                       MissingScriptWarning? missingScript = null)
    {
        _users = users; _tokens = tokens; _hasher = hasher; _jwt = jwt; _opt = opt; _missingScript = missingScript;
    }

    public const string InvalidCredentials = "Invalid username or password.";
    public const string Locked = "Account is temporarily locked. Try again later.";
    public const string Disabled = "Account is disabled.";

    /// <summary>
    /// EVERY ANSWER COSTS ONE ARGON2 VERIFICATION (QA3 SEC-6). The hash is the slow part of a login
    /// (a few hundred milliseconds by design), so a refusal that skipped it — an unknown username, a
    /// locked or disabled account — came back measurably faster than a wrong password and told a
    /// stranger which usernames exist. Those paths now verify against the hasher's decoy.
    ///
    /// The same generic sentence for an unknown user and a wrong password; "disabled" is said only to
    /// someone who has just proved the password, so it reveals nothing to anyone else. "Locked" stays
    /// as it was: it is what the real owner needs to read, and it is only reached after failures.
    /// </summary>
    public async Task<AuthResult> LoginAsync(LoginRequest request, string? ip)
    {
        var password = request.Password ?? string.Empty;
        var user = await _users.GetForLoginAsync(request.Username);

        if (user is null)
        {
            _hasher.Verify(password, _hasher.DecoyHash);
            return AuthResult.Fail(InvalidCredentials);
        }

        if (user.LockoutEnd is not null && user.LockoutEnd > DateTime.UtcNow)
        {
            // Not the real hash: while locked, the password is not checked at all.
            _hasher.Verify(password, _hasher.DecoyHash);
            return AuthResult.Fail(Locked);
        }

        var passwordOk = _hasher.Verify(password, user.PasswordHash);

        if (!user.IsActive)
            return AuthResult.Fail(passwordOk ? Disabled : InvalidCredentials);

        if (!passwordOk)
        {
            var f = await _users.RegisterLoginFailureAsync(user.UserId);
            return (f.LockoutEnd is not null && f.LockoutEnd > DateTime.UtcNow)
                ? AuthResult.Fail(Locked)
                : AuthResult.Fail(InvalidCredentials);
        }

        // The success is recorded once there is a session: a sign-in refused at issue (the password
        // changed during the check) must not reset the failure count or stamp LastLoginAt.
        var result = await IssueTokensAsync(user, ip);
        if (result.Success)
            await _users.RegisterLoginSuccessAsync(user.UserId);
        return result;
    }

    /// <summary>
    /// A refresh token for a new pair. The rotation (security.usp_RefreshToken_RotateChecked, script 105)
    /// refuses a revoked, expired or unknown token and a disabled account, and returns the account's
    /// session stamp read in the same transaction: the new access token carries THAT stamp, never one
    /// read afterwards, or a refresh that raced a password change could leave with a token that passes.
    ///
    /// WHILE SCRIPT 105 IS NOT APPLIED (the API deployed first): the base usp_RefreshToken_Rotate, as
    /// before it — the account is still checked below, and the stamp is the account's as read there
    /// (none, until the script adds the column).
    /// </summary>
    public async Task<AuthResult> RefreshAsync(string rawRefreshToken, string? ip)
    {
        var oldHash = _jwt.HashRefreshToken(rawRefreshToken);
        var (raw, newHash) = _jwt.CreateRefreshToken();
        var expires = DateTime.UtcNow.AddDays(_opt.RefreshTokenDays);

        IssuedRefreshToken? rotated;
        var stampFromRotation = true;
        try
        {
            rotated = await _tokens.RotateAsync(oldHash, newHash, expires, ip);
        }
        catch (MissingScriptException missing)
        {
            _missingScript?.FellBack(missing, "refresh rotates with the base usp_RefreshToken_Rotate");
            rotated = await _tokens.RotateLegacyAsync(oldHash, newHash, expires, ip);
            stampFromRotation = false;
        }
        if (rotated is null)
            return AuthResult.Fail("Invalid or expired refresh token.");

        var user = await _users.GetByIdAsync(rotated.UserId);
        if (user is null || !user.IsActive)
            return AuthResult.Fail("Account is disabled.");
        if (stampFromRotation)
            user.SessionStamp = rotated.SessionStamp;

        var perms = (await _users.GetPermissionsAsync(user.UserId)).Select(p => p.Code);
        var (access, accessExp) = _jwt.CreateAccessToken(user, perms);

        return AuthResult.Ok(new TokenResponse
        {
            AccessToken = access,
            RefreshToken = raw,
            AccessTokenExpiresAt = accessExp
        });
    }

    public async Task LogoutAsync(string rawRefreshToken)
    {
        var hash = _jwt.HashRefreshToken(rawRefreshToken);
        await _tokens.RevokeAsync(hash);
    }

    public async Task<CurrentUser?> GetCurrentUserAsync(int userId)
    {
        var user = await _users.GetByIdAsync(userId);
        if (user is null) return null;

        var roles = (await _users.GetRoleNamesAsync(userId)).ToList();
        var perms = (await _users.GetPermissionsAsync(userId)).Select(p => p.Code).ToList();

        return new CurrentUser
        {
            UserId = user.UserId,
            Username = user.Username,
            Roles = roles,
            Permissions = perms
        };
    }

    /// <summary>
    /// The refresh token first, and only while the account is active with the password hash just
    /// checked (security.usp_RefreshToken_Issue): a password changed or an account disabled during the
    /// few hundred milliseconds of the check gets no session. Then the access token, with the stamp
    /// the issue read.
    ///
    /// WHILE SCRIPT 105 IS NOT APPLIED (the API deployed first): the inline insert from before it, with
    /// no re-check and no stamp — the account has none until the script adds the column, so the token
    /// passes the session check. Sign-in must never stop because the SQL step was missed.
    /// </summary>
    private async Task<AuthResult> IssueTokensAsync(User user, string? ip)
    {
        var (raw, hash) = _jwt.CreateRefreshToken();
        var expires = DateTime.UtcNow.AddDays(_opt.RefreshTokenDays);
        try
        {
            var issued = await _tokens.IssueAsync(user.UserId, user.PasswordHash, hash, expires, ip);
            if (issued is null)
                return AuthResult.Fail(InvalidCredentials);
            user.SessionStamp = issued.SessionStamp;
        }
        catch (MissingScriptException missing)
        {
            _missingScript?.FellBack(missing, "sign-in issues its refresh token with the inline insert from before it");
            await _tokens.CreateLegacyAsync(user.UserId, hash, expires, ip);
        }

        var perms = (await _users.GetPermissionsAsync(user.UserId)).Select(p => p.Code);
        var (access, accessExp) = _jwt.CreateAccessToken(user, perms);

        return AuthResult.Ok(new TokenResponse
        {
            AccessToken = access,
            RefreshToken = raw,
            AccessTokenExpiresAt = accessExp
        });
    }
}