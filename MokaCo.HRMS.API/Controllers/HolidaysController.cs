using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Model.Core;
using MokaCo.HRMS.Services.Core;

namespace MokaCo.HRMS.Api.Controllers;

/// <summary>
/// Public holidays (D1). READING IS FOR EVERYBODY WHO IS SIGNED IN — the leave form counts working days with
/// it, the roster paints it — and carries nothing private. WRITING is CORE_MANAGE: a holiday re-prices a day
/// for a whole branch.
///
/// A refusal from the procedures ("A holiday is already recorded on that date…", "This period is paid — raise
/// a payroll adjustment instead.") is not caught here: the global handler answers it as { error, traceId }
/// with the procedure's own sentence (ApiErrorMap).
/// </summary>
[ApiController]
[Route("api/holidays")]
public class HolidaysController : ControllerBase
{
    private readonly IHolidayService _holidays;
    private readonly ILiveNotifier _live;

    public HolidaysController(IHolidayService holidays, ILiveNotifier live)
    {
        _holidays = holidays;
        _live = live;
    }

    [HttpGet]
    [Authorize]
    public async Task<IActionResult> GetAll([FromQuery] int? year, [FromQuery] int? branchId)
        => Ok(await _holidays.GetAllAsync(year, branchId));

    [HttpPost]
    [HasPermission("CORE_MANAGE")]
    public async Task<IActionResult> Create([FromBody] HolidayUpsertRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.Name) || request.HolidayDate == default)
            return BadRequest(new { error = "A holiday needs a date and a name." });

        var saved = await _holidays.CreateAsync(request, User.UserId());
        await _live.NotifyAsync("attendance", "payroll");     // the days it touches were re-derived
        return Ok(saved);
    }

    [HttpPut("{id:int}")]
    [HasPermission("CORE_MANAGE")]
    public async Task<IActionResult> Update(int id, [FromBody] HolidayUpsertRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.Name) || request.HolidayDate == default)
            return BadRequest(new { error = "A holiday needs a date and a name." });

        var saved = await _holidays.UpdateAsync(id, request, User.UserId());
        if (saved is null)
            return NotFound();

        await _live.NotifyAsync("attendance", "payroll");
        return Ok(saved);
    }

    [HttpDelete("{id:int}")]
    [HasPermission("CORE_MANAGE")]
    public async Task<IActionResult> Delete(int id)
    {
        await _holidays.DeleteAsync(id, User.UserId());
        await _live.NotifyAsync("attendance", "payroll");
        return NoContent();
    }
}
