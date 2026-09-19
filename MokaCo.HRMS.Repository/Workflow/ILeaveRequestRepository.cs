using MokaCo.HRMS.Model.HR;
using MokaCo.HRMS.Model.Workflow;

namespace MokaCo.HRMS.Repository.Workflow;

public interface ILeaveRequestRepository
{
    /// <summary>
    /// Raises a leave request: submits it into the engine and stores the payload in one transaction.
    /// REFUSES dates overlapping another open or approved leave for the same employee — that refusal
    /// names the clashing dates and must reach the user verbatim.
    /// </summary>
    Task<LeaveRequestCreated?> CreateAsync(
        int employeeId, int raisedByUserId, int leaveTypeId,
        DateTime fromDate, DateTime toDate, string? reason, string? title,
        string? relationToEmployee, string? halfDay);

    /// <summary>hr.usp_Leave_CountWorkingDays: what a range would cost, for the form's preview.</summary>
    Task<LeaveWorkingDays?> CountWorkingDaysAsync(int employeeId, int? leaveTypeId, DateTime fromDate, DateTime toDate, string? halfDay);

    /// <summary>
    /// Approves, optionally granting fewer days than requested. Posts the ledger movement ONCE, when
    /// the request closes Approved. Returns the granted figure and the resulting balance.
    ///
    /// <paramref name="makeDiscretionary"/> waives that posting: the leave is approved but never
    /// deducted. It is the FINAL approver's answer that counts, since only the closing decision
    /// touches the ledger at all.
    /// </summary>
    Task<LeaveRequestDecideResult?> DecideAsync(
        int requestInstanceId, int actedByUserId, decimal? approvedDays,
        string? comment, bool signedWithPassword, bool makeDiscretionary);

    /// <summary>The leave payload behind a request, with the employee's current balance. Null when the request is not a leave one.</summary>
    Task<LeaveRequestPayload?> GetPayloadAsync(int requestInstanceId);

    /// <summary>One employee's leave history, newest first. The date bounds are an overlap filter, not a containment one.</summary>
    Task<IEnumerable<MyLeaveRequest>> GetForEmployeeAsync(int employeeId, DateTime? fromDate, DateTime? toDate);

    /// <summary>An employee's balance for one leave type. Null when the leave type does not exist.</summary>
    Task<LeaveBalanceSummary?> GetBalanceAsync(int employeeId, int leaveTypeId);

    /// <summary>
    /// hr.usp_Leave_GetBalanceByYear: every leave type's balance for one leave year (null = current).
    /// YearOpened false ⇒ Balances empty — the year was never opened for this employee.
    /// </summary>
    Task<LeaveYearBalance> GetBalanceByYearAsync(int employeeId, int? year);
}
