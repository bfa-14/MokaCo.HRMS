using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using MokaCo.HRMS.Api.Auth;

using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Services.Attendance;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Api.Controllers;

/// <summary>
/// "SOMETHING IS WRONG WITH THIS DAY" (script 110). Reporting and reading one's own reports need only a sign-in: the
/// procedure lets the employee report their own days and a branch manager the days of their branches, nobody else.
/// The queue and the decision are HR's: ATTENDANCE_CORRECT, the code that approves corrections (accepting a report IS
/// an approved correction), with the branch scope and "never your own day" checked by the procedure.
/// </summary>
[ApiController]
[Route("api/day-reports")]
[Authorize]
public class DayReportsController : ControllerBase
{
    private readonly IDayReportService _reports;
    private readonly ILiveNotifier _live;

    public DayReportsController(IDayReportService reports, ILiveNotifier live)
    {
        _reports = reports;
        _live = live;
    }

    [HttpPost]
    public async Task<IActionResult> Create([FromBody] DayReportCreateRequest request)
    {
        try
        {
            var id = await _reports.CreateAsync(request, User.UserId());
            await _live.NotifyAsync("attendance");
            return Ok(new { reportId = id });
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    [HttpGet("mine")]
    public async Task<IActionResult> Mine([FromQuery] DateTime? from, [FromQuery] DateTime? to)
        => Ok(await _reports.GetMineAsync(from, to, User.UserId()));

    [HttpPost("{id:int}/withdraw")]
    public async Task<IActionResult> Withdraw(int id)
    {
        try
        {
            await _reports.WithdrawAsync(id, User.UserId());
            await _live.NotifyAsync("attendance");
            return NoContent();
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    [HttpGet]
    [HasPermission("ATTENDANCE_CORRECT")]
    public async Task<IActionResult> Queue([FromQuery] string? status, [FromQuery] DateTime? from, [FromQuery] DateTime? to)
        => Ok(await _reports.GetQueueAsync(status, from, to, User.UserId()));

    [HttpPost("{id:int}/decide")]
    [HasPermission("ATTENDANCE_CORRECT")]
    public async Task<IActionResult> Decide(int id, [FromBody] DayReportDecisionRequest request)
    {
        try
        {
            var result = await _reports.DecideAsync(id, request, User.UserId());
            await _live.NotifyAsync("attendance", "payroll", "dashboard");
            return Ok(result);
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }
}
