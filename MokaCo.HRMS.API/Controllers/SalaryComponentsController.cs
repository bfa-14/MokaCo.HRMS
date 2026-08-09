using Microsoft.AspNetCore.Mvc;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Model.HR;
using MokaCo.HRMS.Services.HR;

namespace MokaCo.HRMS.Api.Controllers;

[ApiController]
[Route("api/salary-components")]
public class SalaryComponentsController : ControllerBase
{
    private readonly ISalaryComponentService _salaryComponents;
    public SalaryComponentsController(ISalaryComponentService salaryComponents) => _salaryComponents = salaryComponents;

    [HttpGet("by-employee/{employeeId:int}")]
    [HasPermission("EMP_VIEW")]
    public async Task<IActionResult> GetByEmployee(int employeeId)
        => Ok(await _salaryComponents.GetByEmployeeAsync(employeeId));

    [HttpPost]
    [HasPermission("EMP_EDIT")]
    public async Task<IActionResult> Create([FromBody] SalaryComponentCreateRequest request)
    {
        var id = await _salaryComponents.CreateAsync(request);
        return CreatedAtAction(nameof(GetByEmployee), new { employeeId = request.EmployeeId },
            new { salaryComponentId = id });
    }

    [HttpPut("{id:int}")]
    [HasPermission("EMP_EDIT")]
    public async Task<IActionResult> Update(int id, [FromBody] SalaryComponentUpdateRequest request)
    {
        await _salaryComponents.UpdateAsync(id, request);
        return NoContent();
    }

    [HttpDelete("{id:int}")]
    [HasPermission("EMP_EDIT")]
    public async Task<IActionResult> Delete(int id)
    {
        await _salaryComponents.DeleteAsync(id);
        return NoContent();
    }
}
