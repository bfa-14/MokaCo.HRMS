using System.Reflection;
using System.Security.Claims;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Routing;
using Microsoft.Extensions.DependencyInjection;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Api.Controllers;

namespace MokaCo.HRMS.Tests.Attendance;

/// <summary>
/// THE RULE: attendance is changed by HR through its permissions, never by an employee editing it.
/// An employee changes their attendance only by raising a request (exit permission, correction)
/// through the workflow.
///
/// These tests hold every attendance controller to that rule by reflection, so a new action added
/// without a permission attribute fails the build's tests instead of quietly opening a write to
/// every logged-in user (the fallback policy only demands authentication, not a permission).
/// </summary>
public class AttendanceAuthorizationTests
{
    /// <summary>Permissions that may gate a write. One of these — never bare [Authorize] — on every non-GET action.</summary>
    private static readonly string[] WritePermissions =
        { "ATTENDANCE_CORRECT", "ATTENDANCE_MANAGE", "ATTENDANCE_IMPORT", "DEVICE_MANAGE" };

    /// <summary>Permissions that may gate a read of other people's attendance.</summary>
    private static readonly string[] ReadPermissions =
        WritePermissions.Concat(new[] { "ATTENDANCE_VIEW" }).ToArray();

    /// <summary>The controllers whose actions touch attendance data or its configuration.</summary>
    private static readonly Type[] AttendanceControllers =
    {
        typeof(AttendanceController),
        typeof(AttendanceCorrectionsController),
        typeof(AttendanceIngestionController),
        typeof(DevicesController),
        typeof(ShiftsController),
        typeof(RosterController),
        typeof(RosterApprovalsController),
        typeof(ExitPermissionsController),
    };

    /// <summary>
    /// The deliberate exceptions, each with the reason it is not a hole. Anything not listed here
    /// must carry one of the attendance permissions.
    /// </summary>
    private static readonly Dictionary<string, string> DocumentedExceptions = new()
    {
        // The terminal cannot hold a JWT; the action is gated by the per-device key filter instead.
        [$"{nameof(AttendanceIngestionController)}.{nameof(AttendanceIngestionController.Punch)}"] = "REQUIRES_DEVICE_KEY",
        // Raising a request IS the employee path. The service pins the employee id to the token.
        [$"{nameof(ExitPermissionsController)}.{nameof(ExitPermissionsController.Create)}"] = "REQUEST_RAISE_SELF",
        // A decision on a request: the database checks the caller is the step's approver.
        [$"{nameof(ExitPermissionsController)}.{nameof(ExitPermissionsController.Decide)}"] = "AUTHENTICATED",
        // The caller's own requests, resolved from the token.
        [$"{nameof(ExitPermissionsController)}.{nameof(ExitPermissionsController.Mine)}"] = "AUTHENTICATED",
        [$"{nameof(ExitPermissionsController)}.{nameof(ExitPermissionsController.GetByRequest)}"] = "AUTHENTICATED",
        // Read of a shift pattern for the request forms; the action itself restricts non-viewers to their own id.
        [$"{nameof(RosterController)}.{nameof(RosterController.GetEmployeePattern)}"] = "REQUEST_RAISE_SELF",
    };

    public static IEnumerable<object[]> Actions()
    {
        foreach (var controller in AttendanceControllers)
        foreach (var method in controller.GetMethods(BindingFlags.Public | BindingFlags.Instance | BindingFlags.DeclaredOnly))
        {
            if (method.GetCustomAttributes<HttpMethodAttribute>().Any())
                yield return new object[] { controller, method };
        }
    }

    [Theory]
    [MemberData(nameof(Actions))]
    public void Every_attendance_action_is_gated_by_a_permission_or_is_a_documented_exception(Type controller, MethodInfo action)
    {
        var key = $"{controller.Name}.{action.Name}";
        var isWrite = action.GetCustomAttributes<HttpMethodAttribute>()
            .SelectMany(a => a.HttpMethods)
            .Any(m => !string.Equals(m, "GET", StringComparison.OrdinalIgnoreCase));

        var permissions = EffectivePermissions(controller, action);
        var anonymous = action.GetCustomAttribute<AllowAnonymousAttribute>() is not null
                        || controller.GetCustomAttribute<AllowAnonymousAttribute>() is not null;

        if (DocumentedExceptions.TryGetValue(key, out var rule))
        {
            switch (rule)
            {
                case "REQUIRES_DEVICE_KEY":
                    Assert.True(anonymous, $"{key}: the device endpoint must be [AllowAnonymous] (the terminal has no JWT)");
                    Assert.NotNull(action.GetCustomAttribute<DeviceApiKeyAttribute>());
                    break;
                case "AUTHENTICATED":
                    Assert.False(anonymous, $"{key}: must not be anonymous");
                    Assert.NotNull(controller.GetCustomAttribute<AuthorizeAttribute>(inherit: true));
                    break;
                default:
                    Assert.False(anonymous, $"{key}: must not be anonymous");
                    Assert.Contains(rule, permissions);
                    break;
            }
            return;
        }

        Assert.False(anonymous, $"{key}: an attendance action must never be anonymous");
        var allowed = isWrite ? WritePermissions : ReadPermissions;
        Assert.True(permissions.Intersect(allowed).Any(),
            $"{key}: {(isWrite ? "a write" : "a read")} on attendance must carry one of [{string.Join(", ", allowed)}]; found [{string.Join(", ", permissions)}]");
    }

    [Fact]
    public void Overtime_sweep_into_attendance_requires_attendance_manage()
    {
        var action = typeof(OvertimeController).GetMethod(nameof(OvertimeController.ApplyToAttendance))!;
        Assert.Contains("ATTENDANCE_MANAGE", EffectivePermissions(typeof(OvertimeController), action));
    }

    [Fact]
    public void Attendance_controllers_have_a_class_level_floor()
    {
        // The floor is what stops a future action without its own attribute from being open to
        // every logged-in employee. RosterController is excluded on purpose: it hosts the
        // employee-facing shift-pattern read; AttendanceIngestionController hosts the device punch.
        foreach (var controller in new[]
                 {
                     typeof(AttendanceController), typeof(AttendanceCorrectionsController),
                     typeof(ShiftsController), typeof(DevicesController)
                 })
        {
            var floor = controller.GetCustomAttributes<HasPermissionAttribute>(inherit: false)
                .Select(a => a.Policy!.Substring(HasPermissionAttribute.Prefix.Length));
            Assert.Contains("ATTENDANCE_VIEW", floor);
        }
    }

    /// <summary>
    /// The policy the attribute resolves to must actually demand the claim: a caller whose token
    /// carries only the Employee role's permissions is refused, with the permission they succeed,
    /// and an unauthenticated principal is refused whatever it claims.
    /// </summary>
    [Theory]
    [InlineData("ATTENDANCE_CORRECT")]
    [InlineData("ATTENDANCE_MANAGE")]
    [InlineData("ATTENDANCE_IMPORT")]
    [InlineData("ATTENDANCE_VIEW")]
    public async Task Permission_policy_refuses_a_token_without_the_permission_and_accepts_one_with_it(string permission)
    {
        var services = new ServiceCollection();
        services.AddLogging();
        services.AddOptions();
        services.AddAuthorization();
        services.AddSingleton<IAuthorizationPolicyProvider, PermissionPolicyProvider>();
        var auth = services.BuildServiceProvider().GetRequiredService<IAuthorizationService>();
        var policy = HasPermissionAttribute.Prefix + permission;

        var employeePerms = new[] { "EMP_VIEW", "WORKFLOW_CONFIGURE", "REQUEST_RAISE_SELF", "REQUEST_RAISE_OTHERS", "REQUEST_VIEW_ALL" };
        var employee = Principal(employeePerms);
        var hr = Principal(employeePerms.Append(permission));
        var anonymous = new ClaimsPrincipal(new ClaimsIdentity(new[] { new Claim("perm", permission) })); // no authentication type = not authenticated

        Assert.False((await auth.AuthorizeAsync(employee, null, policy)).Succeeded, "a token without the permission must be refused");
        Assert.True((await auth.AuthorizeAsync(hr, null, policy)).Succeeded, "a token with the permission must pass");
        Assert.False((await auth.AuthorizeAsync(anonymous, null, policy)).Succeeded, "an unauthenticated principal must be refused");
    }

    private static ClaimsPrincipal Principal(IEnumerable<string> permissions)
    {
        var claims = new List<Claim> { new(ClaimTypes.NameIdentifier, "79") };
        claims.AddRange(permissions.Select(p => new Claim("perm", p)));
        return new ClaimsPrincipal(new ClaimsIdentity(claims, "Test"));
    }

    private static List<string> EffectivePermissions(Type controller, MethodInfo action)
        => controller.GetCustomAttributes<HasPermissionAttribute>(inherit: true)
            .Concat(action.GetCustomAttributes<HasPermissionAttribute>(inherit: true))
            .Select(a => a.Policy!.Substring(HasPermissionAttribute.Prefix.Length))
            .ToList();
}
