using System.Reflection;
using System.Security.Claims;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Abstractions;
using Microsoft.AspNetCore.Mvc.Filters;
using Microsoft.AspNetCore.Mvc.ModelBinding;
using Microsoft.AspNetCore.Routing;
using Microsoft.Extensions.DependencyInjection;
using Moq;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Api.Controllers;
using MokaCo.HRMS.Model.Workflow;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Tests.Api;

/// <summary>
/// QA3 SEC-1: a typed read of one request (payload, conflicts, an exit permission's day) answers only
/// to someone who may see the request itself — the rule of GET /api/requests/{id}, run first.
/// </summary>
public class RequestVisibleAttributeTests
{
    private const int UserId = 7;
    private const int EmployeeId = 70;

    private static async Task<(IActionResult? Result, bool Reached, RequestCaller? Seen)> Run(
        Func<RequestCaller, Task<RequestDetail?>> answer, bool viewAll = false)
    {
        RequestCaller? seen = null;
        var requests = new Mock<IRequestService>();
        requests.Setup(r => r.GetByIdAsync(42, It.IsAny<RequestCaller>()))
            .Returns((int _, RequestCaller c) => { seen = c; return answer(c); });
        var support = new Mock<IWorkflowSupportService>();
        support.Setup(s => s.GetEmployeeByUserIdAsync(UserId)).ReturnsAsync(new MyEmployee { EmployeeId = EmployeeId });

        var claims = new List<Claim> { new(ClaimTypes.NameIdentifier, UserId.ToString()) };
        if (viewAll)
            claims.Add(new Claim("perm", "REQUEST_VIEW_ALL"));
        var http = new DefaultHttpContext
        {
            User = new ClaimsPrincipal(new ClaimsIdentity(claims, "test")),
            RequestServices = new ServiceCollection()
                .AddSingleton(requests.Object).AddSingleton(support.Object).BuildServiceProvider(),
        };
        var actionContext = new ActionContext(http, new RouteData(), new ActionDescriptor(), new ModelStateDictionary());
        var context = new ActionExecutingContext(actionContext, [], new Dictionary<string, object?> { ["id"] = 42 }, controller: new object());

        var reached = false;
        await new RequestVisibleAttribute().OnActionExecutionAsync(context, () =>
        {
            reached = true;
            return Task.FromResult(new ActionExecutedContext(actionContext, [], new object()));
        });
        return (context.Result, reached, seen);
    }

    [Fact]
    public async Task Someone_who_may_not_see_the_request_gets_403_and_the_payload_is_never_read()
    {
        var (result, reached, _) = await Run(_ => throw new WorkflowException(403, "You do not have access to this request."));

        Assert.False(reached);
        Assert.Equal(403, Assert.IsType<ObjectResult>(result).StatusCode);
    }

    [Fact]
    public async Task No_such_request_is_404()
    {
        var (result, reached, _) = await Run(_ => Task.FromResult<RequestDetail?>(null));

        Assert.False(reached);
        Assert.IsType<NotFoundResult>(result);
    }

    [Fact]
    public async Task A_visible_request_reaches_the_action_judged_as_the_signed_in_employee()
    {
        var (result, reached, seen) = await Run(_ => Task.FromResult<RequestDetail?>(new RequestDetail()), viewAll: true);

        Assert.True(reached);
        Assert.Null(result);
        Assert.Equal(new RequestCaller(UserId, EmployeeId, HasViewAll: true), seen);
    }

    /// <summary>Every typed read keyed by a request id carries the gate — a new one cannot be added without it.</summary>
    [Fact]
    public void Every_typed_read_of_one_request_is_gated()
    {
        var routes = new[] { "{id:int}/payload", "{id:int}/conflicts", "by-request/{id:int}" };
        var actions = typeof(RequestsController).Assembly.GetTypes()
            .Where(t => typeof(ControllerBase).IsAssignableFrom(t))
            .SelectMany(t => t.GetMethods(BindingFlags.Public | BindingFlags.Instance | BindingFlags.DeclaredOnly))
            .Where(m => m.GetCustomAttributes<HttpGetAttribute>().Any(g => routes.Contains(g.Template)))
            .ToList();

        Assert.True(actions.Count >= 12, $"expected the 12 typed reads, found {actions.Count}");
        var ungated = actions.Where(m => m.GetCustomAttribute<RequestVisibleAttribute>() is null)
            .Select(m => $"{m.DeclaringType!.Name}.{m.Name}").ToList();
        Assert.Empty(ungated);
    }
}
