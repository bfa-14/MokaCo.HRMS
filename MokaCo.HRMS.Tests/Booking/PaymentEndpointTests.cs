using System.Reflection;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Abstractions;
using Microsoft.AspNetCore.Mvc.Controllers;
using Microsoft.AspNetCore.Mvc.Filters;
using Microsoft.AspNetCore.Mvc.ModelBinding;
using Microsoft.AspNetCore.RateLimiting;
using Microsoft.AspNetCore.Routing;
using Microsoft.Extensions.DependencyInjection;
using Moq;
using MokaCo.HRMS.Api.Controllers;
using MokaCo.HRMS.Api.Hubs;
using MokaCo.HRMS.Api.PublicBooking;
using MokaCo.HRMS.Services.Booking;
using MokaCo.HRMS.Services.Booking.Payments;

namespace MokaCo.HRMS.Tests.Booking;

/// <summary>
/// POST /{ref}/pay and GET /verify at the controller: the answer for every opening and settlement
/// outcome (302 targets included), and — through the access filter run with each action's REAL
/// attributes — that /verify is reachable with no Origin header while /pay is still gated.
/// </summary>
public class PaymentEndpointTests
{
    private const string Ref = "MC-1A2B3C4D";

    private static readonly MpgsOptions Gateway = new()
    {
        BaseUrl = "https://test-bobsal.gateway.mastercard.com",
        MerchantId = "TESTMOKANDCO",
        ApiPassword = "pw-not-real",
        ApiVersion = 73,
        SiteUrl = "https://mokanco.com.lb",
        ApiPublicUrl = "https://api.mokanco.com.lb",
    };

    private static (PublicBookingController Controller, Mock<IOnlineDepositService> Deposits, Mock<IBookingLivePublisher> Live) Controller()
    {
        var deposits = new Mock<IOnlineDepositService>();
        deposits.SetupGet(d => d.Gateway).Returns(Gateway);
        var live = new Mock<IBookingLivePublisher>();
        var controller = new PublicBookingController(Mock.Of<IBookingService>(), Mock.Of<IRoomService>(), live.Object, deposits.Object)
        {
            ControllerContext = new ControllerContext { HttpContext = new DefaultHttpContext() },
        };
        return (controller, deposits, live);
    }

    private static object? Prop(object body, string name) => body.GetType().GetProperty(name)?.GetValue(body);

    /* ---- /pay ------------------------------------------------------------------------------- */

    [Fact]
    public async Task Pay_answers_the_session_id()
    {
        var (controller, deposits, _) = Controller();
        deposits.Setup(d => d.OpenAsync(Ref, It.IsAny<CancellationToken>()))
            .ReturnsAsync(new PaymentOpening(PayOpenResult.Opened, Ref, "SESSION0001", 12.50m, "USD", new DateTime(2026, 9, 26, 12, 15, 0)));

        var ok = Assert.IsType<OkObjectResult>(await controller.Pay("mc-1a2b3c4d"));    // the route's case is normalised

        Assert.Equal("SESSION0001", Prop(ok.Value!, "sessionId"));
        Assert.Equal(Ref, Prop(ok.Value!, "ref"));
        Assert.Equal(12.50m, Prop(ok.Value!, "deposit"));
    }

    [Theory]
    [InlineData(PayOpenResult.AlreadyPaid, 409, "already_paid")]
    [InlineData(PayOpenResult.PreviousUnconfirmed, 409, "payment_unconfirmed")]
    [InlineData(PayOpenResult.GatewayError, 502, "gateway_error")]
    [InlineData(PayOpenResult.UnknownBooking, 404, "not_found")]
    public async Task Pay_refusals_leave_as_error_and_code(PayOpenResult result, int status, string code)
    {
        var (controller, deposits, _) = Controller();
        deposits.Setup(d => d.OpenAsync(Ref, It.IsAny<CancellationToken>())).ReturnsAsync(new PaymentOpening(result, Ref));

        var answer = Assert.IsAssignableFrom<ObjectResult>(await controller.Pay(Ref));

        Assert.Equal(status, answer.StatusCode);
        Assert.Equal(code, Prop(answer.Value!, "code"));
        Assert.False(string.IsNullOrEmpty(Prop(answer.Value!, "error") as string));
    }

    [Fact]
    public async Task Pay_that_found_an_earlier_payment_tells_the_hub()
    {
        var (controller, deposits, live) = Controller();
        deposits.Setup(d => d.OpenAsync(Ref, It.IsAny<CancellationToken>())).ReturnsAsync(new PaymentOpening(PayOpenResult.AlreadyPaid, Ref, Changed: true));

        await controller.Pay(Ref);

        live.Verify(l => l.PublishAsync(Ref), Times.Once());
    }

    /* ---- /verify ---------------------------------------------------------------------------- */

    [Theory]
    [InlineData(SettlementResult.Paid, "https://mokanco.com.lb/reservations/confirmed/?ref=MC-1A2B3C4D")]
    [InlineData(SettlementResult.Released, "https://mokanco.com.lb/reservations/?payment=failed")]
    [InlineData(SettlementResult.Failed, "https://mokanco.com.lb/reservations/?payment=failed")]
    [InlineData(SettlementResult.NotApplicable, "https://mokanco.com.lb/reservations/?payment=failed")]   // no payment was ever opened
    [InlineData(SettlementResult.UnknownBooking, "https://mokanco.com.lb/reservations/?payment=failed")]
    [InlineData(SettlementResult.Unconfirmed, "https://mokanco.com.lb/reservations/?payment=unconfirmed&ref=MC-1A2B3C4D")]
    [InlineData(SettlementResult.PaidNeedsStaff, "https://mokanco.com.lb/reservations/?payment=unconfirmed&ref=MC-1A2B3C4D")]
    public async Task Verify_redirects_each_outcome(SettlementResult result, string location)
    {
        var (controller, deposits, _) = Controller();
        deposits.Setup(d => d.SettleAsync(Ref, SettleTrigger.GatewayReturn, It.IsAny<CancellationToken>()))
            .ReturnsAsync(new Settlement(result, Ref, true, null, "test"));

        var redirect = Assert.IsType<RedirectResult>(await controller.Verify(Ref));

        Assert.False(redirect.Permanent);                 // 302
        Assert.Equal(location, redirect.Url);
        Assert.Equal("no-store", controller.Response.Headers.CacheControl.ToString());
    }

    [Fact]
    public async Task Verify_replay_redirects_the_same_and_tells_nobody()
    {
        var (controller, deposits, live) = Controller();
        deposits.Setup(d => d.SettleAsync(Ref, SettleTrigger.GatewayReturn, It.IsAny<CancellationToken>()))
            .ReturnsAsync(new Settlement(SettlementResult.Paid, Ref, false, "Confirmed", "already recorded"));

        var first = Assert.IsType<RedirectResult>(await controller.Verify(Ref));
        var second = Assert.IsType<RedirectResult>(await controller.Verify(Ref));

        Assert.Equal(first.Url, second.Url);
        live.Verify(l => l.PublishAsync(It.IsAny<string?>()), Times.Never());
    }

    [Fact]
    public async Task Verify_that_changed_the_booking_tells_the_hub()
    {
        var (controller, deposits, live) = Controller();
        deposits.Setup(d => d.SettleAsync(Ref, SettleTrigger.GatewayReturn, It.IsAny<CancellationToken>()))
            .ReturnsAsync(new Settlement(SettlementResult.Paid, Ref, true, "Confirmed", "Confirmed"));

        await controller.Verify(Ref);

        live.Verify(l => l.PublishAsync(Ref), Times.Once());
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("MC-123")]
    [InlineData("MC-1A2B3C4D'--")]
    public async Task Verify_with_a_malformed_reference_asks_nobody(string? reference)
    {
        var (controller, deposits, _) = Controller();

        var redirect = Assert.IsType<RedirectResult>(await controller.Verify(reference));

        Assert.Equal("https://mokanco.com.lb/reservations/?payment=failed", redirect.Url);
        deposits.Verify(d => d.SettleAsync(It.IsAny<string>(), It.IsAny<SettleTrigger>(), It.IsAny<CancellationToken>()), Times.Never());
    }

    [Fact]
    public async Task Verify_that_breaks_sends_the_guest_to_unconfirmed_never_to_failed()
    {
        var (controller, deposits, _) = Controller();
        deposits.Setup(d => d.SettleAsync(Ref, SettleTrigger.GatewayReturn, It.IsAny<CancellationToken>())).ThrowsAsync(new TimeoutException());

        var redirect = Assert.IsType<RedirectResult>(await controller.Verify(Ref));

        Assert.Equal("https://mokanco.com.lb/reservations/?payment=unconfirmed&ref=MC-1A2B3C4D", redirect.Url);
    }

    /* ---- who may call which ----------------------------------------------------------------- */

    private static MethodInfo Action(string name) => typeof(PublicBookingController).GetMethod(name)!;

    [Fact]
    public void Verify_is_exempt_from_the_gate_and_anonymous_but_rate_limited()
    {
        var verify = Action(nameof(PublicBookingController.Verify));

        Assert.NotNull(verify.GetCustomAttribute<GatewayReturnAttribute>());
        Assert.Null(verify.GetCustomAttribute<PausesWithWebsiteAttribute>());      // a paid guest must get home even when bookings are paused
        Assert.Equal(PublicBookingController.ReadRateLimitPolicy, verify.GetCustomAttribute<EnableRateLimitingAttribute>()?.PolicyName);
        Assert.NotNull(typeof(PublicBookingController).GetCustomAttribute<AllowAnonymousAttribute>());   // the authorization fallback does not apply
    }

    [Fact]
    public void Pay_has_the_create_tier_and_no_exemption()
    {
        var pay = Action(nameof(PublicBookingController.Pay));

        Assert.Null(pay.GetCustomAttribute<GatewayReturnAttribute>());
        Assert.NotNull(pay.GetCustomAttribute<PausesWithWebsiteAttribute>());
        Assert.Equal(PublicBookingController.WriteRateLimitPolicy, pay.GetCustomAttribute<EnableRateLimitingAttribute>()?.PolicyName);
        Assert.NotNull(typeof(PublicBookingController).GetCustomAttribute<PublicBookingAccessAttribute>());
    }

    [Fact]
    public void Only_verify_is_exempt_from_the_gate()
    {
        var exempt = typeof(PublicBookingController).GetMethods()
            .Where(m => m.GetCustomAttribute<GatewayReturnAttribute>() is not null)
            .Select(m => m.Name);

        Assert.Equal([nameof(PublicBookingController.Verify)], exempt);
    }

    private sealed class StubGate(PublicBookingSnapshot snapshot) : IPublicBookingGate
    {
        public Task<PublicBookingSnapshot> CurrentAsync(CancellationToken cancellationToken = default) => Task.FromResult(snapshot);
    }

    /// <summary>The access filter, run with the action's own attributes as endpoint metadata — what the framework hands it.</summary>
    private static async Task<(int? Status, bool Reached)> Gate(string action, bool websiteEnabled = true, string? origin = null)
    {
        var snapshot = new PublicBookingSnapshot(websiteEnabled, ["https://mokanco.com.lb"], ApiKey: "");
        var services = new ServiceCollection().AddSingleton<IPublicBookingGate>(new StubGate(snapshot)).BuildServiceProvider();
        var http = new DefaultHttpContext { RequestServices = services };
        if (origin is not null) http.Request.Headers.Origin = origin;

        var descriptor = new ControllerActionDescriptor { EndpointMetadata = Action(action).GetCustomAttributes().Cast<object>().ToList() };
        var actionContext = new ActionContext(http, new RouteData(), descriptor, new ModelStateDictionary());
        var context = new ActionExecutingContext(actionContext, [], new Dictionary<string, object?>(), controller: new object());

        var reached = false;
        await new PublicBookingAccessAttribute().OnActionExecutionAsync(context, () =>
        {
            reached = true;
            return Task.FromResult(new ActionExecutedContext(actionContext, [], new object()));
        });

        return ((context.Result as ObjectResult)?.StatusCode, reached);
    }

    [Fact]
    public async Task Verify_is_reachable_with_no_origin_and_no_key()
    {
        Assert.Equal((null, true), await Gate(nameof(PublicBookingController.Verify)));
        Assert.Equal((null, true), await Gate(nameof(PublicBookingController.Verify), websiteEnabled: false));   // paused site too
    }

    [Fact]
    public async Task Pay_is_still_gated()
    {
        Assert.Equal((401, false), await Gate(nameof(PublicBookingController.Pay)));
        Assert.Equal((401, false), await Gate(nameof(PublicBookingController.Pay), origin: "https://evil.example"));
        Assert.Equal((null, true), await Gate(nameof(PublicBookingController.Pay), origin: "https://mokanco.com.lb"));
        Assert.Equal((503, false), await Gate(nameof(PublicBookingController.Pay), websiteEnabled: false, origin: "https://mokanco.com.lb"));
    }
}
