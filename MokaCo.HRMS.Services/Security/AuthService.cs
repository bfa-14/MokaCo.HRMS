using MokaCo.HRMS.Model.Security;
using MokaCo.HRMS.Repository.Security;
using MokaCo.HRMS.Services.Auth;

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

    public AuthService(IUserRepository users, IRefreshTokenRepository tokens,
                       IPasswordHasher hasher, IJwtTokenService jwt, JwtOptions opt)
    {
        _users = users; _tokens = tokens; _hasher = hasher; _jwt = jwt; _opt = opt;
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

        await _users.RegisterLoginSuccessAsync(user.UserId);
        return await IssueTokensAsync(user, ip);
    }

    public async Task<AuthResult> RefreshAsync(string rawRefreshToken, string? ip)
    {
        var oldHash = _jwt.HashRefreshToken(rawRefreshToken);
        var (raw, newHash) = _jwt.CreateRefreshToken();
        var expires = DateTime.UtcNow.AddDays(_opt.RefreshTokenDays);

        var rotated = await _tokens.RotateAsync(oldHash, newHash, expires, ip);
        if (rotated is null)
            return AuthResult.Fail("Invalid or expired refresh token.");

        var user = await _users.GetByIdAsync(rotated.UserId);
        if (user is null || !user.IsActive)
            return AuthResult.Fail("Account is disabled.");

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

    private async Task<AuthResult> IssueTokensAsync(User user, string? ip)
    {
        var perms = (await _users.GetPermissionsAsync(user.UserId)).Select(p => p.Code);
        var (access, accessExp) = _jwt.CreateAccessToken(user, perms);
        var (raw, hash) = _jwt.CreateRefreshToken();
        await _tokens.CreateAsync(user.UserId, hash, DateTime.UtcNow.AddDays(_opt.RefreshTokenDays), ip);

        return AuthResult.Ok(new TokenResponse
        {
            AccessToken = access,
            RefreshToken = raw,
            AccessTokenExpiresAt = accessExp
        });
    }
}