using System.Buffers.Text;
using System.Diagnostics.CodeAnalysis;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace MokaCo.HRMS.Services.Security.Gate;

/// <summary>
/// What a gate cookie says (docs/GOOGLE_SIGNIN_GATE.md §3), with the JSON names it travels under:
/// the person (Kind "e" + EmployeeId, or "x" + GateExtraEmailId), the Google email, when it was issued,
/// when it ends (unix seconds) and the sign-out epoch it belongs to.
///
/// TWO MORE THAN §3 LISTS, so a cookie stops when what it proved stops being true:
///   en   the person's stored address, normalised, as usp_Gate_SignIn gave it — an admin who corrects an
///        employee's Gmail or edits an extra address ends the old address's cookies;
///   aud  the Google client ID the sign-in was made with — a new client ID needs a new test sign-in
///        before the switch can go on, so a mistyped one cannot lock everybody else out.
/// </summary>
public sealed record GateCookiePayload(
    [property: JsonPropertyName("k")] string Kind,
    [property: JsonPropertyName("id")] int PersonId,
    [property: JsonPropertyName("em")] string Email,
    [property: JsonPropertyName("en")] string? EmailNorm,
    [property: JsonPropertyName("aud")] string? ClientId,
    [property: JsonPropertyName("iat")] long IssuedAt,
    [property: JsonPropertyName("exp")] long ExpiresAt,
    [property: JsonPropertyName("ep")] int Epoch);

/// <summary>
/// The gate cookie's value: v1.&lt;b64url(json)&gt;.&lt;b64url(HMACSHA256(key, "v1." + b64json))&gt;.
///
/// SIGNED, NOT ENCRYPTED. It holds nothing secret — who signed in and when — and the browser cannot
/// read it anyway (HttpOnly). What matters is that nobody can write one: the signature is checked
/// before the JSON is even parsed, and compared in constant time.
///
/// THE COOKIE IS NEVER TRUSTED ON ITS OWN. A valid one still has to pass the settings of the moment:
/// the epoch ("sign everyone out" moves it on), and the number of days, so shortening GoogleSignInDays
/// also shortens the cookies already out there. Whether the person is still allowed — with the same
/// address, under the same client ID — is the caller's question (GateSnapshot.Admits), asked of the
/// current allowed list on every request.
/// </summary>
public static class GateCookie
{
    public const string Version = "v1";
    public const int SecondsPerDay = 86400;

    /// <summary>Anything longer is not ours: a real value is a few hundred characters, and a browser caps a cookie at 4 KB.</summary>
    public const int MaxLength = 4096;

    private const string KeyLabel = "mokaco-gate-cookie-v1";

    /// <summary>
    /// HMACSHA256(key: UTF8(Jwt:SecretKey), data: UTF8("mokaco-gate-cookie-v1")). Derived rather than a
    /// new secret in api.env; production and the test API have different JWT keys, so a cookie from one
    /// is refused by the other — which matters, because both answer on the same host.
    /// </summary>
    public static byte[] DeriveKey(string jwtSecretKey)
        => HMACSHA256.HashData(Encoding.UTF8.GetBytes(jwtSecretKey), Encoding.UTF8.GetBytes(KeyLabel));

    /// <summary>A payload issued now that ends after <paramref name="days"/>.</summary>
    public static GateCookiePayload Create(
        string kind, int personId, string email, string? emailNorm, string clientId, long nowUnix, int days, int epoch)
        => new(kind, personId, email, emailNorm, clientId, nowUnix, nowUnix + (long)days * SecondsPerDay, epoch);

    public static string Issue(GateCookiePayload payload, ReadOnlySpan<byte> key)
    {
        var body = Base64Url.EncodeToString(JsonSerializer.SerializeToUtf8Bytes(payload));
        return $"{Version}.{body}.{Sign(body, key)}";
    }

    /// <summary>
    /// True only if the value is ours and still good now: the format, the signature, now before the
    /// end, now before issued + <paramref name="days"/>, and the cookie's epoch equal to <paramref name="epoch"/>.
    /// Never throws: anything else a browser sends is simply not valid.
    /// </summary>
    public static bool TryRead(
        string? value, ReadOnlySpan<byte> key, long nowUnix, int days, int epoch,
        [NotNullWhen(true)] out GateCookiePayload? payload)
    {
        payload = null;
        if (string.IsNullOrEmpty(value) || value.Length > MaxLength || days < 1)
            return false;

        var parts = value.Split('.');
        if (parts.Length != 3 || parts[0] != Version || parts[1].Length == 0)
            return false;

        // The signature first: JSON nobody signed is never parsed.
        if (!CryptographicOperations.FixedTimeEquals(
                Encoding.UTF8.GetBytes(Sign(parts[1], key)), Encoding.UTF8.GetBytes(parts[2])))
            return false;

        GateCookiePayload? read;
        try
        {
            read = JsonSerializer.Deserialize<GateCookiePayload>(Base64Url.DecodeFromChars(parts[1]));
        }
        catch (Exception ex) when (ex is FormatException or JsonException)
        {
            return false;
        }

        if (read is null || read.Kind is not ("e" or "x") || read.PersonId <= 0 || string.IsNullOrEmpty(read.Email))
            return false;

        if (nowUnix >= read.ExpiresAt || nowUnix >= read.IssuedAt + (long)days * SecondsPerDay || read.Epoch != epoch)
            return false;

        payload = read;
        return true;
    }

    /// <summary>
    /// Compared as TEXT, not as decoded bytes: a lenient base64 decoder ignores the spare bits of the
    /// last character, so two different strings could decode to the same signature. Re-encoding ours
    /// and comparing the strings leaves exactly one value that passes, whatever the decoder.
    /// </summary>
    private static string Sign(string body, ReadOnlySpan<byte> key)
        => Base64Url.EncodeToString(HMACSHA256.HashData(key, Encoding.UTF8.GetBytes($"{Version}.{body}")));
}

/// <summary>
/// The gate cookie on the wire: mokaco_gate=&lt;value&gt;; Max-Age=&lt;days × 86400&gt;; Path=/; Secure;
/// HttpOnly; SameSite=Lax. Written as a raw Set-Cookie so it comes out exactly so.
///
/// SECURE ALWAYS, never decided from the request: behind nginx the API itself is spoken to over plain
/// http, so "secure when the request was https" would quietly mean never. Lax, not Strict, so a link
/// to the HRMS from an email or WhatsApp opens signed in.
/// </summary>
public static class GateCookieOptions
{
    public const string Name = "mokaco_gate";

    /// <summary>The header that sets <paramref name="value"/> for <paramref name="days"/> days.</summary>
    public static string SetCookie(string value, int days) => Header(value, (long)days * GateCookie.SecondsPerDay);

    /// <summary>The header that removes the cookie (sign this browser out).</summary>
    public static string Expired { get; } = Header(string.Empty, 0);

    private static string Header(string value, long maxAgeSeconds)
        => $"{Name}={value}; Max-Age={maxAgeSeconds}; Path=/; Secure; HttpOnly; SameSite=Lax";
}
