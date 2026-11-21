using System.Security.Cryptography;
using System.Text;

namespace MokaCo.HRMS.Services.Booking.Payments;

/// <summary>
/// WHISH PAY (doc v2.0.0), the second way to pay a booking deposit. Its three credentials and base URL come from
/// the environment - /etc/mokaco/api.env in production, the gitignored appsettings.Local.json in development -
/// NEVER from a tracked file, the database or a chat:
///
///   WHISH_BASE          https://api.whish.money/itel-service/api (live)
///                       https://partner.api.sbx.whish.money/itel-service/api (sandbox)
///   WHISH_CHANNEL       issued by Whish
///   WHISH_SECRET        issued by Whish
///   WHISH_WEBSITE_URL   the EXACT value Whish issued with the keys (it is compared, not resolved)
///
/// plus the two public origins the card flow already uses: BOOKING_SITE_URL (where the guest is sent back) and
/// API_PUBLIC_URL (where Whish calls back). All of them present and well-formed = configured; anything missing =
/// not configured, which is an ordinary state (Whish simply is not offered) and never stops the start.
///
/// Nothing here is ever logged except <see cref="ToString"/>, which names the host and never a credential.
/// </summary>
public sealed class WhishOptions
{
    public const string BaseKey = "WHISH_BASE";
    public const string ChannelKey = "WHISH_CHANNEL";
    public const string SecretKey = "WHISH_SECRET";
    public const string WebsiteUrlKey = "WHISH_WEBSITE_URL";

    /// <summary>The setting that offers Whish on the website (script 118). Off by default.</summary>
    public const string EnabledSetting = "BookingWhishEnabled";

    /// <summary>Whish asks for "AppName/version (website; contact-email)", our own details.</summary>
    public const string UserAgent = "MokaCoHRMS/1.0 (https://mokanco.com.lb; bookings@mokanco.com.lb)";

    /// <summary>A Whish payment link allows one attempt and lives five minutes.</summary>
    public static readonly TimeSpan LinkLifetime = TimeSpan.FromMinutes(5);

    /// <summary>How long after the link's end a still-"pending" attempt is taken for what it is: never paid.</summary>
    public static readonly TimeSpan LinkGrace = TimeSpan.FromMinutes(1);

    public string BaseUrl { get; init; } = string.Empty;
    public string Channel { get; init; } = string.Empty;
    public string Secret { get; init; } = string.Empty;
    public string WebsiteUrl { get; init; } = string.Empty;
    public string SiteUrl { get; init; } = string.Empty;
    public string ApiPublicUrl { get; init; } = string.Empty;

    public bool IsConfigured { get; init; }

    /// <summary>Why it is not configured, naming keys and never values. Null when it is, or when no Whish key is set at all.</summary>
    public string? Problem { get; init; }

    public static WhishOptions Unconfigured { get; } = new();

    public static WhishOptions FromSettings(Func<string, string?> read)
    {
        string Get(string key) => read(key)?.Trim() ?? string.Empty;

        var baseUrl = Get(BaseKey).TrimEnd('/');
        var channel = Get(ChannelKey);
        var secret = Get(SecretKey);
        var website = Get(WebsiteUrlKey);

        // No Whish key at all: Whish is simply not used here. Nothing to report.
        if (baseUrl.Length == 0 && channel.Length == 0 && secret.Length == 0 && website.Length == 0)
            return Unconfigured;

        var site = Get(MpgsOptions.SiteUrlKey).TrimEnd('/');
        var api = Get(MpgsOptions.ApiPublicUrlKey).TrimEnd('/');
        var problems = new List<string>();

        void Need(string key, string value)
        {
            if (value.Length == 0) problems.Add($"{key} is missing");
        }

        void Origin(string key, string value, bool httpsOnly)
        {
            if (value.Length == 0) { problems.Add($"{key} is missing"); return; }
            if (!Uri.TryCreate(value, UriKind.Absolute, out var uri) || (uri.Scheme != Uri.UriSchemeHttps && uri.Scheme != Uri.UriSchemeHttp))
                problems.Add($"{key} must be an absolute http(s) URL");
            // The secret travels in a header of every call: https, except to a stand-in on this machine (a test double).
            else if (httpsOnly && uri.Scheme != Uri.UriSchemeHttps && !uri.IsLoopback)
                problems.Add($"{key} must be https");
        }

        Origin(BaseKey, baseUrl, httpsOnly: true);
        Need(ChannelKey, channel);
        Need(SecretKey, secret);
        Need(WebsiteUrlKey, website);
        Origin(MpgsOptions.SiteUrlKey, site, httpsOnly: false);
        Origin(MpgsOptions.ApiPublicUrlKey, api, httpsOnly: false);

        if (problems.Count > 0)
            return new WhishOptions
            {
                Problem = "Whish deposits are not configured: " + string.Join("; ", problems) +
                          ". Set them in /etc/mokaco/api.env (production) or appsettings.Local.json (development).",
            };

        return new WhishOptions
        {
            BaseUrl = baseUrl, Channel = channel, Secret = secret, WebsiteUrl = website,
            SiteUrl = site, ApiPublicUrl = api, IsConfigured = true,
        };
    }

    /* ---- the ids and the addresses ------------------------------------------------------------ */

    /// <summary>True for the id of a Whish attempt on <paramref name="bookingRef"/>: "MC-K7Q2M9PW-A3". The bare reference is a card order.</summary>
    public static bool IsAttemptId(string? gatewayOrderId, string bookingRef)
        => AttemptNumber(gatewayOrderId, bookingRef) is not null;

    public static int? AttemptNumber(string? gatewayOrderId, string bookingRef)
    {
        var prefix = bookingRef + "-A";
        if (gatewayOrderId is null || !gatewayOrderId.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) return null;
        return int.TryParse(gatewayOrderId.AsSpan(prefix.Length), System.Globalization.NumberStyles.None,
            System.Globalization.CultureInfo.InvariantCulture, out var number) && number >= 1 ? number : null;
    }

    public static string AttemptId(string bookingRef, int attempt) => $"{bookingRef}-A{attempt}";

    /// <summary>
    /// What the callback address carries beside the reference. Whish adds nothing of its own and forwards ours, so
    /// anybody can call the address: the token only keeps junk from making us ask Whish about a booking. It proves
    /// nothing about a payment - the status call does. Derived from the secret, so nothing is stored.
    /// </summary>
    public string CallbackToken(string bookingRef)
    {
        var mac = HMACSHA256.HashData(Encoding.UTF8.GetBytes(Secret), Encoding.UTF8.GetBytes("whish-callback:" + bookingRef.ToUpperInvariant()));
        return Convert.ToHexString(mac)[..24].ToLowerInvariant();
    }

    public bool IsCallbackToken(string bookingRef, string? token)
        => IsConfigured && token is not null
           && CryptographicOperations.FixedTimeEquals(Encoding.ASCII.GetBytes(CallbackToken(bookingRef)), Encoding.ASCII.GetBytes(token.Trim().ToLowerInvariant()));

    /// <summary>The server-to-server signal (both the success and the failure one: each only triggers a status check).</summary>
    public string CallbackUrl(string bookingRef)
        => $"{ApiPublicUrl}/api/public/booking/whish/callback?ref={Uri.EscapeDataString(bookingRef)}&t={CallbackToken(bookingRef)}";

    /// <summary>Where Whish's page sends the payer's browser (both outcomes: the answer comes from the status call).</summary>
    public string ReturnUrl(string bookingRef)
        => $"{ApiPublicUrl}/api/public/booking/whish/return?ref={Uri.EscapeDataString(bookingRef)}";

    /* The same three places on the website the card flow sends the guest to. */
    public string ConfirmedUrl(string bookingRef) => $"{SiteUrl}/reservations/confirmed/?ref={Uri.EscapeDataString(bookingRef)}";
    public string FailedUrl() => $"{SiteUrl}/reservations/?payment=failed";
    public string UnconfirmedUrl(string bookingRef) => $"{SiteUrl}/reservations/?payment=unconfirmed&ref={Uri.EscapeDataString(bookingRef)}";

    public override string ToString()
        => !IsConfigured ? "Whish not configured"
         : $"Whish {BaseUrl}{(BaseUrl.Contains(".sbx.", StringComparison.OrdinalIgnoreCase) ? " (SANDBOX)" : string.Empty)}; site {SiteUrl}; api {ApiPublicUrl}";
}
