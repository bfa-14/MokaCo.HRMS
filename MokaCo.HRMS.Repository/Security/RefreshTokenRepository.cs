using System.Data;
using Dapper;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.Security;

/// <summary>
/// Refresh-token access. Rotation and revoke use the stored procedures (atomic /
/// security-critical). Initial creation on login is a simple inline insert.
/// </summary>
public class RefreshTokenRepository : IRefreshTokenRepository
{
    private readonly IDbConnectionFactory _factory;
    public RefreshTokenRepository(IDbConnectionFactory factory) => _factory = factory;

    public async Task CreateAsync(int userId, string tokenHash, DateTime expiresAt, string? createdByIp)
    {
        const string sql = @"
            INSERT INTO security.REFRESH_TOKEN (UserId, TokenHash, ExpiresAt, CreatedByIp)
            VALUES (@UserId, @TokenHash, @ExpiresAt, @CreatedByIp);";
        using var db = _factory.Create();
        await db.ExecuteAsync(sql, new { UserId = userId, TokenHash = tokenHash, ExpiresAt = expiresAt, CreatedByIp = createdByIp });
    }

    public async Task<RotateResult?> RotateAsync(string oldTokenHash, string newTokenHash, DateTime expiresAt, string? createdByIp)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<RotateResult>(
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
