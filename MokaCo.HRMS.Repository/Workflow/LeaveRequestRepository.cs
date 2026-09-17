using System.Data;
using Dapper;
using MokaCo.HRMS.Model.HR;
using MokaCo.HRMS.Model.Workflow;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.Workflow;

/// <summary>
/// Dapper access for leave requests via workflow.usp_LeaveRequest_* and hr.usp_Leave_GetBalance.
///
/// Every rule lives in the procedures — the overlap refusal, the inclusive day count, the
/// 0-to-requested bound on the granted figure, and the once-only ledger posting. Nothing here
/// re-implements or second-guesses any of them; the errors they raise travel up as SqlException and
/// are mapped to statuses one layer above.
/// </summary>
public class LeaveRequestRepository : ILeaveRequestRepository
{
    private readonly IDbConnectionFactory _factory;
    public LeaveRequestRepository(IDbConnectionFactory factory) => _factory = factory;

    public async Task<LeaveRequestCreated?> CreateAsync(
        int employeeId, int raisedByUserId, int leaveTypeId,
        DateTime fromDate, DateTime toDate, string? reason, string? title,
        string? relationToEmployee)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<LeaveRequestCreated>(
            "workflow.usp_LeaveRequest_Create",
            new
            {
                EmployeeId = employeeId,
                RaisedByUserId = raisedByUserId,
                LeaveTypeId = leaveTypeId,
                FromDate = fromDate.Date,
                ToDate = toDate.Date,
                Reason = reason,
                // Null/blank → the procedure composes the standard title. Never composed here.
                Title = title,
                // Passed through untouched: the procedure decides whether this type needs one, and
                // refuses an unknown relation. Nothing here validates it against a list.
                RelationToEmployee = relationToEmployee,
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<LeaveRequestDecideResult?> DecideAsync(
        int requestInstanceId, int actedByUserId, decimal? approvedDays,
        string? comment, bool signedWithPassword, bool makeDiscretionary)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<LeaveRequestDecideResult>(
            "workflow.usp_LeaveRequest_Decide",
            new
            {
                RequestInstanceId = requestInstanceId,
                ActedByUserId = actedByUserId,
                // Null means "as requested" — the procedure's own default, not a figure invented here.
                ApprovedDays = approvedDays,
                Comment = comment,
                SignedWithPassword = signedWithPassword,
                // Whether to waive the deduction. Passed through as asked; WHEN it can take effect
                // (only on the decision that closes the request) is the procedure's rule, and what it
                // actually did comes back as DiscretionaryGranted.
                MakeDiscretionary = makeDiscretionary,
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<LeaveRequestPayload?> GetPayloadAsync(int requestInstanceId)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<LeaveRequestPayload>(
            "workflow.usp_LeaveRequest_GetPayload",
            new { RequestInstanceId = requestInstanceId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<MyLeaveRequest>> GetForEmployeeAsync(int employeeId, DateTime? fromDate, DateTime? toDate)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<MyLeaveRequest>(
            "workflow.usp_LeaveRequest_GetForEmployee",
            new { EmployeeId = employeeId, FromDate = fromDate, ToDate = toDate },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<LeaveBalanceSummary?> GetBalanceAsync(int employeeId, int leaveTypeId)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<LeaveBalanceSummary>(
            "hr.usp_Leave_GetBalance",
            new { EmployeeId = employeeId, LeaveTypeId = leaveTypeId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<LeaveYearBalance> GetBalanceByYearAsync(int employeeId, int? year)
    {
        using var db = _factory.Create();
        using var grid = await db.QueryMultipleAsync(
            "hr.usp_Leave_GetBalanceByYear",
            new { EmployeeId = employeeId, Year = year },
            commandType: CommandType.StoredProcedure);

        // Two result sets, in the procedure's order: the header (YearOpened, Year), then the rows.
        var header = await grid.ReadSingleAsync<(bool YearOpened, int Year)>();
        var rows = (await grid.ReadAsync<LeaveTypeYearBalance>()).ToList();
        return new LeaveYearBalance
        {
            EmployeeId = employeeId,
            Year = header.Year,
            YearOpened = header.YearOpened,
            Balances = rows,
        };
    }
}
