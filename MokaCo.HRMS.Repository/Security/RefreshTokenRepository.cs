using System.Data;
using Dapper;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.Security;

/// <summary>
/// Refresh-token access, all through procedures. Issue and rotation are script 105's (QA3 SEC-5): they
/// lock the account's USER row before any token, as usp_User_EndSessions does, so a sign-in or refresh
/// cannot slip a live token past a password change or a disable. Revoke (logout) is the base one.
/// </summary>
public class RefreshTokenRepository : IRefreshTokenRepository
{
    private readonly IDbConnectionFactory _factory;
    public RefreshTokenRepository(IDbConnectionFactory factory) => _factory = factory;

    public async Task<IssuedRefreshToken?> IssueAsync(int userId, string verifiedPasswordHash, string tokenHash, DateTime expiresAt, string? createdByIp)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<IssuedRefreshToken>(
            "security.usp_RefreshToken_Issue",
            new { UserId = userId, PasswordHash = verifiedPasswordHash, TokenHash = tokenHash, ExpiresAt = expiresAt, CreatedByIp = createdByIp },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IssuedRefreshToken?> RotateAsync(string oldTokenHash, string newTokenHash, DateTime expiresAt, string? createdByIp)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<IssuedRefreshToken>(
            "security.usp_RefreshToken_RotateChecked",
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
