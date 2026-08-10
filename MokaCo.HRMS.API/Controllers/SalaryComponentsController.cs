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
    public async Task<IActionResult> GetByEmployee(int employeeId)
        => Ok(await _salaryComponents.GetByEmployeeAsync(employeeId));

    [HttpPost]
    [HasPermission("EMP_EDIT")]
    public async Task<IActionResult> Create([FromBody] SalaryComponentCreateRequest request)
    {
        var id = await _salaryComponents.CreateAsync(request);
        await NotifyPayAsync();
        return CreatedAtAction(nameof(GetByEmployee), new { employeeId = request.EmployeeId },
            new { salaryComponentId = id });
    }

    [HttpPut("{id:int}")]
    [HasPermission("EMP_EDIT")]
    public async Task<IActionResult> Update(int id, [FromBody] SalaryComponentUpdateRequest request)
    {
        await _salaryComponents.UpdateAsync(id, request);
        await NotifyPayAsync();
        return NoContent();
    }

    [HttpDelete("{id:int}")]
    [HasPermission("EMP_EDIT")]
    public async Task<IActionResult> Delete(int id)
    {
        await _salaryComponents.DeleteAsync(id);
        await NotifyPayAsync();
        return NoContent();
    }

    /// <summary>
    /// CLOSES a standing row on a date — the honest way to remove a component.
    ///
    /// Not the same act as <see cref="Delete"/> above, which erases the row: a component that was
    /// paid for six months and then stopped is history, and deleting it would rewrite what those
    /// months paid. Ending it says when it stopped and leaves the record intact.
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
