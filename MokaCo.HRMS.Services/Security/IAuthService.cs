using MokaCo.HRMS.Model.Security;

namespace MokaCo.HRMS.Services.Security;

public interface IAuthService
{
    Task<AuthResult> LoginAsync(LoginRequest request, string? ip);
    Task<AuthResult> RefreshAsync(string rawRefreshToken, string? ip);
    Task LogoutAsync(string rawRefreshToken);
    Task<CurrentUser?> GetCurrentUserAsync(int userId);
}
