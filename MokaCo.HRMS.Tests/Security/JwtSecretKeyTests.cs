using System.Text.Json;
using MokaCo.HRMS.Services.Auth;

namespace MokaCo.HRMS.Tests.Security;

/// <summary>
/// QA3: the API refuses to start on a signing key anybody could know — blank, the placeholder tracked
/// in appsettings.json, or too short for HMAC-SHA256 — and says so without ever printing the value.
/// </summary>
public class JwtSecretKeyTests
{
    private static string? Problem(string key) => new JwtOptions { SecretKey = key }.SecretKeyProblem();

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData(JwtOptions.PlaceholderSecretKey)]
    [InlineData(" " + JwtOptions.PlaceholderSecretKey + " ")]
    [InlineData("0123456789abcdef0123456789abcde")]    // 31 bytes
    public void An_unusable_key_stops_the_start_naming_the_key(string key)
    {
        var problem = Problem(key);

        Assert.NotNull(problem);
        Assert.StartsWith("Jwt:SecretKey ", problem);
        Assert.Contains("Jwt__SecretKey", problem);
    }

    [Fact]
    public void The_message_never_carries_the_value()
    {
        const string shortSecret = "s3cr3t-but-short";
        Assert.DoesNotContain(shortSecret, Problem(shortSecret));
    }

    [Theory]
    [InlineData("0123456789abcdef0123456789abcdef")]   // exactly 32 bytes
    [InlineData("éééééééééééééééé")]                   // 16 characters, 32 bytes in UTF-8 — bytes are what HMAC uses
    public void A_key_of_32_bytes_or_more_is_accepted(string key) => Assert.Null(Problem(key));

    [Fact]
    public void A_key_like_the_deploy_script_writes_is_accepted()
        => Assert.Null(Problem(Convert.ToBase64String(new byte[48])));     // openssl rand -base64 48 -> 64 characters

    /// <summary>The tracked appsettings.json still carries the placeholder, so a server with nothing of its own cannot start.</summary>
    [Fact]
    public void The_tracked_appsettings_holds_exactly_the_placeholder_the_check_refuses()
    {
        var dir = AppContext.BaseDirectory;
        while (dir is not null && !File.Exists(Path.Combine(dir, "MokaCo.HRMS.slnx")))
            dir = Path.GetDirectoryName(dir);
        Assert.NotNull(dir);

        using var json = JsonDocument.Parse(File.ReadAllText(Path.Combine(dir!, "MokaCo.HRMS.API", "appsettings.json")));
        var tracked = json.RootElement.GetProperty("Jwt").GetProperty("SecretKey").GetString();

        Assert.Equal(JwtOptions.PlaceholderSecretKey, tracked);
        Assert.NotNull(Problem(tracked!));
    }
}
