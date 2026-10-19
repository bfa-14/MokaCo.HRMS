using System.Data;
using Dapper;
using MokaCo.HRMS.Model.HR;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.HR;

/// <summary>Dapper access for hr.usp_Scope_CallerSees.</summary>
public class ScopeRepository : IScopeRepository
{
    private readonly IDbConnectionFactory _factory;
    public ScopeRepository(IDbConnectionFactory factory) => _factory = factory;

    public async Task<CallerScope> CallerSeesAsync(int callerUserId, int? employeeId = null, long? attendanceId = null, int? documentId = null)
    {
        using var db = _factory.Create();
        return await db.QuerySingleAsync<CallerScope>(
            "hr.usp_Scope_CallerSees",
            new { CallerUserId = callerUserId, EmployeeId = employeeId, AttendanceId = attendanceId, DocumentId = documentId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<CallerScopeSet> CallerEmployeesAsync(int callerUserId, DateTime? fromDate, DateTime? toDate)
    {
        using var db = _factory.Create();
        var rows = await MissingScriptException.GuardAsync(Scripts.Security105, "hr.usp_Scope_CallerEmployees",
            () => db.QueryAsync<(string Kind, int? Id)>(
                "hr.usp_Scope_CallerEmployees",
                new { CallerUserId = callerUserId, FromDate = fromDate?.Date, ToDate = toDate?.Date },
                commandType: CommandType.StoredProcedure));
        return CallerScopeSet.From(rows);
    }
}
