using System.Data;
using Dapper;
using MokaCo.HRMS.Model.Workflow;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.Workflow;

public interface IOvertimeRepository
{
    /// <summary>
    /// Raises an overtime request. The PAST-DATE refusal lives in the procedure and must reach the
    /// user word for word — it is the one people hit most.
    /// </summary>
    Task<OvertimeCreated?> CreateAsync(
        int employeeId, int raisedByUserId, DateTime workDate,
        int requestedMinutes, string? reason, string? title);

    /// <summary>
    /// Approves at a stated cap. The figure is REQUIRED and may only ever TIGHTEN: the procedure
    /// refuses more than was requested, and refuses more than an earlier approver already capped it
    /// at, each with a sentence naming the figure in question. Null is passed through so that
    /// omitting it earns the procedure's own "State the approved minutes", not a local guess.
    /// </summary>
    Task<OvertimeDecisionResult?> DecideAsync(
        int requestInstanceId, int actedByUserId, int? approvedMinutes,
        string? comment, bool signedWithPassword);

    Task<OvertimePayload?> GetPayloadAsync(int requestInstanceId);
    Task<IEnumerable<MyOvertime>> GetForEmployeeAsync(int employeeId, DateTime? fromDate, DateTime? toDate);

    /// <summary>
    /// Links approved overtime to the attendance day it belongs to. Null workDate sweeps everything
    /// outstanding. Idempotent — a request already stamped is left alone.
    /// </summary>
    Task<OvertimeApplyResult> ApplyToAttendanceAsync(DateTime? workDate);
}

/// <summary>
/// Dapper access for overtime via workflow.usp_Overtime_*.
///
/// Every rule belongs to the procedures: the past-date refusal, the duplicate guard, the bound on
/// what may be granted, and the payable figure being the LESSER of what was detected and what was
/// approved. Nothing here re-derives any of it.
/// </summary>
public class OvertimeRepository : IOvertimeRepository
{
    private readonly IDbConnectionFactory _factory;
    public OvertimeRepository(IDbConnectionFactory factory) => _factory = factory;

    public async Task<OvertimeCreated?> CreateAsync(
        int employeeId, int raisedByUserId, DateTime workDate,
        int requestedMinutes, string? reason, string? title)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<OvertimeCreated>(
            "workflow.usp_Overtime_Create",
            new
            {
                EmployeeId = employeeId,
                RaisedByUserId = raisedByUserId,
                WorkDate = workDate.Date,
                RequestedMinutes = requestedMinutes,
                Reason = reason,
                Title = title,
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<OvertimeDecisionResult?> DecideAsync(
        int requestInstanceId, int actedByUserId, int? approvedMinutes,
        string? comment, bool signedWithPassword)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<OvertimeDecisionResult>(
            "workflow.usp_Overtime_Decide",
            new
            {
                RequestInstanceId = requestInstanceId,
                ActedByUserId = actedByUserId,
                // Passed through even when null: the procedure refuses it with the sentence that
                // names what is missing, which is better than anything invented here.
                ApprovedMinutes = approvedMinutes,
                Comment = comment,
                SignedWithPassword = signedWithPassword,
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<OvertimePayload?> GetPayloadAsync(int requestInstanceId)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<OvertimePayload>(
            "workflow.usp_Overtime_GetPayload",
            new { RequestInstanceId = requestInstanceId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<MyOvertime>> GetForEmployeeAsync(int employeeId, DateTime? fromDate, DateTime? toDate)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<MyOvertime>(
            "workflow.usp_Overtime_GetForEmployee",
            new { EmployeeId = employeeId, FromDate = fromDate, ToDate = toDate },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<OvertimeApplyResult> ApplyToAttendanceAsync(DateTime? workDate)
    {
        using var db = _factory.Create();
        return await db.QuerySingleAsync<OvertimeApplyResult>(
            "workflow.usp_Overtime_ApplyToAttendance",
            new { WorkDate = workDate },
            commandType: CommandType.StoredProcedure,
            // A whole-backlog sweep touches every unstamped day; well past the 30s default.
            commandTimeout: 300);
    }
}
