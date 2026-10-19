using System.Reflection;
using System.Security.Claims;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Abstractions;
using Microsoft.AspNetCore.Mvc.Filters;
using Microsoft.AspNetCore.Mvc.ModelBinding;
using Microsoft.AspNetCore.Routing;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Moq;
using MokaCo.HRMS.Api.Hubs;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Api.Controllers;
using MokaCo.HRMS.Model.HR;
using MokaCo.HRMS.Repository.HR;
using MokaCo.HRMS.Services.HR;

namespace MokaCo.HRMS.Tests.Api;

/// <summary>
/// QA3 SEC-2: a read of ONE record answers only inside the caller's branch scope (script 87's rule,
/// run by hr.usp_Scope_CallerSees), and a salary read also needs HR or payroll rights, or to be one's own.
/// </summary>
public class InCallerScopeAttributeTests
{
    private const int UserId = 5;

    private static async Task<(IActionResult? Result, bool Reached, Mock<IScopeRepository> Scopes)> Run(
        InCallerScopeAttribute attribute, CallerScope answer, object routeValue, string routeKey = "id", params string[] perms)
    {
        var scopes = new Mock<IScopeRepository>();
        scopes.Setup(s => s.CallerSeesAsync(UserId, It.IsAny<int?>(), It.IsAny<long?>(), It.IsAny<int?>())).ReturnsAsync(answer);

        var claims = new List<Claim> { new(ClaimTypes.NameIdentifier, UserId.ToString()) };
        claims.AddRange(perms.Select(p => new Claim("perm", p)));
        var http = new DefaultHttpContext
        {
            User = new ClaimsPrincipal(new ClaimsIdentity(claims, "test")),
            RequestServices = new ServiceCollection().AddSingleton(scopes.Object).BuildServiceProvider(),
        };
        var actionContext = new ActionContext(http, new RouteData(), new ActionDescriptor(), new ModelStateDictionary());
        var context = new ActionExecutingContext(actionContext, [], new Dictionary<string, object?> { [routeKey] = routeValue }, controller: new object());

        var reached = false;
        await attribute.OnActionExecutionAsync(context, () =>
        {
            reached = true;
            return Task.FromResult(new ActionExecutedContext(actionContext, [], new object()));
        });
        return (context.Result, reached, scopes);
    }

    private static CallerScope Answer(bool found = true, bool canSee = true, bool isSelf = false) => new() { Found = found, CanSee = canSee, IsSelf = isSelf };

    [Fact]
    public async Task Another_branchs_employee_is_403_and_never_read()
    {
        var (result, reached, _) = await Run(new InCallerScopeAttribute(ScopeTarget.Employee), Answer(canSee: false), 40);

        Assert.False(reached);
        Assert.Equal(403, Assert.IsType<ObjectResult>(result).StatusCode);
    }

    [Fact]
    public async Task A_missing_record_is_404()
    {
        var (result, reached, _) = await Run(new InCallerScopeAttribute(ScopeTarget.Employee), Answer(found: false, canSee: false), 999);

        Assert.False(reached);
        Assert.IsType<NotFoundResult>(result);
    }

    [Fact]
    public async Task Each_target_asks_about_its_own_kind_of_record()
    {
        var (_, reached, scopes) = await Run(new InCallerScopeAttribute(ScopeTarget.Attendance), Answer(), 9000000001L);
        Assert.True(reached);
        scopes.Verify(s => s.CallerSeesAsync(UserId, null, 9000000001L, null), Times.Once());

        (_, reached, scopes) = await Run(new InCallerScopeAttribute(ScopeTarget.Document), Answer(), 12);
        Assert.True(reached);
        scopes.Verify(s => s.CallerSeesAsync(UserId, null, null, 12), Times.Once());

        (_, reached, scopes) = await Run(new InCallerScopeAttribute(ScopeTarget.Employee) { RouteKey = "employeeId" }, Answer(), 30, routeKey: "employeeId");
        Assert.True(reached);
        scopes.Verify(s => s.CallerSeesAsync(UserId, 30, null, null), Times.Once());
    }

    [Fact]
    public async Task A_branch_manager_sees_the_branch_but_not_its_salaries()
    {
        var salary = new InCallerScopeAttribute(ScopeTarget.Employee) { Salary = true };

        var (result, reached, _) = await Run(salary, Answer(), 30, perms: "EMP_VIEW");
        Assert.False(reached);
        Assert.Equal(403, Assert.IsType<ObjectResult>(result).StatusCode);

        (_, reached, _) = await Run(salary, Answer(), 30, perms: ["EMP_VIEW", "PAYROLL_VIEW"]);
        Assert.True(reached);

        (_, reached, _) = await Run(salary, Answer(), 30, perms: ["EMP_VIEW", "EMP_VIEW_ALL"]);
        Assert.True(reached);

        (_, reached, _) = await Run(salary, Answer(isSelf: true), 30, perms: "EMP_VIEW");
        Assert.True(reached);
    }

    [Theory]
    [InlineData(typeof(EmployeesController), "GetProfile")]
    [InlineData(typeof(EmployeesController), "GetBranchHistory")]
    [InlineData(typeof(EmployeesController), "GetReportingLine")]
    [InlineData(typeof(EmployeesController), "GetLeaveRequests")]
    [InlineData(typeof(EmployeesController), "GetExpenses")]
    [InlineData(typeof(EmployeesController), "GetOvertime")]
    [InlineData(typeof(EmployeesController), "GetLeaveBalance")]
    [InlineData(typeof(EmployeesController), "GetSalaryComponents")]
    [InlineData(typeof(SalaryComponentsController), "GetByEmployee")]
    [InlineData(typeof(DocumentsController), "GetByEmployee")]
    [InlineData(typeof(DocumentsController), "Download")]
    [InlineData(typeof(AttendanceController), "GetById")]
    public void The_reads_of_one_record_are_scoped(Type controller, string action)
    {
        var method = controller.GetMethod(action, BindingFlags.Public | BindingFlags.Instance)!;
        Assert.NotNull(method.GetCustomAttribute<InCallerScopeAttribute>());
    }

    [Fact]
    public void Salary_reads_carry_the_salary_rule()
    {
        Assert.True(typeof(EmployeesController).GetMethod("GetSalaryComponents")!.GetCustomAttribute<InCallerScopeAttribute>()!.Salary);
        Assert.True(typeof(SalaryComponentsController).GetMethod("GetByEmployee")!.GetCustomAttribute<InCallerScopeAttribute>()!.Salary);
    }
}

/// <summary>QA3: /download serves only files under the storage root, whatever StoragePath a recorded document carries.</summary>
public class DocumentDownloadPathTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "qa3-docs-" + Guid.NewGuid().ToString("N"));

    public DocumentDownloadPathTests() => Directory.CreateDirectory(Path.Combine(_dir, "root", "7"));

    public void Dispose() => Directory.Delete(_dir, recursive: true);

    private async Task<IActionResult> Download(string storagePath)
    {
        var docs = new Mock<IDocumentService>();
        docs.Setup(d => d.GetByIdAsync(1)).ReturnsAsync(new Document { DocumentId = 1, EmployeeId = 7, FileName = "f.txt", StoragePath = storagePath, ContentType = "text/plain" });
        var config = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?> { ["Storage:DocumentsPath"] = Path.Combine(_dir, "root") }).Build();
        var controller = new DocumentsController(docs.Object, Mock.Of<IWebHostEnvironment>(), config, Mock.Of<ILiveNotifier>());
        return await controller.Download(1);
    }

    [Fact]
    public async Task A_file_under_the_root_is_served()
    {
        await File.WriteAllTextAsync(Path.Combine(_dir, "root", "7", "a.txt"), "ok");
        Assert.IsType<FileContentResult>(await Download(Path.Combine("7", "a.txt")));
    }

    [Theory]
    [InlineData("../secret.txt")]
    [InlineData("7/../../secret.txt")]
    public async Task A_path_that_climbs_out_of_the_root_is_not_served(string storagePath)
    {
        await File.WriteAllTextAsync(Path.Combine(_dir, "secret.txt"), "secret");
        Assert.IsType<NotFoundObjectResult>(await Download(storagePath));
    }

    [Fact]
    public async Task An_absolute_path_is_not_served()
    {
        var outside = Path.Combine(_dir, "secret.txt");
        await File.WriteAllTextAsync(outside, "secret");
        Assert.IsType<NotFoundObjectResult>(await Download(outside));
    }
}
