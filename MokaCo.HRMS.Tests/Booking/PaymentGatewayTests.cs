using System.Text;
using System.Text.Json;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Logging.Abstractions;
using Moq;
using MokaCo.HRMS.Api.Controllers;
using MokaCo.HRMS.Model.Booking;
using MokaCo.HRMS.Repository.Booking;
using MokaCo.HRMS.Repository.Common;
using MokaCo.HRMS.Services.Booking;
using MokaCo.HRMS.Services.Booking.Payments;

namespace MokaCo.HRMS.Tests.Booking;

/// <summary>
/// THE PAYMENT GATEWAYS IN HRMS (script 119). No network and no database: the gateways' settings live in a list, the
/// gateway clients are mocks. What is held:
///   - a key is encrypted before it is stored, can only be opened by the server that saved it, and is bound to its
///     gateway and mode;
///   - which keys a gateway works with: what is saved in HRMS for the mode in use, otherwise the server file's;
///   - what an admin may save, and that nothing the API answers with carries a key;
///   - a payment is settled with the keys of the mode it was OPENED in, and every step is logged;
///   - a gateway test is never a booking, and its trip back goes to the HRMS page it was opened from;
///   - when a Whish payment may be refunded from HRMS.
/// Every credential here is made up.
/// </summary>
public class PaymentGatewayTests
{
    private const string ServerSecret = "a-made-up-signing-key-for-these-tests-0123456789";
    private const string Ref = "MC-1A2B3C4D";
    private static readonly DateTime Now = new(2026, 11, 21, 12, 0, 0, DateTimeKind.Utc);

    private static readonly Dictionary<string, string> WhishTestKeys = new()
    {
        [GatewayKeyFields.Channel] = "10191111",
        [GatewayKeyFields.Secret] = "test-secret-aaaaaaaaaaaaaaaaaaaa1234",
        [GatewayKeyFields.WebsiteUrl] = "example.test",
    };

    private static readonly Dictionary<string, string> WhishLiveKeys = new()
    {
        [GatewayKeyFields.Channel] = "20292222",
        [GatewayKeyFields.Secret] = "live-secret-bbbbbbbbbbbbbbbbbbbb9876",
        [GatewayKeyFields.WebsiteUrl] = "example.test",
    };

    private static string? Origins(string key) => key switch
    {
        MpgsOptions.SiteUrlKey => "https://site.example.test",
        MpgsOptions.ApiPublicUrlKey => "https://api.example.test",
        _ => null,
    };

    /* ---- the cipher --------------------------------------------------------------------------- */

    [Fact]
    public void Keys_come_back_only_on_the_server_that_saved_them_and_only_for_their_own_gateway_and_mode()
    {
        var protector = new GatewayKeyProtector(ServerSecret);
        var blob = protector.Protect(GatewayNames.Whish, GatewayModes.Live, WhishLiveKeys);

        Assert.Equal(WhishLiveKeys, protector.Unprotect(GatewayNames.Whish, GatewayModes.Live, blob));

        // The database never holds a readable key.
        Assert.DoesNotContain(WhishLiveKeys[GatewayKeyFields.Secret], Encoding.UTF8.GetString(blob));
        Assert.DoesNotContain(WhishLiveKeys[GatewayKeyFields.Channel], Encoding.UTF8.GetString(blob));

        // Another server (a test server given a copy of production's database): unreadable, not an error.
        Assert.Null(new GatewayKeyProtector("another-servers-signing-key-0123456789abcdef").Unprotect(GatewayNames.Whish, GatewayModes.Live, blob));

        // The live keys cannot be moved into the test row, nor to the other gateway.
        Assert.Null(protector.Unprotect(GatewayNames.Whish, GatewayModes.Test, blob));
        Assert.Null(protector.Unprotect(GatewayNames.Card, GatewayModes.Live, blob));

        // Tampered with, cut short, or not ours at all.
        var tampered = (byte[])blob.Clone();
        tampered[^1] ^= 0x01;
        Assert.Null(protector.Unprotect(GatewayNames.Whish, GatewayModes.Live, tampered));
        Assert.Null(protector.Unprotect(GatewayNames.Whish, GatewayModes.Live, blob[..20]));
        Assert.Null(protector.Unprotect(GatewayNames.Whish, GatewayModes.Live, null));

        // Saving the same keys twice never gives the same bytes (a fresh nonce each time).
        Assert.NotEqual(blob, protector.Protect(GatewayNames.Whish, GatewayModes.Live, WhishLiveKeys));
    }

    [Fact]
    public void A_secret_is_shown_by_its_end_at_most()
    {
        Assert.Equal("••••1234", GatewayKeyMask.Hint("test-secret-aaaaaaaaaaaaaaaaaaaa1234"));
        Assert.Equal("••••", GatewayKeyMask.Hint("short"));
        Assert.Null(GatewayKeyMask.Hint("  "));
        Assert.Null(GatewayKeyMask.Hint(null));
    }

    /* ---- which keys a gateway works with -------------------------------------------------------- */

    /// <summary>The gateways' settings as script 119 stores them, in memory.</summary>
    private sealed class Store : IPaymentGatewayRepository
    {
        public Dictionary<string, string?> Modes { get; } = new();
        public Dictionary<(string Gateway, string Mode), byte[]> Keys { get; } = new();
        public List<PaymentEventEntry> Events { get; } = [];
        public Dictionary<string, GatewayTestRow> Tests { get; } = new();
        public bool ScriptMissing { get; set; }
        public int Reads { get; private set; }

        public Task<GatewayStore> GetGatewaysAsync()
        {
            Reads++;
            if (ScriptMissing) throw new MissingScriptException(Scripts.PaymentGateways119, "booking.usp_Gateway_Get", MissingScriptException.ProcedureNotFound);
            return Task.FromResult(new GatewayStore(
                Modes.Select(m => new GatewayModeRow { Gateway = m.Key, ActiveMode = m.Value, ModifiedAtUtc = Now, ModifiedBy = "owner" }).ToList(),
                Keys.Select(k => new GatewayKeysRow { Gateway = k.Key.Gateway, Mode = k.Key.Mode, KeysCipher = k.Value, ModifiedAtUtc = Now, ModifiedBy = "owner" }).ToList()));
        }

        public Task SaveKeysAsync(string gateway, string mode, byte[] keysCipher, int? userId) { Keys[(gateway, mode)] = keysCipher; return Task.CompletedTask; }
        public Task DeleteKeysAsync(string gateway, string mode, int? userId) { Keys.Remove((gateway, mode)); return Task.CompletedTask; }
        public Task SetModeAsync(string gateway, string? mode, int? userId) { Modes[gateway] = mode; return Task.CompletedTask; }
        public Task<IReadOnlyList<GatewayHistoryRow>> GetHistoryAsync(int top) => Task.FromResult<IReadOnlyList<GatewayHistoryRow>>([]);
        public Task AddEventAsync(PaymentEventEntry entry) { Events.Add(entry); return Task.CompletedTask; }

        public List<PaymentRow> Payments { get; } = [];

        public Task<IReadOnlyList<PaymentRow>> ListPaymentsAsync(DateTime fromUtc, DateTime toUtc, string? gateway, string? state, string? search, int giveUpMinutes)
            => Task.FromResult<IReadOnlyList<PaymentRow>>(Payments.Where(p => gateway is null || p.Gateway == gateway).ToList());
        public Task<PaymentDetail?> GetPaymentAsync(int bookingId, int giveUpMinutes) => Task.FromResult<PaymentDetail?>(null);

        public Task<GatewayTestRow?> AddTestAsync(string testRef, string gateway, string mode, decimal amount, string currency, string? returnUrl, int? userId)
        {
            Tests[testRef] = new GatewayTestRow
            {
                TestRef = testRef, Gateway = gateway, Mode = mode, Amount = amount, CurrencyCode = currency, ReturnUrl = returnUrl,
                Status = "Opened", CreatedAtUtc = Now, CreatedByUserId = userId,
            };
            return Task.FromResult<GatewayTestRow?>(Tests[testRef]);
        }

        public Task<GatewayTestRow?> UpdateTestAsync(string testRef, GatewayTestChange change)
        {
            if (!Tests.TryGetValue(testRef, out var test)) return Task.FromResult<GatewayTestRow?>(null);
            test.Status = change.Refunded ? "Refunded" : change.Status ?? test.Status;
            test.GatewayStatus = change.GatewayStatus ?? test.GatewayStatus;
            test.Detail = change.Detail ?? test.Detail;
            test.PayUrl = change.PayUrl ?? test.PayUrl;
            test.PayerPhone = change.PayerPhone ?? test.PayerPhone;
            if (change.Callback) test.CallbackAtUtc ??= Now;
            if (change.Returned) test.ReturnedAtUtc ??= Now;
            return Task.FromResult<GatewayTestRow?>(test);
        }

        public Task<GatewayTestDetail?> GetTestAsync(string testRef)
            => Task.FromResult(Tests.TryGetValue(testRef, out var test) ? new GatewayTestDetail(test, []) : null);

        public Task<IReadOnlyList<GatewayTestRow>> ListTestsAsync(int top) => Task.FromResult<IReadOnlyList<GatewayTestRow>>(Tests.Values.ToList());
    }

    private sealed class NoHttp : IHttpClientFactory
    {
        public HttpClient CreateClient(string name) => new();
    }

    private sealed class FixedClock(DateTime utc) : TimeProvider
    {
        public override DateTimeOffset GetUtcNow() => new(utc);
    }

    private static readonly GatewayKeyProtector Protector = new(ServerSecret);

    private static readonly MpgsOptions ServerCard = MpgsOptions.FromSettings(key => key switch
    {
        MpgsOptions.BaseKey => "https://test-gateway.example.test",
        MpgsOptions.MerchantIdKey => "TESTMERCHANT",
        MpgsOptions.ApiPasswordKey => "server-file-password",
        MpgsOptions.ApiVersionKey => "73",
        _ => Origins(key),
    });

    private static PaymentGateways Gateways(Store store, MpgsOptions? serverCard = null, WhishOptions? serverWhish = null)
        => new(store, new GatewayStoreCache(), Protector, serverCard ?? MpgsOptions.Missing("the server file holds no card keys"),
            serverWhish ?? WhishOptions.Unconfigured, Origins, new NoHttp(), NullLoggerFactory.Instance, new FixedClock(Now));

    [Fact]
    public async Task With_nothing_saved_in_hrms_the_gateways_work_from_the_server_file_as_before()
    {
        var gateways = Gateways(new Store(), ServerCard);

        var card = await gateways.CardAsync();
        Assert.True(card.IsConfigured);
        Assert.Equal((GatewayModes.Test, GatewayKeySources.Server, "TESTMERCHANT"), (card.Mode, card.Source, card.MerchantId));

        // The other mode has no keys anywhere: an ordinary state, said in a sentence.
        var live = await gateways.CardAsync(GatewayModes.Live);
        Assert.False(live.IsConfigured);
        Assert.Contains("No live keys are saved for Bank of Beirut", live.Problem);

        Assert.False((await gateways.WhishAsync()).IsConfigured);
    }

    [Fact]
    public async Task Keys_saved_in_hrms_are_used_for_their_mode_and_the_mode_in_use_is_what_was_chosen()
    {
        var store = new Store();
        store.Keys[(GatewayNames.Whish, GatewayModes.Test)] = Protector.Protect(GatewayNames.Whish, GatewayModes.Test, WhishTestKeys);
        store.Keys[(GatewayNames.Whish, GatewayModes.Live)] = Protector.Protect(GatewayNames.Whish, GatewayModes.Live, WhishLiveKeys);
        var gateways = Gateways(store);

        // Nothing chosen and nothing in the server file: test.
        var inUse = await gateways.WhishAsync();
        Assert.True(inUse.IsConfigured);
        Assert.Equal((WhishOptions.SandboxBase, "10191111", GatewayKeySources.Settings), (inUse.BaseUrl, inUse.Channel, inUse.Source));
        Assert.Equal("https://api.example.test", inUse.ApiPublicUrl);

        // Production can be asked for by name without switching anything (the test page does).
        var live = await gateways.WhishAsync(GatewayModes.Live);
        Assert.Equal((WhishOptions.LiveBase, "20292222", GatewayModes.Live), (live.BaseUrl, live.Channel, live.Mode));
        Assert.Equal(GatewayModes.Test, (await gateways.WhishAsync()).Mode);

        // Chosen live: live is in use; test is still there by name.
        store.Modes[GatewayNames.Whish] = GatewayModes.Live;
        gateways.Refresh();
        Assert.Equal(WhishOptions.LiveBase, (await gateways.WhishAsync()).BaseUrl);
        Assert.Equal(WhishOptions.SandboxBase, (await gateways.WhishAsync(GatewayModes.Test)).BaseUrl);
    }

    [Fact]
    public async Task Keys_saved_in_hrms_take_the_place_of_the_server_files_for_the_same_mode()
    {
        var store = new Store();
        store.Keys[(GatewayNames.Card, GatewayModes.Test)] = Protector.Protect(GatewayNames.Card, GatewayModes.Test, new Dictionary<string, string>
        {
            [GatewayKeyFields.BaseUrl] = "https://test-gateway.example.test",
            [GatewayKeyFields.MerchantId] = "TESTFROMHRMS",
            [GatewayKeyFields.ApiPassword] = "hrms-password",
            [GatewayKeyFields.ApiVersion] = "73",
        });

        var card = await Gateways(store, ServerCard).CardAsync();
        Assert.Equal(("TESTFROMHRMS", "hrms-password", GatewayKeySources.Settings), (card.MerchantId, card.ApiPassword, card.Source));
        Assert.Equal("https://site.example.test", card.SiteUrl);
    }

    [Fact]
    public async Task Keys_this_server_cannot_open_read_as_not_configured_and_say_to_enter_them_again()
    {
        var store = new Store();
        store.Keys[(GatewayNames.Whish, GatewayModes.Test)] =
            new GatewayKeyProtector("another-servers-signing-key-0123456789abcdef").Protect(GatewayNames.Whish, GatewayModes.Test, WhishTestKeys);

        var gateways = Gateways(store);
        var whish = await gateways.WhishAsync();
        Assert.False(whish.IsConfigured);
        Assert.Contains("cannot be opened on this server", whish.Problem);

        var status = await gateways.StatusAsync(GatewayNames.Whish);
        Assert.True(status.Modes.Single(m => m.Mode == GatewayModes.Test).Unreadable);
    }

    [Fact]
    public async Task A_database_without_script_119_never_stops_a_payment_the_server_file_is_used()
    {
        var store = new Store { ScriptMissing = true };
        var gateways = Gateways(store, ServerCard);

        Assert.True((await gateways.CardAsync()).IsConfigured);
        Assert.Equal(GatewayKeySources.Server, (await gateways.CardAsync()).Source);
        Assert.Equal(1, store.Reads);          // and the database is not asked again at every payment
    }

    [Fact]
    public async Task What_was_read_is_kept_for_a_moment_and_re_read_after_a_change()
    {
        var store = new Store();
        var gateways = Gateways(store);

        await gateways.WhishAsync();
        await gateways.WhishAsync();
        await gateways.CardAsync();
        Assert.Equal(1, store.Reads);

        gateways.Refresh();
        await gateways.WhishAsync();
        Assert.Equal(2, store.Reads);
    }

    /* ---- what an admin may save, and what comes back ---------------------------------------------- */

    private sealed class AdminRig
    {
        public Store Store { get; } = new();
        public Mock<IWhishClient> Whish { get; } = new(MockBehavior.Strict);
        public Mock<IMpgsClient> Card { get; } = new(MockBehavior.Strict);
        public Mock<IOnlineDepositRepository> Deposits { get; } = new();
        public Mock<IBookingService> Bookings { get; } = new();
        public PaymentGateways Real { get; }
        public GatewayAdminService Service { get; }

        /// <summary>The two website switches as core.SETTING holds them ('1' / '0').</summary>
        public Dictionary<string, string> Switches { get; } = new() { [GatewayAdminService.DepositsSetting] = "0", [WhishOptions.EnabledSetting] = "0" };

        public AdminRig(MpgsOptions? serverCard = null, bool production = false)
        {
            var settings = new Mock<MokaCo.HRMS.Services.Core.ISettingService>();
            settings.Setup(x => x.GetAsync(It.IsAny<string>())).ReturnsAsync((string key) => Switches.TryGetValue(key, out var value)
                ? new MokaCo.HRMS.Model.Core.Setting { SettingKey = key, SettingValue = value, DataType = "bool", Description = "kept" } : null);
            settings.Setup(x => x.UpsertAsync(It.IsAny<string>(), It.IsAny<MokaCo.HRMS.Model.Core.SettingUpsertRequest>(), It.IsAny<int?>()))
                .Callback((string key, MokaCo.HRMS.Model.Core.SettingUpsertRequest request, int? _) => Switches[key] = request.SettingValue)
                .Returns(Task.CompletedTask);
            Deposits.Setup(d => d.IsWhishEnabledAsync()).ReturnsAsync(() => Switches[WhishOptions.EnabledSetting] == "1");
            Bookings.Setup(b => b.IsDepositRequiredAsync()).ReturnsAsync(() => Switches[GatewayAdminService.DepositsSetting] == "1");
            Production = production;
            Settings = settings.Object;
            Real = Gateways(Store, serverCard);
            // The real resolution, but the two clients are the mocks: nothing here reaches a network.
            var gateways = new Mock<IPaymentGateways>();
            gateways.Setup(g => g.CardAsync()).Returns(() => Real.CardAsync());
            gateways.Setup(g => g.WhishAsync()).Returns(() => Real.WhishAsync());
            gateways.Setup(g => g.CardAsync(It.IsAny<string?>())).Returns((string? mode) => Real.CardAsync(mode));
            gateways.Setup(g => g.WhishAsync(It.IsAny<string?>())).Returns((string? mode) => Real.WhishAsync(mode));
            gateways.Setup(g => g.StatusAsync(It.IsAny<string>())).Returns((string gateway) => Real.StatusAsync(gateway));
            gateways.Setup(g => g.Refresh()).Callback(() => Real.Refresh());
            gateways.Setup(g => g.WhishClient(It.IsAny<WhishOptions>())).Returns(Whish.Object);
            gateways.Setup(g => g.CardClient(It.IsAny<MpgsOptions>())).Returns(Card.Object);

            Service = new GatewayAdminService(gateways.Object, Store, Protector, new PaymentEventLog(Store, NullLogger<PaymentEventLog>.Instance),
                Deposits.Object, Bookings.Object, new GatewayServerFacts("https://site.example.test", "https://api.example.test", Production),
                NullLogger<GatewayAdminService>.Instance, new FixedClock(Now), Settings);
        }

        public bool Production { get; }
        public MokaCo.HRMS.Services.Core.ISettingService Settings { get; }

        public Task<GatewayActionResult> SaveWhish(string mode, IReadOnlyDictionary<string, string> keys) => Service.SaveKeysAsync(GatewayNames.Whish, mode, new GatewayKeysInput
        {
            Channel = keys[GatewayKeyFields.Channel], Secret = keys[GatewayKeyFields.Secret], WebsiteUrl = keys[GatewayKeyFields.WebsiteUrl],
        }, userId: 7);
    }

    [Fact]
    public async Task Saved_keys_are_stored_encrypted_and_nothing_the_page_is_given_carries_one()
    {
        var rig = new AdminRig(ServerCard);
        Assert.True((await rig.SaveWhish(GatewayModes.Test, WhishTestKeys)).Ok);
        Assert.True((await rig.SaveWhish(GatewayModes.Live, WhishLiveKeys)).Ok);

        // In the database: a cipher, not the keys.
        var stored = Encoding.UTF8.GetString(rig.Store.Keys[(GatewayNames.Whish, GatewayModes.Live)]);
        Assert.DoesNotContain(WhishLiveKeys[GatewayKeyFields.Secret], stored);

        // On the page: the website URL in full, a secret by its last four characters, nothing more.
        var overview = await rig.Service.GetAsync();
        var json = JsonSerializer.Serialize(overview);
        foreach (var secret in new[] { WhishTestKeys[GatewayKeyFields.Secret], WhishLiveKeys[GatewayKeyFields.Secret], WhishTestKeys[GatewayKeyFields.Channel], WhishLiveKeys[GatewayKeyFields.Channel], "server-file-password" })
            Assert.DoesNotContain(secret, json);

        var test = overview.Whish.Modes.Single(m => m.Mode == GatewayModes.Test);
        Assert.True(test.Ready);
        Assert.Equal("example.test", test.Shown[GatewayKeyFields.WebsiteUrl]);
        Assert.Equal("••••1234", test.Shown[GatewayKeyFields.Secret]);
        Assert.Equal((GatewayKeySources.Settings, "owner"), (test.Source, test.SavedBy));

        // The card gateway still comes from the server file, and says so.
        Assert.Equal(GatewayKeySources.Server, overview.Card.Modes.Single(m => m.Mode == GatewayModes.Test).Source);
        Assert.Equal(GatewayModes.Test, overview.Card.ActiveMode);
    }

    [Fact]
    public async Task A_box_left_empty_keeps_what_is_saved()
    {
        var rig = new AdminRig();
        await rig.SaveWhish(GatewayModes.Test, WhishTestKeys);

        // Only the website URL is typed again: the channel and the secret stay.
        var result = await rig.Service.SaveKeysAsync(GatewayNames.Whish, GatewayModes.Test, new GatewayKeysInput { WebsiteUrl = "other.example.test" }, 7);
        Assert.True(result.Ok);

        var options = await rig.Real.WhishAsync(GatewayModes.Test);
        Assert.Equal(("10191111", WhishTestKeys[GatewayKeyFields.Secret], "other.example.test"), (options.Channel, options.Secret, options.WebsiteUrl));
    }

    [Fact]
    public async Task Keys_that_are_incomplete_or_in_the_wrong_box_are_refused_in_a_sentence_and_nothing_is_stored()
    {
        var rig = new AdminRig();

        var incomplete = await rig.Service.SaveKeysAsync(GatewayNames.Whish, GatewayModes.Live, new GatewayKeysInput { Channel = "1", Secret = "x" }, 7);
        Assert.False(incomplete.Ok);
        Assert.Contains("all three", incomplete.Message);

        GatewayKeysInput Card(string merchant, string address = "https://bobsal.gateway.mastercard.com") => new()
        {
            BaseUrl = address, MerchantId = merchant, ApiPassword = "a-password",
        };

        // The bank names its test profiles TEST...: live keys cannot land in the test box, nor the reverse.
        Assert.Contains("LIVE profile", (await rig.Service.SaveKeysAsync(GatewayNames.Card, GatewayModes.Test, Card("MOKANDCO"), 7)).Message);
        Assert.Contains("TEST profile", (await rig.Service.SaveKeysAsync(GatewayNames.Card, GatewayModes.Live, Card("TESTMOKANDCO"), 7)).Message);
        Assert.Contains("https://", (await rig.Service.SaveKeysAsync(GatewayNames.Card, GatewayModes.Live, Card("MOKANDCO", "http://bobsal.gateway.mastercard.com"), 7)).Message);

        // The password travels to this address with every call: only the bank's gateway, and only its bare host.
        foreach (var elsewhere in new[] { "https://attacker.example.test", "https://gateway.mastercard.com.attacker.example.test", "https://bobsal.gateway.mastercard.com/checkout",
                     "https://bobsal.gateway.mastercard.com:8443", "https://user@bobsal.gateway.mastercard.com" })
            Assert.Contains("Mastercard gateway", (await rig.Service.SaveKeysAsync(GatewayNames.Card, GatewayModes.Live, Card("MOKANDCO", elsewhere), 7)).Message);

        Assert.Empty(rig.Store.Keys);

        // The right box: saved, the API version defaulting to the one the bank's flow uses.
        Assert.True((await rig.Service.SaveKeysAsync(GatewayNames.Card, GatewayModes.Live, Card("MOKANDCO"), 7)).Ok);
        var live = await rig.Real.CardAsync(GatewayModes.Live);
        Assert.Equal((true, GatewayModes.Live, 73), (live.IsConfigured, live.Mode, live.ApiVersion));
        Assert.False(live.SendsThreeDsBypass);
    }

    [Fact]
    public async Task A_saved_password_never_follows_a_new_address_or_merchant_by_itself()
    {
        var rig = new AdminRig();
        var first = new GatewayKeysInput { BaseUrl = "https://bobsal.gateway.mastercard.com", MerchantId = "MOKANDCO", ApiPassword = "the-saved-password" };
        Assert.True((await rig.Service.SaveKeysAsync(GatewayNames.Card, GatewayModes.Live, first, 7)).Ok);

        // Only the address is sent, everything else left blank: the saved password would go with it. Refused.
        var moved = await rig.Service.SaveKeysAsync(GatewayNames.Card, GatewayModes.Live, new GatewayKeysInput { BaseUrl = "https://ap-gateway.mastercard.com" }, 7);
        Assert.False(moved.Ok);
        Assert.Contains("type the API password again", moved.Message);
        var merchant = await rig.Service.SaveKeysAsync(GatewayNames.Card, GatewayModes.Live, new GatewayKeysInput { MerchantId = "OTHERMERCHANT" }, 7);
        Assert.Contains("type the API password again", merchant.Message);
        Assert.Equal("https://bobsal.gateway.mastercard.com", (await rig.Real.CardAsync(GatewayModes.Live)).BaseUrl);

        // With the password typed again, or with nothing but the version changed: saved.
        Assert.True((await rig.Service.SaveKeysAsync(GatewayNames.Card, GatewayModes.Live,
            new GatewayKeysInput { BaseUrl = "https://ap-gateway.mastercard.com", ApiPassword = "typed-again" }, 7)).Ok);
        Assert.True((await rig.Service.SaveKeysAsync(GatewayNames.Card, GatewayModes.Live, new GatewayKeysInput { ApiVersion = "81" }, 7)).Ok);
        var now = await rig.Real.CardAsync(GatewayModes.Live);
        Assert.Equal(("https://ap-gateway.mastercard.com", "typed-again", 81), (now.BaseUrl, now.ApiPassword, now.ApiVersion));
    }

    [Fact]
    public async Task Keys_stay_while_a_payment_opened_with_them_is_still_waiting()
    {
        var rig = new AdminRig();
        await rig.SaveWhish(GatewayModes.Live, WhishLiveKeys);
        rig.Store.Payments.Add(new PaymentRow { BookingRef = Ref, Gateway = GatewayNames.Whish, Mode = GatewayModes.Live, PayState = "Open" });

        var refused = await rig.Service.DeleteKeysAsync(GatewayNames.Whish, GatewayModes.Live, 7);
        Assert.False(refused.Ok);
        Assert.Contains("still waiting to be settled", refused.Message);
        Assert.True(rig.Store.Keys.ContainsKey((GatewayNames.Whish, GatewayModes.Live)));

        // Settled (or never of this mode): the keys can go.
        rig.Store.Payments[0].PayState = "Paid";
        Assert.True((await rig.Service.DeleteKeysAsync(GatewayNames.Whish, GatewayModes.Live, 7)).Ok);
    }

    [Fact]
    public async Task The_banks_own_no_such_order_proves_the_keys_a_bare_404_proves_nothing()
    {
        var rig = new AdminRig(ServerCard);

        rig.Card.Setup(c => c.RetrieveOrderAsync(It.IsAny<string>(), It.IsAny<CancellationToken>())).ReturnsAsync(MpgsOrderLookup.NotFound());
        Assert.True((await rig.Service.CheckConnectionAsync(GatewayNames.Card, GatewayModes.Test, 7)).Ok);

        // A wrong address or API version answers 404 too: never "the bank accepted the keys".
        rig.Card.Setup(c => c.RetrieveOrderAsync(It.IsAny<string>(), It.IsAny<CancellationToken>())).ReturnsAsync(MpgsOrderLookup.NotFound(byStatusOnly: true));
        var wrong = await rig.Service.CheckConnectionAsync(GatewayNames.Card, GatewayModes.Test, 7);
        Assert.False(wrong.Ok);
        Assert.Contains("address or the API version", wrong.Message);

        rig.Card.Setup(c => c.RetrieveOrderAsync(It.IsAny<string>(), It.IsAny<CancellationToken>())).ReturnsAsync(MpgsOrderLookup.Error("HTTP 401"));
        Assert.Contains("refused the keys", (await rig.Service.CheckConnectionAsync(GatewayNames.Card, GatewayModes.Test, 7)).Message);
    }

    [Fact]
    public async Task A_booking_reference_is_looked_up_on_whish_as_its_first_attempt_whatever_letters_it_holds()
    {
        var rig = new AdminRig();
        await rig.SaveWhish(GatewayModes.Test, WhishTestKeys);
        var asked = new List<string>();
        rig.Whish.Setup(w => w.GetStatusAsync(It.IsAny<string>(), "USD", It.IsAny<CancellationToken>()))
            .Callback((string id, string _, CancellationToken _) => asked.Add(id))
            .ReturnsAsync(new WhishCollectLookup(WhishLookupKind.Found, "success"));

        await rig.Service.LookupAsync(GatewayNames.Whish, GatewayModes.Test, "mc-a7q2m9pw", "USD");      // a reference that itself holds "-A"
        await rig.Service.LookupAsync(GatewayNames.Whish, GatewayModes.Test, "MC-A7Q2M9PW-A3", "USD");
        await rig.Service.LookupAsync(GatewayNames.Whish, GatewayModes.Test, "GT-AAAA2222", "USD");

        Assert.Equal(["MC-A7Q2M9PW-A1", "MC-A7Q2M9PW-A3", "GT-AAAA2222"], asked);
    }

    [Fact]
    public async Task A_gateway_cannot_be_switched_to_a_mode_it_has_no_keys_for()
    {
        var rig = new AdminRig();
        await rig.SaveWhish(GatewayModes.Test, WhishTestKeys);

        var refused = await rig.Service.SetModeAsync(GatewayNames.Whish, GatewayModes.Live, 7);
        Assert.False(refused.Ok);
        Assert.Contains("Save the live keys first", refused.Message);
        Assert.False(rig.Store.Modes.ContainsKey(GatewayNames.Whish));

        await rig.SaveWhish(GatewayModes.Live, WhishLiveKeys);
        Assert.True((await rig.Service.SetModeAsync(GatewayNames.Whish, GatewayModes.Live, 7)).Ok);
        Assert.Equal(GatewayModes.Live, (await rig.Real.WhishAsync()).Mode);

        // Removing the keys of a mode in use leaves it honestly "not configured", never silently on the other keys.
        await rig.Service.DeleteKeysAsync(GatewayNames.Whish, GatewayModes.Live, 7);
        Assert.False((await rig.Real.WhishAsync()).IsConfigured);
    }

    [Fact]
    public async Task The_connection_check_asks_with_the_keys_of_the_mode_named_and_is_logged()
    {
        var rig = new AdminRig();
        await rig.SaveWhish(GatewayModes.Test, WhishTestKeys);
        rig.Whish.Setup(w => w.GetBalanceAsync("USD", It.IsAny<CancellationToken>())).ReturnsAsync(new WhishBalanceResult(true, 12.5m));

        var ok = await rig.Service.CheckConnectionAsync(GatewayNames.Whish, GatewayModes.Test, 7);
        Assert.True(ok.Ok);
        Assert.Contains("accepted the keys", ok.Message);
        Assert.Contains("USD 12.50", ok.Message);

        // No keys for live: said, and the gateway is not asked.
        var none = await rig.Service.CheckConnectionAsync(GatewayNames.Whish, GatewayModes.Live, 7);
        Assert.False(none.Ok);
        rig.Whish.Verify(w => w.GetBalanceAsync(It.IsAny<string>(), It.IsAny<CancellationToken>()), Times.Once);

        Assert.Equal(["Ok", "Failed"], rig.Store.Events.Where(e => e.EventType == PaymentEvents.ConnectionCheck).Select(e => e.Outcome));
    }

    [Fact]
    public void A_gateways_refusal_is_put_in_words_a_person_can_act_on()
    {
        // Whish's own table: auth.error = the server's address is not registered (refunds).
        Assert.Contains("not registered with Whish", GatewayAdminService.WhishProblem("auth.error", "code auth.error"));
        Assert.Contains("refused the keys", GatewayAdminService.WhishProblem("auth.session_not_exist", "code auth.session_not_exist"));
        Assert.Contains("did not answer in time", GatewayAdminService.WhishProblem(null, "timed out"));
        Assert.Contains("could not be reached", GatewayAdminService.WhishProblem(null, "network error: HttpRequestException"));

        Assert.Contains("refused the keys", GatewayAdminService.CardProblem("HTTP 401"));
        Assert.Contains("could not be reached", GatewayAdminService.CardProblem("network error"));
    }

    /* ---- gateway tests ------------------------------------------------------------------------- */

    [Fact]
    public void A_test_reference_is_never_the_shape_of_a_bookings()
    {
        for (var i = 0; i < 200; i++)
        {
            var reference = GatewayTestRefs.New();
            Assert.True(GatewayTestRefs.IsTestRef(reference), reference);
            Assert.StartsWith("GT-", reference);
            Assert.Equal(11, reference.Length);
        }

        Assert.False(GatewayTestRefs.IsTestRef(Ref));
        Assert.False(GatewayTestRefs.IsTestRef("GT-short"));
        Assert.False(GatewayTestRefs.IsTestRef(null));
    }

    [Theory]
    [InlineData("https://hrms.example.test", "https://hrms.example.test/bookings/gateway-test?test=GT-AAAA2222")]
    [InlineData("https://HRMS.example.test/some/path?x=1", "https://hrms.example.test/bookings/gateway-test?test=GT-AAAA2222")]
    [InlineData("http://localhost:5173", "http://localhost:5173/bookings/gateway-test?test=GT-AAAA2222")]      // a development server on this machine
    [InlineData("https://elsewhere.example.test", null)]            // an origin somebody merely names: not where the request was sent
    [InlineData("https://hrms.example.test@elsewhere.example.test", null)]
    [InlineData("https://user@hrms.example.test", null)]
    [InlineData("javascript:alert(1)", null)]
    [InlineData("", null)]
    [InlineData(null, null)]
    public void The_tester_is_sent_back_only_to_the_hrms_address_the_request_itself_was_sent_to(string? origin, string? expected)
        => Assert.Equal(expected, GatewayAdminService.ReturnUrlFor(origin, "GT-AAAA2222", "hrms.example.test:443"));

    [Fact]
    public async Task An_old_tests_public_address_no_longer_leads_anywhere()
    {
        var rig = new AdminRig();
        rig.Store.Tests["GT-AAAA2222"] = new GatewayTestRow
        {
            TestRef = "GT-AAAA2222", Gateway = GatewayNames.Card, Mode = GatewayModes.Test, Amount = 1, CurrencyCode = "USD", Status = "Paid",
            ReturnUrl = "https://hrms.example.test/bookings/gateway-test?test=GT-AAAA2222", CreatedAtUtc = Now.AddDays(-2),
        };
        // Its mode has no keys in this rig: the check on return says so and the answer is still "no address".
        Assert.Null(await rig.Service.TestReturnAsync("GT-AAAA2222"));
    }

    [Fact]
    public async Task A_whish_test_payment_is_opened_with_the_keys_of_the_mode_named_and_followed_to_paid_and_refunded()
    {
        var rig = new AdminRig();
        await rig.SaveWhish(GatewayModes.Live, WhishLiveKeys);

        string? sentId = null, callback = null, back = null;
        rig.Whish.Setup(w => w.CreateCollectAsync(It.IsAny<string>(), 2m, "USD", It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string>(),
                It.IsAny<string>(), It.IsAny<string>(), It.IsAny<CancellationToken>()))
            .Callback((string id, decimal _, string _, string _, string successCallback, string _, string successRedirect, string _, CancellationToken _) =>
            {
                sentId = id; callback = successCallback; back = successRedirect;
            })
            .ReturnsAsync("https://pay.example.test/pay/abc");

        // The website's payments are NOT in live mode here (nothing was chosen): the test names its own mode.
        var opened = await rig.Service.OpenTestAsync(GatewayNames.Whish, GatewayModes.Live, 2m, "usd", "https://hrms.example.test", 7, requestHost: "hrms.example.test");
        Assert.True(opened.Ok);
        var test = opened.Test!;
        Assert.True(GatewayTestRefs.IsTestRef(test.TestRef));
        Assert.Equal((test.TestRef, "https://pay.example.test/pay/abc", GatewayModes.Live), (sentId, test.PayUrl, test.Mode));
        Assert.StartsWith($"https://api.example.test/api/public/booking/whish/callback?ref={test.TestRef}&t=", callback);
        Assert.Equal($"https://api.example.test/api/public/booking/whish/return?ref={test.TestRef}", back);
        Assert.Equal($"https://hrms.example.test/bookings/gateway-test?test={test.TestRef}", test.ReturnUrl);

        // Whish's server reaches the callback address: noted only with the right token.
        var live = await rig.Real.WhishAsync(GatewayModes.Live);
        Assert.False(await rig.Service.TestCallbackAsync(test.TestRef, "0123456789abcdef01234567"));
        Assert.True(await rig.Service.TestCallbackAsync(test.TestRef, live.CallbackToken(test.TestRef)));
        Assert.NotNull(test.CallbackAtUtc);

        // The tester comes back: the test is checked, and the browser goes to the HRMS page.
        rig.Whish.Setup(w => w.GetStatusAsync(test.TestRef, "USD", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new WhishCollectLookup(WhishLookupKind.Found, "success", "96170000000"));
        Assert.Equal(test.ReturnUrl, await rig.Service.TestReturnAsync(test.TestRef));
        Assert.Equal(("Paid", "96170000000"), (test.Status, test.PayerPhone));

        // A real payment made for a test is given back from the same page.
        rig.Whish.Setup(w => w.RefundAsync(test.TestRef, "USD", It.IsAny<string>(), It.IsAny<CancellationToken>())).ReturnsAsync(new WhishRefundResult(true));
        var refund = await rig.Service.RefundTestAsync(test.TestRef, 7);
        Assert.True(refund.Ok);
        Assert.Equal("Refunded", test.Status);

        // Everything about it is in the log, under the test's reference and never a booking's.
        Assert.All(rig.Store.Events, e => Assert.Null(e.BookingRef));
        Assert.Equal([PaymentEvents.Opened, PaymentEvents.Checked, PaymentEvents.Checked, PaymentEvents.Refunded],
            rig.Store.Events.Where(e => e.TestRef == test.TestRef).Select(e => e.EventType));
    }

    [Fact]
    public async Task A_test_payment_is_small_and_needs_keys()
    {
        var rig = new AdminRig();

        // No keys: said, nothing opened, nothing stored.
        var noKeys = await rig.Service.OpenTestAsync(GatewayNames.Whish, GatewayModes.Test, 1m, "USD", null, 7);
        Assert.False(noKeys.Ok);
        Assert.Null(noKeys.Test);

        await rig.SaveWhish(GatewayModes.Test, WhishTestKeys);
        Assert.Contains("between 0 and USD 20", (await rig.Service.OpenTestAsync(GatewayNames.Whish, GatewayModes.Test, 500m, "USD", null, 7)).Message);
        Assert.Contains("between 0 and", (await rig.Service.OpenTestAsync(GatewayNames.Whish, GatewayModes.Test, 0m, "USD", null, 7)).Message);
        Assert.Contains("USD or LBP", (await rig.Service.OpenTestAsync(GatewayNames.Whish, GatewayModes.Test, 1m, "EUR", null, 7)).Message);
        Assert.Empty(rig.Store.Tests);
    }

    [Fact]
    public async Task A_card_test_comes_back_through_our_own_verifier_whatever_the_guest_does_on_the_banks_page()
    {
        var rig = new AdminRig(ServerCard);
        string? returnUrl = null, cancelUrl = null, timeoutUrl = null, order = null;
        rig.Card.Setup(c => c.InitiateCheckoutAsync(It.IsAny<string>(), 1.5m, "USD", It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string>(), It.IsAny<CancellationToken>()))
            .Callback((string id, decimal _, string _, string _, string onReturn, string onCancel, string onTimeout, CancellationToken _) =>
            {
                order = id; returnUrl = onReturn; cancelUrl = onCancel; timeoutUrl = onTimeout;
            })
            .ReturnsAsync("SESSION0001");

        var opened = await rig.Service.OpenTestAsync(GatewayNames.Card, GatewayModes.Test, 1.5m, "USD", "https://hrms.example.test", 7, requestHost: "hrms.example.test");
        var test = opened.Test!;
        Assert.Equal(test.TestRef, order);
        Assert.Equal($"https://api.example.test/api/public/booking/verify?ref={test.TestRef}", returnUrl);
        Assert.Equal((returnUrl, returnUrl), (cancelUrl, timeoutUrl));
        Assert.Equal("https://site.example.test/pay/#session=SESSION0001", test.PayUrl);

        // Paid in full on the bank's page.
        rig.Card.Setup(c => c.RetrieveOrderAsync(test.TestRef, It.IsAny<CancellationToken>()))
            .ReturnsAsync(new MpgsOrderLookup(MpgsLookupKind.Found, "SUCCESS", "CAPTURED", 1.5m, "USD", 1.5m, "1", TransactionCount: 1, TotalAuthorizedAmount: 1.5m));
        var check = await rig.Service.CheckTestAsync(test.TestRef, 7, PaymentEvents.FromStaff);
        Assert.True(check.Ok);
        Assert.Equal("Paid", test.Status);

        // A card test is refunded at the bank, and the page says so instead of pretending.
        var refund = await rig.Service.RefundTestAsync(test.TestRef, 7);
        Assert.False(refund.Ok);
        Assert.Contains("bank's merchant portal", refund.Message);
    }

    /* ---- the public addresses: a test's trip back ------------------------------------------------ */

    [Fact]
    public async Task The_public_return_addresses_send_a_test_back_to_hrms_and_never_treat_it_as_a_booking()
    {
        var deposits = new Mock<IOnlineDepositService>(MockBehavior.Strict);      // strict: a test never reaches the booking path
        var tests = new Mock<IGatewayAdminService>();
        tests.Setup(t => t.TestReturnAsync("GT-AAAA2222", It.IsAny<CancellationToken>())).ReturnsAsync("https://hrms.example.test/bookings/gateway-test?test=GT-AAAA2222");
        tests.Setup(t => t.TestReturnAsync("GT-BBBB3333", It.IsAny<CancellationToken>())).ReturnsAsync((string?)null);
        tests.Setup(t => t.TestCallbackAsync("GT-AAAA2222", "good")).ReturnsAsync(true);

        var controller = new PublicBookingController(Mock.Of<IBookingService>(), Mock.Of<IRoomService>(), null, deposits.Object, null, tests.Object)
        {
            ControllerContext = new ControllerContext { HttpContext = new DefaultHttpContext() },
        };

        // The card's return and Whish's return: both lead back to the HRMS page.
        Assert.Equal("https://hrms.example.test/bookings/gateway-test?test=GT-AAAA2222", Assert.IsType<RedirectResult>(await controller.Verify("gt-aaaa2222")).Url);
        Assert.Equal("https://hrms.example.test/bookings/gateway-test?test=GT-AAAA2222", Assert.IsType<RedirectResult>(await controller.WhishReturn("GT-AAAA2222")).Url);

        // Opened without a browser: a line of text, not a redirect to nowhere.
        Assert.IsType<ContentResult>(await controller.Verify("GT-BBBB3333"));

        // The callback: 200 with the right token, 404 otherwise.
        Assert.IsType<OkResult>(await controller.WhishCallback("GT-AAAA2222", "good"));
        Assert.IsType<NotFoundResult>(await controller.WhishCallback("GT-AAAA2222", "bad"));
    }

    /* ---- a payment is settled with the mode it was opened in, and logged --------------------------- */

    /// <summary>Remembers which mode each question named.</summary>
    private sealed class RecordingGateways(IMpgsClient card, IWhishClient whish) : IPaymentGateways
    {
        public List<string?> CardModes { get; } = [];
        public List<string?> WhishModes { get; } = [];
        public string InUse { get; set; } = GatewayModes.Test;

        private MpgsOptions CardFor(string? mode) => MpgsOptions.FromSettings(key => key switch
        {
            MpgsOptions.BaseKey => "https://gateway.example.test",
            MpgsOptions.MerchantIdKey => (mode ?? InUse) == GatewayModes.Test ? "TESTMERCHANT" : "MERCHANT",
            MpgsOptions.ApiPasswordKey => "a-password",
            MpgsOptions.ApiVersionKey => "73",
            _ => Origins(key),
        });

        private WhishOptions WhishFor(string? mode) => WhishOptions.FromSettings(key => key switch
        {
            WhishOptions.BaseKey => (mode ?? InUse) == GatewayModes.Test ? WhishOptions.SandboxBase : WhishOptions.LiveBase,
            WhishOptions.ChannelKey => "10191111",
            WhishOptions.SecretKey => "a-made-up-secret-0123456789abcdef",
            WhishOptions.WebsiteUrlKey => "example.test",
            _ => Origins(key),
        });

        public Task<MpgsOptions> CardAsync() => CardAsync(null);
        public Task<WhishOptions> WhishAsync() => WhishAsync(null);
        public Task<MpgsOptions> CardAsync(string? mode) { CardModes.Add(mode); return Task.FromResult(CardFor(mode)); }
        public Task<WhishOptions> WhishAsync(string? mode) { WhishModes.Add(mode); return Task.FromResult(WhishFor(mode)); }
        public IMpgsClient CardClient(MpgsOptions options) => card;
        public IWhishClient WhishClient(WhishOptions options) => whish;
        public Task<GatewayStatus> StatusAsync(string gateway) => throw new NotSupportedException();
        public void Refresh() { }
    }

    private sealed class SettleRig
    {
        public Mock<IOnlineDepositRepository> Deposits { get; } = new();
        public Mock<IBookingRepository> Bookings { get; } = new();
        public Mock<IMpgsClient> Card { get; } = new(MockBehavior.Strict);
        public Mock<IWhishClient> Whish { get; } = new(MockBehavior.Strict);
        public Store Log { get; } = new();
        public RecordingGateways Gateways { get; }
        public OnlineDepositService Service { get; }

        public SettleRig()
        {
            Gateways = new RecordingGateways(Card.Object, Whish.Object);
            Deposits.Setup(d => d.IsWhishEnabledAsync()).ReturnsAsync(true);
            Service = new OnlineDepositService(Deposits.Object, Bookings.Object, Gateways,
                new OnlineDepositOptions { ReconcileAfterMinutes = 10, GiveUpAfterMinutes = 30 }, NullLogger<OnlineDepositService>.Instance,
                new FixedClock(Now), new PaymentEventLog(Log, NullLogger<PaymentEventLog>.Instance));
        }

        public void State(string? gatewayOrderId, string status = "Pending", double openedMinutesAgo = 2, int holdMinutesLeft = 13, string? openedIn = null)
        {
            Deposits.Setup(d => d.GetPaymentStateAsync(Ref)).ReturnsAsync(new PaymentState
            {
                BookingId = 42, BookingRef = Ref, Status = status, Source = "Website", DepositDue = 30m, CurrencyCode = "USD",
                PaymentOpenedUtc = gatewayOrderId is null ? null : Now.AddMinutes(-openedMinutesAgo),
                HoldExpiresUtc = gatewayOrderId is null ? null : Now.AddMinutes(holdMinutesLeft),
                GatewayOrderId = gatewayOrderId,
            });
            Deposits.Setup(d => d.GetPaymentModeAsync(Ref)).ReturnsAsync(openedIn);
        }
    }

    [Fact]
    public async Task A_payment_opened_in_live_is_settled_with_the_live_keys_even_after_the_gateway_was_switched_to_test()
    {
        var rig = new SettleRig();
        rig.Gateways.InUse = GatewayModes.Test;                                        // switched to test since
        rig.State(WhishOptions.AttemptId(Ref, 1), openedIn: GatewayModes.Live);        // but this guest paid in live
        rig.Whish.Setup(w => w.GetStatusAsync($"{Ref}-A1", "USD", It.IsAny<CancellationToken>()))
            .ReturnsAsync(new WhishCollectLookup(WhishLookupKind.Found, "success", "96170000000"));
        rig.Deposits.Setup(d => d.ConfirmOnlinePaymentAsync(Ref, 30m, "USD", $"{Ref}-A1", "96170000000", PaymentMethods.WhishLineName))
            .ReturnsAsync(new OnlinePaymentRecorded { Outcome = OnlinePaymentRecorded.Confirmed, BookingRef = Ref, Status = "Confirmed", PaidAmount = 30m });

        var settled = await rig.Service.SettleAsync(Ref, SettleTrigger.GatewayReturn);

        Assert.Equal(SettlementResult.Paid, settled.Result);
        Assert.Equal([GatewayModes.Live], rig.Gateways.WhishModes);

        var line = Assert.Single(rig.Log.Events);
        Assert.Equal((PaymentEvents.Paid, PaymentEvents.FromReturn, GatewayModes.Live, OnlinePaymentRecorded.Confirmed, "success"),
            (line.EventType, line.Source, line.Mode, line.Outcome, line.GatewayStatus));
        Assert.Equal((Ref, $"{Ref}-A1", 30m), (line.BookingRef, line.GatewayOrderId, line.Amount));
    }

    [Fact]
    public async Task Opening_a_card_payment_notes_the_mode_in_use_and_logs_it()
    {
        var rig = new SettleRig();
        rig.Gateways.InUse = GatewayModes.Live;
        rig.State(null);
        rig.Deposits.Setup(d => d.StartPaymentAsync(Ref)).ReturnsAsync(new PaymentStarted
        {
            BookingId = 42, BookingRef = Ref, DepositDue = 30m, CurrencyCode = "USD", TotalAmount = 100m, BookDate = Now.Date, Hours = 2, RoomName = "Room",
            HoldExpiresUtc = Now.AddMinutes(15), PaymentOpenedUtc = Now,
        });
        rig.Card.Setup(c => c.InitiateCheckoutAsync(Ref, 30m, "USD", It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync("SESSION0001");

        var opening = await rig.Service.OpenAsync(Ref);

        Assert.Equal(PayOpenResult.Opened, opening.Result);
        rig.Deposits.Verify(d => d.SetPaymentModeAsync(Ref, GatewayModes.Live), Times.Once);
        var line = Assert.Single(rig.Log.Events);
        Assert.Equal((GatewayNames.Card, PaymentEvents.Opened, PaymentEvents.FromWebsite, GatewayModes.Live, 30m),
            (line.Gateway, line.EventType, line.Source, line.Mode, line.Amount));
    }

    [Fact]
    public async Task A_gateway_that_does_not_open_the_payment_is_logged_with_what_it_said()
    {
        var rig = new SettleRig();
        rig.State(null);
        rig.Deposits.Setup(d => d.StartPaymentAsync(Ref)).ReturnsAsync(new PaymentStarted
        {
            BookingId = 42, BookingRef = Ref, DepositDue = 30m, CurrencyCode = "USD", TotalAmount = 100m, BookDate = Now.Date, Hours = 2, RoomName = "Room",
        });
        rig.Deposits.Setup(d => d.StartWhishAttemptAsync(Ref)).ReturnsAsync(new WhishAttemptStarted { BookingRef = Ref, ExternalId = $"{Ref}-A1", Attempt = 1 });
        rig.Whish.Setup(w => w.CreateCollectAsync($"{Ref}-A1", 30m, "USD", It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string>(), It.IsAny<CancellationToken>()))
            .ThrowsAsync(new WhishException("Whish did not create the payment: code auth.session_not_exist."));

        var opening = await rig.Service.OpenAsync(Ref, PaymentMethods.Whish);

        Assert.Equal(PayOpenResult.GatewayError, opening.Result);
        var line = Assert.Single(rig.Log.Events);
        Assert.Equal((GatewayNames.Whish, PaymentEvents.OpenFailed, $"{Ref}-A1"), (line.Gateway, line.EventType, line.GatewayOrderId));
        Assert.Contains("auth.session_not_exist", line.Detail);
    }

    [Fact]
    public async Task Asked_by_staff_a_payment_is_judged_as_the_job_judges_it_and_logged_under_their_name()
    {
        var rig = new SettleRig();
        // A failed card order, opened two minutes ago: the guest may still be retrying on the bank's page. The guest's
        // own return would release it; the job - and staff asking by hand - wait.
        rig.State(Ref, openedMinutesAgo: 2);
        rig.Card.Setup(c => c.RetrieveOrderAsync(Ref, It.IsAny<CancellationToken>()))
            .ReturnsAsync(new MpgsOrderLookup(MpgsLookupKind.Found, "FAILURE", "FAILED", 30m, "USD", 0m, "1", TransactionCount: 1, TotalAuthorizedAmount: 0m));

        var settled = await rig.Service.StaffCheckAsync(Ref, userId: 9);

        Assert.Equal(SettlementResult.Unconfirmed, settled.Result);
        rig.Bookings.Verify(b => b.ReleaseHoldAsync(It.IsAny<string>()), Times.Never);
        rig.Deposits.Verify(d => d.PaymentCheckedAsync(Ref, true), Times.Once);
        rig.Deposits.Verify(d => d.QueuePaymentAlertAsync(It.IsAny<int>(), It.IsAny<string>(), It.IsAny<string?>()), Times.Never);     // no e-mail for a hand check

        var line = Assert.Single(rig.Log.Events);
        Assert.Equal((PaymentEvents.Checked, PaymentEvents.FromStaff, 9, "Unconfirmed", "FAILURE / FAILED"),
            (line.EventType, line.Source, line.UserId, line.Outcome, line.GatewayStatus));
    }

    [Fact]
    public async Task A_log_that_cannot_be_written_never_breaks_a_payment()
    {
        var broken = new Mock<IPaymentGatewayRepository>();
        broken.Setup(r => r.AddEventAsync(It.IsAny<PaymentEventEntry>())).ThrowsAsync(new InvalidOperationException("the database hiccupped"));
        var log = new PaymentEventLog(broken.Object, NullLogger<PaymentEventLog>.Instance);

        await log.WriteAsync(new PaymentEventEntry(GatewayNames.Card, PaymentEvents.Paid, PaymentEvents.FromJob, BookingRef: Ref));      // does not throw
        broken.Verify(r => r.AddEventAsync(It.IsAny<PaymentEventEntry>()), Times.Once);
    }

    /* ---- when a Whish payment may be refunded from HRMS -------------------------------------------- */

    private static PaymentDetail Paid(string gateway = GatewayNames.Whish, string status = "Cancelled", bool gatewayRefunded = false, decimal owed = 30m, params PaymentLineRow[] extra)
    {
        var orderId = gateway == GatewayNames.Whish ? $"{Ref}-A1" : Ref;
        var lines = new List<PaymentLineRow> { new() { PaymentId = 1, Amount = 30m, MethodName = "Whish", GatewayOrderId = orderId } };
        lines.AddRange(extra);
        return new PaymentDetail(new PaymentRow
        {
            BookingId = 42, BookingRef = Ref, BookingStatus = status, Gateway = gateway, PayState = "RefundDue", CurrencyCode = "USD",
            PaymentId = 1, PaidAmount = 30m, GatewayOrderId = orderId, GatewayRefunded = gatewayRefunded,
            RefundAmount = owed, RefundedAmount = -lines.Where(l => l.IsRefund).Sum(l => l.Amount),
        }, [], lines);
    }

    [Fact]
    public void A_whish_payment_is_refunded_from_hrms_only_whole_only_once_and_only_on_a_cancelled_booking()
    {
        Assert.Null(PaymentDeskService.RefundRefusal(Paid()));

        Assert.Contains("Cancel the booking first", PaymentDeskService.RefundRefusal(Paid(status: "Confirmed")));
        Assert.Contains("already refunded", PaymentDeskService.RefundRefusal(Paid(gatewayRefunded: true)));
        Assert.Contains("already refunded", PaymentDeskService.RefundRefusal(Paid(extra:
            new PaymentLineRow { PaymentId = 2, Amount = -30m, IsRefund = true, Reference = PaymentDeskService.RefundReference($"{Ref}-A1") })));

        // Part of it was given back by hand: Whish can only give back the whole payment.
        Assert.Contains("already refunded by hand", PaymentDeskService.RefundRefusal(Paid(extra:
            new PaymentLineRow { PaymentId = 2, Amount = -10m, IsRefund = true, Reference = "cash" })));

        // ONLY WHAT IS OWED. A guest who cancelled keeps no claim on the deposit: nothing is owed, nothing goes back.
        Assert.Contains("Nothing is owed back", PaymentDeskService.RefundRefusal(Paid(owed: 0m)));
        // Less is owed than the payment, and Whish cannot return a part.
        var part = PaymentDeskService.RefundRefusal(Paid(owed: 10m));
        Assert.Contains("Only USD 10.00 is owed back", part);
        Assert.Contains("USD 30.00", part);

        // The bank's refunds stay in its portal.
        Assert.Contains("bank's merchant portal", PaymentDeskService.RefundRefusal(Paid(GatewayNames.Card)));

        // Never paid: nothing to give back.
        var unpaid = new PaymentDetail(new PaymentRow { BookingRef = Ref, Gateway = GatewayNames.Whish, BookingStatus = "Cancelled", GatewayOrderId = $"{Ref}-A1" }, [], []);
        Assert.Contains("Nothing was paid on Whish", PaymentDeskService.RefundRefusal(unpaid));
    }

    [Fact]
    public async Task A_refund_goes_to_whish_first_then_onto_the_bookings_books_and_both_are_logged()
    {
        var store = new Mock<IPaymentGatewayRepository>();
        var log = new Store();
        store.Setup(r => r.GetPaymentAsync(42, It.IsAny<int>())).ReturnsAsync(Paid());
        store.Setup(r => r.AddEventAsync(It.IsAny<PaymentEventEntry>())).Returns((PaymentEventEntry entry) => log.AddEventAsync(entry));

        var whish = new Mock<IWhishClient>(MockBehavior.Strict);
        whish.Setup(w => w.RefundAsync($"{Ref}-A1", "USD", "Guest asked", It.IsAny<CancellationToken>())).ReturnsAsync(new WhishRefundResult(true));
        var gateways = new RecordingGateways(Mock.Of<IMpgsClient>(), whish.Object);

        var bookings = new Mock<IBookingService>();
        BookingRefundRequest? recorded = null;
        bookings.Setup(b => b.AddRefundAsync(42, It.IsAny<BookingRefundRequest>(), 9))
            .Callback((int _, BookingRefundRequest request, int _) => recorded = request)
            .ReturnsAsync(new RefundOutcome { Added = new RefundAdded { PaymentId = 2 }, Method = new PaymentMethod { PaymentMethodId = 3, Name = "Whish" } });

        var desk = new PaymentDeskService(store.Object, gateways, Mock.Of<IOnlineDepositService>(), bookings.Object,
            new PaymentEventLog(store.Object, NullLogger<PaymentEventLog>.Instance), new OnlineDepositOptions(), NullLogger<PaymentDeskService>.Instance);

        var result = await desk.RefundAsync(42, "Guest asked", userId: 9);

        Assert.True(result!.Ok);
        Assert.True(result.Changed);
        Assert.Equal((30m, $"Whish refund {Ref}-A1", "Whish"), (recorded!.Amount, recorded.Reference, recorded.Method!.Value.GetString()));
        var line = Assert.Single(log.Events);
        Assert.Equal((PaymentEvents.Refunded, PaymentEvents.FromStaff, 9, 30m), (line.EventType, line.Source, line.UserId, line.Amount));
    }

    [Fact]
    public async Task A_refund_whish_refuses_changes_nothing_and_says_why()
    {
        var store = new Mock<IPaymentGatewayRepository>();
        var log = new Store();
        store.Setup(r => r.GetPaymentAsync(42, It.IsAny<int>())).ReturnsAsync(Paid());
        store.Setup(r => r.AddEventAsync(It.IsAny<PaymentEventEntry>())).Returns((PaymentEventEntry entry) => log.AddEventAsync(entry));

        var whish = new Mock<IWhishClient>(MockBehavior.Strict);
        whish.Setup(w => w.RefundAsync($"{Ref}-A1", "USD", It.IsAny<string>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(new WhishRefundResult(false, Code: "auth.error", Problem: "code auth.error"));
        var bookings = new Mock<IBookingService>(MockBehavior.Strict);          // strict: the books are not touched

        var desk = new PaymentDeskService(store.Object, new RecordingGateways(Mock.Of<IMpgsClient>(), whish.Object), Mock.Of<IOnlineDepositService>(),
            bookings.Object, new PaymentEventLog(store.Object, NullLogger<PaymentEventLog>.Instance), new OnlineDepositOptions(), NullLogger<PaymentDeskService>.Instance);

        var result = await desk.RefundAsync(42, null, userId: 9);

        Assert.False(result!.Ok);
        Assert.False(result.Changed);
        Assert.Contains("not registered with Whish", result.Message);
        Assert.Equal(PaymentEvents.RefundFailed, Assert.Single(log.Events).EventType);
    }

    /* ---- found by the review of this change ------------------------------------------------------ */

    [Fact]
    public async Task One_booking_one_mode_a_second_session_is_opened_in_the_mode_of_the_first()
    {
        var rig = new SettleRig();
        rig.Gateways.InUse = GatewayModes.Test;                         // the gateway was switched to test since
        rig.State(Ref, openedMinutesAgo: 3, openedIn: GatewayModes.Live);   // this booking's first session was live
        // The earlier session: nothing was attempted on it.
        rig.Card.Setup(c => c.RetrieveOrderAsync(Ref, It.IsAny<CancellationToken>())).ReturnsAsync(MpgsOrderLookup.NotFound());
        rig.Deposits.Setup(d => d.StartPaymentAsync(Ref)).ReturnsAsync(new PaymentStarted
        {
            BookingId = 42, BookingRef = Ref, DepositDue = 30m, CurrencyCode = "USD", TotalAmount = 100m, BookDate = Now.Date, Hours = 2, RoomName = "Room",
        });
        rig.Card.Setup(c => c.InitiateCheckoutAsync(Ref, 30m, "USD", It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync("SESSION0002");

        var opening = await rig.Service.OpenAsync(Ref);

        // Two sessions in two modes would be the same order id at two merchants, and only one could ever be asked.
        Assert.Equal(PayOpenResult.Opened, opening.Result);
        Assert.All(rig.Gateways.CardModes, mode => Assert.Equal(GatewayModes.Live, mode));
        rig.Deposits.Verify(d => d.SetPaymentModeAsync(Ref, GatewayModes.Live), Times.Once);
        rig.Deposits.Verify(d => d.SetPaymentModeAsync(Ref, GatewayModes.Test), Times.Never);
    }

    /// <summary>Gateways whose keys are gone: every question is answered "not configured".</summary>
    private sealed class NoKeys : IPaymentGateways
    {
        public Task<MpgsOptions> CardAsync() => CardAsync(null);
        public Task<WhishOptions> WhishAsync() => WhishAsync(null);
        public Task<MpgsOptions> CardAsync(string? mode) => Task.FromResult(MpgsOptions.Missing("the keys were removed"));
        public Task<WhishOptions> WhishAsync(string? mode) => Task.FromResult(WhishOptions.Missing("the keys were removed"));
        public IMpgsClient CardClient(MpgsOptions options) => throw new InvalidOperationException("nobody to ask");
        public IWhishClient WhishClient(WhishOptions options) => throw new InvalidOperationException("nobody to ask");
        public Task<GatewayStatus> StatusAsync(string gateway) => throw new NotSupportedException();
        public void Refresh() { }
    }

    [Theory]
    [InlineData(45, true)]         // past the patience: staff are told, once
    [InlineData(12, false)]        // still within it: the job simply looks again
    public async Task A_payment_whose_keys_are_gone_is_not_left_waiting_for_ever_without_anybody_told(int openedMinutesAgo, bool alerted)
    {
        var deposits = new Mock<IOnlineDepositRepository>();
        deposits.Setup(d => d.GetPaymentStateAsync(Ref)).ReturnsAsync(new PaymentState
        {
            BookingId = 42, BookingRef = Ref, Status = "Pending", Source = "Website", DepositDue = 30m, CurrencyCode = "USD",
            PaymentOpenedUtc = Now.AddMinutes(-openedMinutesAgo), HoldExpiresUtc = Now.AddMinutes(5), GatewayOrderId = WhishOptions.AttemptId(Ref, 1),
        });
        deposits.Setup(d => d.GetPaymentModeAsync(Ref)).ReturnsAsync(GatewayModes.Live);
        deposits.Setup(d => d.QueuePaymentAlertAsync(42, OnlineDepositService.AlertUnconfirmed, It.IsAny<string?>())).ReturnsAsync(true);
        var bookings = new Mock<IBookingRepository>(MockBehavior.Strict);          // strict: nothing is released
        var log = new Store();
        var service = new OnlineDepositService(deposits.Object, bookings.Object, new NoKeys(),
            new OnlineDepositOptions { ReconcileAfterMinutes = 10, GiveUpAfterMinutes = 30 }, NullLogger<OnlineDepositService>.Instance,
            new FixedClock(Now), new PaymentEventLog(log, NullLogger<PaymentEventLog>.Instance));

        var settled = await service.SettleAsync(Ref, SettleTrigger.Reconciliation);

        Assert.Equal(SettlementResult.Unconfirmed, settled.Result);
        deposits.Verify(d => d.QueuePaymentAlertAsync(42, OnlineDepositService.AlertUnconfirmed, It.IsAny<string?>()), alerted ? Times.Once() : Times.Never());
        Assert.Equal(alerted ? [PaymentEvents.Checked, PaymentEvents.Alerted] : new[] { PaymentEvents.Checked }, log.Events.Select(e => e.EventType));

        // The guest's own return trip never e-mails anybody.
        deposits.Invocations.Clear();
        await service.SettleAsync(Ref, SettleTrigger.GatewayReturn);
        deposits.Verify(d => d.QueuePaymentAlertAsync(It.IsAny<int>(), It.IsAny<string>(), It.IsAny<string?>()), Times.Never);
    }

    [Fact]
    public async Task A_callbacks_token_and_a_returning_guest_are_judged_with_the_keys_of_the_mode_the_booking_was_opened_in()
    {
        var rig = new SettleRig();
        rig.Gateways.InUse = GatewayModes.Test;
        rig.Deposits.Setup(d => d.GetPaymentModeAsync(Ref)).ReturnsAsync(GatewayModes.Live);

        var forBooking = await rig.Service.WhishForAsync(Ref);

        Assert.Equal((GatewayModes.Live, WhishOptions.LiveBase), (forBooking.Mode, forBooking.BaseUrl));
        Assert.Equal(GatewayModes.Test, (await rig.Service.WhishAsync()).Mode);
    }

    private static PaymentDeskService Desk(Mock<IPaymentGatewayRepository> store, IWhishClient whish, IBookingService bookings, IRoomService? rooms = null)
        => new(store.Object, new RecordingGateways(Mock.Of<IMpgsClient>(), whish), Mock.Of<IOnlineDepositService>(), bookings,
            new PaymentEventLog(store.Object, NullLogger<PaymentEventLog>.Instance), new OnlineDepositOptions(), NullLogger<PaymentDeskService>.Instance, rooms);

    [Fact]
    public async Task No_answer_from_whish_is_never_reported_as_not_refunded()
    {
        var store = new Mock<IPaymentGatewayRepository>();
        var events = new List<PaymentEventEntry>();
        store.Setup(r => r.GetPaymentAsync(43, It.IsAny<int>())).ReturnsAsync(Paid());
        store.Setup(r => r.AddEventAsync(It.IsAny<PaymentEventEntry>())).Callback((PaymentEventEntry e) => events.Add(e)).Returns(Task.CompletedTask);
        var whish = new Mock<IWhishClient>(MockBehavior.Strict);
        whish.Setup(w => w.RefundAsync($"{Ref}-A1", "USD", It.IsAny<string>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(new WhishRefundResult(false, Problem: "timed out", Unknown: true));

        var result = await Desk(store, whish.Object, new Mock<IBookingService>(MockBehavior.Strict).Object).RefundAsync(43, null, 9);

        Assert.False(result!.Ok);
        Assert.Contains("NOT known whether the refund went through", result.Message);
        Assert.DoesNotContain("Nothing was changed", result.Message);
        Assert.Equal("Unknown", Assert.Single(events).Outcome);
    }

    [Fact]
    public async Task A_second_press_finds_the_refund_made_and_does_nothing()
    {
        var store = new Mock<IPaymentGatewayRepository>();
        // After the first refund the booking carries its refund line: that is what a second press reads.
        var refunded = Paid(extra: new PaymentLineRow { PaymentId = 2, Amount = -30m, IsRefund = true, Reference = PaymentDeskService.RefundReference($"{Ref}-A1") });
        store.SetupSequence(r => r.GetPaymentAsync(44, It.IsAny<int>())).ReturnsAsync(Paid()).ReturnsAsync(refunded).ReturnsAsync(refunded).ReturnsAsync(refunded);
        store.Setup(r => r.AddEventAsync(It.IsAny<PaymentEventEntry>())).Returns(Task.CompletedTask);
        var whish = new Mock<IWhishClient>(MockBehavior.Strict);
        whish.Setup(w => w.RefundAsync($"{Ref}-A1", "USD", It.IsAny<string>(), It.IsAny<CancellationToken>())).ReturnsAsync(new WhishRefundResult(true));
        var bookings = new Mock<IBookingService>();
        bookings.Setup(b => b.AddRefundAsync(44, It.IsAny<BookingRefundRequest>(), 9))
            .ReturnsAsync(new RefundOutcome { Added = new RefundAdded { PaymentId = 2 }, Method = new PaymentMethod { PaymentMethodId = 3, Name = "Whish" } });
        var desk = Desk(store, whish.Object, bookings.Object);

        // Two presses at once: one at a time, and the second reads the booking after the first.
        var both = await Task.WhenAll(desk.RefundAsync(44, null, 9), desk.RefundAsync(44, null, 9));

        Assert.Single(both, r => r!.Ok);
        Assert.Contains(both, r => !r!.Ok && r.Message.Contains("already refunded"));
        whish.Verify(w => w.RefundAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string>(), It.IsAny<CancellationToken>()), Times.Once);
        bookings.Verify(b => b.AddRefundAsync(44, It.IsAny<BookingRefundRequest>(), 9), Times.Once);
    }

    [Fact]
    public async Task What_could_stop_the_refund_reaching_the_books_is_checked_before_any_money_moves()
    {
        var store = new Mock<IPaymentGatewayRepository>();
        store.Setup(r => r.GetPaymentAsync(45, It.IsAny<int>())).ReturnsAsync(Paid());
        var whish = new Mock<IWhishClient>(MockBehavior.Strict);                  // strict: Whish is never asked
        var rooms = new Mock<IRoomService>();
        rooms.Setup(r => r.GetActivePaymentMethodsAsync()).ReturnsAsync([new PaymentMethod { PaymentMethodId = 1, Name = "Cash", IsActive = true }]);

        var result = await Desk(store, whish.Object, new Mock<IBookingService>(MockBehavior.Strict).Object, rooms.Object).RefundAsync(45, null, 9);

        Assert.False(result!.Ok);
        Assert.Contains("payment method \"Whish\" is switched off", result.Message);
    }

    [Fact]
    public async Task A_refund_asked_for_is_carried_through_even_when_the_browser_goes_away()
    {
        var store = new Mock<IPaymentGatewayRepository>();
        store.Setup(r => r.GetPaymentAsync(46, It.IsAny<int>())).ReturnsAsync(Paid());
        store.Setup(r => r.AddEventAsync(It.IsAny<PaymentEventEntry>())).Returns(Task.CompletedTask);
        var whish = new Mock<IWhishClient>(MockBehavior.Strict);
        CancellationToken seen = default;
        whish.Setup(w => w.RefundAsync($"{Ref}-A1", "USD", It.IsAny<string>(), It.IsAny<CancellationToken>()))
            .Callback((string _, string _, string _, CancellationToken token) => seen = token).ReturnsAsync(new WhishRefundResult(true));
        var bookings = new Mock<IBookingService>();
        bookings.Setup(b => b.AddRefundAsync(46, It.IsAny<BookingRefundRequest>(), 9))
            .ReturnsAsync(new RefundOutcome { Added = new RefundAdded { PaymentId = 2 }, Method = new PaymentMethod { PaymentMethodId = 3, Name = "Whish" } });

        using var request = new CancellationTokenSource();
        var result = await Desk(store, whish.Object, bookings.Object).RefundAsync(46, null, 9, request.Token);

        // Whish is not asked under the request's own token: between its "refunded" and the books nothing may stop.
        Assert.True(result!.Ok);
        Assert.False(seen.CanBeCanceled);
    }

    /// <summary>A database that answers a read only when told to: a read that is still on its way while a save happens.</summary>
    private sealed class SlowStore : IPaymentGatewayRepository
    {
        public TaskCompletionSource<GatewayStore> Pending { get; private set; } = new();
        public GatewayStore Next { get; set; } = GatewayStore.Empty;
        public bool Slow { get; set; }

        public Task<GatewayStore> GetGatewaysAsync() => Slow ? Pending.Task : Task.FromResult(Next);
        public Task SaveKeysAsync(string gateway, string mode, byte[] keysCipher, int? userId) => Task.CompletedTask;
        public Task DeleteKeysAsync(string gateway, string mode, int? userId) => Task.CompletedTask;
        public Task SetModeAsync(string gateway, string? mode, int? userId) => Task.CompletedTask;
        public Task<IReadOnlyList<GatewayHistoryRow>> GetHistoryAsync(int top) => Task.FromResult<IReadOnlyList<GatewayHistoryRow>>([]);
        public Task AddEventAsync(PaymentEventEntry entry) => Task.CompletedTask;
        public Task<IReadOnlyList<PaymentRow>> ListPaymentsAsync(DateTime fromUtc, DateTime toUtc, string? gateway, string? state, string? search, int giveUpMinutes) => Task.FromResult<IReadOnlyList<PaymentRow>>([]);
        public Task<PaymentDetail?> GetPaymentAsync(int bookingId, int giveUpMinutes) => Task.FromResult<PaymentDetail?>(null);
        public Task<GatewayTestRow?> AddTestAsync(string testRef, string gateway, string mode, decimal amount, string currency, string? returnUrl, int? userId) => Task.FromResult<GatewayTestRow?>(null);
        public Task<GatewayTestRow?> UpdateTestAsync(string testRef, GatewayTestChange change) => Task.FromResult<GatewayTestRow?>(null);
        public Task<GatewayTestDetail?> GetTestAsync(string testRef) => Task.FromResult<GatewayTestDetail?>(null);
        public Task<IReadOnlyList<GatewayTestRow>> ListTestsAsync(int top) => Task.FromResult<IReadOnlyList<GatewayTestRow>>([]);
    }

    [Fact]
    public async Task A_read_that_began_before_a_save_never_puts_the_old_settings_back()
    {
        var store = new SlowStore { Slow = true };
        var gateways = new PaymentGateways(store, new GatewayStoreCache(), Protector, MpgsOptions.Missing("none"), WhishOptions.Unconfigured, Origins,
            new NoHttp(), NullLoggerFactory.Instance, new FixedClock(Now));

        // A payment asks for the settings; the database is slow to answer.
        var early = gateways.WhishAsync();

        // Meanwhile an admin switches Whish to live and saves: what was read before is forgotten.
        var live = new GatewayStore(
            [new GatewayModeRow { Gateway = GatewayNames.Whish, ActiveMode = GatewayModes.Live }],
            [new GatewayKeysRow { Gateway = GatewayNames.Whish, Mode = GatewayModes.Live, KeysCipher = Protector.Protect(GatewayNames.Whish, GatewayModes.Live, WhishLiveKeys), ModifiedAtUtc = Now }]);
        gateways.Refresh();

        // The slow read comes back with the settings from BEFORE the save.
        store.Pending.SetResult(GatewayStore.Empty);
        Assert.False((await early).IsConfigured);

        // The next question must be answered from the database as it is now, not from that old answer.
        store.Slow = false;
        store.Next = live;
        Assert.Equal(GatewayModes.Live, (await gateways.WhishAsync()).Mode);
    }

    /* ---- what guests can do on the website -------------------------------------------------------- */

    [Fact]
    public async Task Whish_is_offered_to_guests_only_when_its_keys_are_there()
    {
        var rig = new AdminRig();

        var noKeys = await rig.Service.SetWebsiteAsync(null, true, 7);
        Assert.False(noKeys.Ok);
        Assert.Contains("Save the Whish keys first", noKeys.Message);
        Assert.Equal("0", rig.Switches[WhishOptions.EnabledSetting]);

        await rig.SaveWhish(GatewayModes.Test, WhishTestKeys);
        var on = await rig.Service.SetWebsiteAsync(null, true, 7);
        Assert.True(on.Ok);
        Assert.Equal("1", rig.Switches[WhishOptions.EnabledSetting]);
        Assert.Contains("only see it once the deposit is taken online", on.Message);      // the other switch is still off

        // Deposits on: with Whish offered and ready, a gateway is ready.
        Assert.True((await rig.Service.SetWebsiteAsync(true, null, 7)).Ok);
        Assert.Equal("1", rig.Switches[GatewayAdminService.DepositsSetting]);

        // And off again, always allowed.
        Assert.True((await rig.Service.SetWebsiteAsync(false, false, 7)).Ok);
        Assert.Equal(("0", "0"), (rig.Switches[GatewayAdminService.DepositsSetting], rig.Switches[WhishOptions.EnabledSetting]));
    }

    [Fact]
    public async Task Deposits_are_not_taken_online_while_no_gateway_is_ready()
    {
        var rig = new AdminRig();
        var refused = await rig.Service.SetWebsiteAsync(true, null, 7);
        Assert.False(refused.Ok);
        Assert.Contains("No gateway is ready", refused.Message);
        Assert.Equal("0", rig.Switches[GatewayAdminService.DepositsSetting]);
    }

    [Fact]
    public async Task On_the_live_system_guests_are_never_offered_a_gateway_in_test_mode()
    {
        // The live system, with the bank's TEST profile in the server file and Whish's test keys saved.
        var rig = new AdminRig(ServerCard, production: true);
        await rig.SaveWhish(GatewayModes.Test, WhishTestKeys);

        // A test payment costs nothing and would confirm a real booking: neither switch goes on.
        Assert.Contains("TEST mode", (await rig.Service.SetWebsiteAsync(null, true, 7)).Message);
        Assert.Contains("Bank of Beirut is in TEST mode", (await rig.Service.SetWebsiteAsync(true, null, 7)).Message);
        Assert.Equal(("0", "0"), (rig.Switches[GatewayAdminService.DepositsSetting], rig.Switches[WhishOptions.EnabledSetting]));

        // The same choices on the test side are fine: that is what it is for.
        var test = new AdminRig(ServerCard, production: false);
        await test.SaveWhish(GatewayModes.Test, WhishTestKeys);
        Assert.True((await test.Service.SetWebsiteAsync(true, true, 7)).Ok);
    }

    [Fact]
    public async Task On_the_live_system_a_gateway_guests_pay_with_cannot_be_put_into_test_mode()
    {
        var rig = new AdminRig(production: true);
        await rig.SaveWhish(GatewayModes.Test, WhishTestKeys);
        await rig.SaveWhish(GatewayModes.Live, WhishLiveKeys);
        Assert.True((await rig.Service.SetModeAsync(GatewayNames.Whish, GatewayModes.Live, 7)).Ok);
        Assert.True((await rig.Service.SetWebsiteAsync(true, true, 7)).Ok);           // live, offered to guests

        var refused = await rig.Service.SetModeAsync(GatewayNames.Whish, GatewayModes.Test, 7);
        Assert.False(refused.Ok);
        Assert.Contains("Turn off", refused.Message);
        Assert.Equal(GatewayModes.Live, (await rig.Real.WhishAsync()).Mode);

        // Taken off the website first, it can be tested again.
        Assert.True((await rig.Service.SetWebsiteAsync(null, false, 7)).Ok);
        Assert.True((await rig.Service.SetModeAsync(GatewayNames.Whish, GatewayModes.Test, 7)).Ok);
    }
}
