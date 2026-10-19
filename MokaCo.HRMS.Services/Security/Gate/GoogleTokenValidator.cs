using System.Text.Json;
using Microsoft.Extensions.Logging;
using Microsoft.IdentityModel.JsonWebTokens;
using Microsoft.IdentityModel.Protocols;
using Microsoft.IdentityModel.Protocols.OpenIdConnect;
using Microsoft.IdentityModel.Tokens;

namespace MokaCo.HRMS.Services.Security.Gate;

public enum GoogleTokenStatus
{
    /// <summary>Google signed it, for our client ID, it is current, and the email is verified.</summary>
    Ok,

    /// <summary>Not a Google ID token for us: bad signature, wrong issuer or audience, expired, not RS256, unreadable.</summary>
    Invalid,

    /// <summary>A real token, but email_verified is missing or not true.</summary>
    Unverified,

    /// <summary>Google's signing keys could not be fetched, so nothing could be checked.</summary>
    Unreachable,
}

public sealed record GoogleTokenResult(GoogleTokenStatus Status, string? Email = null, string? Subject = null, string? Name = null)
{
    public static GoogleTokenResult Ok(string email, string? subject, string? name) => new(GoogleTokenStatus.Ok, email, subject, name);
    public static readonly GoogleTokenResult Invalid = new(GoogleTokenStatus.Invalid);
    public static readonly GoogleTokenResult Unverified = new(GoogleTokenStatus.Unverified);
    public static readonly GoogleTokenResult Unreachable = new(GoogleTokenStatus.Unreachable);
}

/// <summary>Checks the ID token Google Identity Services gave the gate page. An interface so the service can be tested without Google.</summary>
public interface IGoogleTokenValidator
{
    Task<GoogleTokenResult> ValidateAsync(string? credential, string clientId, CancellationToken cancellationToken = default);
}

/// <summary>
/// Verifies a Google ID token ourselves (docs/GOOGLE_SIGNIN_GATE.md G2): the signature against the keys
/// Google publishes (its OpenID discovery document → jwks_uri), the issuer, the audience = our client ID,
/// the lifetime with two minutes of clock skew, RS256 only, and email_verified. No client secret is
/// involved and nothing is sent to Google but the two public key downloads.
///
/// THE KEYS ARE CACHED by ConfigurationManager (re-read every 12 hours). Google rotates them; a token
/// signed with a key newer than our copy asks for ONE refresh and is checked again.
///
/// Logs why a token was refused (the exception type) — never the token or the email.
/// </summary>
public sealed class GoogleTokenValidator : IGoogleTokenValidator
{
    public const string MetadataAddressKey = "Google:MetadataAddress";
    public const string DefaultMetadataAddress = "https://accounts.google.com/.well-known/openid-configuration";
    public const string HttpClientName = "google-signin";
    public static readonly TimeSpan HttpTimeout = TimeSpan.FromSeconds(10);

    public static readonly IReadOnlyList<string> Issuers = ["accounts.google.com", "https://accounts.google.com"];
    public static readonly TimeSpan ClockSkew = TimeSpan.FromMinutes(2);

    /// <summary>A Google ID token is about 1 KB; anything this long is not one and is not parsed.</summary>
    private const int MaxCredentialLength = 16 * 1024;

    private static readonly TimeSpan RefreshPoll = TimeSpan.FromMilliseconds(100);

    private readonly IConfigurationManager<OpenIdConnectConfiguration> _metadata;
    private readonly ILogger<GoogleTokenValidator> _logger;
    private readonly TimeSpan _refreshWait;
    private readonly JsonWebTokenHandler _handler = new();

    /// <summary>The production wiring: Google's discovery document fetched through the named HttpClient.</summary>
    public GoogleTokenValidator(string metadataAddress, IHttpClientFactory httpClients, ILogger<GoogleTokenValidator> logger)
        : this(
            new ConfigurationManager<OpenIdConnectConfiguration>(
                metadataAddress,
                new OpenIdConnectConfigurationRetriever(),
                new FactoryDocumentRetriever(httpClients, requireHttps: !new Uri(metadataAddress).IsLoopback)),
            logger)
    {
    }

    /// <param name="refreshWait">How long a key refresh may take before the token is judged on the keys we have (tests shorten it).</param>
    public GoogleTokenValidator(
        IConfigurationManager<OpenIdConnectConfiguration> metadata, ILogger<GoogleTokenValidator> logger, TimeSpan? refreshWait = null)
    {
        _metadata = metadata;
        _logger = logger;
        _refreshWait = refreshWait ?? TimeSpan.FromSeconds(3);
    }

    /// <summary>
    /// Google:MetadataAddress, or Google's own when it is not set. HTTPS ONLY, except a loopback address
    /// (a local fake for tests): the keys decide who may open the HRMS, so they are never fetched over a
    /// connection someone on the way could rewrite. Throws at startup, naming the key, otherwise.
    /// </summary>
    public static string ResolveMetadataAddress(string? configured)
    {
        var address = string.IsNullOrWhiteSpace(configured) ? DefaultMetadataAddress : configured.Trim();

        if (!Uri.TryCreate(address, UriKind.Absolute, out var uri)
            || !(uri.Scheme == Uri.UriSchemeHttps || (uri.Scheme == Uri.UriSchemeHttp && uri.IsLoopback)))
            throw new InvalidOperationException(
                $"{MetadataAddressKey} must be an https address (plain http only for a loopback test server).");

        return address;
    }

    public async Task<GoogleTokenResult> ValidateAsync(string? credential, string clientId, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(credential) || credential.Length > MaxCredentialLength
            || string.IsNullOrWhiteSpace(clientId) || !_handler.CanReadToken(credential))
            return GoogleTokenResult.Invalid;

        var configuration = await ConfigurationAsync(refresh: null, cancellationToken);
        if (configuration is null)
            return GoogleTokenResult.Unreachable;

        var result = await _handler.ValidateTokenAsync(credential, Parameters(configuration, clientId));

        // A key we have not seen: Google rotated after our copy was read. One refresh, one more try.
        if (!result.IsValid && result.Exception is SecurityTokenSignatureKeyNotFoundException)
        {
            configuration = await ConfigurationAsync(refresh: configuration, cancellationToken);
            if (configuration is null)
                return GoogleTokenResult.Unreachable;

            result = await _handler.ValidateTokenAsync(credential, Parameters(configuration, clientId));
        }

        if (!result.IsValid)
        {
            _logger.LogInformation("A Google sign-in token was refused: {Reason}.", result.Exception?.GetType().Name ?? "invalid");
            return GoogleTokenResult.Invalid;
        }

        if (!IsTrue(Claim(result, "email_verified")))
            return GoogleTokenResult.Unverified;

        if (Claim(result, "email") is not string email || string.IsNullOrWhiteSpace(email))
            return GoogleTokenResult.Invalid;

        return GoogleTokenResult.Ok(email.Trim(), Claim(result, "sub") as string, Claim(result, "name") as string);
    }

    private static TokenValidationParameters Parameters(OpenIdConnectConfiguration configuration, string clientId) => new()
    {
        ValidateIssuer = true,
        ValidIssuers = Issuers,
        ValidateAudience = true,
        ValidAudience = clientId,
        ValidateLifetime = true,
        RequireExpirationTime = true,
        ClockSkew = ClockSkew,
        RequireSignedTokens = true,
        IssuerSigningKeys = configuration.SigningKeys,
        // RS256 only: an "alg": "HS256" (or "none") token is refused whatever key it names.
        ValidAlgorithms = [SecurityAlgorithms.RsaSha256],
    };

    /// <summary>
    /// The current keys; with <paramref name="refresh"/>, newer ones than that copy. NULL when they could
    /// not be fetched at all.
    ///
    /// ConfigurationManager refreshes IN THE BACKGROUND: the first call after RequestRefresh still answers
    /// with the old copy. So the refresh is awaited here, briefly — until a different copy comes back,
    /// or the wait is over (a refresh it declined, as it does within five minutes of the last one).
    /// </summary>
    private async Task<OpenIdConnectConfiguration?> ConfigurationAsync(OpenIdConnectConfiguration? refresh, CancellationToken cancellationToken)
    {
        try
        {
            if (refresh is null)
                return await _metadata.GetConfigurationAsync(cancellationToken);

            _metadata.RequestRefresh();
            var deadline = DateTime.UtcNow + _refreshWait;
            while (true)
            {
                var configuration = await _metadata.GetConfigurationAsync(cancellationToken);
                if (!ReferenceEquals(configuration, refresh) || DateTime.UtcNow >= deadline)
                    return configuration;

                await Task.Delay(RefreshPoll, cancellationToken);
            }
        }
        catch (Exception ex) when (!cancellationToken.IsCancellationRequested)
        {
            _logger.LogWarning(ex, "Google's sign-in keys could not be fetched.");
            return null;
        }
    }

    private static object? Claim(TokenValidationResult result, string name)
        => result.Claims.TryGetValue(name, out var value) ? value : null;

    /// <summary>email_verified arrives as a JSON true, or (some Google flows) as the string "true". Anything else is not verified.</summary>
    private static bool IsTrue(object? value) => value switch
    {
        bool flag => flag,
        string text => string.Equals(text.Trim(), "true", StringComparison.OrdinalIgnoreCase),
        JsonElement { ValueKind: JsonValueKind.True } => true,
        JsonElement { ValueKind: JsonValueKind.String } element
            => string.Equals(element.GetString()?.Trim(), "true", StringComparison.OrdinalIgnoreCase),
        _ => false,
    };

    /// <summary>
    /// A client from the factory per download, not one held for the life of the singleton: the factory
    /// recycles its handlers, so a change of Google's addresses is picked up.
    /// </summary>
    private sealed class FactoryDocumentRetriever(IHttpClientFactory httpClients, bool requireHttps) : IDocumentRetriever
    {
        public Task<string> GetDocumentAsync(string address, CancellationToken cancel)
            => new HttpDocumentRetriever(httpClients.CreateClient(HttpClientName)) { RequireHttps = requireHttps }
                .GetDocumentAsync(address, cancel);
    }
}
