using MokaCo.HRMS.Model.Attendance;

namespace MokaCo.HRMS.Services.Attendance;

public interface IRosterService
{
    Task<IEnumerable<ShiftAssignment>> GetAsync(DateTime fromDate, DateTime toDate, int? employeeId);
    Task<int> SetDayAsync(RosterDayRequest request);
    Task DeleteAsync(int shiftAssignmentId);
    Task<RosterGenerateResult> GenerateAsync(RosterGenerateRequest request);
    Task<RosterBulkResult> GenerateBulkAsync(RosterGenerateBulkRequest request);
    Task<RosterGenerateResult> CopyPeriodAsync(RosterCopyPeriodRequest request);
    Task<RosterGenerateResult> ApplyPatternAsync(RosterApplyPatternRequest request);
    Task<IEnumerable<RosterGap>> GetGapsAsync(DateTime fromDate, DateTime toDate);
    Task<IEnumerable<ShiftPattern>> GetPatternsAsync(int employeeId);

    /// <summary>The weekly template as SEVEN rows, whatever is on file — see IRosterRepository.</summary>
    Task<IEnumerable<EmployeePatternDay>> GetEmployeePatternAsync(int employeeId);
    Task SavePatternsAsync(int employeeId, IEnumerable<ShiftPatternUpsertRequest> days);
    Task DeletePatternsAsync(int employeeId);

    /// <summary>
    /// Clears one branch-month of roster. Refused (WorkflowException 409, procedure's sentence) while a
    /// roster request is pending/on hold/approved for it, or once attendance exists on any of its days.
    /// </summary>
    Task<RosterClearResult> ClearMonthAsync(int branchId, int year, int month, int? userId);
}
