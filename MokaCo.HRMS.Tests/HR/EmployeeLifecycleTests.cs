using System.Reflection;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Moq;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Api.Controllers;
using MokaCo.HRMS.Model.HR;
using MokaCo.HRMS.Model.Security;
using MokaCo.HRMS.Repository.HR;
using MokaCo.HRMS.Services.HR;

namespace MokaCo.HRMS.Tests.HR;

/// <summary>
/// QA3 unit W (docs/106_qa3_webhr.sql): the C# side of a new employee's tier (LEAD-1), the nightly termination sweep
/// (REL-4), the shift-swap partners (WEB-2) and the two pick-lists of the chain builder. The rules themselves live in
/// the procedures and are tested by tests/qa3/webhr/*.sql; these pin what the API passes and how it is gated.
/// </summary>
public class EmployeeLifecycleTests
{
    private static EmployeeCreateRequest Request(int? tier) => new()
    {
        BranchId = 1, DepartmentId = 1, PositionId = 1,
        FullName = "W3TEST Person", HireDate = new DateTime(2026, 1, 5),
        Email = "w3@mokaco.com", PhoneNumber = "03123456", ApprovalTier = tier,
    };

    /* ---- LEAD-1: the tier travels with the create, so there is no window in which the person is the head ---- */

    [Fact]
    public async Task Create_passes_the_chosen_tier_to_the_procedure()
    {
        var repo = new Mock<IEmployeeRepository>(MockBehavior.Strict);
        repo.Setup(r => r.CreateAsync(
                null, 1, 1, 1, "W3TEST Person", null, null, new DateTime(2026, 1, 5), 7,
                "w3@mokaco.com", "+9613123456", null, 6))
            .ReturnsAsync(11);

        var id = await new EmployeeService(repo.Object).CreateAsync(Request(6), 7);

        Assert.Equal(11, id);
        repo.VerifyAll();
    }

    [Fact]
    public async Task Create_without_a_tier_sends_null_never_a_tier_of_its_own()
    {
        // Null is the procedure's to resolve (the lowest tier of the dictionary). A 1 chosen here would be the head.
        var repo = new Mock<IEmployeeRepository>(MockBehavior.Strict);
        repo.Setup(r => r.CreateAsync(
                null, 1, 1, 1, "W3TEST Person", null, null, new DateTime(2026, 1, 5), 7,
                "w3@mokaco.com", "+9613123456", null, null))
            .ReturnsAsync(12);

        Assert.Equal(12, await new EmployeeService(repo.Object).CreateAsync(Request(null), 7));
        repo.VerifyAll();
    }

    /* ---- REL-4: the sweep is the procedure's; the service hands its one row back unchanged ---- */

    [Fact]
    public async Task The_termination_sweep_returns_the_procedures_counts()
    {
        var row = new TerminationSweepResult { EmployeesApplied = 2, UsersDisabled = 1, UsersKept = 1, PinMappingsRemoved = 3, Summary = "x" };
        var repo = new Mock<IEmployeeRepository>(MockBehavior.Strict);
        repo.Setup(r => r.ApplyDueTerminationsAsync()).ReturnsAsync(row);

        Assert.Same(row, await new EmployeeService(repo.Object).ApplyDueTerminationsAsync());
    }

    /* ---- WEB-2: one result set, split into the requester and the colleagues ---- */

    [Fact]
    public async Task Swap_counterparts_split_the_requester_from_the_colleagues_in_order()
    {
        var repo = new Mock<IEmployeeRepository>(MockBehavior.Strict);
        repo.Setup(r => r.GetSwapCounterpartsAsync(5, 9)).ReturnsAsync(new[]
        {
            new SwapCounterpartRow { EmployeeId = 5, FullName = "Requester", Position = "Barista", Branch = "Hamra", IsRequester = true },
            new SwapCounterpartRow { EmployeeId = 7, FullName = "Ali", Position = "Barista", Branch = "Hamra" },
            new SwapCounterpartRow { EmployeeId = 6, FullName = "Maya", Position = "Barista", Branch = "Hamra", TerminationDate = new DateTime(2026, 11, 30) },
        });

        var result = await new EmployeeService(repo.Object).GetSwapCounterpartsAsync(5, 9);

        Assert.Equal(5, result.Requester?.EmployeeId);
        Assert.Equal(new[] { 7, 6 }, result.Counterparts.Select(c => c.EmployeeId));
    }

    [Fact]
    public void Swap_counterparts_without_rows_have_no_requester_and_nobody_to_offer()
    {
        var result = SwapCounterparts.From(Array.Empty<SwapCounterpartRow>());
        Assert.Null(result.Requester);
        Assert.Empty(result.Counterparts);
    }

    /* ---- the chain builder's pick-lists ---- */

    [Fact]
    public void The_user_pick_list_offers_active_accounts_only_by_username_and_nothing_else()
    {
        var users = new[]
        {
            new UserListItem { UserId = 3, Username = "zeina", IsActive = true, EmployeeName = "Zeina K", LastLoginAt = DateTime.UtcNow },
            new UserListItem { UserId = 1, Username = "Adam", IsActive = true },
            new UserListItem { UserId = 2, Username = "bilal", IsActive = false, EmployeeName = "Bilal" },
        };

        var list = PickLists.Users(users);

        Assert.Equal(new[] { 1, 3 }, list.Select(u => u.UserId));
        Assert.Equal(new UserPickItem(3, "zeina", "Zeina K"), list[1]);
        // the record carries no sign-in time and no roles — that stays behind USER_MANAGE
        Assert.Equal(new[] { "UserId", "Username", "EmployeeName" },
            typeof(UserPickItem).GetProperties().Select(p => p.Name).Where(n => n != "EqualityContract"));
    }

    [Fact]
    public void The_role_pick_list_is_every_role_by_name()
    {
        var roles = new[] { new Role { RoleId = 2, Name = "Owner" }, new Role { RoleId = 9, Name = "hr" }, new Role { RoleId = 4, Name = "Admin" } };
        Assert.Equal(new[] { "Admin", "hr", "Owner" }, PickLists.Roles(roles).Select(r => r.Name));
    }

    /* ---- the gates: signed-in only, the procedure decides the rest; the pick-lists are the chain builder's ---- */

    public static IEnumerable<object[]> SignedInOnlyActions() => new[]
    {
        new object[] { typeof(EmployeesController), nameof(EmployeesController.GetSwapCounterparts), "{id:int}/swap-counterparts" },
    };

    [Theory]
    [MemberData(nameof(SignedInOnlyActions))]
    public void The_new_reads_need_a_sign_in_and_no_permission(Type controller, string action, string template)
    {
        var method = controller.GetMethod(action)!;
        var get = method.GetCustomAttribute<HttpGetAttribute>();
        Assert.NotNull(get);
        Assert.Equal(template, get!.Template);
        Assert.NotNull(method.GetCustomAttribute<AuthorizeAttribute>());
        Assert.Null(method.GetCustomAttribute<HasPermissionAttribute>());
        Assert.Null(method.GetCustomAttribute<Microsoft.AspNetCore.Authorization.AllowAnonymousAttribute>());
    }

    /// <summary>The user and role pick-lists: WORKFLOW_CONFIGURE, as the chain builder's other reads - usernames are not for every signed-in user.</summary>
    [Theory]
    [InlineData(typeof(UsersController))]
    [InlineData(typeof(RolesController))]
    public void The_pick_lists_are_for_the_chain_builder(Type controller)
    {
        var method = controller.GetMethod("GetNames")!;
        Assert.Equal("names", method.GetCustomAttribute<HttpGetAttribute>()!.Template);
        Assert.Equal("perm:WORKFLOW_CONFIGURE", method.GetCustomAttribute<HasPermissionAttribute>()!.Policy);
        Assert.Null(method.GetCustomAttribute<Microsoft.AspNetCore.Authorization.AllowAnonymousAttribute>());
    }

    [Fact]
    public void The_full_user_and_role_lists_stay_behind_their_permissions()
    {
        Assert.Equal("perm:USER_MANAGE", typeof(UsersController).GetMethod(nameof(UsersController.GetAll))!.GetCustomAttribute<HasPermissionAttribute>()!.Policy);
        Assert.Equal("perm:ROLE_MANAGE", typeof(RolesController).GetMethod(nameof(RolesController.GetRoles))!.GetCustomAttribute<HasPermissionAttribute>()!.Policy);
    }
}
