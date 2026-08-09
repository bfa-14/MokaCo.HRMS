using Microsoft.AspNetCore.Mvc;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Model.HR;
using MokaCo.HRMS.Services.HR;

namespace MokaCo.HRMS.Api.Controllers;

[ApiController]
[Route("api/positions")]
public class PositionsController : ControllerBase
{
    private readonly IPositionService _positions;
    public PositionsController(IPositionService positions) => _positions = positions;

    [HttpGet]
    [HasPermission("EMP_VIEW")]
    public async Task<IActionResult> GetAll() => Ok(await _positions.GetAllAsync());

    [HttpPost]
    [HasPermission("EMP_EDIT")]
    public async Task<IActionResult> Create([FromBody] PositionCreateRequest request)
    {
        var id = await _positions.CreateAsync(request.Title);
        return CreatedAtAction(nameof(GetAll), new { id }, new { positionId = id });
    }

    [HttpPut("{id:int}")]
    [HasPermission("EMP_EDIT")]
    public async Task<IActionResult> Update(int id, [FromBody] PositionUpdateRequest request)
    {
        await _positions.UpdateAsync(id, request.Title, request.IsActive);
        return NoContent();
    }
}
