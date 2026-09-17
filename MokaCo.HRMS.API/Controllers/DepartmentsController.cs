using Microsoft.AspNetCore.Mvc;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Model.HR;
using MokaCo.HRMS.Services.HR;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Api.Controllers;

[ApiController]
[Route("api/departments")]
public class DepartmentsController : ControllerBase
{
    private readonly IDepartmentService _departments;
    private readonly ILiveNotifier _live;

    public DepartmentsController(IDepartmentService departments, ILiveNotifier live)
    {
        _departments = departments;
        _live = live;
    }

    [HttpGet]
    [HasPermission("EMP_VIEW")]
    public async Task<IActionResult> GetAll() => Ok(await _departments.GetAllAsync());

    [HttpPost]
    [HasPermission("ORG_MANAGE")]
    public async Task<IActionResult> Create([FromBody] DepartmentCreateRequest request)
    {
        var id = await _departments.CreateAsync(request.Name);
        await _live.NotifyAsync("hr", "dashboard");
        return CreatedAtAction(nameof(GetAll), new { id }, new { departmentId = id });
    }

    [HttpPut("{id:int}")]
    [HasPermission("ORG_MANAGE")]
    public async Task<IActionResult> Update(int id, [FromBody] DepartmentUpdateRequest request)
    {
        await _departments.UpdateAsync(id, request.Name, request.IsActive);
        await _live.NotifyAsync("hr", "dashboard");
        return NoContent();
    }

    /// <summary>
    /// Deletes an UNUSED department. One that anything references (employees, payslip lines, requests…)
    /// is refused with 409 and the procedure's own sentence — "Cannot delete 'X': it is used by 12
    /// employees and 340 payslip lines. Deactivate it instead." — which the UI shows verbatim.
    /// </summary>
    [HttpDelete("{id:int}")]
    [HasPermission("ORG_MANAGE")]
    public async Task<IActionResult> Delete(int id)
    {
        try
        {
            await _departments.DeleteAsync(id);
            await _live.NotifyAsync("hr", "dashboard");
            return NoContent();
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>The "deactivate it instead" path: PATCH …/{id}/active { isActive }.</summary>
    [HttpPatch("{id:int}/active")]
    [HasPermission("ORG_MANAGE")]
    public async Task<IActionResult> SetActive(int id, [FromBody] SetActiveRequest request)
    {
        try
        {
            await _departments.SetActiveAsync(id, request.IsActive);
            await _live.NotifyAsync("hr", "dashboard");
            return NoContent();
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }
}
