namespace MokaCo.HRMS.Model.Security;

/// <summary>Maps to security.REFRESH_TOKEN. Stores a HASH of the token, not the raw value.</summary>
public class RefreshToken
{
    public long RefreshTokenId { get; set; }
    public int UserId { get; set; }
    public string TokenHash { get; set; } = string.Empty;
    public DateTime ExpiresAt { get; set; }
    public DateTime CreatedAt { get; set; }
    public string? CreatedByIp { get; set; }
    public DateTime? RevokedAt { get; set; }
    public string? ReplacedByHash { get; set; }
}
