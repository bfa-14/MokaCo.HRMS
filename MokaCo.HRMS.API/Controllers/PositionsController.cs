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
    private readonly ILiveNotifier _live;

    public PositionsController(IPositionService positions, ILiveNotifier live)
    {
        _positions = positions;
        _live = live;
    }

    [HttpGet]
    [HasPermission("EMP_VIEW")]
    public async Task<IActionResult> GetAll() => Ok(await _positions.GetAllAsync());

    [HttpPost]
    [HasPermission("ORG_MANAGE")]
    public async Task<IActionResult> Create([FromBody] PositionCreateRequest request)
    {
        var id = await _positions.CreateAsync(request.Title);
        await _live.NotifyAsync("hr", "dashboard");
        return CreatedAtAction(nameof(GetAll), new { id }, new { positionId = id });
    }

    [HttpPut("{id:int}")]
    [HasPermission("ORG_MANAGE")]
    public async Task<IActionResult> Update(int id, [FromBody] PositionUpdateRequest request)
    {
        await _positions.UpdateAsync(id, request.Title, request.IsActive);
        await _live.NotifyAsync("hr", "dashboard");
        return NoContent();
    }
}
