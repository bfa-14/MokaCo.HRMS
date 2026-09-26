using System.Globalization;

namespace MokaCo.HRMS.Services.Booking.Payments;

/// <summary>
/// The payment gateway (Mastercard Payment Gateway Services, Bank of Beirut) and the two public
/// origins its redirects point at — read from the ENVIRONMENT, never from a tracked file.
///
/// Production sets these in /etc/mokaco/api.env; a developer puts them in the gitignored
/// appsettings.Local.json (top-level keys, same names). THE API DOES NOT START WITHOUT THEM
/// (<see cref="FromSettings"/> throws naming the missing keys, never a value): a booking site that
/// silently cannot take a deposit is worse than a service that refuses to boot.
///
/// THE 3-D SECURE BYPASS. The test profiles carry only retired 3DS1 schemes, so every
/// authentication attempt fails and poisons the payment; the website's proven flow
/// (mokanco-lb functions/api/booking.js) sends interaction.action.3DSecure = BYPASS in test. Here it
/// is sent only when BOTH the merchant id is a TEST profile (TESTMOKANDCO) AND the developer flag
/// <see cref="TestBypassKey"/> is on. Production's merchant (MOKANDCO) can never send it whatever
/// the flag says, and production's api.env carries no such flag at all. 3DS shifts fraud liability
/// to the issuer; skipping it on a live merchant would move it back to the café.
/// </summary>
public sealed class MpgsOptions
{
    public const string BaseKey = "MPGS_BASE";
    public const string MerchantIdKey = "MPGS_MERCHANT_ID";
    public const string ApiPasswordKey = "MPGS_API_PASSWORD";
    public const string ApiVersionKey = "MPGS_API_VERSION";
    public const string SiteUrlKey = "BOOKING_SITE_URL";
    public const string ApiPublicUrlKey = "API_PUBLIC_URL";

    /// <summary>Developer-only. Honoured for a TEST merchant profile and ignored for any other.</summary>
    public const string TestBypassKey = "MPGS_TEST_3DS_BYPASS";

    /// <summary>The prefix the gateway gives its test merchant profiles.</summary>
    public const string TestProfilePrefix = "TEST";

    /// <summary>e.g. https://test-bobsal.gateway.mastercard.com — no trailing slash.</summary>
    public string BaseUrl { get; init; } = string.Empty;

    /// <summary>TESTMOKANDCO in test, MOKANDCO live.</summary>
    public string MerchantId { get; init; } = string.Empty;

    public string ApiPassword { get; init; } = string.Empty;

    /// <summary>The REST API version in the URL. 73 is what the website's proven flow uses.</summary>
    public int ApiVersion { get; init; }

    /// <summary>The website's origin the guest is sent back to, e.g. https://mokanco.com.lb.</summary>
    public string SiteUrl { get; init; } = string.Empty;

    /// <summary>This API's public origin, e.g. https://api.mokanco.com.lb — the gateway's returnUrl points here.</summary>
    public string ApiPublicUrl { get; init; } = string.Empty;

    /// <summary>The raw developer flag. Read <see cref="SendsThreeDsBypass"/>, never this.</summary>
    public bool TestBypassRequested { get; init; }

    public bool IsTestProfile => MerchantId.StartsWith(TestProfilePrefix, StringComparison.OrdinalIgnoreCase);

    /// <summary>TEST profile AND the flag. The only place that decides it.</summary>
    public bool SendsThreeDsBypass => IsTestProfile && TestBypassRequested;

    /// <summary>
    /// Reads and checks every value. Throws <see cref="InvalidOperationException"/> listing EVERY
    /// missing or malformed key by name, so one failed start tells the whole story. Values never
    /// appear in the message.
    /// </summary>
    public static MpgsOptions FromSettings(Func<string, string?> read)
    {
        var problems = new List<string>();

        string Required(string key)
        {
            var value = read(key)?.Trim();
            if (string.IsNullOrEmpty(value))
                problems.Add($"{key} is missing");
            return value ?? string.Empty;
        }

        string Origin(string key)
        {
            var value = Required(key).TrimEnd('/');
            if (value.Length > 0 && (!Uri.TryCreate(value, UriKind.Absolute, out var uri)
                                     || (uri.Scheme != Uri.UriSchemeHttps && uri.Scheme != Uri.UriSchemeHttp)))
                problems.Add($"{key} must be an absolute http(s) URL");
            return value;
        }

        var baseUrl = Origin(BaseKey);
        if (baseUrl.StartsWith("http://", StringComparison.OrdinalIgnoreCase))
            problems.Add($"{BaseKey} must be https");

        var merchant = Required(MerchantIdKey);
        var password = Required(ApiPasswordKey);

        var versionText = Required(ApiVersionKey);
        var version = 0;
        if (versionText.Length > 0 && (!int.TryParse(versionText, NumberStyles.None, CultureInfo.InvariantCulture, out version) || version <= 0))
            problems.Add($"{ApiVersionKey} must be a whole number such as 73");

        var site = Origin(SiteUrlKey);
        var api = Origin(ApiPublicUrlKey);

        if (problems.Count > 0)
            throw new InvalidOperationException(
                "Online deposits (MPGS) are not configured: " + string.Join("; ", problems) +
                ". Set them in /etc/mokaco/api.env (production) or appsettings.Local.json (development); " +
                "see appsettings.Local.example.json.");

        return new MpgsOptions
        {
            BaseUrl = baseUrl,
            MerchantId = merchant,
            ApiPassword = password,
            ApiVersion = version,
            SiteUrl = site,
            ApiPublicUrl = api,
            TestBypassRequested = IsOn(read(TestBypassKey)),
        };
    }

    private static bool IsOn(string? value)
        => value?.Trim().ToLowerInvariant() is "1" or "true" or "yes" or "on";

    /* ---- where the guest is sent ---------------------------------------------------------- */

    /// <summary>The gateway's returnUrl: this API's verifier, which asks the gateway and redirects.</summary>
    public string VerifyUrl(string bookingRef) => $"{ApiPublicUrl}/api/public/booking/verify?ref={Uri.EscapeDataString(bookingRef)}";

    public string ConfirmedUrl(string bookingRef) => $"{SiteUrl}/reservations/confirmed/?ref={Uri.EscapeDataString(bookingRef)}";

    public string CancelledUrl() => $"{SiteUrl}/reservations/?payment=cancelled";

    public string FailedUrl() => $"{SiteUrl}/reservations/?payment=failed";

    /// <summary>Outcome unknown: the guest must NOT be told nothing was charged, and must not be nudged to pay again.</summary>
    public string UnconfirmedUrl(string bookingRef) => $"{SiteUrl}/reservations/?payment=unconfirmed&ref={Uri.EscapeDataString(bookingRef)}";

    /// <summary>Everything but the password.</summary>
    public override string ToString()
        => $"MPGS {BaseUrl} v{ApiVersion} merchant {MerchantId}{(SendsThreeDsBypass ? " (TEST, 3DS BYPASS)" : IsTestProfile ? " (TEST)" : string.Empty)}; site {SiteUrl}; api {ApiPublicUrl}";
}

/// <summary>
/// The reconciliation job's clock, from configuration section "OnlineDeposits" (not secrets; the
/// defaults are the intended values). Environment override: OnlineDeposits__ReconcileEveryMinutes.
/// </summary>
public sealed class OnlineDepositOptions
{
    public const string Section = "OnlineDeposits";

    /// <summary>How often the job runs.</summary>
    public int ReconcileEveryMinutes { get; set; } = 5;

    /// <summary>
    /// A payment opened at least this long ago with no settled outcome is asked about. Kept BELOW
    /// BookingHoldMinutes (15) so the first check — which keeps the hold alive when the answer is
    /// "not yet" — lands before the hold lapses and the slot is offered to somebody else.
    /// </summary>
    public int ReconcileAfterMinutes { get; set; } = 10;

    /// <summary>
    /// Before this age the job only waits (the guest may still be on the gateway's page, even retrying
    /// after a decline). From this age: an order the gateway never saw, or a failed one, is released;
    /// one it still cannot confirm is reported to staff (once) and keeps its hold.
    /// </summary>
    public int GiveUpAfterMinutes { get; set; } = 30;

    public void Validate()
    {
        if (ReconcileEveryMinutes < 1 || ReconcileAfterMinutes < 1 || GiveUpAfterMinutes < ReconcileAfterMinutes)
            throw new InvalidOperationException(
                $"{Section}: ReconcileEveryMinutes and ReconcileAfterMinutes must be at least 1, and GiveUpAfterMinutes at least ReconcileAfterMinutes.");
    }
}
