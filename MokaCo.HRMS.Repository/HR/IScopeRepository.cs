using MokaCo.HRMS.Model.HR;

namespace MokaCo.HRMS.Repository.HR;

/// <summary>The branch scope of one record (hr.usp_Scope_CallerSees, script 98). Pass exactly one id.</summary>
public interface IScopeRepository
{
    Task<CallerScope> CallerSeesAsync(int callerUserId, int? employeeId = null, long? attendanceId = null, int? documentId = null);

    /// <summary>
    /// What the caller may see for <paramref name="fromDate"/>..<paramref name="toDate"/> (null = any day):
    /// hr.usp_Scope_CallerEmployees, script 105 (QA3 ATT-16). For filtering the rows of a list.
    /// </summary>
    Task<CallerScopeSet> CallerEmployeesAsync(int callerUserId, DateTime? fromDate, DateTime? toDate);
}
