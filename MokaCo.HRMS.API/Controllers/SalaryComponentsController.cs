using System.Security.Claims;
using Microsoft.AspNetCore.Mvc;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Model.HR;
using MokaCo.HRMS.Services.HR;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Api.Controllers;

[ApiController]
[Route("api/salary-components")]
public class SalaryComponentsController : ControllerBase
{
    private readonly ISalaryComponentService _salaryComponents;
    private readonly ILiveNotifier _live;

    public SalaryComponentsController(
        ISalaryComponentService salaryComponents, ILiveNotifier live)
    {
        _salaryComponents = salaryComponents;
        _live = live;
    }

    /// <summary>These rows ARE somebody's pay — the next run reads them.</summary>
    private Task NotifyPayAsync() => _live.NotifyAsync("hr", "payroll", "dashboard");

    private int CurrentUserId =>
        int.Parse(User.FindFirstValue(ClaimTypes.NameIdentifier) ?? User.FindFirstValue("sub")!);

    [HttpGet("by-employee/{employeeId:int}")]
    [HasPermission("EMP_VIEW")]

    [InCallerScope(ScopeTarget.Employee, RouteKey = "employeeId", Salary = true)]
    public async Task<IActionResult> GetByEmployee(int employeeId)
        => Ok(await _salaryComponents.GetByEmployeeAsync(employeeId));

    /* THE RAW WRITES ARE RETIRED (QA3 PAY-6 / REL-2). POST, PUT and DELETE on this resource used to
       insert, edit in place and hard-delete hr.SALARY_COMPONENT rows: no locked-month check, the
       standing row never closed (a raise from the 16th was paid on top of the old salary, both in
       full), and a deleted row rewrote what a paid month had paid. Nothing calls them any more — the
       Salary tab sets a value FROM a date through PUT /api/employees/{id}/salary-components (which
       closes the standing row the day before, refuses a locked month and names the earliest date that
       works) and closes a row with the End action below. A raw route left in place would be the next
       way round both rules, so they are gone rather than patched. */

    /// <summary>
    /// CLOSES a standing row on a date — the honest way to remove a component.
    ///
    /// Not the same act as the retired DELETE, which erased the row: a component that was paid for
    /// six months and then stopped is history, and deleting it would rewrite what those months paid.
    /// Ending it says when it stopped and leaves the record intact.
    ///
    /// The procedure refuses an already-closed row, an end before the start, and any date inside a
    /// locked month. HR (or Admin) only, checked in SQL.
    /// </summary>
    [HttpPost("{id:int}/end")]
    [HasPermission("EMP_EDIT")]
    public async Task<IActionResult> End(int id, [FromBody] SalaryComponentEndRequest request)
    {
        try
        {
            var ended = await _salaryComponents.EndAsync(id, request, CurrentUserId);
            await NotifyPayAsync();
            return Ok(ended);
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }
}
