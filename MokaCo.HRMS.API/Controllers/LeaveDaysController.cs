using Microsoft.AspNetCore.Mvc;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Services.HR;

namespace MokaCo.HRMS.Api.Controllers;

/// <summary>
/// Who is on approved leave, by day.
///
/// It exists for the roster: a person on leave must not be given a working shift, and to know that
/// the roster needs everybody's leave for a whole month at once. The rest of the ledger API reads
/// one employee at a time, which would mean a round trip per person per month just to draw a
/// calendar.
///
/// Guarded by EMP_VIEW — the same gate as every other leave read, and no new barrier in practice:
/// the roster page already cannot function without EMP_VIEW, since it lists employees.
///
/// THIS IS A SEAM. Leave is derived from hr.LEAVE_LEDGER 'Usage' movements because that is the only
/// source that exists — workflow.LEAVE_REQUEST, with a real FromDate..ToDate, belongs to the
/// workflow stage and has not been built. When it lands, the stored procedure behind this endpoint
/// is what changes; the endpoint's shape, and every caller, stay as they are.
/// </summary>
[ApiController]
[Route("api/leave")]
public class LeaveDaysController : ControllerBase
{
    private readonly ILeaveLedgerService _ledger;
    public LeaveDaysController(ILeaveLedgerService ledger) => _ledger = ledger;

    /// <summary>
    /// Every employee-day on approved leave between two dates. One row per employee-day, whatever
    /// the ledger holds underneath.
    /// </summary>
    [HttpGet("days")]
    [HasPermission("EMP_VIEW")]
    public async Task<IActionResult> GetDays([FromQuery] DateTime from, [FromQuery] DateTime to)
    {
        if (from > to)
            return BadRequest(new { error = "'from' must be on or before 'to'." });

        return Ok(await _ledger.GetLeaveDaysInRangeAsync(from, to));
    }
}
