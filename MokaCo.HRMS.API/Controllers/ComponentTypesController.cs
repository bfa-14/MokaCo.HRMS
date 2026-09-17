using Microsoft.AspNetCore.Mvc;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Model.HR;
using MokaCo.HRMS.Services.HR;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Api.Controllers;

[ApiController]
[Route("api/component-types")]
public class ComponentTypesController : ControllerBase
{
    private readonly IComponentTypeService _componentTypes;
    private readonly ILiveNotifier _live;

    public ComponentTypesController(IComponentTypeService componentTypes, ILiveNotifier live)
    {
        _componentTypes = componentTypes;
        _live = live;
    }

    [HttpGet]
    [HasPermission("EMP_VIEW")]
    public async Task<IActionResult> GetAll() => Ok(await _componentTypes.GetAllAsync());

    [HttpPost]
    [HasPermission("COMPONENT_MANAGE")]
    public async Task<IActionResult> Create([FromBody] ComponentTypeCreateRequest request)
    {
        var id = await _componentTypes.CreateAsync(request.Name, request.Category, request.Sign, request.IsActive);
        await _live.NotifyAsync("payroll");
        return CreatedAtAction(nameof(GetAll), new { id }, new { componentTypeId = id });
    }

    [HttpPut("{id:int}")]
    [HasPermission("COMPONENT_MANAGE")]
    public async Task<IActionResult> Update(int id, [FromBody] ComponentTypeUpdateRequest request)
    {
        await _componentTypes.UpdateAsync(id, request.Name, request.Category, request.Sign, request.IsActive);
        // The SIGN decides whether an amount is paid or deducted — never a cosmetic edit.
        await _live.NotifyAsync("payroll");
        return NoContent();
    }

    /// <summary>
    /// Deletes an UNUSED salary component type. One that anything references (employees, payslip lines, requests…)
    /// is refused with 409 and the procedure's own sentence — "Cannot delete 'X': it is used by 12
    /// employees and 340 payslip lines. Deactivate it instead." — which the UI shows verbatim.
    /// </summary>
    [HttpDelete("{id:int}")]
    [HasPermission("COMPONENT_MANAGE")]
    public async Task<IActionResult> Delete(int id)
    {
        try
        {
            await _componentTypes.DeleteAsync(id);
            await _live.NotifyAsync("payroll");
            return NoContent();
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>The "deactivate it instead" path: PATCH …/{id}/active { isActive }.</summary>
    [HttpPatch("{id:int}/active")]
    [HasPermission("COMPONENT_MANAGE")]
    public async Task<IActionResult> SetActive(int id, [FromBody] SetActiveRequest request)
    {
        try
        {
            await _componentTypes.SetActiveAsync(id, request.IsActive);
            await _live.NotifyAsync("payroll");
            return NoContent();
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }
}
