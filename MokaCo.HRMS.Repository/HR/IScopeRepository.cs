using MokaCo.HRMS.Model.HR;

namespace MokaCo.HRMS.Repository.HR;

/// <summary>The branch scope of one record (hr.usp_Scope_CallerSees, script 98). Pass exactly one id.</summary>
public interface IScopeRepository
{
    Task<CallerScope> CallerSeesAsync(int callerUserId, int? employeeId = null, long? attendanceId = null, int? documentId = null);
}
