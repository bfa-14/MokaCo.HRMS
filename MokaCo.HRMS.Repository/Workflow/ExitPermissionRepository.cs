using System.Data;
using Dapper;
using MokaCo.HRMS.Model.Workflow;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.Workflow;

/// <summary>
/// Dapper access for exit permissions via workflow.usp_ExitPermission_*.
///
/// Creating one submits a request AND stores the payload in a single transaction; applying it pushes
/// the approved minutes into the attendance day when that day exists. The apply is idempotent — a
/// permission carries AppliedToAttendanceAt, so a repeat sweep changes nothing.
/// </summary>
public class ExitPermissionRepository : IExitPermissionRepository
{
    private readonly IDbConnectionFactory _factory;
    public ExitPermissionRepository(IDbConnectionFactory factory) => _factory = factory;

    public async Task<ExitPermissionCreated?> CreateAsync(int employeeId, int raisedByUserId, DateTime exitDate, TimeSpan fromTime, TimeSpan toTime, string reason, bool convertToLeave, string? title)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<ExitPermissionCreated>(
            "workflow.usp_ExitPermission_Create",
            new
            {
                EmployeeId = employeeId,
                RaisedByUserId = raisedByUserId,
                ExitDate = exitDate,
                FromTime = fromTime,
                ToTime = toTime,
                Reason = reason,
                ConvertToLeave = convertToLeave,
                // Null/blank → the procedure composes the standard title. Never composed here.
                Title = title,
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<MyExitPermission>> GetForEmployeeAsync(int employeeId, DateTime? fromDate, DateTime? toDate)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<MyExitPermission>(
            "workflow.usp_ExitPermission_GetForEmployee",
            new { EmployeeId = employeeId, FromDate = fromDate, ToDate = toDate },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>The payload plus, once the day exists, what attendance recorded — approved vs actual vs variance.</summary>
    public async Task<ExitPermissionDetail?> GetByRequestAsync(int requestInstanceId)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<ExitPermissionDetail>(
            "workflow.usp_ExitPermission_GetByRequest",
            new { RequestInstanceId = requestInstanceId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<ApplyResult> ApplyToAttendanceAsync(int? exitPermissionId, DateTime? workDate)
    {
        using var db = _factory.Create();
        return await db.QuerySingleAsync<ApplyResult>(
            "workflow.usp_ExitPermission_ApplyToAttendance",
            new { ExitPermissionId = exitPermissionId, WorkDate = workDate },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<PendingApplication>> GetPendingApplicationAsync()
    {
        using var db = _factory.Create();
        return await db.QueryAsync<PendingApplication>(
            "workflow.usp_ExitPermission_GetPendingApplication",
            commandType: CommandType.StoredProcedure);
    }

    public async Task<PostLeaveResult> PostLeaveUsageAsync(string periodYearMonth, int leaveTypeId, int? postedBy)
    {
        using var db = _factory.Create();
        return await db.QuerySingleAsync<PostLeaveResult>(
            "workflow.usp_ExitPermission_PostLeaveUsage",
            new { PeriodYearMonth = periodYearMonth, LeaveTypeId = leaveTypeId, PostedBy = postedBy },
            commandType: CommandType.StoredProcedure);
    }
}
