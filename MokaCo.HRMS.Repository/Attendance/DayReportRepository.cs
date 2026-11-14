using System.Data;
using Dapper;
using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.Attendance;

public interface IDayReportRepository
{
    Task<int> CreateAsync(DayReportCreateRequest request, int employeeId, int callerUserId);
    Task<IEnumerable<DayReport>> GetListAsync(string scope, string? status, DateTime? fromDate, DateTime? toDate, int callerUserId);
    Task<DayReportHeader?> GetAsync(int reportId);
    Task WithdrawAsync(int reportId, int callerUserId);
    Task<DayReportDecisionResult> RejectAsync(int reportId, string? note, int callerUserId);
    /// <summary>
    /// ONE TRANSACTION: the correction with the reported times (requested by the reporter), its approval by the caller,
    /// and the report marked Accepted. Any refusal rolls all three back.
    /// </summary>
    Task<DayReportDecisionResult> AcceptAsync(DayReportHeader report, string? note, int callerUserId);
}

/// <summary>Dapper access for attendance.usp_DayReport_* (script 110). Every call is guarded for a database without it.</summary>
public class DayReportRepository : IDayReportRepository
{
    private readonly IDbConnectionFactory _factory;
    public DayReportRepository(IDbConnectionFactory factory) => _factory = factory;

    private static Task<T> Guard<T>(string procedure, Func<Task<T>> call)
        => MissingScriptException.GuardAsync(Scripts.DayReports110, procedure, call);

    public async Task<int> CreateAsync(DayReportCreateRequest request, int employeeId, int callerUserId)
    {
        using var db = _factory.Create();
        return await Guard("attendance.usp_DayReport_Create", () => db.QuerySingleAsync<int>(
            "attendance.usp_DayReport_Create",
            new { EmployeeId = employeeId, WorkDate = request.WorkDate.Date, request.ClaimedIn, request.ClaimedOut, request.Message, CallerUserId = callerUserId },
            commandType: CommandType.StoredProcedure));
    }

    public async Task<IEnumerable<DayReport>> GetListAsync(string scope, string? status, DateTime? fromDate, DateTime? toDate, int callerUserId)
    {
        using var db = _factory.Create();
        return await Guard("attendance.usp_DayReport_GetList", () => db.QueryAsync<DayReport>(
            "attendance.usp_DayReport_GetList",
            new { Scope = scope, Status = status, FromDate = fromDate?.Date, ToDate = toDate?.Date, CallerUserId = callerUserId },
            commandType: CommandType.StoredProcedure));
    }

    public async Task<DayReportHeader?> GetAsync(int reportId)
    {
        using var db = _factory.Create();
        return await Guard("attendance.usp_DayReport_Get", () => db.QuerySingleOrDefaultAsync<DayReportHeader>(
            "attendance.usp_DayReport_Get", new { ReportId = reportId }, commandType: CommandType.StoredProcedure));
    }

    public async Task WithdrawAsync(int reportId, int callerUserId)
    {
        using var db = _factory.Create();
        await Guard("attendance.usp_DayReport_Withdraw", () => db.ExecuteAsync(
            "attendance.usp_DayReport_Withdraw", new { ReportId = reportId, CallerUserId = callerUserId },
            commandType: CommandType.StoredProcedure));
    }

    public async Task<DayReportDecisionResult> RejectAsync(int reportId, string? note, int callerUserId)
    {
        using var db = _factory.Create();
        return await Guard("attendance.usp_DayReport_Decide", () => db.QuerySingleAsync<DayReportDecisionResult>(
            "attendance.usp_DayReport_Decide",
            new { ReportId = reportId, Accept = false, Note = note, CorrectionId = (int?)null, CallerUserId = callerUserId },
            commandType: CommandType.StoredProcedure));
    }

    public async Task<DayReportDecisionResult> AcceptAsync(DayReportHeader report, string? note, int callerUserId)
    {
        using var db = _factory.Create();
        db.Open();
        using var tx = db.BeginTransaction();
        var reason = $"Day report #{report.ReportId} by {report.ReportedBy ?? "the employee"}: {report.Message}";
        if (reason.Length > 300) reason = reason[..300];
        var correctionId = await db.QuerySingleAsync<int>(
            "attendance.usp_Correction_Create",
            new
            {
                AttendanceId = report.AttendanceId,
                RequestedBy = report.ReportedByUserId,
                NewFirstInUtc = report.ClaimedIn,
                NewLastOutUtc = report.ClaimedOut,
                NewExitMinutes = (int?)null,
                NewStatus = (report.ClaimedIn is not null || report.ClaimedOut is not null) ? "Present" : null,
                Reason = reason,
            },
            tx, commandType: CommandType.StoredProcedure);
        // Its result set (the day as re-derived) is not needed here; a refusal is raised as an error.
        await db.ExecuteAsync("attendance.usp_Correction_Approve",
            new { CorrectionId = correctionId, ApprovedBy = callerUserId }, tx, commandType: CommandType.StoredProcedure);
        var result = await Guard("attendance.usp_DayReport_Decide", () => db.QuerySingleAsync<DayReportDecisionResult>(
            "attendance.usp_DayReport_Decide",
            new { ReportId = report.ReportId, Accept = true, Note = note, CorrectionId = correctionId, CallerUserId = callerUserId },
            tx, commandType: CommandType.StoredProcedure));
        tx.Commit();
        return result;
    }
}
