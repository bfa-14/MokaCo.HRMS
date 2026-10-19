using System.Reflection;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Routing;
using Microsoft.AspNetCore.RateLimiting;
using Microsoft.Extensions.Logging.Abstractions;
using Moq;
using MokaCo.HRMS.Api.Controllers;
using MokaCo.HRMS.Model.Security;
using MokaCo.HRMS.Services.Security.Gate;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Tests.Security.Gate;

/// <summary>
/// api/gate of §3. The check answers 204 or 401 and nothing else — no body, never an exception, never
/// a redirect; an exempt path never reaches the service. Every answer is Cache-Control: no-store. The
/// sign-in sets the cookie with every flag; a refusal sets none.
/// </summary>
public class GateControllerTests
{
    private const string CookieValue = "v1.body.signature";

    private static (GateController Controller, Mock<IGateService> Gate, DefaultHttpContext Http) Build(
        string? originalUri = "/employees", string? cookie = CookieValue)
    {
        var gate = new Mock<IGateService>(MockBehavior.Strict);
        var http = new DefaultHttpContext();
        if (originalUri is not null)
            http.Request.Headers[GateController.OriginalUriHeader] = originalUri;
        if (cookie is not null)
            http.Request.Headers.Cookie = $"mokaco_env=test; {GateCookieOptions.Name}={cookie}";

        var controller = new GateController(gate.Object, NullLogger<GateController>.Instance)
        {
            ControllerContext = new ControllerContext { HttpContext = http },
        };
        return (controller, gate, http);
    }

    private static object? Field(object? value, string name) => value?.GetType().GetProperty(name)?.GetValue(value);

    /// <summary>The status the client receives, and whether the result writes a body.</summary>
    private static (int Status, bool HasBody) Answer(IActionResult result, HttpContext http) => result switch
    {
        NoContentResult => (204, false),
        EmptyResult => (http.Response.StatusCode, false),
        ObjectResult obj => (obj.StatusCode ?? 200, true),
        StatusCodeResult code => (code.StatusCode, false),
        _ => throw new InvalidOperationException(result.GetType().Name),
    };

    /* ---- check ---- */

    [Theory]
    [InlineData("/health")]
    [InlineData("/gate/index.html")]
    [InlineData("/api/gate/config")]
    [InlineData("/iclock/cdata?SN=1")]
    [InlineData("/api/attendance/punch")]
    public async Task An_exempt_path_is_204_without_asking_the_service(string uri)
    {
        var (controller, gate, http) = Build(uri, cookie: null);

        var result = await controller.Check();

        Assert.Equal((204, false), Answer(result, http));
        gate.VerifyNoOtherCalls();
        Assert.Equal("no-store", http.Response.Headers.CacheControl.ToString());
    }

    [Fact]
    public async Task Gate_off_or_a_valid_cookie_is_204_and_the_service_gets_the_cookie()
    {
        var (controller, gate, http) = Build("/employees");
        gate.Setup(g => g.IsAllowedAsync(CookieValue, It.IsAny<CancellationToken>())).ReturnsAsync(true);

        Assert.Equal((204, false), Answer(await controller.Check(), http));
        gate.Verify(g => g.IsAllowedAsync(CookieValue, It.IsAny<CancellationToken>()), Times.Once);
    }

    [Fact]
    public async Task No_or_an_invalid_cookie_is_401_with_no_body()
    {
        var (controller, gate, http) = Build("/api/employees", cookie: null);
        gate.Setup(g => g.IsAllowedAsync(null, It.IsAny<CancellationToken>())).ReturnsAsync(false);

        var result = await controller.Check();

        Assert.IsType<EmptyResult>(result);
        Assert.Equal((401, false), Answer(result, http));
        Assert.Equal("no-store", http.Response.Headers.CacheControl.ToString());
    }

    [Fact]
    public async Task A_fault_is_401_never_an_exception()
    {
        var (controller, gate, http) = Build("/employees");
        gate.Setup(g => g.IsAllowedAsync(It.IsAny<string?>(), It.IsAny<CancellationToken>()))
            .ThrowsAsync(new InvalidOperationException("the database is gone"));

        var result = await controller.Check();

        Assert.Equal((401, false), Answer(result, http));
    }

    [Fact]
    public async Task No_original_uri_is_not_exempt()
    {
        var (controller, gate, http) = Build(originalUri: null);
        gate.Setup(g => g.IsAllowedAsync(CookieValue, It.IsAny<CancellationToken>())).ReturnsAsync(false);

        Assert.Equal((401, false), Answer(await controller.Check(), http));
    }

    [Fact]
    public async Task Two_original_uri_headers_are_not_trusted_as_exempt()
    {
        var (controller, gate, http) = Build(originalUri: null);
        http.Request.Headers[GateController.OriginalUriHeader] = new[] { "/health", "/api/employees" };
        gate.Setup(g => g.IsAllowedAsync(CookieValue, It.IsAny<CancellationToken>())).ReturnsAsync(false);

        Assert.Equal((401, false), Answer(await controller.Check(), http));
        gate.Verify(g => g.IsAllowedAsync(CookieValue, It.IsAny<CancellationToken>()), Times.Once);
    }

    [Fact]
    public async Task A_traversal_through_the_gate_folder_is_asked_like_any_page()
    {
        var (controller, gate, http) = Build("/gate/../api/employees", cookie: null);
        gate.Setup(g => g.IsAllowedAsync(null, It.IsAny<CancellationToken>())).ReturnsAsync(false);

        Assert.Equal((401, false), Answer(await controller.Check(), http));
    }

    /* ---- config ---- */

    [Fact]
    public async Task Config_is_the_services_answer_for_this_browsers_cookie()
    {
        var (controller, gate, http) = Build();
        var config = new GateConfig { Required = true, ClientId = "x.apps.googleusercontent.com", Days = 30 };
        gate.Setup(g => g.GetConfigAsync(CookieValue)).ReturnsAsync(config);

        var result = await controller.GetConfig();

        Assert.Same(config, Assert.IsType<OkObjectResult>(result).Value);
        Assert.Equal("no-store", http.Response.Headers.CacheControl.ToString());
    }

    /* ---- google ---- */

    [Fact]
    public async Task An_allowed_sign_in_sets_the_cookie_with_every_flag()
    {
        var (controller, gate, http) = Build(cookie: null);
        http.Connection.RemoteIpAddress = System.Net.IPAddress.Parse("203.0.113.9");
        http.Request.Headers.UserAgent = "Mozilla/5.0 (iPhone)";
        gate.Setup(g => g.SignInAsync("the-credential", "203.0.113.9", "Mozilla/5.0 (iPhone)"))
            .ReturnsAsync(new GateSignInResult("rana@gmail.com", "Rana Haddad", 30, "v1.new.cookie"));

        var result = await controller.SignInWithGoogle(new GateGoogleSignInRequest { Credential = "the-credential" });

        var ok = Assert.IsType<OkObjectResult>(result);
        Assert.Equal("rana@gmail.com", Field(ok.Value, "email"));
        Assert.Equal("Rana Haddad", Field(ok.Value, "name"));
        Assert.Equal(30, Field(ok.Value, "days"));
        Assert.Equal(
            "mokaco_gate=v1.new.cookie; Max-Age=2592000; Path=/; Secure; HttpOnly; SameSite=Lax",
            Assert.Single(http.Response.Headers.SetCookie.ToArray()));
        Assert.Equal("no-store", http.Response.Headers.CacheControl.ToString());
    }

    [Theory]
    [InlineData(400, "Google could not confirm this sign-in — try again.")]
    [InlineData(403, "rana@gmail.com is not on the HRMS list. Ask the administrator to put this Gmail on your employee record.")]
    [InlineData(503, "Google sign-in is not set up yet. Ask the administrator.")]
    public async Task A_refused_sign_in_is_its_status_and_sentence_and_sets_no_cookie(int status, string sentence)
    {
        var (controller, gate, http) = Build();
        gate.Setup(g => g.SignInAsync(It.IsAny<string?>(), It.IsAny<string?>(), It.IsAny<string?>()))
            .ThrowsAsync(new WorkflowException(status, sentence));

        var result = await controller.SignInWithGoogle(new GateGoogleSignInRequest { Credential = "x" });

        var obj = Assert.IsAssignableFrom<ObjectResult>(result);
        Assert.Equal(status, obj.StatusCode);
        Assert.Equal(sentence, Field(obj.Value, "error"));
        Assert.Equal(0, http.Response.Headers.SetCookie.Count);
    }

    [Fact]
    public async Task A_missing_body_is_judged_by_the_service_as_no_credential()
    {
        var (controller, gate, _) = Build();
        gate.Setup(g => g.SignInAsync(null, It.IsAny<string?>(), It.IsAny<string?>()))
            .ThrowsAsync(new WorkflowException(400, "Google could not confirm this sign-in — try again."));

        Assert.Equal(400, Assert.IsAssignableFrom<ObjectResult>(await controller.SignInWithGoogle(null)).StatusCode);
    }

    /* ---- signout ---- */

    [Fact]
    public void Sign_out_clears_the_cookie()
    {
        var (controller, gate, http) = Build();

        var result = controller.SignOutBrowser();

        Assert.IsType<NoContentResult>(result);
        Assert.Equal("mokaco_gate=; Max-Age=0; Path=/; Secure; HttpOnly; SameSite=Lax", Assert.Single(http.Response.Headers.SetCookie.ToArray()));
        Assert.Equal("no-store", http.Response.Headers.CacheControl.ToString());
        gate.VerifyNoOtherCalls();
    }

    /* ---- the §3 table ---- */

    [Fact]
    public void The_controller_is_anonymous_at_api_gate()
    {
        var type = typeof(GateController);
        Assert.Equal("api/gate", type.GetCustomAttribute<RouteAttribute>()?.Template);
        Assert.NotNull(type.GetCustomAttribute<AllowAnonymousAttribute>());
        Assert.Empty(type.GetCustomAttributes<AuthorizeAttribute>());
    }

    public static TheoryData<string, string[], string> Endpoints() => new()
    {
        { nameof(GateController.Check), ["GET", "HEAD"], "check" },
        { nameof(GateController.GetConfig), ["GET"], "config" },
        { nameof(GateController.SignInWithGoogle), ["POST"], "google" },
        { nameof(GateController.SignOutBrowser), ["POST"], "signout" },
    };

    [Theory]
    [MemberData(nameof(Endpoints))]
    public void Each_endpoint_has_the_route_and_verbs_of_the_spec(string action, string[] verbs, string template)
    {
        var method = typeof(GateController).GetMethod(action)!;
        var http = method.GetCustomAttributes<HttpMethodAttribute>().ToList();

        Assert.Equal(verbs, http.SelectMany(a => a.HttpMethods).Order());
        Assert.All(http, a => Assert.Equal(template, a.Template));
        Assert.Empty(method.GetCustomAttributes<AuthorizeAttribute>());
    }

    [Fact]
    public void The_controller_has_exactly_the_four_endpoints()
        => Assert.Equal(4, typeof(GateController)
            .GetMethods(BindingFlags.Public | BindingFlags.Instance | BindingFlags.DeclaredOnly)
            .Count(m => m.GetCustomAttributes<HttpMethodAttribute>().Any()));

    [Fact]
    public void Only_the_sign_in_is_rate_limited_and_with_the_gate_signin_policy()
    {
        var limited = typeof(GateController).GetMethods()
            .Where(m => m.GetCustomAttribute<EnableRateLimitingAttribute>() is not null)
            .ToList();

        var signIn = Assert.Single(limited);
        Assert.Equal(nameof(GateController.SignInWithGoogle), signIn.Name);
        Assert.Equal("gate-signin", signIn.GetCustomAttribute<EnableRateLimitingAttribute>()!.PolicyName);
    }
}
