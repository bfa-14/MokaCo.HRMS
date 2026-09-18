using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Abstractions;
using Microsoft.AspNetCore.Mvc.Controllers;
using Microsoft.AspNetCore.Mvc.Filters;
using Microsoft.AspNetCore.Mvc.ModelBinding;
using Microsoft.AspNetCore.Routing;
using Microsoft.Extensions.DependencyInjection;
using MokaCo.HRMS.Api.PublicBooking;

namespace MokaCo.HRMS.Tests.Booking;

/// <summary>
/// THE ACCESS FILTER, IN ITS STATED ORDER: paused (503, quote/create only) → an allowed Origin →
/// X-Booking-Key equal to a NON-EMPTY BookingApiKey → 401 { error: "Not allowed.", code:
/// "unauthorized" }. The gate is stubbed, so these run without a database and without the
/// 60-second cache in the way.
/// </summary>
public class PublicBookingAccessTests
{
    private sealed class StubGate(PublicBookingSnapshot snapshot) : IPublicBookingGate
    {
        public Task<PublicBookingSnapshot> CurrentAsync(CancellationToken cancellationToken = default) => Task.FromResult(snapshot);
    }

    private static readonly PublicBookingSnapshot Open = new(
        WebsiteEnabled: true,
        Origins: ["http://localhost:4321", "https://mokanco.com.lb"],
        ApiKey: "");

    private static async Task<(int? Status, string? Code, bool Reached)> Run(
        PublicBookingSnapshot snapshot, string? origin = null, string? key = null, bool pauses = false)
    {
        var services = new ServiceCollection().AddSingleton<IPublicBookingGate>(new StubGate(snapshot)).BuildServiceProvider();
        var http = new DefaultHttpContext { RequestServices = services };
        if (origin is not null) http.Request.Headers.Origin = origin;
        if (key is not null) http.Request.Headers[PublicBookingAccessAttribute.ApiKeyHeader] = key;

        var descriptor = new ControllerActionDescriptor
        {
            EndpointMetadata = pauses ? [new PausesWithWebsiteAttribute()] : [],
        };
        var actionContext = new ActionContext(http, new RouteData(), descriptor, new ModelStateDictionary());
        var context = new ActionExecutingContext(actionContext, [], new Dictionary<string, object?>(), controller: new object());

        var reached = false;
        await new PublicBookingAccessAttribute().OnActionExecutionAsync(context, () =>
        {
            reached = true;
            return Task.FromResult(new ActionExecutedContext(actionContext, [], new object()));
        });

        if (context.Result is ObjectResult result)
        {
            var body = result.Value!;
            var code = body.GetType().GetProperty("code")?.GetValue(body) as string;
            return (result.StatusCode, code, reached);
        }

        return (null, null, reached);
    }

    [Fact]
    public async Task An_allowed_origin_needs_nothing_else()
    {
        var (status, _, reached) = await Run(Open, origin: "http://localhost:4321");
        Assert.True(reached);
        Assert.Null(status);
    }

    [Fact]
    public async Task Origin_match_is_exact_and_case_insensitive()
    {
        Assert.True((await Run(Open, origin: "HTTPS://MOKANCO.COM.LB")).Reached);
        Assert.False((await Run(Open, origin: "https://mokanco.com.lb.attacker.example")).Reached);
        Assert.False((await Run(Open, origin: "http://localhost:4322")).Reached);
    }

    [Fact]
    public async Task No_origin_and_no_key_is_401_unauthorized()
    {
        var (status, code, reached) = await Run(Open);
        Assert.False(reached);
        Assert.Equal(401, status);
        Assert.Equal("unauthorized", code);
    }

    [Fact]
    public async Task A_key_opens_the_door_only_when_one_is_configured()
    {
        var withKey = Open with { ApiKey = "s3cret" };

        Assert.True((await Run(withKey, key: "s3cret")).Reached);
        Assert.Equal(401, (await Run(withKey, key: "S3CRET")).Status);
        Assert.Equal(401, (await Run(withKey, key: "s3cre")).Status);

        // An EMPTY setting means the key mode is OFF, not that any key will do.
        Assert.Equal(401, (await Run(Open, key: "")).Status);
        Assert.Equal(401, (await Run(Open, key: "anything")).Status);
    }

    [Fact]
    public async Task Paused_answers_503_on_quote_and_create_before_the_access_check()
    {
        var paused = Open with { WebsiteEnabled = false };

        var (status, code, reached) = await Run(paused, origin: "http://localhost:4321", pauses: true);
        Assert.False(reached);
        Assert.Equal(503, status);
        Assert.Equal("paused", code);

        // Even a caller with no access is told "paused" first — the truer answer.
        Assert.Equal(503, (await Run(paused, pauses: true)).Status);
    }

    [Fact]
    public async Task Paused_leaves_the_reads_up()
    {
        var paused = Open with { WebsiteEnabled = false };
        Assert.True((await Run(paused, origin: "http://localhost:4321")).Reached);
        Assert.Equal(401, (await Run(paused)).Status);
    }

    [Fact]
    public void Snapshot_ignores_a_trailing_slash_on_the_presented_origin()
    {
        Assert.True(Open.AllowsOrigin("http://localhost:4321/"));
        Assert.False(Open.AllowsOrigin(null));
        Assert.False(Open.AllowsOrigin(""));
    }
}
