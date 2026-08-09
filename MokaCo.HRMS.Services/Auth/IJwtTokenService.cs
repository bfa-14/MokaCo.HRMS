using MokaCo.HRMS.Model.Security;

namespace MokaCo.HRMS.Services.Auth;

public interface IJwtTokenService
{
    (string token, DateTime expiresAt) CreateAccessToken(User user, IEnumerable<string> permissions);
    // opaque refresh token: returns the raw value (given to client) + its hash (stored)
    (string raw, string hash) CreateRefreshToken();
    string HashRefreshToken(string raw);
}
