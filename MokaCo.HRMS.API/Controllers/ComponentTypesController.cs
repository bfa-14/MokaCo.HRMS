using Microsoft.AspNetCore.Mvc;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Model.HR;
using MokaCo.HRMS.Services.HR;

namespace MokaCo.HRMS.Api.Controllers;

[ApiController]
[Route("api/component-types")]
public class ComponentTypesController : ControllerBase
{
    private readonly IComponentTypeService _componentTypes;
    public ComponentTypesController(IComponentTypeService componentTypes) => _componentTypes = componentTypes;

    [HttpGet]
    [HasPermission("EMP_VIEW")]
    public async Task<IActionResult> GetAll() => Ok(await _componentTypes.GetAllAsync());

    [HttpPost]
    [HasPermission("EMP_EDIT")]
    public async Task<IActionResult> Create([FromBody] ComponentTypeCreateRequest request)
    {
        var id = await _componentTypes.CreateAsync(request.Name, request.Category, request.Sign);
        return CreatedAtAction(nameof(GetAll), new { id }, new { componentTypeId = id });
    }

    [HttpPut("{id:int}")]
    [HasPermission("EMP_EDIT")]
    public async Task<IActionResult> Update(int id, [FromBody] ComponentTypeUpdateRequest request)
    {
        await _componentTypes.UpdateAsync(id, request.Name, request.Category, request.Sign);
        return NoContent();
    }
}
