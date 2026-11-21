using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Logging;
using MokaCo.HRMS.Model.Booking;
using MokaCo.HRMS.Repository.Booking;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Services.Booking.Payments;

public static class GatewayNames
{
    public const string Card = "card";
    public const string Whish = "whish";

    /// <summary>"card" or "whish"; null for anything else.</summary>
    public static string? Parse(string? gateway) => (gateway ?? string.Empty).Trim().ToLowerInvariant() switch
    {
        Card => Card,
        Whish => Whish,
        _ => null,
    };
}

public static class GatewayModes
{
    public const string Test = "test";
    public const string Live = "live";

    /// <summary>"test" or "live"; null for anything else.</summary>
    public static string? Parse(string? mode) => (mode ?? string.Empty).Trim().ToLowerInvariant() switch
    {
        Test => Test,
        Live => Live,
        _ => null,
    };
}

/// <summary>Where a gateway's keys come from.</summary>
public static class GatewayKeySources
{
    /// <summary>The server file: /etc/mokaco/api.env (production), appsettings.Local.json (development).</summary>
    public const string Server = "server";

    /// <summary>Entered in HRMS (Settings > Payment gateways), stored encrypted (script 119).</summary>
    public const string Settings = "settings";

    public const string None = "none";
}

/// <summary>
/// ENCRYPTS A GATEWAY'S KEYS BEFORE THEY REACH THE DATABASE, and opens them again. AES-256-GCM with a key the
/// database never sees: it is derived (HKDF-SHA256) from this server's own signing key, which lives in the server
/// file. So the table holds no readable secret, a database copy restored on another server cannot use the keys
/// (they read as "enter them again" there - a test server never inherits production's keys), and each blob is bound
/// to its gateway and mode: the live keys cannot be moved into the test row.
///
/// Changing the server's signing key makes the stored keys unreadable; they are then entered again.
/// </summary>
public sealed class GatewayKeyProtector
{
    private const byte Version = 1;
    private const int NonceBytes = 12;
    private const int TagBytes = 16;

    private readonly byte[] _key;

    public GatewayKeyProtector(string serverSecret)
    {
        if (string.IsNullOrWhiteSpace(serverSecret))
            throw new ArgumentException("The server's signing key is required to protect the gateway keys.", nameof(serverSecret));

        _key = HKDF.DeriveKey(HashAlgorithmName.SHA256, Encoding.UTF8.GetBytes(serverSecret), 32,
            salt: Encoding.UTF8.GetBytes("MokaCo.HRMS"), info: Encoding.UTF8.GetBytes("payment-gateway-keys/v1"));
    }

    public byte[] Protect(string gateway, string mode, IReadOnlyDictionary<string, string> fields)
    {
        var plain = JsonSerializer.SerializeToUtf8Bytes(fields);
        var nonce = RandomNumberGenerator.GetBytes(NonceBytes);
        var cipher = new byte[plain.Length];
        var tag = new byte[TagBytes];

        using var aes = new AesGcm(_key, TagBytes);
        aes.Encrypt(nonce, plain, cipher, tag, Bound(gateway, mode));
        CryptographicOperations.ZeroMemory(plain);

        var blob = new byte[1 + NonceBytes + TagBytes + cipher.Length];
        blob[0] = Version;
        nonce.CopyTo(blob, 1);
        tag.CopyTo(blob, 1 + NonceBytes);
        cipher.CopyTo(blob, 1 + NonceBytes + TagBytes);
        return blob;
    }

    /// <summary>Null when the blob cannot be opened here: another server's, a changed signing key, or not ours at all.</summary>
    public IReadOnlyDictionary<string, string>? Unprotect(string gateway, string mode, byte[]? blob)
    {
        if (blob is null || blob.Length <= 1 + NonceBytes + TagBytes || blob[0] != Version)
            return null;

        var nonce = blob.AsSpan(1, NonceBytes);
        var tag = blob.AsSpan(1 + NonceBytes, TagBytes);
        var cipher = blob.AsSpan(1 + NonceBytes + TagBytes);
        var plain = new byte[cipher.Length];
        try
        {
            using var aes = new AesGcm(_key, TagBytes);
            aes.Decrypt(nonce, cipher, tag, plain, Bound(gateway, mode));
            return JsonSerializer.Deserialize<Dictionary<string, string>>(plain);
        }
        catch (Exception ex) when (ex is CryptographicException or JsonException)
        {
            return null;
        }
        finally
        {
            CryptographicOperations.ZeroMemory(plain);
        }
    }

    private static byte[] Bound(string gateway, string mode) => Encoding.UTF8.GetBytes($"{gateway}:{mode}");
}

/// <summary>The names of the fields a gateway's keys are stored under (inside the cipher).</summary>
public static class GatewayKeyFields
{
    public const string Channel = "channel";
    public const string Secret = "secret";
    public const string WebsiteUrl = "websiteUrl";

    public const string BaseUrl = "baseUrl";
    public const string MerchantId = "merchantId";
    public const string ApiPassword = "apiPassword";
    public const string ApiVersion = "apiVersion";
}

/// <summary>
/// THE TWO GATEWAYS AS THEY ARE CONFIGURED RIGHT NOW, and a client for each. Since script 119 a gateway's keys can be
/// entered in HRMS for TEST and for LIVE, and one mode is "in use"; nothing entered = the server file, as before.
///
///   the mode in use   what was chosen in Settings; otherwise the mode of the server file's keys; otherwise test
///   a mode's keys     the keys saved in HRMS for it; otherwise the server file's, when they are of that mode
///
/// "In use" is what the website's payments run on. The test page asks for a mode by name, so production can be tried
/// without switching anything; and a payment in flight is settled with the mode it was OPENED in.
/// </summary>
public interface IPaymentGateways
{
    /// <summary>The card gateway in the mode in use.</summary>
    Task<MpgsOptions> CardAsync();

    /// <summary>Whish in the mode in use.</summary>
    Task<WhishOptions> WhishAsync();

    /// <summary>The card gateway in a named mode; null or unknown = the mode in use.</summary>
    Task<MpgsOptions> CardAsync(string? mode);

    /// <summary>Whish in a named mode; null or unknown = the mode in use.</summary>
    Task<WhishOptions> WhishAsync(string? mode);

    IMpgsClient CardClient(MpgsOptions options);

    IWhishClient WhishClient(WhishOptions options);

    /// <summary>Everything the settings page shows: per gateway, the mode in use and each mode's keys (opened).</summary>
    Task<GatewayStatus> StatusAsync(string gateway);

    /// <summary>Forget what was read: the next question re-reads the database (after a save).</summary>
    void Refresh();
}

/// <param name="ChosenMode">What Settings says, or null when it follows the server file.</param>
/// <param name="ServerMode">The mode of the server file's keys, or null when it holds none.</param>
/// <param name="ActiveMode">The mode in use.</param>
public sealed record GatewayStatus(
    string Gateway,
    string? ChosenMode,
    string? ServerMode,
    string ActiveMode,
    DateTime? ModeChangedAtUtc,
    string? ModeChangedBy,
    IReadOnlyList<GatewayModeStatus> Modes);

/// <param name="Source">settings | server | none.</param>
/// <param name="Fields">The saved keys, opened - for the service to mask; never sent anywhere as they are.</param>
/// <param name="Unreadable">Keys are saved but cannot be opened on this server.</param>
public sealed record GatewayModeStatus(
    string Mode,
    string Source,
    bool Saved,
    bool Unreadable,
    IReadOnlyDictionary<string, string>? Fields,
    DateTime? SavedAtUtc,
    string? SavedBy);

/// <summary>What was last read from the database, shared by every request (the gateways are asked on every payment).</summary>
public sealed class GatewayStoreCache
{
    public static readonly TimeSpan Lifetime = TimeSpan.FromSeconds(20);

    private readonly object _gate = new();
    private GatewayStore? _store;
    private DateTime _readAtUtc;

    public GatewayStore? Get(DateTime nowUtc)
    {
        lock (_gate) return _store is not null && nowUtc - _readAtUtc < Lifetime ? _store : null;
    }

    /// <summary>The last store read, however old: what is used when the database cannot be read just now.</summary>
    public GatewayStore? Last
    {
        get { lock (_gate) return _store; }
    }

    public void Set(GatewayStore store, DateTime nowUtc)
    {
        lock (_gate) { _store = store; _readAtUtc = nowUtc; }
    }

    public void Clear()
    {
        lock (_gate) _readAtUtc = DateTime.MinValue;
    }
}

public sealed class PaymentGateways : IPaymentGateways
{
    public const string CardHttpClient = "mpgs";
    public const string WhishHttpClient = "whish";

    private readonly IPaymentGatewayRepository _repository;
    private readonly GatewayStoreCache _cache;
    private readonly GatewayKeyProtector _protector;
    private readonly MpgsOptions _serverCard;
    private readonly WhishOptions _serverWhish;
    private readonly Func<string, string?> _serverSetting;
    private readonly IHttpClientFactory _http;
    private readonly ILoggerFactory _loggers;
    private readonly ILogger<PaymentGateways> _log;
    private readonly TimeProvider _clock;

    /// <param name="serverCard">The card gateway as the server file configures it (possibly not at all).</param>
    /// <param name="serverWhish">Whish as the server file configures it (possibly not at all).</param>
    /// <param name="serverSetting">Reads a key of the server file: the two public origins and the 3-D Secure test flag.</param>
    public PaymentGateways(IPaymentGatewayRepository repository, GatewayStoreCache cache, GatewayKeyProtector protector,
        MpgsOptions serverCard, WhishOptions serverWhish, Func<string, string?> serverSetting,
        IHttpClientFactory http, ILoggerFactory loggers, TimeProvider? clock = null)
    {
        _repository = repository;
        _cache = cache;
        _protector = protector;
        _serverCard = serverCard;
        _serverWhish = serverWhish;
        _serverSetting = serverSetting;
        _http = http;
        _loggers = loggers;
        _log = loggers.CreateLogger<PaymentGateways>();
        _clock = clock ?? TimeProvider.System;
    }

    public Task<MpgsOptions> CardAsync() => CardAsync(null);

    public Task<WhishOptions> WhishAsync() => WhishAsync(null);

    public async Task<MpgsOptions> CardAsync(string? mode)
    {
        var store = await StoreAsync();
        var wanted = GatewayModes.Parse(mode) ?? ActiveMode(store, GatewayNames.Card, ServerCardMode);
        var saved = store.Keys.FirstOrDefault(k => k.Gateway == GatewayNames.Card && k.Mode == wanted);

        if (saved is not null)
        {
            var fields = _protector.Unprotect(GatewayNames.Card, wanted, saved.KeysCipher);
            return fields is null
                ? MpgsOptions.Missing(UnreadableProblem("Bank of Beirut", wanted), GatewayKeySources.Settings)
                : CardFromFields(fields);
        }

        return _serverCard.IsConfigured && ServerCardMode == wanted
            ? _serverCard
            : MpgsOptions.Missing(NoKeysProblem("Bank of Beirut", wanted, _serverCard.IsConfigured ? null : _serverCard.Problem));
    }

    public async Task<WhishOptions> WhishAsync(string? mode)
    {
        var store = await StoreAsync();
        var wanted = GatewayModes.Parse(mode) ?? ActiveMode(store, GatewayNames.Whish, ServerWhishMode);
        var saved = store.Keys.FirstOrDefault(k => k.Gateway == GatewayNames.Whish && k.Mode == wanted);

        if (saved is not null)
        {
            var fields = _protector.Unprotect(GatewayNames.Whish, wanted, saved.KeysCipher);
            return fields is null
                ? WhishOptions.Missing(UnreadableProblem("Whish", wanted), GatewayKeySources.Settings)
                : WhishFromFields(wanted, fields);
        }

        return _serverWhish.IsConfigured && ServerWhishMode == wanted
            ? _serverWhish
            : WhishOptions.Missing(NoKeysProblem("Whish", wanted, _serverWhish.Problem));
    }

    public IMpgsClient CardClient(MpgsOptions options)
        => new MpgsClient(_http.CreateClient(CardHttpClient), options, _loggers.CreateLogger<MpgsClient>());

    public IWhishClient WhishClient(WhishOptions options)
        => new WhishClient(_http.CreateClient(WhishHttpClient), options, _loggers.CreateLogger<WhishClient>());

    public async Task<GatewayStatus> StatusAsync(string gateway)
    {
        var store = await StoreAsync();
        var serverMode = gateway == GatewayNames.Card ? ServerCardMode : ServerWhishMode;
        var chosen = store.Modes.FirstOrDefault(m => m.Gateway == gateway);
        var modes = new List<GatewayModeStatus>(2);

        foreach (var mode in new[] { GatewayModes.Test, GatewayModes.Live })
        {
            var saved = store.Keys.FirstOrDefault(k => k.Gateway == gateway && k.Mode == mode);
            if (saved is not null)
            {
                var fields = _protector.Unprotect(gateway, mode, saved.KeysCipher);
                modes.Add(new GatewayModeStatus(mode, GatewayKeySources.Settings, Saved: true, Unreadable: fields is null, fields,
                    DateTime.SpecifyKind(saved.ModifiedAtUtc, DateTimeKind.Utc), saved.ModifiedBy));
            }
            else
            {
                modes.Add(new GatewayModeStatus(mode, serverMode == mode ? GatewayKeySources.Server : GatewayKeySources.None,
                    Saved: false, Unreadable: false, null, null, null));
            }
        }

        return new GatewayStatus(gateway, GatewayModes.Parse(chosen?.ActiveMode), serverMode, ActiveMode(store, gateway, serverMode),
            chosen?.ModifiedAtUtc is { } at && chosen.ActiveMode is not null ? DateTime.SpecifyKind(at, DateTimeKind.Utc) : null,
            chosen?.ActiveMode is not null ? chosen.ModifiedBy : null, modes);
    }

    public void Refresh() => _cache.Clear();

    /* ---- resolution ------------------------------------------------------------------------ */

    private string? ServerCardMode => _serverCard.IsConfigured ? _serverCard.Mode : null;

    private string? ServerWhishMode => _serverWhish.IsConfigured ? _serverWhish.Mode : null;

    private static string ActiveMode(GatewayStore store, string gateway, string? serverMode)
        => GatewayModes.Parse(store.Modes.FirstOrDefault(m => m.Gateway == gateway)?.ActiveMode) ?? serverMode ?? GatewayModes.Test;

    private static string NoKeysProblem(string name, string mode, string? serverProblem)
        => $"No {mode} keys are saved for {name}. Enter them on Settings > Payment gateways."
           + (serverProblem is null ? string.Empty : " (The server file: " + serverProblem + ")");

    private static string UnreadableProblem(string name, string mode)
        => $"The {mode} keys saved for {name} cannot be opened on this server (they were saved on another server, or its signing key changed). Enter them again on Settings > Payment gateways.";

    /// <summary>Keys from HRMS + the two public origins from the server file, through the same checks as the server file's own.</summary>
    private MpgsOptions CardFromFields(IReadOnlyDictionary<string, string> fields)
    {
        string? Read(string key) => key switch
        {
            MpgsOptions.BaseKey => fields.GetValueOrDefault(GatewayKeyFields.BaseUrl),
            MpgsOptions.MerchantIdKey => fields.GetValueOrDefault(GatewayKeyFields.MerchantId),
            MpgsOptions.ApiPasswordKey => fields.GetValueOrDefault(GatewayKeyFields.ApiPassword),
            MpgsOptions.ApiVersionKey => fields.GetValueOrDefault(GatewayKeyFields.ApiVersion),
            _ => _serverSetting(key),
        };

        return MpgsOptions.FromSettingsOrUnconfigured(Read).From(GatewayKeySources.Settings);
    }

    private WhishOptions WhishFromFields(string mode, IReadOnlyDictionary<string, string> fields)
    {
        string? Read(string key) => key switch
        {
            WhishOptions.BaseKey => mode == GatewayModes.Live ? WhishOptions.LiveBase : WhishOptions.SandboxBase,
            WhishOptions.ChannelKey => fields.GetValueOrDefault(GatewayKeyFields.Channel),
            WhishOptions.SecretKey => fields.GetValueOrDefault(GatewayKeyFields.Secret),
            WhishOptions.WebsiteUrlKey => fields.GetValueOrDefault(GatewayKeyFields.WebsiteUrl),
            _ => _serverSetting(key),
        };

        return WhishOptions.FromSettings(Read).From(GatewayKeySources.Settings);
    }

    /// <summary>
    /// What Settings holds. A database without script 119, or one that cannot be read just now, NEVER stops a
    /// payment: the gateways then work from what was last read, or from the server file alone - as before script 119.
    /// </summary>
    private async Task<GatewayStore> StoreAsync()
    {
        var now = _clock.GetUtcNow().UtcDateTime;
        if (_cache.Get(now) is { } fresh) return fresh;

        try
        {
            var store = await _repository.GetGatewaysAsync();
            _cache.Set(store, now);
            return store;
        }
        catch (MissingScriptException)
        {
            _cache.Set(GatewayStore.Empty, now);
            return GatewayStore.Empty;
        }
        catch (SqlException ex)
        {
            _log.LogWarning("The gateways' settings could not be read (SQL error {Number}); using what was read last.", ex.Number);
            return _cache.Last ?? GatewayStore.Empty;
        }
    }
}

/// <summary>
/// Fixed gateways: the options and clients handed in, whatever mode is asked for. What the deposit service was built
/// on before script 119, and what its tests still build it on.
/// </summary>
public sealed class FixedPaymentGateways : IPaymentGateways
{
    private readonly MpgsOptions _card;
    private readonly IMpgsClient _cardClient;
    private readonly WhishOptions _whish;
    private readonly IWhishClient? _whishClient;

    public FixedPaymentGateways(MpgsOptions card, IMpgsClient cardClient, WhishOptions? whish = null, IWhishClient? whishClient = null)
    {
        _card = card;
        _cardClient = cardClient;
        _whishClient = whishClient;
        _whish = whishClient is null ? WhishOptions.Unconfigured : whish ?? WhishOptions.Unconfigured;
    }

    public Task<MpgsOptions> CardAsync() => Task.FromResult(_card);
    public Task<WhishOptions> WhishAsync() => Task.FromResult(_whish);
    public Task<MpgsOptions> CardAsync(string? mode) => Task.FromResult(_card);
    public Task<WhishOptions> WhishAsync(string? mode) => Task.FromResult(_whish);
    public IMpgsClient CardClient(MpgsOptions options) => _cardClient;
    public IWhishClient WhishClient(WhishOptions options) => _whishClient ?? throw new InvalidOperationException("Whish is not configured.");

    public Task<GatewayStatus> StatusAsync(string gateway)
    {
        var mode = gateway == GatewayNames.Card ? _card.Mode : _whish.Mode;
        return Task.FromResult(new GatewayStatus(gateway, null, mode, mode, null, null, []));
    }

    public void Refresh() { }
}

/// <summary>Shows the end of a key and nothing else: enough to tell two keys apart, useless to anybody who reads it.</summary>
public static class GatewayKeyMask
{
    public static string? Hint(string? value)
    {
        var text = (value ?? string.Empty).Trim();
        if (text.Length == 0) return null;
        // A short key gives nothing away; a long one shows its last four characters.
        return text.Length < 12 ? "••••" : "••••" + text[^4..];
    }

    public static string Version(int version) => version.ToString(CultureInfo.InvariantCulture);
}
