using MokaCo.HRMS.Model.HR;

namespace MokaCo.HRMS.Services.HR;

public interface ILeaveLedgerService
{
    Task<IEnumerable<LeaveLedgerEntry>> GetByEmployeeAsync(int employeeId, string? periodYearMonth);

    /// <summary>Everybody's approved leave days in a range. The roster uses it to avoid scheduling a shift on a leave day.</summary>
    Task<IEnumerable<LeaveDay>> GetLeaveDaysInRangeAsync(DateTime fromDate, DateTime toDate);
    Task<int> PostMovementAsync(LeaveLedgerPostRequest request, int? createdBy);
    Task DeleteAsync(int leaveLedgerId);
    Task<IEnumerable<LeaveBalance>> GetBalanceAsync(int employeeId, string? periodYearMonth);
}
