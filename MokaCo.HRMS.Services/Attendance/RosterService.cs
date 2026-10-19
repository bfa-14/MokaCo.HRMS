using Microsoft.Extensions.Logging;
using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Repository.Attendance;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Services.Attendance;

/// <summary>
/// The roster: what each person was SUPPOSED to work. This is not paperwork — without a roster row
/// the processor cannot tell late from early, or absent from a day off, so an unrostered day is a
/// day payroll cannot judge.
///
/// Everything here is built around one rule: HR must never type a roster day by day. There are four
/// ways to fill it (generate a range, generate for a team, copy last month weekday-aligned, or
/// expand saved weekly patterns), and all of them are safe to re-run — with Overwrite off they only
/// insert the days that are missing, so manual changes survive a regeneration.
/// </summary>
public class RosterService : IRosterService
{
    private readonly IRosterRepository _repo;
    private readonly ILogger<RosterService>? _logger;

    public RosterService(IRosterRepository repo, ILogger<RosterService>? logger = null)
    {
        _repo = repo;
        _logger = logger;
    }

    public Task<IEnumerable<ShiftAssignment>> GetAsync(DateTime fromDate, DateTime toDate, int? employeeId, int? branchId = null, int? callerUserId = null)
        => _repo.GetByDateRangeAsync(fromDate, toDate, employeeId, branchId, callerUserId);

    /* Every assignment WRITE goes through attendance.usp_Roster_AssertEditable in the database
       (75_roster_approval_applies_and_locks.sql): a month with a roster approval still open is
       read-only, and in an approved month a day in the past or already judged by attendance is a
       record. The procedure's refusal travels up as a 409 with the sentence intact; the C# side
       re-checks nothing, so the database stays the single authority on what may change. */

    public Task<int> SetDayAsync(RosterDayRequest request, int? callerUserId)
        => WorkflowSqlErrors.MapAsync(() =>
            _repo.UpsertDayAsync(request.EmployeeId, request.WorkDate, request.ShiftId, request.IsRestDay, callerUserId));

    public Task DeleteAsync(int shiftAssignmentId, int? callerUserId)
        => WorkflowSqlErrors.MapAsync(async () => { await _repo.DeleteAsync(shiftAssignmentId, callerUserId); return true; });

    public Task<RosterGenerateResult> GenerateAsync(RosterGenerateRequest request, int? callerUserId)
        => WorkflowSqlErrors.MapAsync(() => _repo.GenerateRangeAsync(request.EmployeeId, request.FromDate, request.ToDate,
            request.ShiftId, request.Weekdays, request.Overwrite, callerUserId, request.BranchId));

    /// <summary>
    /// Rosters a whole team in one action. The procedure takes a comma-separated list rather than a
    /// table type, so the ids are flattened here — the repository stays a dumb parameter-passer.
    /// </summary>
    public Task<RosterBulkResult> GenerateBulkAsync(RosterGenerateBulkRequest request, int? callerUserId)
        => WorkflowSqlErrors.MapAsync(() => _repo.GenerateRangeBulkAsync(string.Join(',', request.EmployeeIds), request.FromDate,
            request.ToDate, request.ShiftId, request.Weekdays, request.Overwrite, callerUserId, request.BranchId));

    /// <summary>Copies a month WEEKDAY-ALIGNED — a Monday shift lands on a Monday, not on the same date number. One branch (QA3 ROS-3).</summary>
    public Task<RosterGenerateResult> CopyPeriodAsync(RosterCopyPeriodRequest request, int? callerUserId)
        => WorkflowSqlErrors.MapAsync(() =>
            _repo.CopyPeriodAsync(request.SourceYearMonth, request.TargetYearMonth, request.EmployeeId, request.Overwrite,
                request.BranchId, callerUserId));

    public Task<RosterGenerateResult> ApplyPatternAsync(RosterApplyPatternRequest request, int? callerUserId)
        => WorkflowSqlErrors.MapAsync(() =>
            _repo.ApplyPatternForMonthAsync(request.YearMonth, request.EmployeeId, request.Overwrite, request.BranchId, callerUserId));

    public Task<IEnumerable<RosterGap>> GetGapsAsync(DateTime fromDate, DateTime toDate, int? callerUserId, int? branchId)
        => _repo.GetGapsAsync(fromDate, toDate, callerUserId, branchId);

    public Task<IEnumerable<RosterLeaveDay>> GetLeaveDaysAsync(DateTime fromDate, DateTime toDate, int? branchId, int? callerUserId)
        => WorkflowSqlErrors.MapAsync(() => _repo.GetLeaveDaysAsync(fromDate, toDate, branchId, callerUserId));

    public Task<RosterMonthStatus?> GetMonthAsync(int branchId, DateTime monthDate, int? callerUserId)
        => WorkflowSqlErrors.MapAsync(() => _repo.GetMonthAsync(branchId, monthDate, callerUserId));

    public Task<RosterRederiveResult> RederiveMonthAsync(int branchId, int year, int month, int? callerUserId)
        => WorkflowSqlErrors.MapAsync(async () =>
            new RosterRederiveResult { DaysRederived = await _repo.RederiveMonthAsync(branchId, year, month, callerUserId) });

    /* THE APPROVAL HOOK (QA3 ROS-2). Approving a roster month used to change only its status: every day processed while
       the roster was a draft kept the default day it had been judged against, and payroll readiness stayed blocked by
       rostered days with no record. The month is derived again here, right after the approval committed - outside the
       approve procedure, whose callers wrap it in INSERT...EXEC. A failure here must not turn a committed approval into
       an error for the approver, so it is logged and left to the nightly safety net (the month's RederivedAt is still
       older than its ApprovedAt). */
    public async Task<bool> RederiveApprovedRequestAsync(int requestInstanceId)
    {
        try
        {
            await _repo.RederiveForRequestAsync(requestInstanceId);
            return true;
        }
        catch (Exception ex)
        {
            _logger?.LogWarning(ex,
                "Roster approval {RequestInstanceId}: the month could not be re-derived now; the nightly run will do it.",
                requestInstanceId);
            return false;
        }
    }

    public Task<RosterRederivePendingResult> RederivePendingMonthsAsync() => _repo.RederivePendingAsync();

    public Task<IEnumerable<ShiftPattern>> GetPatternsAsync(int employeeId) => _repo.GetPatternsAsync(employeeId);

    public Task<IEnumerable<EmployeePatternDay>> GetEmployeePatternAsync(int employeeId)
        => _repo.GetEmployeePatternAsync(employeeId);

    /// <summary>
    /// Saves an employee's default week. The editor always sends the whole week, and the procedure
    /// upserts on (EmployeeId, DayOfWeek), so a day that is now a rest day overwrites the shift that
    /// used to be there instead of accumulating alongside it.
    /// </summary>
    public async Task SavePatternsAsync(int employeeId, IEnumerable<ShiftPatternUpsertRequest> days)
    {
        foreach (var day in days)
            await _repo.UpsertPatternAsync(employeeId, day.DayOfWeek, day.ShiftId, day.IsRestDay);
    }

    public Task DeletePatternsAsync(int employeeId) => _repo.DeletePatternsAsync(employeeId);

    /// <summary>The procedure owns every rule; its refusals travel up as a 409 with the sentence intact.</summary>
    public Task<RosterClearResult> ClearMonthAsync(int branchId, int year, int month, int? userId)
        => WorkflowSqlErrors.MapAsync(() => _repo.ClearMonthAsync(branchId, year, month, userId));
}
