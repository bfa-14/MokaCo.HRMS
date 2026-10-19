using System.Reflection;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Routing;
using MokaCo.HRMS.Api.Controllers;

namespace MokaCo.HRMS.Tests.HR;

/// <summary>
/// QA3 PAY-6 / REL-2: the raw salary-row writes (POST / PUT / DELETE /api/salary-components) are gone. They
/// inserted, edited in place and hard-deleted rows with no locked-month check and never closed the standing
/// row, so a raise was paid on top of the old salary. A salary changes only through the history-preserving
/// PUT /api/employees/{id}/salary-components and the End action.
/// </summary>
public class SalaryComponentRoutesTests
{
    [Fact]
    public void SalaryComponents_OnlyTheReadAndTheEndRemain()
    {
        var actions = typeof(SalaryComponentsController)
            .GetMethods(BindingFlags.Public | BindingFlags.Instance | BindingFlags.DeclaredOnly)
            .Where(m => m.GetCustomAttribute<HttpMethodAttribute>() is not null)
            .Select(m => m.Name)
            .OrderBy(n => n)
            .ToList();
        Assert.Equal(new[] { "End", "GetByEmployee" }, actions);
    }

    [Fact]
    public void Employees_StillSetASalaryFromADate()
        => Assert.NotNull(typeof(EmployeesController).GetMethod(nameof(EmployeesController.SetSalaryComponent))
            ?.GetCustomAttribute<HttpPutAttribute>());
}
