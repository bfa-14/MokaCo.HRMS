namespace MokaCo.HRMS.Repository.Security;

public class RotateResult
{
    public long RefreshTokenId { get; set; }
    public int UserId { get; set; }
}

public interface IRefreshTokenRepository
{
    Task CreateAsync(int userId, string tokenHash, DateTime expiresAt, string? createdByIp);
    Task<RotateResult?> RotateAsync(string oldTokenHash, string newTokenHash, DateTime expiresAt, string? createdByIp);
    Task RevokeAsync(string tokenHash);
}
