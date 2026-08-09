using MokaCo.HRMS.Model.Attendance;

namespace MokaCo.HRMS.Repository.Attendance;

public interface IRosterRepository
{
    Task<IEnumerable<ShiftAssignment>> GetByDateRangeAsync(DateTime fromDate, DateTime toDate, int? employeeId);
    Task<int> UpsertDayAsync(int employeeId, DateTime workDate, int? shiftId, bool isRestDay);
    Task DeleteAsync(int shiftAssignmentId);

    Task<RosterGenerateResult> GenerateRangeAsync(int employeeId, DateTime fromDate, DateTime toDate, int shiftId, string weekdays, bool overwrite);
    Task<RosterBulkResult> GenerateRangeBulkAsync(string employeeIds, DateTime fromDate, DateTime toDate, int shiftId, string weekdays, bool overwrite);
    Task<RosterGenerateResult> CopyPeriodAsync(string sourceYearMonth, string targetYearMonth, int? employeeId, bool overwrite);
    Task<RosterGenerateResult> ApplyPatternForMonthAsync(string yearMonth, int? employeeId, bool overwrite);

    Task<IEnumerable<RosterGap>> GetGapsAsync(DateTime fromDate, DateTime toDate);

    Task<IEnumerable<ShiftPattern>> GetPatternsAsync(int employeeId);

    /// <summary>
    /// The employee's weekly template as SEVEN ROWS, whatever is on file — the shape a form that
    /// offers a whole week has to start from. GetPatternsAsync returns only the rows that exist, so a
    /// form built on it would silently offer a three-day week to somebody with three configured days.
    /// </summary>
    Task<IEnumerable<EmployeePatternDay>> GetEmployeePatternAsync(int employeeId);

    Task UpsertPatternAsync(int employeeId, byte dayOfWeek, int? shiftId, bool isRestDay);
    Task DeletePatternsAsync(int employeeId);
}
