using Microsoft.AspNetCore.Mvc;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Services.Attendance;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Api.Controllers;

/// <summary>
/// The roster — what each person was SUPPOSED to work.
///
/// This is the page HR lives in, and the reason it matters is not administrative: without a roster
/// row the processor cannot tell late from early, or absent from a day off. An unrostered day is a
/// day payroll cannot judge, which is why /gaps exists and why payroll readiness counts them.
///
/// Reading is ATTENDANCE_VIEW; writing is ATTENDANCE_MANAGE. Every generator defaults to
/// Overwrite = false, so re-running one fills the holes and leaves HR's manual changes intact.
///
/// THE LOCK (75_roster_approval_applies_and_locks.sql) lives in the database, in front of every
/// writer here: a month whose roster approval is still open is read-only, and in an approved month
/// a day already in the past or already judged by attendance is a record — those come back as a 409
/// with the procedure's sentence. A future day of an approved month may still be changed by the
/// roster manager; the month stays Approved and the roster-month read reports ChangedSinceApproval.
///
/// QA3 (ROS-14): every write passes the CALLER to the procedure, which refuses a branch they do not manage unless
/// they hold EMP_VIEW_ALL — a 403 with the sentence. QA3 (ROS-6): HR may still add a MISSING day in the past of an
/// approved month (no record, not paid); the procedure derives that day at once.
/// </summary>
[ApiController]
[Route("api/roster")]
public class RosterController : ControllerBase
{
    private readonly IRosterService _roster;
    private readonly ILiveNotifier _live;

    public RosterController(IRosterService roster, ILiveNotifier live)
    {
        _roster = roster;
        _live = live;
    }

    /// <summary>
    /// The roster decides who is expected at work, so every write here moves the attendance screens
    /// AND the dashboard's staffing and coverage-gap tiles. Named once so the pair cannot drift.
    /// </summary>
    private Task NotifyRosterAsync() => _live.NotifyAsync("attendance", "dashboard");

    [HttpGet]
    [HasPermission("ATTENDANCE_VIEW")]
    public async Task<IActionResult> Get([FromQuery] DateTime from, [FromQuery] DateTime to, [FromQuery] int? employeeId,
        [FromQuery] int? branchId = null)      // D7: one branch's roster, by the branch each employee belonged to ON the work date
    {
        if (from > to)
            return BadRequest(new { error = "'from' must be on or before 'to'." });

        return Ok(await _roster.GetAsync(from, to, employeeId, branchId, User.UserId()));
    }

    /// <summary>Sets ONE employee-day — what clicking a single calendar cell calls.</summary>
    [HttpPut("day")]
    [HasPermission("ATTENDANCE_MANAGE")]
    public async Task<IActionResult> SetDay([FromBody] RosterDayRequest request)
    {
        // A working day needs a shift; a day off is IsRestDay with no shift. A row with neither tells
        // the processor nothing, which is the one state the roster exists to prevent.
        if (request.ShiftId is null && !request.IsRestDay)
            return BadRequest(new { error = "Choose a shift, or mark the day as a rest day." });

        try
        {
            var id = await _roster.SetDayAsync(request, User.UserId());
            await NotifyRosterAsync();
            return Ok(new { shiftAssignmentId = id });
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    [HttpDelete("{id:int}")]
    [HasPermission("ATTENDANCE_MANAGE")]
    public async Task<IActionResult> Delete(int id)
    {
        try
        {
            await _roster.DeleteAsync(id, User.UserId());
            await NotifyRosterAsync();
            return NoContent();
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>Generates one employee's roster over a range. Days outside the weekday mask become REST DAYS, so the roster comes out complete.</summary>
    [HttpPost("generate")]
    [HasPermission("ATTENDANCE_MANAGE")]
    public async Task<IActionResult> Generate([FromBody] RosterGenerateRequest request)
    {
        var error = ValidateWeekdays(request.Weekdays) ?? ValidateRange(request.FromDate, request.ToDate);
        if (error is not null)
            return BadRequest(new { error });

        try
        {
            var generated = await _roster.GenerateAsync(request, User.UserId());
            await NotifyRosterAsync();
            return Ok(generated);
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>The same, for a whole team in one action.</summary>
    [HttpPost("generate-bulk")]
    [HasPermission("ATTENDANCE_MANAGE")]
    public async Task<IActionResult> GenerateBulk([FromBody] RosterGenerateBulkRequest request)
    {
        if (request.EmployeeIds.Count == 0)
            return BadRequest(new { error = "Choose at least one employee." });

        var error = ValidateWeekdays(request.Weekdays) ?? ValidateRange(request.FromDate, request.ToDate);
        if (error is not null)
            return BadRequest(new { error });

        try
        {
            var generated = await _roster.GenerateBulkAsync(request, User.UserId());
            await NotifyRosterAsync();
            return Ok(generated);
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>Copies a month onto another, aligned by WEEKDAY — a Monday shift lands on a Monday, not on the same date number.</summary>
    [HttpPost("copy-period")]
    [HasPermission("ATTENDANCE_MANAGE")]
    public async Task<IActionResult> CopyPeriod([FromBody] RosterCopyPeriodRequest request)
    {
        if (!IsYearMonth(request.SourceYearMonth) || !IsYearMonth(request.TargetYearMonth))
            return BadRequest(new { error = "Periods must look like '2026-06'." });

        // QA3 (ROS-3): a copy works on ONE branch. Without one it used to write every branch's month at once.
        if (request.BranchId is null)
            return BadRequest(new { error = "Choose a branch — copying a month works on one branch at a time." });

        try
        {
            var copied = await _roster.CopyPeriodAsync(request, User.UserId());
            await NotifyRosterAsync();
            return Ok(copied);
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>Expands employees' saved weekly patterns into real dated roster rows for a month.</summary>
    [HttpPost("apply-pattern")]
    [HasPermission("ATTENDANCE_MANAGE")]
    public async Task<IActionResult> ApplyPattern([FromBody] RosterApplyPatternRequest request)
    {
        if (!IsYearMonth(request.YearMonth))
            return BadRequest(new { error = "Period must look like '2026-06'." });

        // QA3 (ROS-3): the patterns are applied to ONE branch.
        if (request.BranchId is null)
            return BadRequest(new { error = "Choose a branch — weekly patterns are applied to one branch at a time." });

        try
        {
            var applied = await _roster.ApplyPatternAsync(request, User.UserId());
            await NotifyRosterAsync();
            return Ok(applied);
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>
    /// Employee-days with NO roster row at all. These are the ones that block payroll. QA3: `branchId` = one branch, by
    /// the branch each employee belonged to ON the day (ROS-8); a public holiday of that branch is not a gap (ROS-10).
    /// </summary>
    [HttpGet("gaps")]
    [HasPermission("ATTENDANCE_VIEW")]
    public async Task<IActionResult> GetGaps([FromQuery] DateTime from, [FromQuery] DateTime to, [FromQuery] int? branchId = null)
    {
        if (from > to)
            return BadRequest(new { error = "'from' must be on or before 'to'." });

        return Ok(await _roster.GetGapsAsync(from, to, User.UserId(), branchId));
    }

    /// <summary>
    /// QA3 (ROS-4 / LEV-5): who is on APPROVED leave, by day — the roster grid's leave overlay. Read from the leave
    /// requests (the days the approval covers, a half day as 0.5), not from the ledger, which books a month of leave
    /// on one date and also holds exit-permission minutes converted to leave. Scoped like the roster read.
    /// </summary>
    [HttpGet("leave-days")]
    [HasPermission("ATTENDANCE_VIEW")]
    public async Task<IActionResult> GetLeaveDays([FromQuery] DateTime from, [FromQuery] DateTime to, [FromQuery] int? branchId = null)
    {
        if (from > to)
            return BadRequest(new { error = "'from' must be on or before 'to'." });

        try
        {
            return Ok(await _roster.GetLeaveDaysAsync(from, to, branchId, User.UserId()));
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>
    /// QA3 (REL-16): "Re-derive month" — the branch-month's completed days (the 1st to yesterday) derived again from the
    /// roster as it stands, after a settings change for instance. Approving a month does this by itself. Paid and manual
    /// days are left alone. ATTENDANCE_MANAGE, scoped to the branches the caller may plan.
    /// </summary>
    [HttpPost("rederive-month")]
    [HasPermission("ATTENDANCE_MANAGE")]
    public async Task<IActionResult> RederiveMonth([FromBody] RosterRederiveRequest request)
    {
        if (!IsYearMonth(request.YearMonth))
            return BadRequest(new { error = "Period must look like '2026-06'." });

        try
        {
            var month = DateTime.Parse($"{request.YearMonth}-01", System.Globalization.CultureInfo.InvariantCulture);
            var result = await _roster.RederiveMonthAsync(request.BranchId, month.Year, month.Month, User.UserId());
            await NotifyRosterAsync();
            return Ok(result);
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    [HttpGet("patterns/{employeeId:int}")]
    [HasPermission("ATTENDANCE_MANAGE")]
    public async Task<IActionResult> GetPatterns(int employeeId) => Ok(await _roster.GetPatternsAsync(employeeId));

    /// <summary>
    /// The employee's current weekly template as SEVEN rows — what the availability-change form starts
    /// from. Sits here with the other pattern reads, but under /api/employees because it is a fact
    /// about a PERSON that a self-service screen asks for, not a roster administration call.
    ///
    /// DELIBERATELY NOT ATTENDANCE_MANAGE, which the neighbouring reads use. This one feeds a form any
    /// employee may open about themselves, and locking it to the roster administrators would leave an
    /// ordinary barista looking at an empty week. The floor is instead the same permission that lets
    /// them raise the request it feeds, plus the same self-or-others rule the typed create enforces:
    /// your own week is yours to read, somebody else's needs the right to act for them (or the
    /// attendance-wide read that already shows their roster anyway).
    /// </summary>
    [HttpGet("/api/employees/{employeeId:int}/shift-pattern")]
    [HasPermission("REQUEST_RAISE_SELF")]
    public async Task<IActionResult> GetEmployeePattern(int employeeId, [FromServices] IWorkflowSupportService support)
    {
        if (!User.HasPermission("REQUEST_RAISE_OTHERS") && !User.HasPermission("ATTENDANCE_VIEW"))
        {
            var me = await support.GetEmployeeByUserIdAsync(User.UserId());
            if (me?.EmployeeId != employeeId)
                return StatusCode(403, new { error = "You may only read your own weekly pattern." });
        }

        return Ok(await _roster.GetEmployeePatternAsync(employeeId));
    }

    /// <summary>Saves an employee's default week. The editor sends all seven days, so a day that became a rest day replaces the shift that was there.</summary>
    [HttpPut("patterns/{employeeId:int}")]
    [HasPermission("ATTENDANCE_MANAGE")]
    public async Task<IActionResult> SavePatterns(int employeeId, [FromBody] List<ShiftPatternUpsertRequest> days)
    {
        if (days.Any(d => d.DayOfWeek is < 1 or > 7))
            return BadRequest(new { error = "DayOfWeek must be 1 (Monday) to 7 (Sunday)." });

        await _roster.SavePatternsAsync(employeeId, days);
        await NotifyRosterAsync();
        return NoContent();
    }

    [HttpDelete("patterns/{employeeId:int}")]
    [HasPermission("ATTENDANCE_MANAGE")]
    public async Task<IActionResult> DeletePatterns(int employeeId)
    {
        await _roster.DeletePatternsAsync(employeeId);
        await NotifyRosterAsync();
        return NoContent();
    }

    /// <summary>The mask is Monday-first and exactly seven characters — a shorter one would silently roster the wrong days.</summary>
    private static string? ValidateWeekdays(string weekdays)
        => weekdays.Length == 7 && weekdays.All(c => c is '0' or '1')
            ? null
            : "Weekdays must be 7 characters of 0 or 1, Monday first — e.g. '1111100' for Mon–Fri.";

    private static string? ValidateRange(DateTime from, DateTime to)
        => from <= to ? null : "'from' must be on or before 'to'.";

    private static bool IsYearMonth(string value)
        => DateTime.TryParse($"{value}-01", out _) && value.Length == 7;
}
