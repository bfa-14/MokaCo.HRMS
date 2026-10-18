using System.Buffers.Text;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using MokaCo.HRMS.Services.Security.Gate;

namespace MokaCo.HRMS.Tests.Security.Gate;

/// <summary>
/// The gate cookie of docs/GOOGLE_SIGNIN_GATE.md §3: v1.&lt;b64url(json)&gt;.&lt;b64url(HMAC)&gt;, valid only
/// when the format, the signature, the end, issued + days and the epoch all agree — and never an
/// exception, whatever a browser sends.
/// </summary>
public class GateCookieTests
{
    private static readonly byte[] Key = GateCookie.DeriveKey("production-jwt-secret-0123456789-abcdef");
    private static readonly byte[] TestApiKey = GateCookie.DeriveKey("test-api-jwt-secret-0123456789-abcdef");

    private const long T0 = 1_790_000_000;   // a fixed "now", unix seconds
    private const int Days = 30;
    private const int Epoch = 3;
    private const long Day = 86400;
    private const string ClientId = "123456789-abcdef.apps.googleusercontent.com";

    private static string Issue(long issuedAt = T0, int days = Days, int epoch = Epoch, string kind = "e", int id = 12, string email = "Rana.Haddad@gmail.com")
        => GateCookie.Issue(GateCookie.Create(kind, id, email, "ranahaddad@gmail.com", ClientId, issuedAt, days, epoch), Key);

    private static bool Read(string? value, long now = T0 + 60, int days = Days, int epoch = Epoch, byte[]? key = null)
        => GateCookie.TryRead(value, key ?? Key, now, days, epoch, out _);

    /// <summary>A body signed exactly as §3 says: HMACSHA256(key, "v1." + body), base64url.</summary>
    private static string SignedBody(string body)
        => $"v1.{body}.{Base64Url.EncodeToString(HMACSHA256.HashData(Key, Encoding.UTF8.GetBytes("v1." + body)))}";

    /* ---- round trip and format ---- */

    [Fact]
    public void A_cookie_reads_back_what_was_issued()
    {
        Assert.True(GateCookie.TryRead(Issue(), Key, T0 + 60, Days, Epoch, out var payload));

        Assert.Equal(new GateCookiePayload("e", 12, "Rana.Haddad@gmail.com", "ranahaddad@gmail.com", ClientId, T0, T0 + Days * Day, Epoch), payload);
    }

    [Fact]
    public void A_signed_body_without_en_and_aud_reads_them_as_null()
    {
        // The §3 shape alone: such a cookie is ours, but GateSnapshot.Admits will not let it through.
        var body = Base64Url.EncodeToString(Encoding.UTF8.GetBytes(
            $"{{\"k\":\"e\",\"id\":12,\"em\":\"rana@gmail.com\",\"iat\":{T0},\"exp\":{T0 + Day},\"ep\":{Epoch}}}"));

        Assert.True(GateCookie.TryRead(SignedBody(body), Key, T0 + 60, Days, Epoch, out var payload));
        Assert.Null(payload.EmailNorm);
        Assert.Null(payload.ClientId);
    }

    [Fact]
    public void An_extra_address_cookie_reads_back_too()
    {
        Assert.True(GateCookie.TryRead(Issue(kind: "x", id: 3, email: "owner@gmail.com"), Key, T0, Days, Epoch, out var payload));
        Assert.Equal(("x", 3), (payload.Kind, payload.PersonId));
    }

    [Fact]
    public void The_value_is_v1_dot_base64url_json_dot_base64url_hmac_with_the_spec_names_plus_en_and_aud()
    {
        var parts = Issue().Split('.');

        Assert.Equal(3, parts.Length);
        Assert.Equal("v1", parts[0]);
        Assert.DoesNotContain('=', parts[1] + parts[2]);

        using var json = JsonDocument.Parse(Base64Url.DecodeFromChars(parts[1]));
        Assert.Equal(["k", "id", "em", "en", "aud", "iat", "exp", "ep"], json.RootElement.EnumerateObject().Select(p => p.Name));
        Assert.Equal("e", json.RootElement.GetProperty("k").GetString());
        Assert.Equal("ranahaddad@gmail.com", json.RootElement.GetProperty("en").GetString());
        Assert.Equal(ClientId, json.RootElement.GetProperty("aud").GetString());
        Assert.Equal(T0 + Days * Day, json.RootElement.GetProperty("exp").GetInt64());

        // The signature is HMACSHA256(key, "v1." + body), nothing else.
        Assert.Equal(SignedBody(parts[1]), Issue());
    }

    [Fact]
    public void The_key_is_hmac_of_the_jwt_secret_over_the_label()
    {
        var expected = HMACSHA256.HashData(Encoding.UTF8.GetBytes("s3cret"), Encoding.UTF8.GetBytes("mokaco-gate-cookie-v1"));
        Assert.Equal(expected, GateCookie.DeriveKey("s3cret"));
    }

    /* ---- tampering ---- */

    [Theory]
    [InlineData(0)]
    [InlineData(1)]
    [InlineData(2)]
    public void Changing_any_character_of_any_part_refuses_it(int part)
    {
        var parts = Issue().Split('.');
        for (var i = 0; i < parts[part].Length; i++)
        {
            var changed = (string[])parts.Clone();
            var chars = changed[part].ToCharArray();
            chars[i] = chars[i] == 'A' ? 'B' : 'A';
            changed[part] = new string(chars);

            Assert.False(Read(string.Join('.', changed)), $"part {part}, character {i}");
        }
    }

    [Fact]
    public void A_signature_spelled_differently_in_its_spare_bits_is_refused()
    {
        // 32 bytes are 43 base64 characters with 2 spare bits in the last one; flip one of those. A
        // lenient decoder would read the same bytes — the signature is compared as text, so it is refused.
        const string alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
        var value = Issue();
        var twin = alphabet[alphabet.IndexOf(value[^1]) ^ 1];

        Assert.False(Read(value[..^1] + twin));
    }

    [Fact]
    public void Another_cookies_body_under_this_signature_is_refused()
    {
        var mine = Issue().Split('.');
        var theirs = Issue(id: 99).Split('.');

        Assert.False(Read($"v1.{theirs[1]}.{mine[2]}"));
        Assert.False(Read($"v1.{mine[1]}.{theirs[2]}"));
    }

    [Fact]
    public void A_cookie_signed_with_another_key_is_refused()
    {
        var fromTestApi = GateCookie.Issue(GateCookie.Create("e", 12, "rana@gmail.com", "rana@gmail.com", ClientId, T0, Days, Epoch), TestApiKey);

        Assert.False(Read(fromTestApi));
        Assert.True(Read(fromTestApi, key: TestApiKey));
    }

    [Fact]
    public void A_signed_body_that_is_not_a_person_is_refused()
    {
        Assert.False(Read(Issue(kind: "a")));
        Assert.False(Read(Issue(kind: "E")));
        Assert.False(Read(Issue(id: 0)));
        Assert.False(Read(Issue(email: "")));
    }

    [Fact]
    public void A_signed_body_that_is_not_json_is_refused_without_throwing()
    {
        Assert.False(Read(SignedBody(Base64Url.EncodeToString("not json"u8))));
        Assert.False(Read(SignedBody(Base64Url.EncodeToString("{\"k\":\"e\",\"id\":\"12\"}"u8))));
        Assert.False(Read(SignedBody("***")));   // signed, but not base64url
    }

    /* ---- time, days and epoch ---- */

    [Fact]
    public void It_ends_at_exp()
    {
        var end = T0 + Days * Day;
        Assert.True(Read(Issue(), now: end - 1));
        Assert.False(Read(Issue(), now: end));
        Assert.False(Read(Issue(), now: end + 3600));
    }

    [Fact]
    public void Shortening_the_days_after_issue_shortens_the_cookies_already_out()
    {
        var cookie = Issue(days: 30);

        Assert.True(Read(cookie, now: T0 + 6 * Day, days: 7));
        Assert.False(Read(cookie, now: T0 + 7 * Day, days: 7));
        Assert.False(Read(cookie, now: T0 + 8 * Day, days: 7));

        // Lengthening it later does not extend a cookie past its own exp.
        Assert.False(Read(cookie, now: T0 + 31 * Day, days: 90));
    }

    [Fact]
    public void Days_below_one_refuse_everything()
        => Assert.False(Read(Issue(), days: 0));

    [Fact]
    public void A_cookie_from_another_epoch_is_refused()
    {
        Assert.False(Read(Issue(epoch: 3), epoch: 4));
        Assert.False(Read(Issue(epoch: 4), epoch: 3));
    }

    /* ---- garbage ---- */

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("v1")]
    [InlineData("v1.")]
    [InlineData("v1..")]
    [InlineData("v1.a.b")]
    [InlineData("...")]
    [InlineData("v1.a.b.c")]
    [InlineData("v2.eyJrIjoiZSJ9.abc")]
    [InlineData("v1.%%%%.$$$$")]
    [InlineData("mokaco_gate=v1.a.b")]
    [InlineData("v1.eyJrIjoiZSJ9")]
    public void Garbage_is_refused_without_throwing(string? value)
        => Assert.False(Read(value));

    [Fact]
    public void An_oversized_value_is_refused_before_it_is_split()
    {
        var huge = "v1." + new string('A', 6000) + "." + new string('B', 43);
        Assert.False(Read(huge));
        Assert.False(Read(new string('.', 100_000)));
    }

    /* ---- the header ---- */

    [Fact]
    public void The_set_cookie_header_carries_every_flag()
    {
        Assert.Equal(
            "mokaco_gate=v1.abc.def; Max-Age=2592000; Path=/; Secure; HttpOnly; SameSite=Lax",
            GateCookieOptions.SetCookie("v1.abc.def", 30));
        Assert.Equal(
            "mokaco_gate=; Max-Age=0; Path=/; Secure; HttpOnly; SameSite=Lax",
            GateCookieOptions.Expired);
    }
}
