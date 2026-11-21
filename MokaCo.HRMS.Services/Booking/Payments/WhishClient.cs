using System.Globalization;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Extensions.Logging;

namespace MokaCo.HRMS.Services.Booking.Payments;

/// <summary>
/// The three Whish Pay calls the deposit flow makes. An interface so the settlement logic can be tested without a
/// network, exactly as with <see cref="IMpgsClient"/>.
/// </summary>
public interface IWhishClient
{
    /// <summary>
    /// POST /payment/whish: creates the payment and returns Whish's hosted payment link (collectUrl). Re-sending the
    /// SAME externalId with the same body is an idempotent replay (the same link, never a second charge), which is
    /// what a timeout or a "pending" answer is retried with. Throws <see cref="WhishException"/> when no link comes back.
    /// </summary>
    Task<string> CreateCollectAsync(string externalId, decimal amount, string currency, string invoice,
        string successCallbackUrl, string failureCallbackUrl, string successRedirectUrl, string failureRedirectUrl,
        CancellationToken cancellationToken = default);

    /// <summary>
    /// POST /payment/collect/status. NEVER throws for a gateway problem: an HTTP error, an unreadable answer or the
    /// "pending" code is <see cref="WhishLookupKind.Error"/> - "could not tell", like <see cref="MpgsLookupKind.Error"/>.
    /// </summary>
    Task<WhishCollectLookup> GetStatusAsync(string externalId, string currency, CancellationToken cancellationToken = default);

    /// <summary>POST /payment/whish/refund. Idempotent at Whish. Needs our egress IP registered with Whish.</summary>
    Task<WhishRefundResult> RefundAsync(string externalId, string currency, string reason, CancellationToken cancellationToken = default);

    /// <summary>
    /// GET /payment/account/balance: moves nothing, and answers only to the right three keys - which makes it the
    /// connection check (script 119: "Check connection" on the gateway pages). Never throws for a gateway problem.
    /// </summary>
    Task<WhishBalanceResult> GetBalanceAsync(string currency, CancellationToken cancellationToken = default);
}

/// <param name="Ok">Whish accepted the keys and answered.</param>
/// <param name="Code">Whish's error code when it did not; null when there was no answer at all.</param>
public sealed record WhishBalanceResult(bool Ok, decimal? Balance = null, string? Code = null, string? Problem = null);

public sealed class WhishException(string message) : Exception(message);

public enum WhishLookupKind
{
    /// <summary>Whish answered with the payment's persisted state.</summary>
    Found,

    /// <summary>Whish answered that it has no payment under this id: it was never created there.</summary>
    NotFound,

    /// <summary>Could not tell: no answer, an unreadable one, or Whish's own "pending" code.</summary>
    Error,
}

/// <param name="CollectStatus">pending | success | failed | refunded | unknown, lower-cased as received.</param>
/// <param name="PayerPhoneNumber">The phone that paid, when Whish gives one.</param>
public sealed record WhishCollectLookup(WhishLookupKind Kind, string? CollectStatus = null, string? PayerPhoneNumber = null, string? Problem = null)
{
    public static WhishCollectLookup Error(string problem) => new(WhishLookupKind.Error, Problem: problem);
    public static WhishCollectLookup NotFound(string code) => new(WhishLookupKind.NotFound, Problem: code);
}

/// <param name="Refunded">The payment is refunded (now, or already).</param>
/// <param name="AlreadyDone">Whish replayed an earlier refund of it (retrieved = true).</param>
/// <param name="Code">Whish's error code when it was not refunded; "auth.error" = our IP is not registered.</param>
/// <param name="Unknown">No answer, or Whish's "pending": it is NOT known whether the refund went through. Asking again is safe (Whish never refunds a payment twice).</param>
public sealed record WhishRefundResult(bool Refunded, bool AlreadyDone = false, string? Code = null, string? Problem = null, bool Unknown = false);

/// <summary>
/// Typed HttpClient over Whish Pay v2.0.0. Every request carries the three headers Whish issued (channel, secret,
/// websiteUrl) and our User-Agent. Every answer is the envelope { status, code, dialog, data, retrieved } and is
/// judged BY ITS BODY, never by the HTTP status (Whish's rule): status true = done; status false with code "500" =
/// PENDING (unknown, not failed: the same externalId is sent again); status false with any other code = refused.
///
/// LOGS the externalId, Whish's code and the HTTP status - never the secret, a header or a body.
/// </summary>
public sealed class WhishClient : IWhishClient
{
    public const string PendingCode = "500";

    /// <summary>Whish's limit is not documented; a description this long says everything a guest needs.</summary>
    public const int MaxInvoice = 120;

    public static readonly TimeSpan CreateTimeout = TimeSpan.FromSeconds(15);
    public static readonly TimeSpan StatusTimeout = TimeSpan.FromSeconds(8);
    public static readonly TimeSpan RefundTimeout = TimeSpan.FromSeconds(20);
    public const int CreateAttempts = 3;
    public const int StatusAttempts = 2;

    private static readonly string[] NotFoundCodes = ["external_id.not_exists", "collect.not_exists"];

    private readonly HttpClient _http;
    private readonly WhishOptions _options;
    private readonly ILogger<WhishClient> _log;

    public WhishClient(HttpClient http, WhishOptions options, ILogger<WhishClient> log)
    {
        _http = http;
        _options = options;
        _log = log;
    }

    /// <summary>The pause before the same request is sent again (longer each time). A test sets it to nothing.</summary>
    public TimeSpan RetryPause { get; init; } = TimeSpan.FromMilliseconds(700);

    /* ---- create ------------------------------------------------------------------------------- */

    public async Task<string> CreateCollectAsync(string externalId, decimal amount, string currency, string invoice,
        string successCallbackUrl, string failureCallbackUrl, string successRedirectUrl, string failureRedirectUrl,
        CancellationToken cancellationToken = default)
    {
        var body = CreateBody(externalId, amount, currency, invoice, successCallbackUrl, failureCallbackUrl, successRedirectUrl, failureRedirectUrl);
        string problem = "no answer";

        // The SAME id and the SAME body every time: Whish never runs an externalId twice, so a resend after a
        // timeout or a "pending" answer returns the first attempt's link instead of creating another payment.
        for (var attempt = 1; attempt <= CreateAttempts; attempt++)
        {
            var answer = await SendAsync(HttpMethod.Post, "/payment/whish", body, CreateTimeout, cancellationToken);
            if (answer.Ok)
            {
                var url = (answer.Data as JsonObject)?["collectUrl"]?.GetValue<string>();
                if (Uri.TryCreate(url, UriKind.Absolute, out var link) && link.Scheme == Uri.UriSchemeHttps)
                {
                    _log.LogInformation("Whish create {ExternalId}: link received{Replay}.", externalId, answer.Retrieved ? " (replay)" : string.Empty);
                    return url!;
                }
                // "A different amount: a success without a link" - this id was used for another amount.
                problem = "Whish answered without a payment link";
                break;
            }

            problem = answer.Problem;
            if (!answer.Transient) break;      // refused: sending it again would be refused again
            if (attempt < CreateAttempts) await Task.Delay(RetryPause * attempt, cancellationToken);
        }

        _log.LogWarning("Whish create {ExternalId}: no payment link ({Problem}).", externalId, problem);
        throw new WhishException($"Whish did not create the payment: {problem}.");
    }

    /// <summary>The request body, in one place so a test can hold it against the specification.</summary>
    public static JsonObject CreateBody(string externalId, decimal amount, string currency, string invoice,
        string successCallbackUrl, string failureCallbackUrl, string successRedirectUrl, string failureRedirectUrl)
        => new()
        {
            // A JSON STRING, per the specification: "30.00" for USD (two decimals), "45000" for LBP (none).
            ["amount"] = AmountText(amount, currency),
            ["currency"] = currency.Trim().ToUpperInvariant(),
            ["invoice"] = CleanInvoice(invoice),
            ["externalId"] = externalId,
            ["successCallbackUrl"] = successCallbackUrl,
            ["failureCallbackUrl"] = failureCallbackUrl,
            ["successRedirectUrl"] = successRedirectUrl,
            ["failureRedirectUrl"] = failureRedirectUrl,
        };

    public static string AmountText(decimal amount, string currency)
        => string.Equals(currency.Trim(), "LBP", StringComparison.OrdinalIgnoreCase)
            ? decimal.Round(amount, 0, MidpointRounding.AwayFromZero).ToString("0", CultureInfo.InvariantCulture)
            : decimal.Round(amount, 2, MidpointRounding.AwayFromZero).ToString("0.00", CultureInfo.InvariantCulture);

    /// <summary>
    /// Whish refuses a body with characters its database does not take ("emoji.not_supported"), and a room or a
    /// guest's name can carry one. Letters, digits, ordinary punctuation and spaces stay; everything else goes.
    /// </summary>
    public static string CleanInvoice(string? text)
    {
        var clean = new StringBuilder();
        foreach (var rune in (text ?? string.Empty).EnumerateRunes())
        {
            if (rune.Value > 0xFFFF) continue;                                  // emoji and other astral characters
            var category = Rune.GetUnicodeCategory(rune);
            if (category is UnicodeCategory.OtherSymbol or UnicodeCategory.Surrogate or UnicodeCategory.PrivateUse
                or UnicodeCategory.Control or UnicodeCategory.Format or UnicodeCategory.OtherNotAssigned
                or UnicodeCategory.ModifierSymbol or UnicodeCategory.NonSpacingMark or UnicodeCategory.EnclosingMark)
                continue;
            clean.Append(rune.ToString());
        }
        var result = string.Join(' ', clean.ToString().Split(' ', StringSplitOptions.RemoveEmptyEntries));
        return result.Length <= MaxInvoice ? result : result[..MaxInvoice].TrimEnd();
    }

    /* ---- status ------------------------------------------------------------------------------- */

    public async Task<WhishCollectLookup> GetStatusAsync(string externalId, string currency, CancellationToken cancellationToken = default)
    {
        var body = new JsonObject { ["currency"] = currency.Trim().ToUpperInvariant(), ["externalId"] = externalId };
        var last = WhishCollectLookup.Error("no answer");

        for (var attempt = 1; attempt <= StatusAttempts; attempt++)
        {
            var answer = await SendAsync(HttpMethod.Post, "/payment/collect/status", body, StatusTimeout, cancellationToken);
            last = ParseStatus(answer);
            if (last.Kind != WhishLookupKind.Error || !answer.Transient) break;
            if (attempt < StatusAttempts) await Task.Delay(RetryPause, cancellationToken);
        }

        if (last.Kind == WhishLookupKind.Error)
            _log.LogWarning("Whish status {ExternalId}: could not tell ({Problem}).", externalId, last.Problem);
        else
            _log.LogInformation("Whish status {ExternalId}: {Status}.", externalId, last.Kind == WhishLookupKind.NotFound ? "not found" : last.CollectStatus);
        return last;
    }

    private static WhishCollectLookup ParseStatus(WhishAnswer answer)
    {
        if (answer.Ok)
        {
            var data = answer.Data as JsonObject;
            var status = data?["collectStatus"]?.GetValue<string>()?.Trim().ToLowerInvariant();
            if (string.IsNullOrEmpty(status)) return WhishCollectLookup.Error("the answer carries no collectStatus");
            var phone = data?["payerPhoneNumber"]?.GetValue<string>()?.Trim();
            return new WhishCollectLookup(WhishLookupKind.Found, status, string.IsNullOrEmpty(phone) ? null : phone);
        }
        return answer.Code is { } code && NotFoundCodes.Contains(code)
            ? WhishCollectLookup.NotFound(code)
            : WhishCollectLookup.Error(answer.Problem);
    }

    /* ---- refund ------------------------------------------------------------------------------- */

    public async Task<WhishRefundResult> RefundAsync(string externalId, string currency, string reason, CancellationToken cancellationToken = default)
    {
        var why = CleanInvoice(reason);
        if (why.Length == 0) why = "Booking cancelled";                         // "Must not be blank."
        var body = new JsonObject { ["currency"] = currency.Trim().ToUpperInvariant(), ["externalId"] = externalId, ["refundReason"] = why };

        var answer = await SendAsync(HttpMethod.Post, "/payment/whish/refund", body, RefundTimeout, cancellationToken);
        if (answer.Ok)
        {
            _log.LogInformation("Whish refund {ExternalId}: refunded{Replay}.", externalId, answer.Retrieved ? " (already was)" : string.Empty);
            return new WhishRefundResult(true, AlreadyDone: answer.Retrieved);
        }

        _log.LogWarning("Whish refund {ExternalId}: not refunded ({Problem}).", externalId, answer.Problem);
        return new WhishRefundResult(false, Code: answer.Code, Problem: answer.Problem, Unknown: answer.Transient);
    }

    /* ---- balance (the connection check) ------------------------------------------------------- */

    public async Task<WhishBalanceResult> GetBalanceAsync(string currency, CancellationToken cancellationToken = default)
    {
        var answer = await SendAsync(HttpMethod.Get, "/payment/account/balance?currency=" + Uri.EscapeDataString(currency.Trim().ToUpperInvariant()),
            null, StatusTimeout, cancellationToken);
        if (!answer.Ok)
        {
            _log.LogWarning("Whish balance: not answered ({Problem}).", answer.Problem);
            return new WhishBalanceResult(false, Code: answer.Code, Problem: answer.Problem);
        }

        decimal? balance = null;
        if ((answer.Data as JsonObject)?["balance"] is JsonValue value)
        {
            if (value.TryGetValue<decimal>(out var number)) balance = number;
            else if (value.TryGetValue<string>(out var text) && decimal.TryParse(text, NumberStyles.Number, CultureInfo.InvariantCulture, out var parsed)) balance = parsed;
        }

        _log.LogInformation("Whish balance: answered.");
        return new WhishBalanceResult(true, balance);
    }

    /* ---- the envelope ------------------------------------------------------------------------- */

    /// <param name="Ok">status true.</param>
    /// <param name="Transient">Nothing was decided: no answer, an unreadable one, or the "pending" code. Worth sending again.</param>
    private sealed record WhishAnswer(bool Ok, string? Code, JsonNode? Data, bool Retrieved, bool Transient, string Problem);

    private async Task<WhishAnswer> SendAsync(HttpMethod method, string path, JsonObject? body, TimeSpan timeout, CancellationToken cancellationToken)
    {
        using var request = new HttpRequestMessage(method, _options.BaseUrl + path);
        request.Headers.TryAddWithoutValidation("channel", _options.Channel);
        request.Headers.TryAddWithoutValidation("secret", _options.Secret);
        request.Headers.TryAddWithoutValidation("websiteUrl", _options.WebsiteUrl);
        request.Headers.TryAddWithoutValidation("User-Agent", WhishOptions.UserAgent);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        if (body is not null)
            request.Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json");

        using var limit = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        limit.CancelAfter(timeout);
        try
        {
            using var response = await _http.SendAsync(request, limit.Token);
            var text = await response.Content.ReadAsStringAsync(limit.Token);
            return Parse((int)response.StatusCode, text);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return new WhishAnswer(false, null, null, false, Transient: true, "timed out");
        }
        catch (HttpRequestException ex)
        {
            return new WhishAnswer(false, null, null, false, Transient: true, "network error: " + ex.GetType().Name);
        }
    }

    /// <summary>Reads the envelope. Public and pure so the rules can be tested against the specification's own examples.</summary>
    public static (bool Ok, string? Code, JsonNode? Data, bool Retrieved, bool Transient, string Problem) ParseEnvelope(int httpStatus, string? text)
    {
        var a = Parse(httpStatus, text);
        return (a.Ok, a.Code, a.Data, a.Retrieved, a.Transient, a.Problem);
    }

    private static WhishAnswer Parse(int httpStatus, string? text)
    {
        JsonNode? json = null;
        try { json = string.IsNullOrWhiteSpace(text) ? null : JsonNode.Parse(text); }
        catch (JsonException) { /* not JSON: an HTML error page from the edge */ }

        if (json is not JsonObject envelope || envelope["status"] is not JsonValue statusNode || !statusNode.TryGetValue<bool>(out var status))
        {
            // No envelope: Whish's edge answered (a 403 for a localhost callback address, a 5xx page). A 4xx is a
            // refusal of this request; anything else is "could not tell".
            var refused = httpStatus is >= 400 and < 500 && httpStatus != 408 && httpStatus != 429;
            return new WhishAnswer(false, null, null, false, Transient: !refused, $"HTTP {httpStatus} without an answer");
        }

        var code = envelope["code"] is JsonValue codeNode
            ? (codeNode.TryGetValue<string>(out var codeText) ? codeText : codeNode.ToJsonString().Trim('"'))
            : null;
        var retrieved = envelope["retrieved"] is JsonValue retrievedNode && retrievedNode.TryGetValue<bool>(out var replay) && replay;

        if (status)
            return new WhishAnswer(true, null, envelope["data"], retrieved, false, string.Empty);

        // status false + "500" = pending: the call returned no outcome. Unknown, not failed.
        return code == PendingCode
            ? new WhishAnswer(false, code, null, retrieved, Transient: true, "pending (code 500)")
            : new WhishAnswer(false, code, null, retrieved, Transient: false, $"code {code ?? "?"}");
    }
}

/// <summary>
/// THE ONE PLACE that decides what a Whish attempt came to, from what /payment/collect/status said. Pure: no clock,
/// no database, no network. Mapped onto the card flow's <see cref="PaymentDecision"/>, so everything after the
/// decision - recording, releasing, keeping the hold, alerting staff - is the code the card flow already runs.
///
///   success   paid. Whish reports no amount and none is needed: the payment was created with the booking's own
///             deposit, and its id is ours.
///   failed    the link expired unpaid: nothing was taken, and nothing more can happen on it (final: the job
///             releases the booking as soon as it sees this, without the patience a failed card order is given).
///   pending   not paid YET - which is also what a failed attempt reads until the link expires. While the link can
///             still be paid (five minutes) nobody is told "nothing was charged" and no second payment is opened.
///             Once the link is over (and a minute's grace), a pending attempt is one that was never paid:
///             abandoned, like a card order nothing was attempted on.
///   refunded  must not appear while collecting; unknown is Whish's own "undetermined". Both: cannot tell - the
///             hold is kept and staff are alerted by the reconciliation job, as for any unconfirmed payment.
///   no such payment at Whish (the create call never went through): abandoned.
///   no answer, an unreadable one, Whish's "pending" code: cannot tell.
/// </summary>
public static class WhishDecisionTable
{
    public static PaymentDecision Decide(WhishCollectLookup lookup, bool linkOver)
    {
        if (lookup.Kind == WhishLookupKind.Error)
            return new(PaymentOutcome.Unconfirmed, $"status error ({lookup.Problem})");

        if (lookup.Kind == WhishLookupKind.NotFound)
            return new(PaymentOutcome.Unconfirmed, "Whish has no such payment", NothingAttempted: true);

        return lookup.CollectStatus switch
        {
            "success" => new(PaymentOutcome.Paid, "paid on Whish"),
            "failed" => new(PaymentOutcome.Failed, "the Whish link expired unpaid", Final: true),
            "pending" when linkOver => new(PaymentOutcome.Unconfirmed, "not paid and the Whish link is over", NothingAttempted: true),
            "pending" => new(PaymentOutcome.Unconfirmed, "not paid yet, the Whish link is still open"),
            "refunded" => new(PaymentOutcome.Unconfirmed, "Whish says refunded while collecting"),
            _ => new(PaymentOutcome.Unconfirmed, $"Whish status {lookup.CollectStatus ?? "-"}"),
        };
    }
}
