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
// CLASS-LEVEL FLOOR. Every action below names its own permission, but authorization attributes
// combine (class AND action), so an action added later without one is still held to ATTENDANCE_VIEW
// rather than falling through to "any logged-in user". An employee changes their attendance only by
// raising a request — never by calling anything on this controller.
[HasPermission("ATTENDANCE_VIEW")]
public class AttendanceController : ControllerBase
{
    private readonly IAttendanceService _attendance;
    private readonly ILiveNotifier _live;

    public AttendanceController(IAttendanceService attendance, ILiveNotifier live)
    {
        _attendance = attendance;
        _live = live;
    }

    /// <summary>
    /// Every write here rewrites a day the attendance screens are drawing, and the same days feed
    /// the dashboard's staffing and coverage tiles. Named once so the pair cannot drift.
    /// </summary>
    private Task NotifyAttendanceAsync() => _live.NotifyAsync("attendance", "dashboard");

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

    /// <summary>
    /// WHERE ONE BRANCH-MONTH OF ROSTER HAS GOT TO — Draft, Pending or Approved, plus the
    /// ROSTER_APPROVAL request carrying it and that request's own status.
    ///
    /// Returns NULL when the branch-month has no row yet. That is the ordinary state of a month
    /// nobody has put up, not a 404: the caller asked a question about a month that exists, and
    /// "nothing has happened to it" is a real answer. The roster banner is written to read it that
    /// way.
    ///
    /// ATTENDANCE_VIEW — reading where the roster stands is reading, even though putting it up for
    /// approval needs ATTENDANCE_MANAGE.
    ///
    /// `month` is the month's FIRST DAY ('yyyy-MM-01'), the same value the ROSTER_APPROVAL create
    /// takes; both ends normalise it, so the banner and the request cannot be talking about
    /// different things.
    /// </summary>
    [HttpGet("roster-month")]
    [HasPermission("ATTENDANCE_VIEW")]
    public async Task<IActionResult> GetRosterMonth([FromQuery] int branchId, [FromQuery] DateTime month)
        => Ok(await _attendance.GetRosterMonthAsync(branchId, month));

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
    {
        var result = await _attendance.ProcessAsync(workDate);
        await NotifyAttendanceAsync();
        return Ok(result);
    }

    /// <summary>
    /// RE-derives one day from all of its punches, under the punch-interpretation settings in force
    /// right now.
    ///
    /// WHY THIS IS NOT /process WITH A DATE. That endpoint is incremental — it consumes only punches
    /// it has not already consumed — so a day built yesterday under "trust the machine's In/Out
    /// keys" stays exactly as it was when somebody switches to Alternate today. Nothing would
    /// revisit it, and the new setting would appear simply not to work. This re-reads the day whole.
    ///
    /// The raw punches are NOT touched, here or by the procedure: they remain what the machine said,
    /// and only the interpretation is rebuilt. A day a human has corrected is still left alone —
    /// their decision outranks any amount of re-derivation.
    ///
    /// Same ATTENDANCE_MANAGE gate as /process, because both rewrite what people are recorded as
    /// having worked.
    /// </summary>
    [HttpPost("reprocess")]
    [HasPermission("ATTENDANCE_MANAGE")]
    public async Task<IActionResult> Reprocess([FromQuery] DateTime? date)
    {
        if (date is null)
            return BadRequest(new { error = "A date is required — re-processing rebuilds one day." });

        var result = await _attendance.ReprocessDayAsync(date.Value);
        await NotifyAttendanceAsync();
        return Ok(result);
    }

    /// <summary>
    /// Writes records for people who were rostered but never punched at all. Run AFTER the processor:
    /// the processor only sees days that HAVE punches, so without this a fully-absent employee simply
    /// has no record, and payroll never learns they were missing.
    /// </summary>
    [HttpPost("mark-absentees")]
    [HasPermission("ATTENDANCE_MANAGE")]
    public async Task<IActionResult> MarkAbsentees([FromQuery] DateTime workDate)
    {
        var result = await _attendance.MarkAbsenteesAsync(workDate);
        await NotifyAttendanceAsync();
        return Ok(result);
    }

    /* ---- HR overrides (ATTENDANCE_CORRECT) ---- */

    /// <summary>HR enters a day by hand — the machine was down, or the punch never happened. Measured by the same rules as a real one.</summary>
    [HttpPost("manual")]
    [HasPermission("ATTENDANCE_CORRECT")]
    public async Task<IActionResult> Manual([FromBody] ManualAttendanceRequest request)
    {
        var result = await _attendance.ManualUpsertAsync(request);
        await NotifyAttendanceAsync();
        return Ok(result);
    }

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
        if (record is null) return NotFound();

        await NotifyAttendanceAsync();
        return Ok(record);
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
        if (record is null) return NotFound();

        // This is what payroll is blocked on, so the readiness figures move with it too.
        await _live.NotifyAsync("attendance", "payroll", "dashboard");
        return Ok(record);
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
        if (record is null) return NotFound();

        // Changing somebody's hours changes what they will be paid.
        await _live.NotifyAsync("attendance", "payroll", "dashboard");
        return Ok(record);
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
