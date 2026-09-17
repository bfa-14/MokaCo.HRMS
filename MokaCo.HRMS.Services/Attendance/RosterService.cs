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
    public RosterService(IRosterRepository repo) => _repo = repo;

    public Task<IEnumerable<ShiftAssignment>> GetAsync(DateTime fromDate, DateTime toDate, int? employeeId)
        => _repo.GetByDateRangeAsync(fromDate, toDate, employeeId);

    public Task<int> SetDayAsync(RosterDayRequest request)
        => _repo.UpsertDayAsync(request.EmployeeId, request.WorkDate, request.ShiftId, request.IsRestDay);

    public Task DeleteAsync(int shiftAssignmentId) => _repo.DeleteAsync(shiftAssignmentId);

    public Task<RosterGenerateResult> GenerateAsync(RosterGenerateRequest request)
        => _repo.GenerateRangeAsync(request.EmployeeId, request.FromDate, request.ToDate,
            request.ShiftId, request.Weekdays, request.Overwrite);

    /// <summary>
    /// Rosters a whole team in one action. The procedure takes a comma-separated list rather than a
    /// table type, so the ids are flattened here — the repository stays a dumb parameter-passer.
    /// </summary>
    public Task<RosterBulkResult> GenerateBulkAsync(RosterGenerateBulkRequest request)
        => _repo.GenerateRangeBulkAsync(string.Join(',', request.EmployeeIds), request.FromDate,
            request.ToDate, request.ShiftId, request.Weekdays, request.Overwrite);

    /// <summary>Copies a month WEEKDAY-ALIGNED — a Monday shift lands on a Monday, not on the same date number.</summary>
    public Task<RosterGenerateResult> CopyPeriodAsync(RosterCopyPeriodRequest request)
        => _repo.CopyPeriodAsync(request.SourceYearMonth, request.TargetYearMonth, request.EmployeeId, request.Overwrite);

    public Task<RosterGenerateResult> ApplyPatternAsync(RosterApplyPatternRequest request)
        => _repo.ApplyPatternForMonthAsync(request.YearMonth, request.EmployeeId, request.Overwrite);

    public Task<IEnumerable<RosterGap>> GetGapsAsync(DateTime fromDate, DateTime toDate)
        => _repo.GetGapsAsync(fromDate, toDate);

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
