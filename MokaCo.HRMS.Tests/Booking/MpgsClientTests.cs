using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using Microsoft.Extensions.Logging.Abstractions;
using MokaCo.HRMS.Services.Booking.Payments;

namespace MokaCo.HRMS.Tests.Booking;

/// <summary>
/// The gateway client, read off the wire through a fake handler: the INITIATE_CHECKOUT body has the
/// shape of the website's proven booking.js request (PURCHASE, all three URLs, billing address
/// hidden, amount with two invariant decimals), the 3DS bypass is sent for a TEST profile with the
/// flag and NEVER for MOKANDCO, and RETRIEVE_ORDER turns every failure into "could not tell".
/// </summary>
public class MpgsClientTests
{
    private const string Ref = "MC-1A2B3C4D";

    private sealed class FakeHandler(Func<HttpRequestMessage, int, Task<HttpResponseMessage>> answer) : HttpMessageHandler
    {
        public List<(HttpRequestMessage Request, string? Body)> Seen { get; } = [];

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var body = request.Content is null ? null : await request.Content.ReadAsStringAsync(cancellationToken);
            Seen.Add((request, body));
            return await answer(request, Seen.Count);
        }
    }

    private static HttpResponseMessage Json(HttpStatusCode status, string json)
        => new(status) { Content = new StringContent(json, Encoding.UTF8, "application/json") };

    private static MpgsOptions Options(string merchant = "TESTMOKANDCO", bool bypassFlag = false) => new()
    {
        BaseUrl = "https://test-bobsal.gateway.mastercard.com",
        MerchantId = merchant,
        ApiPassword = "pw-not-real",
        ApiVersion = 73,
        SiteUrl = "https://mokanco.com.lb",
        ApiPublicUrl = "https://mokanco.com.lb",
        TestBypassRequested = bypassFlag,
    };

    private static (MpgsClient Client, FakeHandler Handler) Client(MpgsOptions options, Func<HttpRequestMessage, int, Task<HttpResponseMessage>> answer)
    {
        var handler = new FakeHandler(answer);
        return (new MpgsClient(new HttpClient(handler), options, NullLogger<MpgsClient>.Instance), handler);
    }

    private static Task<string> Initiate(MpgsClient client, MpgsOptions o)
        => client.InitiateCheckoutAsync(Ref, 12.5m, "USD", "Room deposit: Studio, 2026-10-01, 2h",
            o.VerifyUrl(Ref), o.CancelledUrl(), o.UnconfirmedUrl(Ref));

    private const string SessionOk = """{"result":"SUCCESS","session":{"id":"SESSION0002776555272F12345678"},"successIndicator":"abc"}""";

    [Fact]
    public async Task Initiate_checkout_sends_the_booking_js_request()
    {
        var options = Options();
        var (client, handler) = Client(options, (_, _) => Task.FromResult(Json(HttpStatusCode.Created, SessionOk)));

        var session = await Initiate(client, options);

        Assert.Equal("SESSION0002776555272F12345678", session);
        var (request, body) = Assert.Single(handler.Seen);
        Assert.Equal(HttpMethod.Post, request.Method);
        Assert.Equal("https://test-bobsal.gateway.mastercard.com/api/rest/version/73/merchant/TESTMOKANDCO/session", request.RequestUri!.ToString());
        Assert.Equal("Basic", request.Headers.Authorization!.Scheme);
        Assert.Equal("merchant.TESTMOKANDCO:pw-not-real", Encoding.UTF8.GetString(Convert.FromBase64String(request.Headers.Authorization.Parameter!)));

        var json = JsonNode.Parse(body!)!;
        Assert.Equal("INITIATE_CHECKOUT", (string?)json["apiOperation"]);
        var interaction = json["interaction"]!;
        Assert.Equal("PURCHASE", (string?)interaction["operation"]);
        Assert.Equal("Moka & Co Lebanon", (string?)interaction["merchant"]!["name"]);
        Assert.Equal("https://mokanco.com.lb/api/public/booking/verify?ref=MC-1A2B3C4D", (string?)interaction["returnUrl"]);
        Assert.Equal("https://mokanco.com.lb/reservations/?payment=cancelled", (string?)interaction["cancelUrl"]);
        Assert.Equal("https://mokanco.com.lb/reservations/?payment=unconfirmed&ref=MC-1A2B3C4D", (string?)interaction["timeoutUrl"]);
        Assert.Equal("HIDE", (string?)interaction["displayControl"]!["billingAddress"]);
        Assert.Null(interaction["action"]);     // no flag: no bypass, even on the TEST profile

        var order = json["order"]!;
        Assert.Equal(Ref, (string?)order["id"]);
        Assert.Equal("12.50", (string?)order["amount"]);                  // a string, two decimals, invariant
        Assert.Equal("USD", (string?)order["currency"]);
        Assert.Equal("Room deposit: Studio, 2026-10-01, 2h", (string?)order["description"]);
    }

    [Fact]
    public void The_amount_has_two_decimals_whatever_the_culture()
    {
        var saved = Thread.CurrentThread.CurrentCulture;
        try
        {
            Thread.CurrentThread.CurrentCulture = new System.Globalization.CultureInfo("fr-FR");
            var body = MpgsClient.CheckoutBody(Options(), Ref, 1234.5m, "USD", "d", "r", "c", "t");
            Assert.Equal("1234.50", (string?)body["order"]!["amount"]);
        }
        finally
        {
            Thread.CurrentThread.CurrentCulture = saved;
        }
    }

    [Fact]
    public void The_3ds_bypass_is_sent_only_for_a_TEST_profile_with_the_flag_on()
    {
        static JsonNode? Action(MpgsOptions o) => MpgsClient.CheckoutBody(o, Ref, 1m, "USD", "d", "r", "c", "t")["interaction"]!["action"];

        Assert.Equal("BYPASS", (string?)Action(Options("TESTMOKANDCO", bypassFlag: true))!["3DSecure"]);
        Assert.Null(Action(Options("TESTMOKANDCO", bypassFlag: false)));
    }

    [Theory]
    [InlineData("MOKANDCO")]
    [InlineData("mokandco")]
    [InlineData("MOKANDCOTEST")]     // "TEST" anywhere but the front is not a test profile
    public void MOKANDCO_never_gets_the_3ds_bypass_whatever_the_flag_says(string merchant)
    {
        var live = Options(merchant, bypassFlag: true);

        Assert.False(live.SendsThreeDsBypass);
        Assert.Null(MpgsClient.CheckoutBody(live, Ref, 1m, "USD", "d", "r", "c", "t")["interaction"]!["action"]);
    }

    [Fact]
    public async Task The_bypass_reaches_the_wire_for_the_test_profile()
    {
        var options = Options("TESTMOKANDCO", bypassFlag: true);
        var (client, handler) = Client(options, (_, _) => Task.FromResult(Json(HttpStatusCode.Created, SessionOk)));

        await Initiate(client, options);

        Assert.Equal("BYPASS", (string?)JsonNode.Parse(handler.Seen[0].Body!)!["interaction"]!["action"]!["3DSecure"]);
    }

    [Fact]
    public async Task A_refused_checkout_throws_and_is_not_retried()
    {
        var options = Options();
        var (client, handler) = Client(options, (_, _) => Task.FromResult(Json(HttpStatusCode.BadRequest, """{"result":"ERROR","error":{"cause":"INVALID_REQUEST"}}""")));

        await Assert.ThrowsAsync<MpgsException>(() => Initiate(client, options));
        Assert.Single(handler.Seen);
    }

    [Fact]
    public async Task A_checkout_that_times_out_throws_MpgsException()
    {
        var options = Options();
        var (client, _) = Client(options, (_, _) => throw new TaskCanceledException("timed out"));

        await Assert.ThrowsAsync<MpgsException>(() => Initiate(client, options));
    }

    [Fact]
    public async Task Retrieve_reads_the_order_and_the_paying_transaction()
    {
        const string order = """
        {"result":"SUCCESS","status":"CAPTURED","amount":12.5,"currency":"USD","totalCapturedAmount":12.50,"id":"MC-1A2B3C4D",
         "transaction":[
           {"result":"FAILURE","transaction":{"id":"1","type":"PAYMENT"}},
           {"result":"SUCCESS","transaction":{"id":"2","type":"AUTHENTICATION"}},
           {"result":"SUCCESS","transaction":{"id":"3","type":"PAYMENT"}}]}
        """;
        var options = Options();
        var (client, handler) = Client(options, (_, _) => Task.FromResult(Json(HttpStatusCode.OK, order)));

        var lookup = await client.RetrieveOrderAsync(Ref);

        Assert.Equal(new MpgsOrderLookup(MpgsLookupKind.Found, "SUCCESS", "CAPTURED", 12.5m, "USD", 12.50m, "3", TransactionCount: 3), lookup);
        var (request, _) = Assert.Single(handler.Seen);
        Assert.Equal(HttpMethod.Get, request.Method);
        Assert.Equal("https://test-bobsal.gateway.mastercard.com/api/rest/version/73/merchant/TESTMOKANDCO/order/MC-1A2B3C4D", request.RequestUri!.ToString());
        Assert.Equal("Basic", request.Headers.Authorization!.Scheme);
    }

    [Fact]
    public void An_order_with_no_transaction_parses_as_such_and_is_abandoned()
    {
        // a checkout session was opened on the order and the guest never submitted a card
        var lookup = MpgsClient.Parse(JsonNode.Parse(@"{""result"":""SUCCESS"",""status"":""INITIATED"",""amount"":12.5,""currency"":""USD"",""totalCapturedAmount"":0,""totalAuthorizedAmount"":0}")!);

        Assert.Equal((0, 0m), (lookup.TransactionCount, lookup.TotalAuthorizedAmount));
        Assert.True(PaymentDecisionTable.Decide(lookup, 12.5m, "USD").NothingAttempted);
    }

    [Fact]
    public async Task Retrieve_retries_a_server_error_then_reports_a_retrieval_error()
    {
        var options = Options();
        var (client, handler) = Client(options, (_, _) => Task.FromResult(Json(HttpStatusCode.ServiceUnavailable, "{}")));

        var lookup = await client.RetrieveOrderAsync(Ref);

        Assert.Equal(MpgsLookupKind.Error, lookup.Kind);
        Assert.Equal(MpgsClient.RetrieveAttempts, handler.Seen.Count);
        Assert.Equal(PaymentOutcome.Unconfirmed, PaymentDecisionTable.Decide(lookup, 12.5m, "USD").Outcome);
    }

    [Fact]
    public async Task Retrieve_recovers_when_a_retry_succeeds()
    {
        var options = Options();
        var (client, handler) = Client(options, (_, n) => n == 1
            ? throw new HttpRequestException("connection reset")
            : Task.FromResult(Json(HttpStatusCode.OK, """{"result":"SUCCESS","status":"AUTHORIZED","amount":12.5,"currency":"USD","totalCapturedAmount":0}""")));

        var lookup = await client.RetrieveOrderAsync(Ref);

        Assert.Equal(MpgsLookupKind.Found, lookup.Kind);
        Assert.Equal("AUTHORIZED", lookup.Status);
        Assert.Equal(2, handler.Seen.Count);
    }

    [Fact]
    public async Task Retrieve_timeout_is_a_retrieval_error()
    {
        var options = Options();
        var (client, _) = Client(options, (_, _) => throw new TaskCanceledException("timed out"));

        var lookup = await client.RetrieveOrderAsync(Ref);

        Assert.Equal(MpgsLookupKind.Error, lookup.Kind);
        Assert.Equal("timeout", lookup.Problem);
    }

    [Theory]
    [InlineData(HttpStatusCode.BadRequest, """{"result":"ERROR","error":{"cause":"INVALID_REQUEST","explanation":"Unable to find order = MC-1A2B3C4D for merchant TESTMOKANDCO"}}""")]
    [InlineData(HttpStatusCode.NotFound, "{}")]
    public async Task An_unknown_order_is_not_found_and_not_retried(HttpStatusCode status, string body)
    {
        var options = Options();
        var (client, handler) = Client(options, (_, _) => Task.FromResult(Json(status, body)));

        var lookup = await client.RetrieveOrderAsync(Ref);

        Assert.Equal(MpgsLookupKind.NotFound, lookup.Kind);
        Assert.Single(handler.Seen);
    }

    [Fact]
    public async Task Another_client_error_is_a_retrieval_error_and_not_retried()
    {
        var options = Options();
        var (client, handler) = Client(options, (_, _) => Task.FromResult(Json(HttpStatusCode.Unauthorized, """{"result":"ERROR","error":{"cause":"INVALID_REQUEST"}}""")));

        var lookup = await client.RetrieveOrderAsync(Ref);

        Assert.Equal(MpgsLookupKind.Error, lookup.Kind);
        Assert.Single(handler.Seen);
    }
}

/// <summary>Startup refuses to run without the gateway's configuration, and says which keys — never which values.</summary>
public class MpgsOptionsTests
{
    private static readonly Dictionary<string, string?> Complete = new()
    {
        [MpgsOptions.BaseKey] = "https://test-bobsal.gateway.mastercard.com/",
        [MpgsOptions.MerchantIdKey] = "TESTMOKANDCO",
        [MpgsOptions.ApiPasswordKey] = "pw-not-real",
        [MpgsOptions.ApiVersionKey] = "73",
        [MpgsOptions.SiteUrlKey] = "https://mokanco.com.lb/",
        [MpgsOptions.ApiPublicUrlKey] = "https://mokanco.com.lb",
    };

    private static MpgsOptions Read(Dictionary<string, string?> values) => MpgsOptions.FromSettings(key => values.GetValueOrDefault(key));

    [Fact]
    public void A_complete_configuration_reads_and_trims_trailing_slashes()
    {
        var options = Read(Complete);

        Assert.Equal("https://test-bobsal.gateway.mastercard.com", options.BaseUrl);
        Assert.Equal("https://mokanco.com.lb", options.SiteUrl);
        Assert.Equal(73, options.ApiVersion);
        Assert.False(options.SendsThreeDsBypass);   // flag absent
        Assert.DoesNotContain("pw-not-real", options.ToString());
    }

    [Fact]
    public void Missing_keys_are_all_named_and_no_value_is_printed()
    {
        var partial = new Dictionary<string, string?>(Complete)
        {
            [MpgsOptions.ApiPasswordKey] = "",
            [MpgsOptions.SiteUrlKey] = null,
            [MpgsOptions.ApiVersionKey] = "seventy-three",
        };

        var error = Assert.Throws<InvalidOperationException>(() => Read(partial));

        Assert.Contains("MPGS_API_PASSWORD is missing", error.Message);
        Assert.Contains("BOOKING_SITE_URL is missing", error.Message);
        Assert.Contains("MPGS_API_VERSION must be a whole number", error.Message);
        Assert.DoesNotContain("seventy-three", error.Message);
        Assert.DoesNotContain("TESTMOKANDCO", error.Message);
    }

    [Fact]
    public void The_gateway_must_be_https()
    {
        var plain = new Dictionary<string, string?>(Complete) { [MpgsOptions.BaseKey] = "http://test-bobsal.gateway.mastercard.com" };
        Assert.Contains("MPGS_BASE must be https", Assert.Throws<InvalidOperationException>(() => Read(plain)).Message);

        // a stand-in gateway on this machine is the one exception
        var local = new Dictionary<string, string?>(Complete) { [MpgsOptions.BaseKey] = "http://127.0.0.1:5099" };
        Assert.Equal("http://127.0.0.1:5099", Read(local).BaseUrl);
    }

    [Theory]
    [InlineData("TESTMOKANDCO", "true", true)]
    [InlineData("TESTMOKANDCO", "1", true)]
    [InlineData("TESTMOKANDCO", "false", false)]
    [InlineData("TESTMOKANDCO", null, false)]
    [InlineData("MOKANDCO", "true", false)]
    [InlineData("MOKANDCO", "1", false)]
    public void The_bypass_needs_a_TEST_profile_and_the_flag(string merchant, string? flag, bool bypass)
    {
        var values = new Dictionary<string, string?>(Complete) { [MpgsOptions.MerchantIdKey] = merchant, [MpgsOptions.TestBypassKey] = flag };
        Assert.Equal(bypass, Read(values).SendsThreeDsBypass);
    }
}
