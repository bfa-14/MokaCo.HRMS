using System.Security.Cryptography;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.IdentityModel.JsonWebTokens;
using Microsoft.IdentityModel.Protocols;
using Microsoft.IdentityModel.Protocols.OpenIdConnect;
using Microsoft.IdentityModel.Tokens;
using MokaCo.HRMS.Services.Security.Gate;

namespace MokaCo.HRMS.Tests.Security.Gate;

/// <summary>
/// G2: a Google ID token checked by us — signature from Google's published keys, issuer, audience =
/// our client ID, lifetime with 2 minutes of skew, RS256 only, email_verified — and one key refresh
/// when the token names a key we have not seen. Google is a locally generated RSA key and a stub
/// metadata source, so none of this touches the network.
/// </summary>
public class GoogleTokenValidatorTests
{
    private const string ClientId = "123456789-abcdef.apps.googleusercontent.com";
    private const string GoogleIssuer = "https://accounts.google.com";

    private static readonly RsaSecurityKey Key1 = NewKey("k1");
    private static readonly RsaSecurityKey Key2 = NewKey("k2");

    private static RsaSecurityKey NewKey(string kid) => new(RSA.Create(2048)) { KeyId = kid };

    /// <summary>The metadata Google would publish; a refresh can swap in a newer copy, and a fetch can fail.</summary>
    private sealed class StubMetadata(OpenIdConnectConfiguration current) : IConfigurationManager<OpenIdConnectConfiguration>
    {
        public OpenIdConnectConfiguration Current { get; set; } = current;
        public OpenIdConnectConfiguration? AfterRefresh { get; set; }
        public Exception? Failure { get; set; }
        public int Reads { get; private set; }
        public int Refreshes { get; private set; }

        public Task<OpenIdConnectConfiguration> GetConfigurationAsync(CancellationToken cancel)
        {
            Reads++;
            return Failure is null ? Task.FromResult(Current) : Task.FromException<OpenIdConnectConfiguration>(Failure);
        }

        public void RequestRefresh()
        {
            Refreshes++;
            if (AfterRefresh is not null)
                Current = AfterRefresh;
        }
    }

    private static OpenIdConnectConfiguration Config(params SecurityKey[] keys)
    {
        var configuration = new OpenIdConnectConfiguration { Issuer = GoogleIssuer };
        foreach (var key in keys)
            configuration.SigningKeys.Add(key);
        return configuration;
    }

    private static readonly object Missing = new();

    private static string Token(
        SecurityKey? key = null, string algorithm = SecurityAlgorithms.RsaSha256,
        string issuer = GoogleIssuer, string audience = ClientId,
        TimeSpan? issuedAgo = null, TimeSpan? expiresIn = null, TimeSpan? notBeforeIn = null,
        object? emailVerified = null, string email = "rana.haddad@gmail.com")
    {
        var now = DateTime.UtcNow;
        var claims = new Dictionary<string, object>
        {
            ["email"] = email,
            ["sub"] = "110248495921238986420",
            ["name"] = "Rana Haddad",
        };
        emailVerified ??= true;
        if (!ReferenceEquals(emailVerified, Missing))
            claims["email_verified"] = emailVerified;

        var issuedAt = now - (issuedAgo ?? TimeSpan.FromMinutes(1));
        return new JsonWebTokenHandler { SetDefaultTimesOnTokenCreation = false }.CreateToken(new SecurityTokenDescriptor
        {
            Issuer = issuer,
            Audience = audience,
            IssuedAt = issuedAt,
            NotBefore = notBeforeIn is { } nbf ? now + nbf : issuedAt,
            Expires = now + (expiresIn ?? TimeSpan.FromMinutes(59)),
            Claims = claims,
            SigningCredentials = new SigningCredentials(key ?? Key1, algorithm),
        });
    }

    private static GoogleTokenValidator Validator(StubMetadata metadata)
        => new(metadata, NullLogger<GoogleTokenValidator>.Instance, refreshWait: TimeSpan.FromMilliseconds(300));

    private static async Task<GoogleTokenResult> Validate(string? token, StubMetadata? metadata = null, string clientId = ClientId)
        => await Validator(metadata ?? new StubMetadata(Config(Key1))).ValidateAsync(token, clientId);

    /* ---- valid ---- */

    [Fact]
    public async Task A_token_Google_signed_for_our_client_is_ok_with_email_sub_and_name()
    {
        var result = await Validate(Token());

        Assert.Equal(GoogleTokenStatus.Ok, result.Status);
        Assert.Equal("rana.haddad@gmail.com", result.Email);
        Assert.Equal("110248495921238986420", result.Subject);
        Assert.Equal("Rana Haddad", result.Name);
    }

    [Fact]
    public async Task Both_spellings_of_Googles_issuer_are_accepted()
    {
        Assert.Equal(GoogleTokenStatus.Ok, (await Validate(Token(issuer: "accounts.google.com"))).Status);
        Assert.Equal(GoogleTokenStatus.Ok, (await Validate(Token(issuer: "https://accounts.google.com"))).Status);
    }

    /* ---- invalid ---- */

    [Fact]
    public async Task A_token_for_another_client_is_invalid()
    {
        Assert.Equal(GoogleTokenStatus.Invalid, (await Validate(Token(audience: "999-other.apps.googleusercontent.com"))).Status);
        Assert.Equal(GoogleTokenStatus.Invalid, (await Validate(Token(), clientId: "999-other.apps.googleusercontent.com")).Status);
    }

    [Theory]
    [InlineData("https://accounts.google.com.evil.example")]
    [InlineData("https://evil.example")]
    [InlineData("http://accounts.google.com")]
    [InlineData("")]
    public async Task A_token_from_another_issuer_is_invalid(string issuer)
        => Assert.Equal(GoogleTokenStatus.Invalid, (await Validate(Token(issuer: issuer))).Status);

    [Fact]
    public async Task An_expired_token_is_invalid_beyond_two_minutes_of_skew()
    {
        Assert.Equal(GoogleTokenStatus.Invalid,
            (await Validate(Token(issuedAgo: TimeSpan.FromHours(2), expiresIn: TimeSpan.FromMinutes(-10)))).Status);
        Assert.Equal(GoogleTokenStatus.Ok,
            (await Validate(Token(issuedAgo: TimeSpan.FromHours(1), expiresIn: TimeSpan.FromSeconds(-60)))).Status);
    }

    [Fact]
    public async Task A_token_not_yet_valid_is_invalid_beyond_two_minutes_of_skew()
    {
        Assert.Equal(GoogleTokenStatus.Invalid, (await Validate(Token(notBeforeIn: TimeSpan.FromMinutes(10)))).Status);
        Assert.Equal(GoogleTokenStatus.Ok, (await Validate(Token(notBeforeIn: TimeSpan.FromSeconds(60)))).Status);
    }

    [Fact]
    public async Task A_token_signed_by_a_key_Google_does_not_publish_is_invalid()
    {
        var stranger = NewKey("k1");   // same kid, different key
        Assert.Equal(GoogleTokenStatus.Invalid, (await Validate(Token(key: stranger))).Status);
    }

    [Fact]
    public async Task An_HS256_token_is_refused_even_when_its_key_is_in_the_set()
    {
        var shared = new SymmetricSecurityKey(RandomNumberGenerator.GetBytes(64)) { KeyId = "hs" };
        var metadata = new StubMetadata(Config(Key1, shared));

        var result = await Validate(Token(key: shared, algorithm: SecurityAlgorithms.HmacSha256), metadata);

        Assert.Equal(GoogleTokenStatus.Invalid, result.Status);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("not-a-token")]
    [InlineData("a.b.c")]
    [InlineData("eyJhbGciOiJub25lIn0.eyJlbWFpbCI6InJAZ21haWwuY29tIn0.")]
    public async Task Garbage_and_unsigned_tokens_are_invalid_and_never_refresh_the_keys(string? credential)
    {
        var metadata = new StubMetadata(Config(Key1));

        Assert.Equal(GoogleTokenStatus.Invalid, (await Validate(credential, metadata)).Status);
        Assert.Equal(0, metadata.Refreshes);
    }

    [Fact]
    public async Task An_oversized_credential_is_invalid_without_asking_for_the_keys()
    {
        var metadata = new StubMetadata(Config(Key1));

        Assert.Equal(GoogleTokenStatus.Invalid, (await Validate(Token() + new string('A', 20_000), metadata)).Status);
        Assert.Equal(0, metadata.Reads);
    }

    [Fact]
    public async Task A_blank_client_id_validates_nothing()
        => Assert.Equal(GoogleTokenStatus.Invalid, (await Validate(Token(), clientId: " ")).Status);

    /* ---- email_verified ---- */

    [Fact]
    public async Task Email_verified_true_as_a_bool_or_as_the_string_true_is_ok()
    {
        Assert.Equal(GoogleTokenStatus.Ok, (await Validate(Token(emailVerified: true))).Status);
        Assert.Equal(GoogleTokenStatus.Ok, (await Validate(Token(emailVerified: "true"))).Status);
        Assert.Equal(GoogleTokenStatus.Ok, (await Validate(Token(emailVerified: "True"))).Status);
    }

    [Fact]
    public async Task Email_verified_false_or_missing_is_unverified()
    {
        Assert.Equal(GoogleTokenStatus.Unverified, (await Validate(Token(emailVerified: false))).Status);
        Assert.Equal(GoogleTokenStatus.Unverified, (await Validate(Token(emailVerified: "false"))).Status);
        Assert.Equal(GoogleTokenStatus.Unverified, (await Validate(Token(emailVerified: Missing))).Status);
        Assert.Equal(GoogleTokenStatus.Unverified, (await Validate(Token(emailVerified: "yes"))).Status);
        Assert.Equal(GoogleTokenStatus.Unverified, (await Validate(Token(emailVerified: 1))).Status);
    }

    [Fact]
    public async Task Unverified_is_only_said_of_a_token_that_is_otherwise_valid()
        => Assert.Equal(GoogleTokenStatus.Invalid, (await Validate(Token(emailVerified: false, audience: "other"))).Status);

    /* ---- keys: rotation and outage ---- */

    [Fact]
    public async Task An_unknown_key_asks_for_one_refresh_and_then_succeeds()
    {
        var metadata = new StubMetadata(Config(Key1)) { AfterRefresh = Config(Key1, Key2) };

        var result = await Validate(Token(key: Key2), metadata);

        Assert.Equal(GoogleTokenStatus.Ok, result.Status);
        Assert.Equal(1, metadata.Refreshes);
    }

    [Fact]
    public async Task An_unknown_key_the_refresh_does_not_bring_is_invalid_after_one_refresh()
    {
        var metadata = new StubMetadata(Config(Key1));

        var result = await Validate(Token(key: Key2), metadata);

        Assert.Equal(GoogleTokenStatus.Invalid, result.Status);
        Assert.Equal(1, metadata.Refreshes);
    }

    [Fact]
    public async Task A_known_key_never_refreshes()
    {
        var metadata = new StubMetadata(Config(Key1, Key2));

        await Validate(Token(key: Key2), metadata);
        await Validate(Token(audience: "other"), metadata);

        Assert.Equal(0, metadata.Refreshes);
    }

    [Fact]
    public async Task Keys_that_cannot_be_fetched_are_unreachable()
    {
        var metadata = new StubMetadata(Config(Key1))
        {
            Failure = new InvalidOperationException("IDX20803: Unable to obtain configuration from: 'https://accounts.google.com/...'."),
        };

        Assert.Equal(GoogleTokenStatus.Unreachable, (await Validate(Token(), metadata)).Status);
    }

    /// <summary>
    /// The real ConfigurationManager refreshes in the BACKGROUND (the call right after RequestRefresh
    /// still returns the old keys): the validator waits for the new copy instead of refusing.
    /// </summary>
    [Fact]
    public async Task With_the_real_configuration_manager_a_rotated_key_is_picked_up_on_the_same_attempt()
    {
        var documents = new InMemoryGoogle(Key1);
        var manager = new ConfigurationManager<OpenIdConnectConfiguration>(
            InMemoryGoogle.Discovery, new OpenIdConnectConfigurationRetriever(), documents);
        var validator = new GoogleTokenValidator(manager, NullLogger<GoogleTokenValidator>.Instance, refreshWait: TimeSpan.FromSeconds(5));

        Assert.Equal(GoogleTokenStatus.Ok, (await validator.ValidateAsync(Token(key: Key1), ClientId)).Status);

        documents.Keys = [Key1, Key2];
        Assert.Equal(GoogleTokenStatus.Ok, (await validator.ValidateAsync(Token(key: Key2), ClientId)).Status);
    }

    /// <summary>Google's discovery document and key set, served from memory.</summary>
    private sealed class InMemoryGoogle(params RsaSecurityKey[] keys) : IDocumentRetriever
    {
        public const string Discovery = "https://accounts.google.com/.well-known/openid-configuration";
        private const string Certs = "https://www.googleapis.com/oauth2/v3/certs";

        public RsaSecurityKey[] Keys { get; set; } = keys;

        public Task<string> GetDocumentAsync(string address, CancellationToken cancel)
        {
            if (address == Discovery)
                return Task.FromResult($$"""{"issuer":"{{GoogleIssuer}}","jwks_uri":"{{Certs}}"}""");

            var jwks = new JsonWebKeySet();
            foreach (var key in Keys)
                jwks.Keys.Add(JsonWebKeyConverter.ConvertFromRSASecurityKey(key));
            return Task.FromResult(System.Text.Json.JsonSerializer.Serialize(new
            {
                keys = jwks.Keys.Select(k => new { kty = k.Kty, kid = k.Kid, use = "sig", alg = "RS256", n = k.N, e = k.E }),
            }));
        }
    }

    /* ---- configuration ---- */

    [Theory]
    [InlineData(null, GoogleTokenValidator.DefaultMetadataAddress)]
    [InlineData("", GoogleTokenValidator.DefaultMetadataAddress)]
    [InlineData("https://accounts.google.com/.well-known/openid-configuration", "https://accounts.google.com/.well-known/openid-configuration")]
    [InlineData(" http://127.0.0.1:5099/.well-known/openid-configuration ", "http://127.0.0.1:5099/.well-known/openid-configuration")]
    [InlineData("http://localhost:5099/fake", "http://localhost:5099/fake")]
    public void The_metadata_address_is_googles_unless_configured(string? configured, string expected)
        => Assert.Equal(expected, GoogleTokenValidator.ResolveMetadataAddress(configured));

    [Theory]
    [InlineData("http://accounts.google.com/.well-known/openid-configuration")]
    [InlineData("http://10.0.0.5/fake")]
    [InlineData("ftp://accounts.google.com/x")]
    [InlineData("accounts.google.com")]
    public void A_metadata_address_that_is_not_https_or_loopback_stops_the_start(string configured)
    {
        var ex = Assert.Throws<InvalidOperationException>(() => GoogleTokenValidator.ResolveMetadataAddress(configured));
        Assert.Contains(GoogleTokenValidator.MetadataAddressKey, ex.Message);
    }
}
