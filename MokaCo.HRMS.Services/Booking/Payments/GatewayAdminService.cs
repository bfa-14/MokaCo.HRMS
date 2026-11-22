using System.Diagnostics;
using System.Globalization;
using System.Security.Cryptography;
using System.Text.RegularExpressions;
using Microsoft.Extensions.Logging;
using MokaCo.HRMS.Model.Booking;
using MokaCo.HRMS.Repository.Booking;

namespace MokaCo.HRMS.Services.Booking.Payments;

/* ---- what the gateway pages are answered with ------------------------------------------------ */

/// <summary>One mode (test or live) of one gateway, as the settings page shows it. NEVER A KEY: the end of one at most.</summary>
/// <param name="Source">settings (saved in HRMS) | server (the server file) | none.</param>
/// <param name="Ready">The keys are complete and usable.</param>
/// <param name="Shown">What may be shown: addresses and ids in full, secrets as "••••" plus their last four characters.</param>
public sealed record GatewayModeView(
    string Mode,
    string Source,
    bool HasKeys,
    bool Unreadable,
    bool Ready,
    string? Problem,
    IReadOnlyDictionary<string, string?> Shown,
    DateTime? SavedAtUtc,
    string? SavedBy);

/// <param name="ChosenMode">What was chosen in HRMS; null = the gateway follows the server file.</param>
/// <param name="ServerMode">The mode of the server file's keys; null = the server file holds none.</param>
public sealed record GatewayView(
    string Gateway,
    string ActiveMode,
    string? ChosenMode,
    string? ServerMode,
    bool Ready,
    string? Problem,
    DateTime? ModeChangedAtUtc,
    string? ModeChangedBy,
    IReadOnlyList<GatewayModeView> Modes);

/// <param name="WhishOnWebsite">The setting BookingWhishEnabled: the website offers Whish.</param>
/// <param name="DepositsRequired">The setting BookingDepositRequired: the website takes deposits online at all.</param>
/// <param name="Production">This is the live system: a gateway in test mode must not be offered to guests here.</param>
public sealed record GatewayOverview(
    GatewayView Card,
    GatewayView Whish,
    bool WhishOnWebsite,
    bool DepositsRequired,
    string? SiteUrl,
    string? ApiPublicUrl,
    IReadOnlyList<GatewayHistoryRow> History,
    bool Production = false);

/// <summary>The outcome of something an admin asked for, in a sentence they can act on.</summary>
public sealed record GatewayActionResult(bool Ok, string Message, int? Milliseconds = null, GatewayTestRow? Test = null,
    IReadOnlyList<GatewayFact>? Facts = null);

/// <summary>One line of what a gateway said: "Status" / "CAPTURED".</summary>
public sealed record GatewayFact(string Label, string Value);

/// <summary>The keys as they are typed in. Blank = keep what is saved (a secret is never sent back to be re-typed).</summary>
public sealed class GatewayKeysInput
{
    /* Whish */
    public string? Channel { get; set; }
    public string? Secret { get; set; }
    public string? WebsiteUrl { get; set; }

    /* Bank of Beirut (MPGS) */
    public string? BaseUrl { get; set; }
    public string? MerchantId { get; set; }
    public string? ApiPassword { get; set; }
    public string? ApiVersion { get; set; }
}

/// <summary>The two public origins of the server file, which the gateways' return addresses are built from.</summary>
/// <param name="Production">This is the live system (not the test side, not a developer's machine): real guests reach it.</param>
public sealed record GatewayServerFacts(string? SiteUrl, string? ApiPublicUrl, bool Production = false);

/// <summary>A gateway test's reference: GT-XXXXXXXX. Never the shape of a booking's (MC-XXXXXXXX).</summary>
public static partial class GatewayTestRefs
{
    public const string Prefix = "GT-";

    public static bool IsTestRef(string? reference) => reference is not null && Shape().IsMatch(reference);

    public static string New()
    {
        const string alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";       // no 0/O, 1/I: it is read out and typed
        Span<char> text = stackalloc char[8];
        for (var i = 0; i < text.Length; i++)
            text[i] = alphabet[RandomNumberGenerator.GetInt32(alphabet.Length)];
        return Prefix + new string(text);
    }

    [GeneratedRegex("^GT-[A-Z0-9]{8}$")]
    private static partial Regex Shape();
}

/// <summary>
/// THE GATEWAYS, FOR AN ADMIN (script 119; permission GATEWAY_ADMIN): their keys for test and for live, which mode
/// is in use, a connection check that moves no money, and TEST PAYMENTS opened from HRMS - so a gateway can be tried,
/// in test or in production, without going through the website and without switching anything.
///
/// NOTHING HERE EVER RETURNS OR LOGS A KEY. What is typed is encrypted before it is stored
/// (<see cref="GatewayKeyProtector"/>); what is shown is an address, an id, or the last four characters of a secret.
///
/// A TEST PAYMENT IS NEVER A BOOKING: its reference is GT-XXXXXXXX, it lives in booking.GATEWAY_TEST, and nothing
/// about it reaches the bookings, their payments or the report. In LIVE mode it moves real money (the page says so
/// before it is opened); a Whish test can be refunded from the page, a card test in the bank's portal.
/// </summary>
public interface IGatewayAdminService
{
    Task<GatewayOverview> GetAsync();
    Task<GatewayActionResult> SaveKeysAsync(string gateway, string mode, GatewayKeysInput input, int userId);
    Task<GatewayActionResult> DeleteKeysAsync(string gateway, string mode, int userId);
    Task<GatewayActionResult> SetModeAsync(string gateway, string? mode, int userId);

    /// <summary>
    /// The two switches that decide what GUESTS can do on the website: pay the deposit online at all
    /// (BookingDepositRequired), and choose Whish beside the card (BookingWhishEnabled). Null = leave as it is.
    /// Turning one on needs a gateway that is ready - and, on the live system, in LIVE mode.
    /// </summary>
    Task<GatewayActionResult> SetWebsiteAsync(bool? deposits, bool? whish, int userId);
    Task<GatewayActionResult> CheckConnectionAsync(string gateway, string mode, int userId, CancellationToken cancellationToken = default);

    Task<IReadOnlyList<GatewayTestRow>> ListTestsAsync();
    Task<GatewayTestDetail?> GetTestAsync(string testRef);
    /// <param name="webOrigin">The request's Origin header.</param>
    /// <param name="requestHost">The host the request was sent to: the tester is only ever sent back there.</param>
    Task<GatewayActionResult> OpenTestAsync(string gateway, string mode, decimal amount, string currency, string? webOrigin, int userId,
        CancellationToken cancellationToken = default, string? requestHost = null);
    Task<GatewayActionResult> CheckTestAsync(string testRef, int? userId, string source, CancellationToken cancellationToken = default);
    Task<GatewayActionResult> RefundTestAsync(string testRef, int userId, CancellationToken cancellationToken = default);
    Task<GatewayActionResult> LookupAsync(string gateway, string mode, string reference, string currency, CancellationToken cancellationToken = default);

    /// <summary>Whish's server reached our callback address for a test: noted (it proves the address works). False = not ours.</summary>
    Task<bool> TestCallbackAsync(string testRef, string? token);

    /// <summary>The tester's browser came back from the gateway's page: the test is checked. Returns where to send the browser, or null.</summary>
    Task<string?> TestReturnAsync(string testRef, CancellationToken cancellationToken = default);
}

public sealed partial class GatewayAdminService : IGatewayAdminService
{
    /// <summary>A test is a small payment: the page cannot be used to move a real amount by a slip of the finger.</summary>
    public const decimal MaxTestAmountUsd = 20m;
    public const decimal MaxTestAmountLbp = 2_000_000m;

    public const int DefaultCardApiVersion = 73;
    public const string WebTestPagePath = "/bookings/gateway-test";

    private readonly IPaymentGateways _gateways;
    private readonly IPaymentGatewayRepository _repository;
    private readonly GatewayKeyProtector _protector;
    private readonly IPaymentEventLog _events;
    private readonly IOnlineDepositRepository _deposits;
    private readonly IBookingService _bookings;
    private readonly GatewayServerFacts _server;
    private readonly TimeProvider _clock;
    private readonly ILogger<GatewayAdminService> _log;
    private readonly Core.ISettingService? _settings;

    /// <summary>The setting that makes a website booking ask for its deposit online.</summary>
    public const string DepositsSetting = "BookingDepositRequired";

    public GatewayAdminService(IPaymentGateways gateways, IPaymentGatewayRepository repository, GatewayKeyProtector protector,
        IPaymentEventLog events, IOnlineDepositRepository deposits, IBookingService bookings, GatewayServerFacts server,
        ILogger<GatewayAdminService> log, TimeProvider? clock = null, Core.ISettingService? settings = null)
    {
        _settings = settings;
        _gateways = gateways;
        _repository = repository;
        _protector = protector;
        _events = events;
        _deposits = deposits;
        _bookings = bookings;
        _server = server;
        _log = log;
        _clock = clock ?? TimeProvider.System;
    }

    /* ---- the overview ----------------------------------------------------------------------- */

    public async Task<GatewayOverview> GetAsync()
    {
        var card = await CardViewAsync();
        var whish = await WhishViewAsync();
        var history = await _repository.GetHistoryAsync(15);
        return new GatewayOverview(card, whish, await _deposits.IsWhishEnabledAsync(), await _bookings.IsDepositRequiredAsync(),
            _server.SiteUrl, _server.ApiPublicUrl, history, _server.Production);
    }

    private async Task<GatewayView> CardViewAsync()
    {
        var status = await _gateways.StatusAsync(GatewayNames.Card);
        var modes = new List<GatewayModeView>(2);
        foreach (var mode in status.Modes)
        {
            var options = await _gateways.CardAsync(mode.Mode);
            var shown = new Dictionary<string, string?>();
            if (options.IsConfigured || mode.Fields is not null)
            {
                shown[GatewayKeyFields.BaseUrl] = options.IsConfigured ? options.BaseUrl : mode.Fields?.GetValueOrDefault(GatewayKeyFields.BaseUrl);
                shown[GatewayKeyFields.MerchantId] = options.IsConfigured ? options.MerchantId : mode.Fields?.GetValueOrDefault(GatewayKeyFields.MerchantId);
                shown[GatewayKeyFields.ApiVersion] = options.IsConfigured ? GatewayKeyMask.Version(options.ApiVersion) : mode.Fields?.GetValueOrDefault(GatewayKeyFields.ApiVersion);
                shown[GatewayKeyFields.ApiPassword] = GatewayKeyMask.Hint(options.IsConfigured ? options.ApiPassword : mode.Fields?.GetValueOrDefault(GatewayKeyFields.ApiPassword));
            }
            modes.Add(new GatewayModeView(mode.Mode, mode.Source, mode.Source != GatewayKeySources.None, mode.Unreadable, options.IsConfigured,
                options.IsConfigured ? null : options.Problem, shown, mode.SavedAtUtc, mode.SavedBy));
        }

        var active = modes.First(m => m.Mode == status.ActiveMode);
        return new GatewayView(GatewayNames.Card, status.ActiveMode, status.ChosenMode, status.ServerMode, active.Ready, active.Problem,
            status.ModeChangedAtUtc, status.ModeChangedBy, modes);
    }

    private async Task<GatewayView> WhishViewAsync()
    {
        var status = await _gateways.StatusAsync(GatewayNames.Whish);
        var modes = new List<GatewayModeView>(2);
        foreach (var mode in status.Modes)
        {
            var options = await _gateways.WhishAsync(mode.Mode);
            var shown = new Dictionary<string, string?>();
            if (options.IsConfigured || mode.Fields is not null)
            {
                shown[GatewayKeyFields.WebsiteUrl] = options.IsConfigured ? options.WebsiteUrl : mode.Fields?.GetValueOrDefault(GatewayKeyFields.WebsiteUrl);
                shown[GatewayKeyFields.Channel] = GatewayKeyMask.Hint(options.IsConfigured ? options.Channel : mode.Fields?.GetValueOrDefault(GatewayKeyFields.Channel));
                shown[GatewayKeyFields.Secret] = GatewayKeyMask.Hint(options.IsConfigured ? options.Secret : mode.Fields?.GetValueOrDefault(GatewayKeyFields.Secret));
            }
            modes.Add(new GatewayModeView(mode.Mode, mode.Source, mode.Source != GatewayKeySources.None, mode.Unreadable, options.IsConfigured,
                options.IsConfigured ? null : options.Problem, shown, mode.SavedAtUtc, mode.SavedBy));
        }

        var active = modes.First(m => m.Mode == status.ActiveMode);
        return new GatewayView(GatewayNames.Whish, status.ActiveMode, status.ChosenMode, status.ServerMode, active.Ready, active.Problem,
            status.ModeChangedAtUtc, status.ModeChangedBy, modes);
    }

    /* ---- the keys --------------------------------------------------------------------------- */

    public async Task<GatewayActionResult> SaveKeysAsync(string gateway, string mode, GatewayKeysInput input, int userId)
    {
        var status = await _gateways.StatusAsync(gateway);
        var saved = status.Modes.FirstOrDefault(m => m.Mode == mode)?.Fields;

        // Blank = keep what is saved: a secret is never sent back to the browser to be typed again.
        string Field(string name, string? typed)
        {
            var value = (typed ?? string.Empty).Trim();
            return value.Length > 0 ? value : saved?.GetValueOrDefault(name) ?? string.Empty;
        }

        Dictionary<string, string> fields;
        if (gateway == GatewayNames.Whish)
        {
            fields = new()
            {
                [GatewayKeyFields.Channel] = Field(GatewayKeyFields.Channel, input.Channel),
                [GatewayKeyFields.Secret] = Field(GatewayKeyFields.Secret, input.Secret),
                [GatewayKeyFields.WebsiteUrl] = Field(GatewayKeyFields.WebsiteUrl, input.WebsiteUrl),
            };
            if (fields.Values.Any(v => v.Length == 0))
                return new GatewayActionResult(false, "Enter all three: the channel, the secret and the website URL, exactly as Whish issued them.");
        }
        else
        {
            var version = Field(GatewayKeyFields.ApiVersion, input.ApiVersion);
            fields = new()
            {
                [GatewayKeyFields.BaseUrl] = Field(GatewayKeyFields.BaseUrl, input.BaseUrl).TrimEnd('/'),
                [GatewayKeyFields.MerchantId] = Field(GatewayKeyFields.MerchantId, input.MerchantId),
                [GatewayKeyFields.ApiPassword] = Field(GatewayKeyFields.ApiPassword, input.ApiPassword),
                [GatewayKeyFields.ApiVersion] = version.Length > 0 ? version : GatewayKeyMask.Version(DefaultCardApiVersion),
            };
            if (fields.Values.Any(v => v.Length == 0))
                return new GatewayActionResult(false, "Enter the gateway address, the merchant ID and the API password the bank issued.");

            if (!Uri.TryCreate(fields[GatewayKeyFields.BaseUrl], UriKind.Absolute, out var address) || address.Scheme != Uri.UriSchemeHttps)
                return new GatewayActionResult(false, "The gateway address must start with https://, for example https://test-bobsal.gateway.mastercard.com.");

            // THE PASSWORD IS SENT TO THIS ADDRESS WITH EVERY CALL, so the address may only be the bank's gateway:
            // a Mastercard gateway host, the bare host, nothing after it. (Anything else would be a way to have a
            // saved password delivered somewhere.)
            if (!IsCardGatewayHost(address))
                return new GatewayActionResult(false, "The gateway address must be the bank's Mastercard gateway, for example https://test-bobsal.gateway.mastercard.com (the host only, nothing after it).");
            fields[GatewayKeyFields.BaseUrl] = address.GetLeftPart(UriPartial.Authority);

            // And a saved password never follows a NEW address or merchant by itself: it is typed again.
            var typedPassword = (input.ApiPassword ?? string.Empty).Trim().Length > 0;
            var moved = saved is not null
                        && (!string.Equals(saved.GetValueOrDefault(GatewayKeyFields.BaseUrl), fields[GatewayKeyFields.BaseUrl], StringComparison.OrdinalIgnoreCase)
                            || !string.Equals(saved.GetValueOrDefault(GatewayKeyFields.MerchantId), fields[GatewayKeyFields.MerchantId], StringComparison.OrdinalIgnoreCase));
            if (moved && !typedPassword)
                return new GatewayActionResult(false, "The gateway address or the merchant ID changed: type the API password again with them.");

            if (!int.TryParse(fields[GatewayKeyFields.ApiVersion], NumberStyles.None, CultureInfo.InvariantCulture, out var number) || number <= 0)
                return new GatewayActionResult(false, "The API version must be a whole number such as 73.");

            // The bank names its test profiles TEST...: the two boxes cannot be mixed up.
            var isTestProfile = fields[GatewayKeyFields.MerchantId].StartsWith(MpgsOptions.TestProfilePrefix, StringComparison.OrdinalIgnoreCase);
            if (mode == GatewayModes.Test && !isTestProfile)
                return new GatewayActionResult(false, "That merchant ID is a LIVE profile. Test keys have a merchant ID that starts with TEST; save live keys under Live.");
            if (mode == GatewayModes.Live && isTestProfile)
                return new GatewayActionResult(false, "That merchant ID is a TEST profile (it starts with TEST). Save it under Test.");
        }

        if (fields.Values.Any(v => v.Length > 300))
            return new GatewayActionResult(false, "One of the values is too long to be a key. Paste it again.");

        await _repository.SaveKeysAsync(gateway, mode, _protector.Protect(gateway, mode, fields), userId);
        _gateways.Refresh();
        _log.LogInformation("Gateway {Gateway}: the {Mode} keys were saved by user {UserId}.", gateway, mode, userId);

        return new GatewayActionResult(true, $"The {mode} keys are saved. Press Check connection to make sure the gateway accepts them.");
    }

    /// <summary>The bank's gateway: a host of mastercard.com whose name ends in "gateway" (bobsal.gateway, test-bobsal.gateway, ap-gateway, ...), default port, no path.</summary>
    public static bool IsCardGatewayHost(Uri address)
    {
        var host = address.Host.ToLowerInvariant();
        const string suffix = "gateway.mastercard.com";
        var named = host == suffix || host.EndsWith("." + suffix, StringComparison.Ordinal) || host.EndsWith("-" + suffix, StringComparison.Ordinal);
        return named && address.IsDefaultPort && address.AbsolutePath is "/" or "" && string.IsNullOrEmpty(address.Query)
               && string.IsNullOrEmpty(address.Fragment) && string.IsNullOrEmpty(address.UserInfo);
    }

    public async Task<GatewayActionResult> DeleteKeysAsync(string gateway, string mode, int userId)
    {
        // Payments opened with these keys and not settled yet can only be asked about - and released or recorded -
        // with these keys: they stay until those payments are settled.
        var inFlight = (await _repository.ListPaymentsAsync(DateTime.UtcNow.AddYears(-5), DateTime.UtcNow.AddDays(1), gateway, null, null, 30))
            .Count(p => p.Mode == mode && p.PayState is "Open" or "Unconfirmed");
        if (inFlight > 0)
            return new GatewayActionResult(false, $"{inFlight} payment(s) opened with these keys are still waiting to be settled. Remove the keys once they are settled (Bookings > Payments).");

        await _repository.DeleteKeysAsync(gateway, mode, userId);
        _gateways.Refresh();
        _log.LogInformation("Gateway {Gateway}: the {Mode} keys were removed by user {UserId}.", gateway, mode, userId);
        return new GatewayActionResult(true, $"The {mode} keys were removed from HRMS.");
    }

    public async Task<GatewayActionResult> SetModeAsync(string gateway, string? mode, int userId)
    {
        if (mode is not null)
        {
            var ready = gateway == GatewayNames.Card ? (await _gateways.CardAsync(mode)).IsConfigured : (await _gateways.WhishAsync(mode)).IsConfigured;
            if (!ready)
                return new GatewayActionResult(false, $"Save the {mode} keys first: a gateway cannot work in a mode it has no keys for.");
        }

        // ON THE LIVE SYSTEM A GATEWAY GUESTS CAN PAY WITH IS NEVER PUT INTO TEST MODE: a test payment costs nothing
        // (Whish's test page has a "Simulate Success" button, the bank's takes test cards), and it would confirm a
        // real booking. Test mode is for the test side and for the Gateway test page, which asks for it by name.
        if (mode == GatewayModes.Test && _server.Production && await OfferedToGuestsAsync(gateway))
            return new GatewayActionResult(false, gateway == GatewayNames.Whish
                ? "Guests can pay with Whish on the website right now. Turn off \"Offer Whish on the website\" first: in test mode anybody could confirm a booking without paying."
                : "Guests pay their deposit online on the website right now. Turn off \"Take the deposit online\" first: in test mode anybody could confirm a booking with a test card.");

        await _repository.SetModeAsync(gateway, mode, userId);
        _gateways.Refresh();
        _log.LogInformation("Gateway {Gateway}: mode set to {Mode} by user {UserId}.", gateway, mode ?? "the server file", userId);

        return new GatewayActionResult(true, mode switch
        {
            GatewayModes.Live => "This gateway now works in LIVE mode: real payments.",
            GatewayModes.Test => "This gateway now works in TEST mode: no real money moves.",
            _ => "This gateway now follows the server file again.",
        });
    }

    /// <summary>Whether guests on the website can pay through this gateway right now.</summary>
    private async Task<bool> OfferedToGuestsAsync(string gateway)
        => await _bookings.IsDepositRequiredAsync() && (gateway == GatewayNames.Card || await _deposits.IsWhishEnabledAsync());

    public async Task<GatewayActionResult> SetWebsiteAsync(bool? deposits, bool? whish, int userId)
    {
        if (_settings is null)
            return new GatewayActionResult(false, "The settings are not available here.");
        if (deposits is null && whish is null)
            return new GatewayActionResult(false, "Say which switch to change.");

        var card = await _gateways.CardAsync();
        var whishNow = await _gateways.WhishAsync();
        var whishOn = whish ?? await _deposits.IsWhishEnabledAsync();
        var depositsOn = deposits ?? await _bookings.IsDepositRequiredAsync();

        // What "usable for guests" means: its keys are there - and on the live system it is in LIVE mode.
        bool Usable(bool configured, string mode) => configured && !(_server.Production && mode == GatewayModes.Test);

        if (whish == true)
        {
            if (!whishNow.IsConfigured)
                return new GatewayActionResult(false, "Save the Whish keys first, and press Check connection.");
            if (!Usable(true, whishNow.Mode))
                return new GatewayActionResult(false, "Whish is in TEST mode. On the live website anybody could confirm a booking without paying (Whish's test page has a Simulate Success button). Switch Whish to Live first.");
        }

        // With deposits on, every method the website offers must be usable: the card always is offered when its
        // keys are there, Whish when its switch is on.
        if (depositsOn && (deposits == true || whish == true))
        {
            var cardUsable = Usable(card.IsConfigured, card.Mode);
            var whishUsable = whishOn && Usable(whishNow.IsConfigured, whishNow.Mode);
            if (!card.IsConfigured && !whishUsable)
                return new GatewayActionResult(false, "No gateway is ready: save the Bank of Beirut keys (or the Whish keys, with Whish offered) first.");
            if (card.IsConfigured && !cardUsable)
                return new GatewayActionResult(false, "Bank of Beirut is in TEST mode. On the live website a booking could be confirmed with a test card. Switch Bank of Beirut to Live first.");
        }

        if (deposits is { } wantDeposits) await WriteSwitchAsync(DepositsSetting, wantDeposits, userId);
        if (whish is { } wantWhish) await WriteSwitchAsync(WhishOptions.EnabledSetting, wantWhish, userId);
        _log.LogInformation("Website payments: deposits {Deposits}, Whish {Whish}, set by user {UserId}.",
            deposits?.ToString() ?? "unchanged", whish?.ToString() ?? "unchanged", userId);

        return new GatewayActionResult(true, (depositsOn, whishOn) switch
        {
            (false, true) => "Saved. Whish is switched on, but guests will only see it once the deposit is taken online (the switch above).",
            (false, false) => "Saved. Guests do not pay online: a website booking is a request that staff confirm.",
            (true, true) => "Saved. Guests pay the deposit online, by card or by Whish.",
            (true, false) => "Saved. Guests pay the deposit online, by card.",
        });
    }

    /// <summary>A switch is stored '1' / '0' (several procedures read exactly that), keeping the row's own type and description.</summary>
    private async Task WriteSwitchAsync(string key, bool on, int userId)
    {
        var current = await _settings!.GetAsync(key);
        await _settings.UpsertAsync(key, new Model.Core.SettingUpsertRequest
        {
            SettingValue = on ? "1" : "0",
            DataType = current?.DataType ?? "bool",
            Description = current?.Description,
        }, userId);
    }

    /* ---- the connection check: moves no money ------------------------------------------------ */

    public async Task<GatewayActionResult> CheckConnectionAsync(string gateway, string mode, int userId, CancellationToken cancellationToken = default)
    {
        var watch = Stopwatch.StartNew();
        GatewayActionResult result;

        if (gateway == GatewayNames.Whish)
        {
            var options = await _gateways.WhishAsync(mode);
            if (!options.IsConfigured)
                result = new GatewayActionResult(false, options.Problem ?? $"No {mode} keys are saved for Whish.");
            else
            {
                var balance = await _gateways.WhishClient(options).GetBalanceAsync("USD", cancellationToken);
                result = balance.Ok
                    ? new GatewayActionResult(true, "Whish answered and accepted the keys."
                        + (balance.Balance is { } amount ? string.Create(CultureInfo.InvariantCulture, $" Account balance: USD {amount:0.00}.") : string.Empty))
                    : new GatewayActionResult(false, WhishProblem(balance.Code, balance.Problem));
            }
        }
        else
        {
            var options = await _gateways.CardAsync(mode);
            if (!options.IsConfigured)
                result = new GatewayActionResult(false, options.Problem ?? $"No {mode} keys are saved for Bank of Beirut.");
            else
            {
                // An order that cannot exist: the bank's own "cannot find order" is it accepting the keys and answering.
                // A bare 404 is NOT that: it is what a wrong address or API version answers too.
                var probe = await _gateways.CardClient(options).RetrieveOrderAsync("HRMS-CHECK-" + GatewayTestRefs.New()[3..], cancellationToken);
                result = probe switch
                {
                    { Kind: MpgsLookupKind.Found } or { Kind: MpgsLookupKind.NotFound, Problem: MpgsOrderLookup.OrderNotFound }
                        => new GatewayActionResult(true, $"The bank answered and accepted the keys (merchant {options.MerchantId})."),
                    { Kind: MpgsLookupKind.NotFound }
                        => new GatewayActionResult(false, "The bank's address answered \"not found\" (HTTP 404). The gateway address or the API version is probably wrong; the keys were not checked."),
                    _ => new GatewayActionResult(false, CardProblem(probe.Problem)),
                };
            }
        }

        watch.Stop();
        result = result with { Milliseconds = (int)watch.ElapsedMilliseconds };
        await _events.WriteAsync(new PaymentEventEntry(gateway, PaymentEvents.ConnectionCheck, PaymentEvents.FromStaff, Mode: mode,
            Outcome: result.Ok ? "Ok" : "Failed", Detail: result.Message, UserId: userId));
        return result;
    }

    /// <summary>Whish's refusal, as something a person can act on. Its code is kept in brackets for whoever rings Whish.</summary>
    public static string WhishProblem(string? code, string? problem)
    {
        var text = (problem ?? string.Empty).ToLowerInvariant();
        if (code is not null)
        {
            var lower = code.ToLowerInvariant();
            // Whish's own table: auth.error = "the call came from a server IP that Whish has not registered" (refunds).
            if (lower == "auth.error")
                return $"Whish refused this server's address: it is not registered with Whish yet (refunds are accepted only from registered addresses). Ask Whish to register the server's public IP address, then try again. [{code}]";
            if (lower.Contains("auth") || lower.Contains("secret") || lower.Contains("channel") || lower.Contains("website") || lower.Contains("unauthor"))
                return $"Whish refused the keys. Check the channel, the secret and the website URL: they must be exactly what Whish issued, for this mode. [{code}]";
            if (lower.Contains("ip"))
                return $"Whish refused this server's address. Ask Whish to register the server's IP address. [{code}]";
            return $"Whish refused the request. [{code}]";
        }
        if (text.Contains("timed out")) return "Whish did not answer in time. Try again in a minute.";
        if (text.Contains("network")) return "Whish could not be reached from this server (network).";
        if (text.Contains("http 401") || text.Contains("http 403"))
            return "Whish's server refused the request before reading it (HTTP 401/403). Check the three keys, and that the return address is a public one.";
        if (text.Contains("pending")) return "Whish answered that it cannot tell yet (pending). Try again in a minute.";
        return "Whish did not give a usable answer" + (problem is null ? "." : $" ({problem}).");
    }

    public static string CardProblem(string? problem)
    {
        var text = (problem ?? string.Empty).ToLowerInvariant();
        if (text.Contains("401") || text.Contains("403"))
            return "The bank refused the keys. Check the merchant ID and the API password (and that they belong to this mode).";
        if (text.Contains("timeout")) return "The bank's gateway did not answer in time. Try again in a minute.";
        if (text.Contains("network")) return "The bank's gateway could not be reached from this server. Check the gateway address.";
        if (text.Contains("404")) return "The gateway address or the API version is wrong (the bank answered 404).";
        return "The bank's gateway did not give a usable answer" + (problem is null ? "." : $" ({problem}).");
    }

    /* ---- test payments ---------------------------------------------------------------------- */

    public Task<IReadOnlyList<GatewayTestRow>> ListTestsAsync() => _repository.ListTestsAsync(30);

    public Task<GatewayTestDetail?> GetTestAsync(string testRef) => _repository.GetTestAsync(testRef);

    public async Task<GatewayActionResult> OpenTestAsync(string gateway, string mode, decimal amount, string currency, string? webOrigin, int userId,
        CancellationToken cancellationToken = default, string? requestHost = null)
    {
        currency = (currency ?? string.Empty).Trim().ToUpperInvariant();
        if (currency is not ("USD" or "LBP"))
            return new GatewayActionResult(false, "The currency must be USD or LBP.");

        var max = currency == "LBP" ? MaxTestAmountLbp : MaxTestAmountUsd;
        if (amount <= 0 || amount > max)
            return new GatewayActionResult(false, string.Create(CultureInfo.InvariantCulture, $"A test payment is between 0 and {currency} {max:0.##}."));

        var testRef = GatewayTestRefs.New();
        var returnUrl = ReturnUrlFor(webOrigin, testRef, requestHost);
        var description = $"MOKA&CO HRMS gateway test {testRef}";

        if (gateway == GatewayNames.Whish)
        {
            var options = await _gateways.WhishAsync(mode);
            if (!options.IsConfigured)
                return new GatewayActionResult(false, options.Problem ?? $"No {mode} keys are saved for Whish.");

            var test = await _repository.AddTestAsync(testRef, gateway, mode, amount, currency, returnUrl, userId);
            try
            {
                var link = await _gateways.WhishClient(options).CreateCollectAsync(testRef, amount, currency, description,
                    options.CallbackUrl(testRef), options.CallbackUrl(testRef), options.ReturnUrl(testRef), options.ReturnUrl(testRef), cancellationToken);
                test = await _repository.UpdateTestAsync(testRef, new GatewayTestChange(PayUrl: link, Detail: "Whish created the payment link. Open it and pay."));
                await _events.WriteAsync(new PaymentEventEntry(gateway, PaymentEvents.Opened, PaymentEvents.FromStaff, TestRef: testRef, Mode: mode,
                    GatewayOrderId: testRef, Outcome: "Opened", Detail: "Test payment: Whish payment link created", Amount: amount, CurrencyCode: currency, UserId: userId));
                return new GatewayActionResult(true, "Whish created the payment. Open the payment page and pay it.", Test: test);
            }
            catch (WhishException ex)
            {
                var message = "Whish did not create the payment. " + ex.Message;
                test = await _repository.UpdateTestAsync(testRef, new GatewayTestChange(Status: "Error", Detail: message));
                await _events.WriteAsync(new PaymentEventEntry(gateway, PaymentEvents.OpenFailed, PaymentEvents.FromStaff, TestRef: testRef, Mode: mode,
                    GatewayOrderId: testRef, Outcome: "GatewayError", Detail: ex.Message, Amount: amount, CurrencyCode: currency, UserId: userId));
                return new GatewayActionResult(false, message, Test: test);
            }
        }
        else
        {
            var options = await _gateways.CardAsync(mode);
            if (!options.IsConfigured)
                return new GatewayActionResult(false, options.Problem ?? $"No {mode} keys are saved for Bank of Beirut.");

            var test = await _repository.AddTestAsync(testRef, gateway, mode, amount, currency, returnUrl, userId);
            try
            {
                // Every way out of the bank's page - paid, cancelled, timed out - comes back through our verifier,
                // which asks the bank and sends the tester back to HRMS.
                var back = options.VerifyUrl(testRef);
                var sessionId = await _gateways.CardClient(options).InitiateCheckoutAsync(testRef, amount, currency, description, back, back, back, cancellationToken);
                var payUrl = $"{options.SiteUrl}/pay/#session={Uri.EscapeDataString(sessionId)}";
                test = await _repository.UpdateTestAsync(testRef, new GatewayTestChange(PayUrl: payUrl, Detail: "The bank opened a checkout session. Open the payment page and pay."));
                await _events.WriteAsync(new PaymentEventEntry(gateway, PaymentEvents.Opened, PaymentEvents.FromStaff, TestRef: testRef, Mode: mode,
                    GatewayOrderId: testRef, Outcome: "Opened", Detail: "Test payment: card checkout session opened", Amount: amount, CurrencyCode: currency, UserId: userId));
                return new GatewayActionResult(true, "The bank opened a checkout session. Open the payment page and pay it.", Test: test);
            }
            catch (MpgsException ex)
            {
                test = await _repository.UpdateTestAsync(testRef, new GatewayTestChange(Status: "Error", Detail: ex.Message));
                await _events.WriteAsync(new PaymentEventEntry(gateway, PaymentEvents.OpenFailed, PaymentEvents.FromStaff, TestRef: testRef, Mode: mode,
                    GatewayOrderId: testRef, Outcome: "GatewayError", Detail: ex.Message, Amount: amount, CurrencyCode: currency, UserId: userId));
                return new GatewayActionResult(false, ex.Message + " Press Check connection to see whether the bank accepts the keys.", Test: test);
            }
        }
    }

    /// <summary>How long a test's return address leads back to HRMS. Afterwards the public address answers with a line of text.</summary>
    public static readonly TimeSpan ReturnWindow = TimeSpan.FromHours(24);

    /// <summary>
    /// The HRMS page the tester's browser is sent back to: the origin the request came from, and only when that is
    /// the very host the request was sent to (HRMS and its API share one address; a development server on this
    /// machine is the other case). Never an address somebody merely names, and never one carrying a user name.
    /// </summary>
    public static string? ReturnUrlFor(string? webOrigin, string testRef, string? requestHost = null)
    {
        if (!Uri.TryCreate((webOrigin ?? string.Empty).Trim(), UriKind.Absolute, out var origin)) return null;
        if (origin.Scheme != Uri.UriSchemeHttps && origin.Scheme != Uri.UriSchemeHttp) return null;
        if (!string.IsNullOrEmpty(origin.UserInfo)) return null;

        var sameHost = requestHost is not null
                       && string.Equals(origin.Host, requestHost.Split(':')[0].Trim(), StringComparison.OrdinalIgnoreCase);
        if (!sameHost && !origin.IsLoopback) return null;

        return $"{origin.Scheme}://{origin.Authority}{WebTestPagePath}?test={Uri.EscapeDataString(testRef)}";
    }

    public async Task<GatewayActionResult> CheckTestAsync(string testRef, int? userId, string source, CancellationToken cancellationToken = default)
    {
        var found = await _repository.GetTestAsync(testRef);
        if (found is null)
            return new GatewayActionResult(false, "No such test.");

        var test = found.Test;
        var facts = new List<GatewayFact>();
        string status, said, message;
        string? phone = null, transaction = null;

        if (test.Gateway == GatewayNames.Whish)
        {
            var options = await _gateways.WhishAsync(test.Mode);
            if (!options.IsConfigured)
                return new GatewayActionResult(false, options.Problem ?? "Whish is not configured for this mode.", Test: test);

            var lookup = await _gateways.WhishClient(options).GetStatusAsync(testRef, test.CurrencyCode, cancellationToken);
            var linkOver = _clock.GetUtcNow().UtcDateTime >= DateTime.SpecifyKind(test.CreatedAtUtc, DateTimeKind.Utc) + WhishOptions.LinkLifetime + WhishOptions.LinkGrace;
            said = OnlineDepositService.Said(lookup);
            phone = lookup.PayerPhoneNumber;
            facts.Add(new GatewayFact("Whish says", said));

            (status, message) = lookup switch
            {
                { Kind: WhishLookupKind.Found, CollectStatus: "success" } => ("Paid", "Paid. Whish took the payment."),
                { Kind: WhishLookupKind.Found, CollectStatus: "refunded" } => ("Refunded", "Whish says this payment was refunded."),
                { Kind: WhishLookupKind.Found, CollectStatus: "failed" } => ("NotPaid", "Not paid: the Whish link expired or the payment failed."),
                { Kind: WhishLookupKind.Found, CollectStatus: "pending" } when linkOver => ("NotPaid", "Not paid: the Whish link is over (a link lives five minutes)."),
                { Kind: WhishLookupKind.Found, CollectStatus: "pending" } => ("Opened", "Not paid yet. The Whish link is still open."),
                { Kind: WhishLookupKind.NotFound } => ("NotPaid", "Whish has no payment under this reference."),
                { Kind: WhishLookupKind.Found } => ("Unknown", $"Whish answered \"{lookup.CollectStatus}\", which says neither paid nor failed."),
                _ => ("Unknown", WhishProblem(null, lookup.Problem)),
            };
        }
        else
        {
            var options = await _gateways.CardAsync(test.Mode);
            if (!options.IsConfigured)
                return new GatewayActionResult(false, options.Problem ?? "Bank of Beirut is not configured for this mode.", Test: test);

            var order = await _gateways.CardClient(options).RetrieveOrderAsync(testRef, cancellationToken);
            var decision = PaymentDecisionTable.Decide(order, test.Amount, test.CurrencyCode);
            var young = _clock.GetUtcNow().UtcDateTime < DateTime.SpecifyKind(test.CreatedAtUtc, DateTimeKind.Utc) + TimeSpan.FromMinutes(20);
            said = OnlineDepositService.Said(order);
            transaction = order.TransactionId;
            facts.AddRange(CardFacts(order));

            (status, message) = decision switch
            {
                { Outcome: PaymentOutcome.Paid } => ("Paid", "Paid. The bank captured the full amount."),
                { Outcome: PaymentOutcome.Failed } => ("NotPaid", $"Not paid: the bank says {decision.Reason}."),
                { NothingAttempted: true } when young => ("Opened", "Nothing was attempted yet on the bank's page."),
                { NothingAttempted: true } => ("NotPaid", "Not paid: nothing was ever attempted on the bank's page."),
                _ when order.Kind == MpgsLookupKind.Error => ("Unknown", CardProblem(order.Problem)),
                _ => ("Unknown", $"The bank cannot say yet ({decision.Reason})."),
            };
        }

        var updated = await _repository.UpdateTestAsync(testRef, new GatewayTestChange(Status: status, GatewayStatus: said, Detail: message,
            PayerPhone: phone, TransactionId: transaction, Checked: true));
        await _events.WriteAsync(new PaymentEventEntry(test.Gateway, PaymentEvents.Checked, source, TestRef: testRef, Mode: test.Mode,
            GatewayOrderId: testRef, Outcome: status, GatewayStatus: said, Detail: message, UserId: userId));

        return new GatewayActionResult(status is "Paid" or "Opened" or "Refunded" or "NotPaid", message, Test: updated ?? test, Facts: facts);
    }

    public async Task<GatewayActionResult> RefundTestAsync(string testRef, int userId, CancellationToken cancellationToken = default)
    {
        var found = await _repository.GetTestAsync(testRef);
        if (found is null)
            return new GatewayActionResult(false, "No such test.");

        var test = found.Test;
        if (test.Gateway != GatewayNames.Whish)
            return new GatewayActionResult(false, "A card test is refunded in the bank's merchant portal (order " + testRef + ").", Test: test);
        if (test.Status == "Refunded")
            return new GatewayActionResult(true, "This test was already refunded.", Test: test);
        if (test.Status != "Paid")
            return new GatewayActionResult(false, "Only a paid test can be refunded. Press Check status first.", Test: test);

        var options = await _gateways.WhishAsync(test.Mode);
        if (!options.IsConfigured)
            return new GatewayActionResult(false, options.Problem ?? "Whish is not configured for this mode.", Test: test);

        var refund = await _gateways.WhishClient(options).RefundAsync(testRef, test.CurrencyCode, "HRMS gateway test", cancellationToken);
        if (!refund.Refunded)
        {
            var problem = WhishProblem(refund.Code, refund.Problem);
            await _events.WriteAsync(new PaymentEventEntry(test.Gateway, PaymentEvents.RefundFailed, PaymentEvents.FromStaff, TestRef: testRef, Mode: test.Mode,
                GatewayOrderId: testRef, Outcome: "Failed", GatewayStatus: refund.Code, Detail: problem, Amount: test.Amount, CurrencyCode: test.CurrencyCode, UserId: userId));
            return new GatewayActionResult(false, "Whish did not refund it. " + problem, Test: test);
        }

        var updated = await _repository.UpdateTestAsync(testRef, new GatewayTestChange(Detail: "Refunded on Whish.", Refunded: true));
        await _events.WriteAsync(new PaymentEventEntry(test.Gateway, PaymentEvents.Refunded, PaymentEvents.FromStaff, TestRef: testRef, Mode: test.Mode,
            GatewayOrderId: testRef, Outcome: refund.AlreadyDone ? "AlreadyRefunded" : "Refunded", Detail: "Test payment refunded on Whish",
            Amount: test.Amount, CurrencyCode: test.CurrencyCode, UserId: userId));
        return new GatewayActionResult(true, "Refunded. Whish gave the money back.", Test: updated ?? test);
    }

    /* ---- look any payment up, exactly as the gateway holds it --------------------------------- */

    public async Task<GatewayActionResult> LookupAsync(string gateway, string mode, string reference, string currency, CancellationToken cancellationToken = default)
    {
        reference = (reference ?? string.Empty).Trim().ToUpperInvariant();
        if (reference.Length is 0 or > 40 || !LookupShape().IsMatch(reference))
            return new GatewayActionResult(false, "Enter a booking reference (MC-XXXXXXXX), a Whish attempt (MC-XXXXXXXX-A1) or a test reference (GT-XXXXXXXX).");

        var watch = Stopwatch.StartNew();
        if (gateway == GatewayNames.Whish)
        {
            var options = await _gateways.WhishAsync(mode);
            if (!options.IsConfigured)
                return new GatewayActionResult(false, options.Problem ?? $"No {mode} keys are saved for Whish.");

            currency = (currency ?? string.Empty).Trim().ToUpperInvariant() is "LBP" ? "LBP" : "USD";
            // A booking's Whish payments are numbered: the bare reference is asked about as its first attempt.
            var externalId = BookingRefShape().IsMatch(reference) ? WhishOptions.AttemptId(reference, 1) : reference;
            var lookup = await _gateways.WhishClient(options).GetStatusAsync(externalId, currency, cancellationToken);
            var facts = new List<GatewayFact> { new("Asked about", externalId), new("Whish says", OnlineDepositService.Said(lookup)) };
            if (lookup.PayerPhoneNumber is { } phone) facts.Add(new GatewayFact("Paid from", phone));
            var decision = WhishDecisionTable.Decide(lookup, linkOver: true);
            facts.Add(new GatewayFact("HRMS reads this as", Reading(decision)));
            return new GatewayActionResult(lookup.Kind != WhishLookupKind.Error,
                lookup.Kind == WhishLookupKind.Error ? WhishProblem(null, lookup.Problem) : "Whish answered.", (int)watch.ElapsedMilliseconds, Facts: facts);
        }
        else
        {
            var options = await _gateways.CardAsync(mode);
            if (!options.IsConfigured)
                return new GatewayActionResult(false, options.Problem ?? $"No {mode} keys are saved for Bank of Beirut.");

            var order = await _gateways.CardClient(options).RetrieveOrderAsync(reference, cancellationToken);
            var facts = new List<GatewayFact> { new("Asked about", reference) };
            facts.AddRange(CardFacts(order));
            if (order.Kind == MpgsLookupKind.Found && order.Amount is { } amount)
                facts.Add(new GatewayFact("HRMS reads this as", Reading(PaymentDecisionTable.Decide(order, amount, order.Currency ?? string.Empty))));
            return new GatewayActionResult(order.Kind != MpgsLookupKind.Error,
                order.Kind == MpgsLookupKind.Error ? CardProblem(order.Problem) : "The bank answered.", (int)watch.ElapsedMilliseconds, Facts: facts);
        }
    }

    private static string Reading(PaymentDecision decision) => decision.Outcome switch
    {
        PaymentOutcome.Paid => "Paid",
        PaymentOutcome.Failed => "Not paid (" + decision.Reason + ")",
        _ when decision.NothingAttempted => "Never paid (" + decision.Reason + ")",
        _ => "Cannot tell (" + decision.Reason + ")",
    };

    public static IReadOnlyList<GatewayFact> CardFacts(MpgsOrderLookup order)
    {
        var facts = new List<GatewayFact> { new("The bank says", OnlineDepositService.Said(order)) };
        if (order.Kind != MpgsLookupKind.Found) return facts;

        string Money(decimal? value) => value is { } amount ? string.Create(CultureInfo.InvariantCulture, $"{order.Currency} {amount:0.00}") : "-";
        facts.Add(new GatewayFact("Order amount", Money(order.Amount)));
        facts.Add(new GatewayFact("Captured", Money(order.TotalCapturedAmount)));
        if (order.TransactionCount is { } count) facts.Add(new GatewayFact("Transactions", count.ToString(CultureInfo.InvariantCulture)));
        if (order.TransactionId is { } id) facts.Add(new GatewayFact("Transaction", id));
        return facts;
    }

    [GeneratedRegex("^[A-Z0-9][A-Z0-9-]{2,39}$")]
    private static partial Regex LookupShape();

    [GeneratedRegex("^MC-[A-Z0-9]{8}$")]
    private static partial Regex BookingRefShape();

    /* ---- a test's trip back through the public addresses -------------------------------------- */

    public async Task<bool> TestCallbackAsync(string testRef, string? token)
    {
        var found = await _repository.GetTestAsync(testRef);
        if (found is null || found.Test.Gateway != GatewayNames.Whish) return false;

        var options = await _gateways.WhishAsync(found.Test.Mode);
        if (!options.IsCallbackToken(testRef, token)) return false;

        await _repository.UpdateTestAsync(testRef, new GatewayTestChange(Callback: true));
        await _events.WriteAsync(new PaymentEventEntry(found.Test.Gateway, PaymentEvents.Checked, PaymentEvents.FromCallback, TestRef: testRef,
            Mode: found.Test.Mode, GatewayOrderId: testRef, Outcome: "CallbackReceived", Detail: "Whish's server reached our callback address"));
        return true;
    }

    public async Task<string?> TestReturnAsync(string testRef, CancellationToken cancellationToken = default)
    {
        var found = await _repository.GetTestAsync(testRef);
        if (found is null) return null;

        await _repository.UpdateTestAsync(testRef, new GatewayTestChange(Returned: true));
        try
        {
            await CheckTestAsync(testRef, null, PaymentEvents.FromReturn, cancellationToken);
        }
        catch (Exception ex)
        {
            _log.LogWarning("Gateway test {Ref}: the check on return failed ({Kind}); the page checks again.", testRef, ex.GetType().Name);
        }

        // The address leads back to HRMS for a day: an old test's public address is not a standing redirect.
        var fresh = _clock.GetUtcNow().UtcDateTime - DateTime.SpecifyKind(found.Test.CreatedAtUtc, DateTimeKind.Utc) <= ReturnWindow;
        return fresh ? found.Test.ReturnUrl : null;
    }
}
