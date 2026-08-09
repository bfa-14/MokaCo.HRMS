using System.Security.Claims;
using Microsoft.AspNetCore.Mvc;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Services.Attendance;

namespace MokaCo.HRMS.Api.Controllers;

/// <summary>
/// Processed attendance: what the punches say, and the HR decisions that can change it.
///
/// ATTENDANCE REPORTS. WORKFLOW AUTHORIZES. HR DECIDES. Nothing on this controller decides what
/// anybody is paid — overtime is reported and left alone, and an exit that ran long is measured and
/// handed to a person.
///
/// WHO MAY CALL WHAT:
///   ATTENDANCE_VIEW     reading days, anomalies, raw punches, summaries, payroll readiness
///   ATTENDANCE_MANAGE   running the processor and marking absentees (it changes the numbers)
///   ATTENDANCE_CORRECT  HR ONLY — manual entry, exit approvals, dispositions, day adjustments.
///                       These directly change what a person is PAID, which is why they are held
///                       apart from MANAGE: whoever runs the processor cannot also rewrite hours.
/// </summary>
[ApiController]
[Route("api/attendance")]
public class AttendanceController : ControllerBase
{
    private readonly IAttendanceService _attendance;
    public AttendanceController(IAttendanceService attendance) => _attendance = attendance;

    private int CurrentUserId =>
        int.Parse(User.FindFirstValue(ClaimTypes.NameIdentifier) ?? User.FindFirstValue("sub")!);

    /* ---- reading ---- */

    [HttpGet]
    [HasPermission("ATTENDANCE_VIEW")]
    public async Task<IActionResult> Get(
        [FromQuery] DateTime from,
        [FromQuery] DateTime to,
        [FromQuery] int? employeeId,
        [FromQuery] int? branchId)
    {
        if (from > to)
            return BadRequest(new { error = "'from' must be on or before 'to'." });

        return Ok(await _attendance.GetAsync(from, to, employeeId, branchId));
    }

    /// <summary>One day WITH the paired intervals behind it — the audit trail that shows WHY worked time is what it is.</summary>
    [HttpGet("{id:long}")]
    [HasPermission("ATTENDANCE_VIEW")]
    public async Task<IActionResult> GetById(long id)
    {
        var record = await _attendance.GetByIdAsync(id);
        return record is null ? NotFound() : Ok(record);
    }

    /// <summary>Days the machine could not read confidently. Not errors — requests for a human to look.</summary>
    [HttpGet("anomalies")]
    [HasPermission("ATTENDANCE_VIEW")]
    public async Task<IActionResult> GetAnomalies([FromQuery] DateTime from, [FromQuery] DateTime to)
        => Ok(await _attendance.GetAnomaliesAsync(from, to));

    /// <summary>The raw punches behind a day — what the device ACTUALLY recorded, before processing or correction.</summary>
    [HttpGet("raw/{employeeId:int}/{date:datetime}")]
    [HasPermission("ATTENDANCE_VIEW")]
    public async Task<IActionResult> GetRaw(int employeeId, DateTime date)
        => Ok(await _attendance.GetRawAsync(employeeId, date));

    /* ---- processing ---- */

    /// <summary>
    /// Turns raw punches into employee-day records. Omitting workDate consumes EVERYTHING outstanding.
    /// Safe to run repeatedly — it only ever consumes unprocessed punches, and it will not touch a day
    /// HR has already corrected. It also runs nightly; this endpoint exists because an in-memory
    /// scheduler misses its run entirely if the API happened to be down.
    /// </summary>
    [HttpPost("process")]
    [HasPermission("ATTENDANCE_MANAGE")]
    public async Task<IActionResult> Process([FromQuery] DateTime? workDate)
        => Ok(await _attendance.ProcessAsync(workDate));

    /// <summary>
    /// Writes records for people who were rostered but never punched at all. Run AFTER the processor:
    /// the processor only sees days that HAVE punches, so without this a fully-absent employee simply
    /// has no record, and payroll never learns they were missing.
    /// </summary>
    [HttpPost("mark-absentees")]
    [HasPermission("ATTENDANCE_MANAGE")]
    public async Task<IActionResult> MarkAbsentees([FromQuery] DateTime workDate)
        => Ok(await _attendance.MarkAbsenteesAsync(workDate));

    /* ---- HR overrides (ATTENDANCE_CORRECT) ---- */

    /// <summary>HR enters a day by hand — the machine was down, or the punch never happened. Measured by the same rules as a real one.</summary>
    [HttpPost("manual")]
    [HasPermission("ATTENDANCE_CORRECT")]
    public async Task<IActionResult> Manual([FromBody] ManualAttendanceRequest request)
        => Ok(await _attendance.ManualUpsertAsync(request));

    /// <summary>
    /// Records what was AUTHORISED for a mid-day exit. It does NOT overwrite what the punches
    /// observed: an exit approved for two hours that actually took ninety minutes stays ninety
    /// minutes. Both numbers survive, and the difference becomes HR's to rule on.
    /// </summary>
    [HttpPost("{id:long}/exit-approval")]
    [HasPermission("ATTENDANCE_CORRECT")]
    public async Task<IActionResult> SetExitApproval(long id, [FromBody] ExitApprovalRequest request)
    {
        var record = await _attendance.SetExitApprovalAsync(id, request);
        return record is null ? NotFound() : Ok(record);
    }

    /// <summary>
    /// HR's ruling on the difference between approved and actual: deduct it, offset it against
    /// overtime already worked, or ignore it. THIS IS WHAT PAYROLL IS BLOCKED ON — the month cannot
    /// be paid while any variance is still undecided.
    /// </summary>
    [HttpPost("{id:long}/exit-disposition")]
    [HasPermission("ATTENDANCE_CORRECT")]
    public async Task<IActionResult> SetExitDisposition(long id, [FromBody] ExitDispositionRequest request)
    {
        if (request.Disposition is not ("UnpaidAbsence" or "Overtime" or "Ignore"))
            return BadRequest(new { error = "Disposition must be UnpaidAbsence, Overtime, or Ignore." });

        var record = await _attendance.SetExitDispositionAsync(id, request);
        return record is null ? NotFound() : Ok(record);
    }

    /// <summary>Adds or removes working time on a day. The note is mandatory: this changes pay, and somebody will ask why.</summary>
    [HttpPost("{id:long}/adjust")]
    [HasPermission("ATTENDANCE_CORRECT")]
    public async Task<IActionResult> Adjust(long id, [FromBody] HrAdjustDayRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.HrNote))
            return BadRequest(new { error = "A note is required — it is the record of why somebody's hours were changed." });

        if (request.WorkedMinutes is null && request.DayFraction is null)
            return BadRequest(new { error = "Provide either worked minutes or a day fraction." });

        var record = await _attendance.AdjustDayAsync(id, request, CurrentUserId);
        return record is null ? NotFound() : Ok(record);
    }

    /// <summary>The HR decision queue: days where what happened differs from what was approved, and nobody has said what that means.</summary>
    [HttpGet("exit-variances")]
    [HasPermission("ATTENDANCE_VIEW")]
    public async Task<IActionResult> GetExitVariances(
        [FromQuery] DateTime from,
        [FromQuery] DateTime to,
        [FromQuery] bool onlyUndecided = true)
        => Ok(await _attendance.GetExitVariancesAsync(from, to, onlyUndecided));

    /* ---- payroll interface ---- */

    /// <summary>
    /// Is this month safe to pay? Six counters, and a verdict. Payroll reads attendance, so an
    /// incomplete month does not fail loudly — it pays the wrong amounts quietly. Call this BEFORE
    /// creating a payroll run and refuse to proceed while IsReady is false.
    /// </summary>
    [HttpGet("payroll-readiness")]
    [HasPermission("ATTENDANCE_VIEW")]
    public async Task<IActionResult> GetPayrollReadiness([FromQuery] string period)
        => Ok(await _attendance.GetPayrollReadinessAsync(period));

    [HttpGet("summary")]
    [HasPermission("ATTENDANCE_VIEW")]
    public async Task<IActionResult> GetSummary([FromQuery] string period, [FromQuery] int employeeId)
    {
        var summary = await _attendance.GetSummaryAsync(employeeId, period);
        return summary is null ? NotFound() : Ok(summary);
    }

    /// <summary>What a payroll RUN iterates over: every active employee's month.</summary>
    [HttpGet("summary/all")]
    [HasPermission("ATTENDANCE_VIEW")]
    public async Task<IActionResult> GetSummaryAll([FromQuery] string period)
        => Ok(await _attendance.GetSummaryAllAsync(period));

    [HttpGet("summary/by-branch")]
    [HasPermission("ATTENDANCE_VIEW")]
    public async Task<IActionResult> GetSummaryByBranch([FromQuery] string period, [FromQuery] int? employeeId)
        => Ok(await _attendance.GetSummaryByBranchAsync(period, employeeId));
}
