using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Extensions.Logging;

namespace MokaCo.HRMS.Services.Booking.Payments;

/// <summary>
/// The two gateway calls the deposit flow makes. An interface so the settlement logic can be tested
/// without a network.
/// </summary>
public interface IMpgsClient
{
    /// <summary>
    /// INITIATE_CHECKOUT for a PURCHASE of <paramref name="amount"/> on order <paramref name="orderId"/>
    /// (the booking reference). Returns the checkout session id. Throws <see cref="MpgsException"/>
    /// when the gateway does not open one. NOT RETRIED: a second session is harmless but a retry
    /// hides a slow gateway from a guest who is waiting for the page.
    /// </summary>
    Task<string> InitiateCheckoutAsync(string orderId, decimal amount, string currency, string description,
        string returnUrl, string cancelUrl, string timeoutUrl, CancellationToken cancellationToken = default);

    /// <summary>
    /// RETRIEVE_ORDER. NEVER THROWS for a gateway problem: an HTTP error, a timeout or an unreadable
    /// answer is <see cref="MpgsLookupKind.Error"/> ("could not tell"), which the decision table
    /// turns into unconfirmed — never into failed. Retried on transient failures.
    /// </summary>
    Task<MpgsOrderLookup> RetrieveOrderAsync(string orderId, CancellationToken cancellationToken = default);
}

/// <summary>The gateway refused or failed to open a checkout session.</summary>
public sealed class MpgsException(string message) : Exception(message);

public enum MpgsLookupKind
{
    /// <summary>The gateway answered with the order.</summary>
    Found,

    /// <summary>The gateway answered that no such order exists: nothing was ever attempted on it.</summary>
    NotFound,

    /// <summary>No usable answer (HTTP error, timeout, unreadable body). The outcome is unknown.</summary>
    Error,
}

/// <summary>What RETRIEVE_ORDER said, reduced to what the decision table reads.</summary>
/// <param name="TransactionCount">
/// How many transactions the order carries: 0 when the gateway answered with an order and no
/// transaction on it (a checkout was opened and nothing was ever attempted). NULL when not reported,
/// which is never read as "none".
/// </param>
public sealed record MpgsOrderLookup(
    MpgsLookupKind Kind,
    string? Result = null,
    string? Status = null,
    decimal? Amount = null,
    string? Currency = null,
    decimal? TotalCapturedAmount = null,
    string? TransactionId = null,
    string? Problem = null,
    int? TransactionCount = null,
    decimal? TotalAuthorizedAmount = null)
{
    public static MpgsOrderLookup Error(string problem) => new(MpgsLookupKind.Error, Problem: problem);
    public static MpgsOrderLookup NotFound() => new(MpgsLookupKind.NotFound, Problem: "order not found");
}

/// <summary>
/// Typed HttpClient over the MPGS REST API (merchant authentication: HTTP Basic,
/// "merchant.{id}:{password}"). The request body mirrors mokanco-lb functions/api/booking.js,
/// which is proven end to end against the test gateway.
///
/// LOGS the order id, the gateway's result and status, and the HTTP status — never the password,
/// the Authorization header or a request/response body.
/// </summary>
public sealed class MpgsClient : IMpgsClient
{
    public const string MerchantName = "Moka & Co Lebanon";

    /// <summary>The gateway's own limit on order.description.</summary>
    public const int MaxDescription = 127;

    public static readonly TimeSpan InitiateTimeout = TimeSpan.FromSeconds(15);
    public static readonly TimeSpan RetrieveTimeout = TimeSpan.FromSeconds(8);
    public const int RetrieveAttempts = 3;
    private static readonly TimeSpan RetryPause = TimeSpan.FromMilliseconds(400);

    private readonly HttpClient _http;
    private readonly MpgsOptions _options;
    private readonly ILogger<MpgsClient> _log;

    public MpgsClient(HttpClient http, MpgsOptions options, ILogger<MpgsClient> log)
    {
        _http = http;
        _options = options;
        _log = log;
    }

    private string MerchantPath => $"{_options.BaseUrl}/api/rest/version/{_options.ApiVersion}/merchant/{Uri.EscapeDataString(_options.MerchantId)}";

    public async Task<string> InitiateCheckoutAsync(string orderId, decimal amount, string currency, string description,
        string returnUrl, string cancelUrl, string timeoutUrl, CancellationToken cancellationToken = default)
    {
        var body = CheckoutBody(_options, orderId, amount, currency, description, returnUrl, cancelUrl, timeoutUrl);

        using var request = new HttpRequestMessage(HttpMethod.Post, $"{MerchantPath}/session")
        {
            Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json"),
        };
        Authorize(request);

        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(InitiateTimeout);

        HttpResponseMessage response;
        try
        {
            response = await _http.SendAsync(request, timeout.Token);
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or OperationCanceledException)
        {
            _log.LogWarning("MPGS INITIATE_CHECKOUT {OrderId}: no answer ({Kind}).", orderId, ex.GetType().Name);
            throw new MpgsException("The payment gateway did not answer.");
        }

        using (response)
        {
            var json = await ReadJsonAsync(response, timeout.Token);
            var result = Text(json, "result");
            var sessionId = Text(json?["session"], "id");

            if (!response.IsSuccessStatusCode || result != "SUCCESS" || string.IsNullOrEmpty(sessionId))
            {
                _log.LogWarning("MPGS INITIATE_CHECKOUT {OrderId}: HTTP {Http}, result {Result}.", orderId, (int)response.StatusCode, result ?? "-");
                throw new MpgsException("The payment gateway did not open a checkout session.");
            }

            _log.LogInformation("MPGS INITIATE_CHECKOUT {OrderId}: result {Result}.", orderId, result);
            return sessionId;
        }
    }

    /// <summary>
    /// The INITIATE_CHECKOUT body, as booking.js sends it. Public so the shape can be asserted on its
    /// own; the client test also reads it off the wire.
    ///
    /// ALL THREE interaction URLs ARE SET: the checkout library otherwise derives cancel and timeout
    /// URLs from the page URL, which breaks when the session travels in a URL fragment (/pay/#session=).
    /// A timeout means the outcome is unknown, so it routes to the unconfirmed page.
    /// </summary>
    public static JsonObject CheckoutBody(MpgsOptions options, string orderId, decimal amount, string currency, string description,
        string returnUrl, string cancelUrl, string timeoutUrl)
    {
        var interaction = new JsonObject
        {
            ["operation"] = "PURCHASE",
            ["merchant"] = new JsonObject { ["name"] = MerchantName },
            ["returnUrl"] = returnUrl,
            ["cancelUrl"] = cancelUrl,
            ["timeoutUrl"] = timeoutUrl,
            ["displayControl"] = new JsonObject { ["billingAddress"] = "HIDE" },
        };

        // TEST merchant profile AND the developer flag — see MpgsOptions. Never on MOKANDCO.
        if (options.SendsThreeDsBypass)
            interaction["action"] = new JsonObject { ["3DSecure"] = "BYPASS" };

        return new JsonObject
        {
            ["apiOperation"] = "INITIATE_CHECKOUT",
            ["interaction"] = interaction,
            ["order"] = new JsonObject
            {
                ["currency"] = currency,
                ["id"] = orderId,
                ["amount"] = amount.ToString("0.00", CultureInfo.InvariantCulture),
                ["description"] = description.Length > MaxDescription ? description[..MaxDescription] : description,
            },
        };
    }

    public async Task<MpgsOrderLookup> RetrieveOrderAsync(string orderId, CancellationToken cancellationToken = default)
    {
        MpgsOrderLookup last = MpgsOrderLookup.Error("not attempted");

        for (var attempt = 1; attempt <= RetrieveAttempts; attempt++)
        {
            var (lookup, transient) = await RetrieveOnceAsync(orderId, cancellationToken);
            last = lookup;
            if (!transient || attempt == RetrieveAttempts || cancellationToken.IsCancellationRequested)
                break;

            try { await Task.Delay(RetryPause * attempt, cancellationToken); }
            catch (OperationCanceledException) { break; }
        }

        if (last.Kind == MpgsLookupKind.Found)
            _log.LogInformation("MPGS RETRIEVE_ORDER {OrderId}: result {Result}, status {Status}.", orderId, last.Result ?? "-", last.Status ?? "-");
        else
            _log.LogWarning("MPGS RETRIEVE_ORDER {OrderId}: {Kind} ({Problem}).", orderId, last.Kind, last.Problem);

        return last;
    }

    private async Task<(MpgsOrderLookup Lookup, bool Transient)> RetrieveOnceAsync(string orderId, CancellationToken cancellationToken)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, $"{MerchantPath}/order/{Uri.EscapeDataString(orderId)}");
        Authorize(request);

        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(RetrieveTimeout);

        try
        {
            using var response = await _http.SendAsync(request, timeout.Token);
            var json = await ReadJsonAsync(response, timeout.Token);

            if (response.IsSuccessStatusCode)
                return json is null
                    ? (MpgsOrderLookup.Error("unreadable answer"), true)
                    : (Parse(json), false);

            if (IsOrderNotFound(response.StatusCode, json))
                return (MpgsOrderLookup.NotFound(), false);

            var code = (int)response.StatusCode;
            var transient = code >= 500 || response.StatusCode is HttpStatusCode.RequestTimeout or HttpStatusCode.TooManyRequests;
            return (MpgsOrderLookup.Error($"HTTP {code}"), transient);
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or OperationCanceledException)
        {
            return (MpgsOrderLookup.Error(ex is HttpRequestException ? "network error" : "timeout"), true);
        }
    }

    /// <summary>
    /// The gateway answers an order it has never seen with an error whose explanation says it cannot
    /// find the order (HTTP 400 on this API, 404 on some), which is a real answer — "nothing was
    /// attempted" — and is kept apart from an outage.
    /// </summary>
    private static bool IsOrderNotFound(HttpStatusCode status, JsonNode? json)
    {
        if (status == HttpStatusCode.NotFound)
            return true;

        var explanation = Text(json?["error"], "explanation") ?? string.Empty;
        return status == HttpStatusCode.BadRequest
               && explanation.Contains("find order", StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>The order-level fields, and the id of the transaction that took the money.</summary>
    public static MpgsOrderLookup Parse(JsonNode json)
    {
        string? transactionId = null;
        var transactionCount = 0;
        if (json["transaction"] is JsonArray transactions)
        {
            transactionCount = transactions.Count;

            var rows = transactions
                .Select(t => (Result: Text(t, "result"), Type: Text(t?["transaction"], "type"), Id: Text(t?["transaction"], "id")))
                .Where(t => !string.IsNullOrEmpty(t.Id))
                .ToList();

            transactionId =
                rows.LastOrDefault(t => t.Result == "SUCCESS" && t.Type is "PAYMENT" or "CAPTURE").Id
                ?? rows.LastOrDefault(t => t.Result == "SUCCESS").Id
                ?? rows.LastOrDefault().Id;
        }

        return new MpgsOrderLookup(
            MpgsLookupKind.Found,
            Result: Text(json, "result"),
            Status: Text(json, "status"),
            Amount: Number(json["amount"]),
            Currency: Text(json, "currency"),
            TotalCapturedAmount: Number(json["totalCapturedAmount"]),
            TransactionId: transactionId,
            TransactionCount: transactionCount,
            TotalAuthorizedAmount: Number(json["totalAuthorizedAmount"]));
    }

    private void Authorize(HttpRequestMessage request)
    {
        var credentials = Convert.ToBase64String(Encoding.UTF8.GetBytes($"merchant.{_options.MerchantId}:{_options.ApiPassword}"));
        request.Headers.Authorization = new AuthenticationHeaderValue("Basic", credentials);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
    }

    private static async Task<JsonNode?> ReadJsonAsync(HttpResponseMessage response, CancellationToken cancellationToken)
    {
        try
        {
            var text = await response.Content.ReadAsStringAsync(cancellationToken);
            return string.IsNullOrWhiteSpace(text) ? null : JsonNode.Parse(text);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static string? Text(JsonNode? node, string property)
        => node is JsonObject obj && obj[property] is JsonValue value && value.TryGetValue<string>(out var text) ? text : null;

    private static decimal? Number(JsonNode? node)
    {
        if (node is not JsonValue value)
            return null;
        if (value.TryGetValue<decimal>(out var number))
            return number;
        if (value.TryGetValue<string>(out var text) && decimal.TryParse(text, NumberStyles.Number, CultureInfo.InvariantCulture, out var parsed))
            return parsed;
        return null;
    }
}
