using MokaCo.HRMS.Model.HR;
using MokaCo.HRMS.Repository.HR;

namespace MokaCo.HRMS.Services.HR;

/// <summary>Leave-ledger administration and derived balance (thin wrapper over the repository).</summary>
public class LeaveLedgerService : ILeaveLedgerService
{
    private readonly ILeaveLedgerRepository _repo;
    public LeaveLedgerService(ILeaveLedgerRepository repo) => _repo = repo;

    public Task<IEnumerable<LeaveLedgerEntry>> GetByEmployeeAsync(int employeeId, string? periodYearMonth)
        => _repo.GetByEmployeeAsync(employeeId, periodYearMonth);

    /// <summary>
    /// Everybody's approved leave days in a range, one row per employee-day.
    ///
    /// This is a SEAM. Leave is derived from ledger movements today because that is the only source
    /// there is; workflow.LEAVE_REQUEST, with a real date range to expand, has not been built. When
    /// it is, the procedure behind this method changes and its callers do not.
    /// </summary>
    public Task<IEnumerable<LeaveDay>> GetLeaveDaysInRangeAsync(DateTime fromDate, DateTime toDate)
        => _repo.GetLeaveDaysInRangeAsync(fromDate, toDate);

    public Task<int> PostMovementAsync(LeaveLedgerPostRequest request, int? createdBy)
        => _repo.PostMovementAsync(
            request.EmployeeId, request.LeaveTypeId, request.MovementType, request.Days,
            request.EffectiveDate, request.LeaveRequestId, request.Note, createdBy);

    public Task DeleteAsync(int leaveLedgerId) => _repo.DeleteAsync(leaveLedgerId);

    public Task<IEnumerable<LeaveBalance>> GetBalanceAsync(int employeeId, string? periodYearMonth)
        => _repo.GetBalanceAsync(employeeId, periodYearMonth);
}
