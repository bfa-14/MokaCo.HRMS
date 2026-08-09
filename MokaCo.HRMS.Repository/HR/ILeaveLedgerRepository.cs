using MokaCo.HRMS.Model.HR;

namespace MokaCo.HRMS.Repository.HR;

public interface ILeaveLedgerRepository
{
    Task<IEnumerable<LeaveLedgerEntry>> GetByEmployeeAsync(int employeeId, string? periodYearMonth);

    /// <summary>
    /// Who is on approved leave between two dates — EVERYONE at once, one row per employee-day.
    /// The roster needs this to avoid scheduling a shift on somebody's leave day, and reading the
    /// ledger one employee at a time would mean a round trip per person per month.
    /// </summary>
    Task<IEnumerable<LeaveDay>> GetLeaveDaysInRangeAsync(DateTime fromDate, DateTime toDate);
    Task<int> PostMovementAsync(
        int employeeId, int leaveTypeId, string movementType, decimal days, DateTime effectiveDate,
        int? leaveRequestId, string? note, int? createdBy);
    Task DeleteAsync(int leaveLedgerId);
    Task<IEnumerable<LeaveBalance>> GetBalanceAsync(int employeeId, string? periodYearMonth);
}
