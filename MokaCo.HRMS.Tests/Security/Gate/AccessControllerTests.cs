using System.Reflection;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Routing;
using Moq;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Api.Controllers;
using MokaCo.HRMS.Api.Hubs;
using MokaCo.HRMS.Model.Core;
using MokaCo.HRMS.Model.Security;
using MokaCo.HRMS.Services.Core;
using MokaCo.HRMS.Services.Security.Gate;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Tests.Security.Gate;

/// <summary>
/// api/access of §3: every action ACCESS_MANAGE, the routes and verbs of the table, the caller's gate
/// cookie handed to the service (for every write that could shut this browser out), and "sign everyone
/// out" re-issuing the caller's cookie. Plus G5: the generic settings endpoint refuses the four Google*
/// keys, and any key SQL Server could turn into one of them.
/// </summary>
public class AccessControllerTests
{
    private const int Caller = 20;
    private const string CookieValue = "v1.body.signature";

    private static (AccessController Controller, Mock<IGateService> Gate, HttpContext Http) Build(string? cookie = CookieValue)
    {
        var gate = new Mock<IGateService>(MockBehavior.Strict);
        var context = TestPrincipal.For(userId: Caller);
        if (cookie is not null)
            context.HttpContext.Request.Headers.Cookie = $"{GateCookieOptions.Name}={cookie}";
        return (new AccessController(gate.Object) { ControllerContext = context }, gate, context.HttpContext);
    }

    private static object? Field(object? value, string name) => value?.GetType().GetProperty(name)?.GetValue(value);

    /* ---- the §3 table ---- */

    public static TheoryData<string, string, string?> Endpoints() => new()
    {
        { nameof(AccessController.Get), "GET", null },
        { nameof(AccessController.SaveSettings), "PUT", "settings" },
        { nameof(AccessController.SetBlocked), "PUT", "people/{employeeId:int}/blocked" },
        { nameof(AccessController.AddExtraEmail), "POST", "extras" },
        { nameof(AccessController.UpdateExtraEmail), "PUT", "extras/{id:int}" },
        { nameof(AccessController.DeleteExtraEmail), "DELETE", "extras/{id:int}" },
        { nameof(AccessController.SignOutEveryone), "POST", "signout-everyone" },
    };

    [Theory]
    [MemberData(nameof(Endpoints))]
    public void Each_endpoint_has_the_route_verb_and_ACCESS_MANAGE(string action, string verb, string? template)
    {
        var type = typeof(AccessController);
        Assert.Equal("api/access", type.GetCustomAttribute<RouteAttribute>()?.Template);

        var method = type.GetMethod(action)!;
        var http = Assert.Single(method.GetCustomAttributes<HttpMethodAttribute>());
        Assert.Equal(verb, Assert.Single(http.HttpMethods));
        Assert.Equal(template, http.Template);
        var permissions = type.GetCustomAttributes<HasPermissionAttribute>()
            .Concat(method.GetCustomAttributes<HasPermissionAttribute>())
            .Select(a => a.Policy!.Substring(HasPermissionAttribute.Prefix.Length));
        Assert.Equal("ACCESS_MANAGE", Assert.Single(permissions));
    }

    [Fact]
    public void The_controller_has_exactly_the_seven_endpoints()
        => Assert.Equal(7, typeof(AccessController)
            .GetMethods(BindingFlags.Public | BindingFlags.Instance | BindingFlags.DeclaredOnly)
            .Count(m => m.GetCustomAttributes<HttpMethodAttribute>().Any()));

    /* ---- behaviour ---- */

    [Fact]
    public async Task Get_hands_the_service_this_browsers_cookie_and_the_caller()
    {
        var (controller, gate, _) = Build();
        var view = new GateAccessView { Caller = new GateCaller { Verified = true, Email = "rana@gmail.com" } };
        gate.Setup(g => g.GetAdminAsync(CookieValue, Caller)).ReturnsAsync(view);

        Assert.Same(view, Assert.IsType<OkObjectResult>(await controller.Get()).Value);
    }

    [Fact]
    public async Task Saving_settings_is_204_and_a_refusal_keeps_its_status_and_sentence()
    {
        var (controller, gate, _) = Build();
        var off = new GateSettingsRequest { Required = false, Days = 30 };
        var on = new GateSettingsRequest { Required = true, ClientId = "x.apps.googleusercontent.com", Days = 30 };
        gate.Setup(g => g.SaveSettingsAsync(off, CookieValue, Caller)).Returns(Task.CompletedTask);
        gate.Setup(g => g.SaveSettingsAsync(on, CookieValue, Caller)).ThrowsAsync(new WorkflowException(409, GateService.VerifyFirst));

        Assert.IsType<NoContentResult>(await controller.SaveSettings(off));

        var refused = Assert.IsAssignableFrom<ObjectResult>(await controller.SaveSettings(on));
        Assert.Equal(409, refused.StatusCode);
        Assert.Equal(GateService.VerifyFirst, Field(refused.Value, "error"));
    }

    [Fact]
    public async Task Blocking_yourself_is_the_procedures_refusal()
    {
        var (controller, gate, _) = Build();
        const string sentence = "You can't block yourself — you would lose access.";
        gate.Setup(g => g.SetBlockedAsync(12, true, CookieValue, Caller)).ThrowsAsync(WorkflowSqlErrors.MapMessage(sentence));

        var refused = Assert.IsAssignableFrom<ObjectResult>(await controller.SetBlocked(12, new GateBlockedRequest { Blocked = true }));

        Assert.Equal(400, refused.StatusCode);
        Assert.Equal(sentence, Field(refused.Value, "error"));
    }

    [Fact]
    public async Task The_writes_that_could_shut_this_browser_out_get_its_cookie_and_keep_the_409()
    {
        var (controller, gate, _) = Build();
        var off = new GateExtraEmailRequest { Email = "owner@gmail.com", IsActive = false };
        gate.Setup(g => g.SetBlockedAsync(12, true, CookieValue, Caller)).ThrowsAsync(new WorkflowException(409, GateService.BlockSelf));
        gate.Setup(g => g.UpdateExtraEmailAsync(3, off, CookieValue, Caller)).ThrowsAsync(new WorkflowException(409, GateService.OwnAddressOff));
        gate.Setup(g => g.DeleteExtraEmailAsync(3, CookieValue, Caller)).ThrowsAsync(new WorkflowException(409, GateService.OwnAddressRemoved));

        foreach (var (result, sentence) in new[]
        {
            (await controller.SetBlocked(12, new GateBlockedRequest { Blocked = true }), GateService.BlockSelf),
            (await controller.UpdateExtraEmail(3, off), GateService.OwnAddressOff),
            (await controller.DeleteExtraEmail(3), GateService.OwnAddressRemoved),
        })
        {
            var refused = Assert.IsAssignableFrom<ObjectResult>(result);
            Assert.Equal(409, refused.StatusCode);
            Assert.Equal(sentence, Field(refused.Value, "error"));
        }
    }

    [Fact]
    public async Task Adding_an_extra_address_is_201_with_its_id()
    {
        var (controller, gate, _) = Build();
        var request = new GateExtraEmailRequest { Email = "owner@gmail.com", Note = "Owner" };
        gate.Setup(g => g.AddExtraEmailAsync(request, Caller)).ReturnsAsync(5);

        var created = Assert.IsType<CreatedAtActionResult>(await controller.AddExtraEmail(request));

        Assert.Equal(201, created.StatusCode);
        Assert.Equal(5, Field(created.Value, "gateExtraEmailId"));
    }

    [Fact]
    public async Task Editing_and_removing_an_extra_address_are_204()
    {
        var (controller, gate, _) = Build();
        var request = new GateExtraEmailRequest { Email = "owner@gmail.com", IsActive = false };
        gate.Setup(g => g.UpdateExtraEmailAsync(5, request, CookieValue, Caller)).Returns(Task.CompletedTask);
        gate.Setup(g => g.DeleteExtraEmailAsync(5, CookieValue, Caller)).Returns(Task.CompletedTask);

        Assert.IsType<NoContentResult>(await controller.UpdateExtraEmail(5, request));
        Assert.IsType<NoContentResult>(await controller.DeleteExtraEmail(5));
    }

    [Fact]
    public async Task Sign_everyone_out_reissues_the_callers_cookie_and_answers_the_epoch()
    {
        var (controller, gate, http) = Build();
        gate.Setup(g => g.SignOutEveryoneAsync(CookieValue, Caller)).ReturnsAsync(new GateSignOutEveryoneResult(5, "v1.new.cookie", 30));

        var ok = Assert.IsType<OkObjectResult>(await controller.SignOutEveryone());

        Assert.Equal(5, Field(ok.Value, "epoch"));
        Assert.Equal(
            "mokaco_gate=v1.new.cookie; Max-Age=2592000; Path=/; Secure; HttpOnly; SameSite=Lax",
            Assert.Single(http.Response.Headers.SetCookie.ToArray()));
    }

    [Fact]
    public async Task Sign_everyone_out_sets_no_cookie_for_a_caller_who_had_none()
    {
        var (controller, gate, http) = Build(cookie: null);
        gate.Setup(g => g.SignOutEveryoneAsync(null, Caller)).ReturnsAsync(new GateSignOutEveryoneResult(5, null, 30));

        Assert.IsType<OkObjectResult>(await controller.SignOutEveryone());
        Assert.Equal(0, http.Response.Headers.SetCookie.Count);
    }

    /* ---- G5: the generic settings endpoint ---- */

    private static (SettingsController Controller, Mock<ISettingService> Settings, Mock<ILiveNotifier> Live) Settings()
    {
        var settings = new Mock<ISettingService>(MockBehavior.Strict);
        var live = new Mock<ILiveNotifier>(MockBehavior.Strict);
        return (new SettingsController(settings.Object, live.Object) { ControllerContext = TestPrincipal.For(userId: Caller) }, settings, live);
    }

    [Theory]
    [InlineData("GoogleSignInRequired")]
    [InlineData("GoogleClientId")]
    [InlineData("GoogleSignInDays")]
    [InlineData("GoogleSignInEpoch")]
    [InlineData("googlesigninrequired")]
    [InlineData("GOOGLECLIENTID")]
    public async Task The_generic_settings_endpoint_refuses_the_Google_keys(string key)
    {
        var (controller, settings, live) = Settings();

        var result = await controller.Upsert(key, new SettingUpsertRequest { SettingValue = "1", DataType = "bool" });

        var bad = Assert.IsType<BadRequestObjectResult>(result);
        Assert.Equal("Change this on Settings → Google sign-in.", Field(bad.Value, "error"));
        settings.VerifyNoOtherCalls();
        live.VerifyNoOtherCalls();
    }

    /// <summary>
    /// Keys that core.usp_Setting_Upsert's VARCHAR(60) @SettingKey turns into a Google* key: SQL Server's
    /// best fit for look-alike letters (proved on SQL_Latin1_General_CP1_CI_AS: İ, ĩ, Ī, ı, ō → I, i, o),
    /// the cut at 60 characters, trailing spaces. No such key is ever a real setting.
    /// </summary>
    [Theory]
    [InlineData("GoogleSign\u0130nRequired")]                 // %C4%B0 İ
    [InlineData("GoogleSign\u0129nRequired")]                 // %C4%A9 ĩ
    [InlineData("GoogleSign\u012AnEpoch")]                    // Ī
    [InlineData("GoogleSign\u0131nDays")]                     // ı
    [InlineData("G\u014DogleSignInRequired")]                 // ō
    [InlineData("\uFF27oogleSignInRequired")]                 // full-width Ｇ
    [InlineData("GoogleSignInRequired ")]
    [InlineData(" GoogleSignInEpoch")]
    [InlineData("GoogleSignInRequired\n")]
    [InlineData("GoogleClientId\t")]
    [InlineData("GoogleSignInRequired                                        x")]   // 61: cut to the key + spaces
    [InlineData("GoogleSignInRequired\u0000")]
    [InlineData("Show Page Help")]
    [InlineData("ShowPageHelp\u00E9")]
    public async Task The_generic_settings_endpoint_refuses_a_key_that_is_not_plain(string key)
    {
        var (controller, settings, live) = Settings();

        var result = await controller.Upsert(key, new SettingUpsertRequest { SettingValue = "1", DataType = "bool" });

        var bad = Assert.IsType<BadRequestObjectResult>(result);
        Assert.Equal("That is not a setting key.", Field(bad.Value, "error"));
        settings.VerifyNoOtherCalls();
        live.VerifyNoOtherCalls();
        Assert.True(GateSettingKeys.IsGateKey(key));   // and the predicate alone would refuse it too
    }

    [Fact]
    public void A_plain_key_is_letters_digits_dot_underscore_hyphen_up_to_sixty()
    {
        Assert.True(GateSettingKeys.IsPlainKey(new string('K', 60)));
        Assert.False(GateSettingKeys.IsPlainKey(new string('K', 61)));
        Assert.True(GateSettingKeys.IsPlainKey("Booking.Api_Key-2"));
        Assert.False(GateSettingKeys.IsPlainKey(""));
        Assert.False(GateSettingKeys.IsPlainKey(null));
        Assert.False(GateSettingKeys.IsGateKey(""));
        Assert.False(GateSettingKeys.IsGateKey(null));
    }

    [Theory]
    [InlineData("ShowPageHelp")]
    [InlineData("GoogleMapsKey")]
    [InlineData("BookingApiKey")]
    [InlineData("GoogleSignInRequiredX")]
    public async Task Every_other_key_is_saved_as_before(string key)
    {
        var (controller, settings, live) = Settings();
        var request = new SettingUpsertRequest { SettingValue = "x" };
        settings.Setup(s => s.UpsertAsync(key, request, Caller)).Returns(Task.CompletedTask);
        live.Setup(l => l.NotifyAsync("workflow", "payroll", "attendance", "hr", "dashboard")).Returns(Task.CompletedTask);

        Assert.IsType<NoContentResult>(await controller.Upsert(key, request));
        settings.Verify(s => s.UpsertAsync(key, request, Caller), Times.Once);
    }
}
