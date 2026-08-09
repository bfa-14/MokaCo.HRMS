using System.Security.Claims;
using Microsoft.AspNetCore.Mvc;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Services.HR;

namespace MokaCo.HRMS.Api.Controllers;

[ApiController]
[Route("api/leave/accrual")]
public class LeaveAccrualController : ControllerBase
{
    private readonly ILeaveAccrualService _accrual;
    public LeaveAccrualController(ILeaveAccrualService accrual) => _accrual = accrual;

    private int CurrentUserId =>
        int.Parse(User.FindFirstValue(ClaimTypes.NameIdentifier) ?? User.FindFirstValue("sub")!);

    /// <summary>
    /// Manually runs the monthly accrual for a given year/month. Recovery path for a missed
    /// scheduled run — safe to call repeatedly because the run is idempotent.
    /// </summary>
    [HttpPost("run")]
    [HasPermission("EMP_EDIT")]
    public async Task<IActionResult> Run([FromQuery] int year, [FromQuery] int month)
    {
        if (year < 2000 || year > 2100)
            return BadRequest(new { error = "Year is out of range." });
        if (month < 1 || month > 12)
            return BadRequest(new { error = "Month must be between 1 and 12." });

        var result = await _accrual.RunMonthlyAccrual(year, month, CurrentUserId);
        return Ok(result);
    }
}
