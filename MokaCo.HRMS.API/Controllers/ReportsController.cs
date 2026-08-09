using Microsoft.AspNetCore.Mvc;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Services.Report;

namespace MokaCo.HRMS.Api.Controllers;

/// <summary>
/// The printable reports — read-only views across attendance and leave data.
///
/// All three are gated on ATTENDANCE_VIEW: a report reveals nothing you could not already read on
/// the attendance and leave pages, it only arranges it for printing, so it needs no permission
/// beyond seeing attendance. Each returns { header, rows } — the caller must render both, because
/// a report without its header is an undated anonymous table.
/// </summary>
[ApiController]
[Route("api/reports")]
public class ReportsController : ControllerBase
{
    private readonly IReportService _reports;
    public ReportsController(IReportService reports) => _reports = reports;

    /// <summary>The sheet HR reviews before running payroll: one row per employee for the month.</summary>
    [HttpGet("monthly-attendance")]
    [HasPermission("ATTENDANCE_VIEW")]
    public async Task<IActionResult> MonthlyAttendance([FromQuery] string period, [FromQuery] int? branchId)
    {
        if (!IsYearMonth(period))
            return BadRequest(new { error = "period must look like '2026-06'." });

        return Ok(await _reports.GetMonthlyAttendanceAsync(period, branchId));
    }

    /// <summary>A branch manager's daily sheet: who was in, late, absent or off on a given date.</summary>
    [HttpGet("daily-attendance")]
    [HasPermission("ATTENDANCE_VIEW")]
    public async Task<IActionResult> DailyAttendance([FromQuery] DateTime workDate, [FromQuery] int? branchId)
        => Ok(await _reports.GetDailyAttendanceAsync(workDate, branchId));

    /// <summary>Accrued / carried over / used / remaining per employee per leave type, as of a period.</summary>
    [HttpGet("leave-balance")]
    [HasPermission("ATTENDANCE_VIEW")]
    public async Task<IActionResult> LeaveBalance([FromQuery] string asOf, [FromQuery] int? employeeId, [FromQuery] int? branchId)
    {
        if (!IsYearMonth(asOf))
            return BadRequest(new { error = "asOf must look like '2026-06'." });

        return Ok(await _reports.GetLeaveBalanceAsync(asOf, employeeId, branchId));
    }

    private static bool IsYearMonth(string value)
        => !string.IsNullOrEmpty(value) && value.Length == 7 && DateTime.TryParse($"{value}-01", out _);
}
