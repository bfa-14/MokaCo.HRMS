using System.Text;

namespace MokaCo.HRMS.Services.Auth;

/// <summary>Bound from the "Jwt" section of appsettings.json.</summary>
public class JwtOptions
{
    /// <summary>
    /// The value the tracked appsettings.json carries in place of the real key. Anybody can read it in
    /// git, so a server signing with it would accept a token forged by anybody (QA3).
    /// </summary>
    public const string PlaceholderSecretKey = "REPLACE_WITH_A_LONG_RANDOM_SECRET_AT_LEAST_32_CHARS";

    /// <summary>HMAC-SHA256 needs a key of at least 256 bits; a shorter one also fails every sign-in at run time.</summary>
    public const int MinSecretKeyBytes = 32;

    public string Issuer { get; set; } = string.Empty;
    public string Audience { get; set; } = string.Empty;
    public string SecretKey { get; set; } = string.Empty;
    public int AccessTokenMinutes { get; set; } = 15;
    public int RefreshTokenDays { get; set; } = 7;

    /// <summary>
    /// Why the start must stop, or null when the signing key is usable: blank, the tracked placeholder,
    /// or shorter than <see cref="MinSecretKeyBytes"/> bytes (UTF-8, as it is used). The sentence names
    /// the key and where to set it — never the value.
    /// </summary>
    public string? SecretKeyProblem()
    {
        var why = string.IsNullOrWhiteSpace(SecretKey) ? "is not set"
            : SecretKey.Trim() == PlaceholderSecretKey ? "is still the placeholder from appsettings.json"
            : Encoding.UTF8.GetByteCount(SecretKey) < MinSecretKeyBytes ? $"is shorter than {MinSecretKeyBytes} bytes"
            : null;

        return why is null
            ? null
            : $"Jwt:SecretKey {why}. The API signs every sign-in with it, so it refuses to start without a secret " +
              $"of its own: set Jwt__SecretKey in /etc/mokaco/api.env (production) or Jwt:SecretKey in " +
              $"appsettings.Local.json (development), for example the output of: openssl rand -base64 48";
    }
}
