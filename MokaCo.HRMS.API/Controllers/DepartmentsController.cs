using Microsoft.AspNetCore.Mvc;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Model.HR;
using MokaCo.HRMS.Services.HR;

namespace MokaCo.HRMS.Api.Controllers;

[ApiController]
[Route("api/departments")]
public class DepartmentsController : ControllerBase
{
    private readonly IDepartmentService _departments;
    public DepartmentsController(IDepartmentService departments) => _departments = departments;

    [HttpGet]
    [HasPermission("EMP_VIEW")]
    public async Task<IActionResult> GetAll() => Ok(await _departments.GetAllAsync());

    [HttpPost]
    [HasPermission("EMP_EDIT")]
    public async Task<IActionResult> Create([FromBody] DepartmentCreateRequest request)
    {
        var id = await _departments.CreateAsync(request.Name);
        return CreatedAtAction(nameof(GetAll), new { id }, new { departmentId = id });
    }

    [HttpPut("{id:int}")]
    [HasPermission("EMP_EDIT")]
    public async Task<IActionResult> Update(int id, [FromBody] DepartmentUpdateRequest request)
    {
        await _departments.UpdateAsync(id, request.Name, request.IsActive);
        return NoContent();
    }
}
