using System.Reflection;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Routing;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Api.Controllers;

namespace MokaCo.HRMS.Tests.Payroll;

/// <summary>
/// QA3 PAY-12 / WEB-4: who may call which payroll route. The web gates the payroll pages on PAYROLL_VIEW and
/// the reports on REPORT_VIEW; the API used to demand PAYROLL_RUN (class-wide) and ATTENDANCE_VIEW, so a
/// reader the web let in met a 403 on every call. Reads are PAYROLL_VIEW, preparing is PAYROLL_RUN, the acts
/// that turn figures into money are PAYROLL_APPROVE.
/// </summary>
public class PayrollPermissionTests
{
    private static string? PermissionOf(MemberInfo m)
        => m.GetCustomAttributes<HasPermissionAttribute>().SingleOrDefault()?.Policy?.Replace(HasPermissionAttribute.Prefix, "");

    private static IEnumerable<(MethodInfo Action, HttpMethodAttribute Verb)> Actions(Type controller)
        => controller.GetMethods(BindingFlags.Public | BindingFlags.Instance | BindingFlags.DeclaredOnly)
            .Select(m => (m, m.GetCustomAttribute<HttpMethodAttribute>()))
            .Where(x => x.Item2 is not null)
            .Select(x => (x.m, x.Item2!));

    [Fact]
    public void PayrollController_HasNoClassLevelGate()
        => Assert.Null(PermissionOf(typeof(PayrollController)));

    [Fact]
    public void PayrollController_EveryReadIsPayrollView()
    {
        var reads = Actions(typeof(PayrollController)).Where(a => a.Verb is HttpGetAttribute).ToList();
        Assert.NotEmpty(reads);
        Assert.All(reads, a => Assert.Equal("PAYROLL_VIEW", PermissionOf(a.Action)));
    }

    [Theory]
    [InlineData(nameof(PayrollController.CreateRun), "PAYROLL_RUN")]
    [InlineData(nameof(PayrollController.Generate), "PAYROLL_RUN")]
    [InlineData(nameof(PayrollController.SendToReview), "PAYROLL_RUN")]
    [InlineData(nameof(PayrollController.Cancel), "PAYROLL_RUN")]
    [InlineData(nameof(PayrollController.UpdateAdvanceMonthly), "PAYROLL_RUN")]
    [InlineData(nameof(PayrollController.DeleteAdjustment), "PAYROLL_RUN")]
    [InlineData(nameof(PayrollController.Approve), "PAYROLL_APPROVE")]
    [InlineData(nameof(PayrollController.SetPayment), "PAYROLL_APPROVE")]
    [InlineData(nameof(PayrollController.CreateAdjustmentsBulk), "PAYROLL_APPROVE")]
    public void PayrollController_EveryWriteHasItsTrust(string action, string permission)
        => Assert.Equal(permission, PermissionOf(typeof(PayrollController).GetMethod(action)!));

    [Fact]
    public void PayrollController_EveryWriteIsGated()
    {
        var writes = Actions(typeof(PayrollController)).Where(a => a.Verb is not HttpGetAttribute).ToList();
        Assert.All(writes, a => Assert.Contains(PermissionOf(a.Action), new[] { "PAYROLL_RUN", "PAYROLL_APPROVE" }));
    }

    [Fact]
    public void Reports_AreReportView()
    {
        var actions = Actions(typeof(ReportsController)).ToList();
        Assert.Equal(3, actions.Count);
        Assert.All(actions, a => Assert.Equal("REPORT_VIEW", PermissionOf(a.Action)));
    }
}
