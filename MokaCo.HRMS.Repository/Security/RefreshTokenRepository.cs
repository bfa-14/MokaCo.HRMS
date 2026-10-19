using System.Data;
using Dapper;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.Security;

/// <summary>
/// Refresh-token access. Issue and rotation are script 105's (QA3 SEC-5): they lock the account's USER
/// row before any token, as usp_User_EndSessions does, so a sign-in or refresh cannot slip a live token
/// past a password change or a disable. Revoke (logout) is the base one. While 105 is not applied, the
/// two 105 calls throw MissingScriptException and AuthService uses the legacy pair below instead.
/// </summary>
public class RefreshTokenRepository : IRefreshTokenRepository
{
    private readonly IDbConnectionFactory _factory;
    public RefreshTokenRepository(IDbConnectionFactory factory) => _factory = factory;

    public async Task<IssuedRefreshToken?> IssueAsync(int userId, string verifiedPasswordHash, string tokenHash, DateTime expiresAt, string? createdByIp)
    {
        using var db = _factory.Create();
        return await MissingScriptException.GuardAsync(Scripts.Security105, "security.usp_RefreshToken_Issue",
            () => db.QuerySingleOrDefaultAsync<IssuedRefreshToken>(
                "security.usp_RefreshToken_Issue",
                new { UserId = userId, PasswordHash = verifiedPasswordHash, TokenHash = tokenHash, ExpiresAt = expiresAt, CreatedByIp = createdByIp },
                commandType: CommandType.StoredProcedure));
    }

    public async Task<IssuedRefreshToken?> RotateAsync(string oldTokenHash, string newTokenHash, DateTime expiresAt, string? createdByIp)
    {
        using var db = _factory.Create();
        return await MissingScriptException.GuardAsync(Scripts.Security105, "security.usp_RefreshToken_RotateChecked",
            () => db.QuerySingleOrDefaultAsync<IssuedRefreshToken>(
                "security.usp_RefreshToken_RotateChecked",
                new { OldTokenHash = oldTokenHash, NewTokenHash = newTokenHash, ExpiresAt = expiresAt, CreatedByIp = createdByIp },
                commandType: CommandType.StoredProcedure));
    }

    /* ---- the ways before script 105, for an API deployed before the script is applied (as on dev) ---- */

    public async Task CreateLegacyAsync(int userId, string tokenHash, DateTime expiresAt, string? createdByIp)
    {
        const string sql = @"
            INSERT INTO security.REFRESH_TOKEN (UserId, TokenHash, ExpiresAt, CreatedByIp)
            VALUES (@UserId, @TokenHash, @ExpiresAt, @CreatedByIp);";
        using var db = _factory.Create();
        await db.ExecuteAsync(sql, new { UserId = userId, TokenHash = tokenHash, ExpiresAt = expiresAt, CreatedByIp = createdByIp });
    }

    public async Task<IssuedRefreshToken?> RotateLegacyAsync(string oldTokenHash, string newTokenHash, DateTime expiresAt, string? createdByIp)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<IssuedRefreshToken>(
            "security.usp_RefreshToken_Rotate",
            new { OldTokenHash = oldTokenHash, NewTokenHash = newTokenHash, ExpiresAt = expiresAt, CreatedByIp = createdByIp },
            commandType: CommandType.StoredProcedure);
    }

    public async Task RevokeAsync(string tokenHash)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "security.usp_RefreshToken_Revoke",
            new { TokenHash = tokenHash },
            commandType: CommandType.StoredProcedure);
    }
}
