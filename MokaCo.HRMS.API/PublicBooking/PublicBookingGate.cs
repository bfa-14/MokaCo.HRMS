using MokaCo.HRMS.Repository.Core;

namespace MokaCo.HRMS.Api.PublicBooking;

/// <summary>What a caller is judged against, as one immutable reading — so a request cannot see the origins from one refresh and the key from the next.</summary>
/// <param name="WebsiteEnabled">core.SETTING BookingWebsiteEnabled. False = quote and create answer 503 paused; the reads stay up.</param>
/// <param name="Origins">core.SETTING BookingCorsOrigins, split on commas. A browser on one of these needs nothing else.</param>
/// <param name="ApiKey">core.SETTING BookingApiKey. EMPTY MEANS THE KEY MODE IS OFF, not "any key will do".</param>
public sealed record PublicBookingSnapshot(bool WebsiteEnabled, string[] Origins, string ApiKey)
{
    /// <summary>Refuse everything — what the gate answers until a read succeeds. An allowlist nobody has managed to load should permit nothing.</summary>
    public static readonly PublicBookingSnapshot Closed = new(WebsiteEnabled: false, Origins: [], ApiKey: string.Empty);

    /// <summary>
    /// ORDINAL, CASE-INSENSITIVE, EXACT. An origin is a scheme, a host and a port and nothing else,
    /// so comparing whole strings is the comparison; anything looser ("starts with") is how
    /// https://mokanco.com.lb.attacker.example ends up on an allowlist.
    /// </summary>
    public bool AllowsOrigin(string? origin)
        => !string.IsNullOrEmpty(origin) && Origins.Contains(origin.Trim().TrimEnd('/'), StringComparer.OrdinalIgnoreCase);
}

/// <summary>The three settings that decide who may talk to the public booking API. An interface so the access filter can be tested without a database.</summary>
public interface IPublicBookingGate
{
    Task<PublicBookingSnapshot> CurrentAsync(CancellationToken cancellationToken = default);
}

/// <summary>
/// Reads BookingWebsiteEnabled, BookingCorsOrigins and BookingApiKey from core.SETTING once a
/// minute and shares the reading with the access filter and the CORS policy provider.
///
/// WHY SETTINGS AND NOT CONFIGURATION. The previous build read BookingCorsOrigins from
/// appsettings.json and built the CORS policy at startup, so the Settings page row of the same name
/// appeared to work and did nothing until a restart. Pausing online booking is something somebody
/// does at 23:00 because the room flooded, not something to schedule a restart for.
///
/// SIXTY SECONDS is the trade for not querying core.SETTING on every calendar click; a pause takes
/// effect within a minute. A FAILED READ KEEPS THE LAST GOOD ANSWER and does not extend the cache,
/// so the next request retries. Before the first successful read the answer is CLOSED.
/// </summary>
public sealed class PublicBookingGate : IPublicBookingGate
{
    public const string WebsiteEnabledSetting = "BookingWebsiteEnabled";
    public const string CorsOriginsSetting = "BookingCorsOrigins";
    public const string ApiKeySetting = "BookingApiKey";

    public static readonly TimeSpan CacheFor = TimeSpan.FromSeconds(60);

    private readonly IServiceScopeFactory _scopes;
    private readonly ILogger<PublicBookingGate> _logger;

    /// <summary>One refresh at a time — a cold start under load must not send every request to the database for the same three rows.</summary>
    private readonly SemaphoreSlim _refresh = new(1, 1);

    private PublicBookingSnapshot _current = PublicBookingSnapshot.Closed;
    private DateTime _readUtc = DateTime.MinValue;

    public PublicBookingGate(IServiceScopeFactory scopes, ILogger<PublicBookingGate> logger)
    {
        _scopes = scopes;
        _logger = logger;
    }

    public async Task<PublicBookingSnapshot> CurrentAsync(CancellationToken cancellationToken = default)
    {
        if (IsFresh)
            return _current;

        await _refresh.WaitAsync(cancellationToken);
        try
        {
            // Checked again under the lock: the caller ahead has usually just refreshed.
            if (IsFresh)
                return _current;

            // A SCOPE OF ITS OWN: this is a singleton and ISettingRepository is scoped.
            using var scope = _scopes.CreateScope();
            var settings = scope.ServiceProvider.GetRequiredService<ISettingRepository>();

            var all = (await settings.GetAllAsync()).ToDictionary(
                setting => setting.SettingKey,
                setting => setting.SettingValue ?? string.Empty,
                StringComparer.OrdinalIgnoreCase);

            _current = new PublicBookingSnapshot(
                WebsiteEnabled: Value(all, WebsiteEnabledSetting) != "0",
                Origins: Value(all, CorsOriginsSetting)
                    .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                    .Select(origin => origin.TrimEnd('/'))
                    .ToArray(),
                ApiKey: Value(all, ApiKeySetting));

            _readUtc = DateTime.UtcNow;
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Could not read the public booking settings; keeping the previous values.");
        }
        finally
        {
            _refresh.Release();
        }

        return _current;
    }

    private bool IsFresh => DateTime.UtcNow - _readUtc < CacheFor;

    private static string Value(IReadOnlyDictionary<string, string> settings, string key)
        => settings.TryGetValue(key, out var value) ? value.Trim() : string.Empty;
}
