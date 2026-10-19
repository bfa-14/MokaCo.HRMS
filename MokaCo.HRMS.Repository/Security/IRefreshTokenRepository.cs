namespace MokaCo.HRMS.Repository.Security;

/// <summary>A refresh token just issued or rotated, with the account's session stamp at that moment (script 105).</summary>
public class IssuedRefreshToken
{
    public long RefreshTokenId { get; set; }
    public int UserId { get; set; }

    /// <summary>
    /// Read in the same transaction as the token was written, under the lock usp_User_EndSessions takes:
    /// the access token issued with this refresh token must carry THIS value, never one read afterwards.
    /// </summary>
    public Guid? SessionStamp { get; set; }
}

public interface IRefreshTokenRepository
{
    /// <summary>
    /// security.usp_RefreshToken_Issue — the refresh token of a sign-in whose password was just checked
    /// against <paramref name="verifiedPasswordHash"/>. Null when the account is no longer active or that
    /// is no longer its hash (changed during the check): no session.
    /// </summary>
    Task<IssuedRefreshToken?> IssueAsync(int userId, string verifiedPasswordHash, string tokenHash, DateTime expiresAt, string? createdByIp);

    /// <summary>
    /// security.usp_RefreshToken_RotateChecked — exchanges a live token for a new one. Null when the token
    /// is unknown, revoked or expired, or the account is disabled.
    /// </summary>
    Task<IssuedRefreshToken?> RotateAsync(string oldTokenHash, string newTokenHash, DateTime expiresAt, string? createdByIp);

    Task RevokeAsync(string tokenHash);
}
