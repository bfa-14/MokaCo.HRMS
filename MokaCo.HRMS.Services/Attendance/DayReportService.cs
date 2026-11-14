using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Repository.Attendance;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Services.Attendance;

public interface IDayReportService
{
    Task<int> CreateAsync(DayReportCreateRequest request, int callerUserId);
    Task<IEnumerable<DayReport>> GetMineAsync(DateTime? fromDate, DateTime? toDate, int callerUserId);
    Task<IEnumerable<DayReport>> GetQueueAsync(string? status, DateTime? fromDate, DateTime? toDate, int callerUserId);
    Task WithdrawAsync(int reportId, int callerUserId);
    Task<DayReportDecisionResult> DecideAsync(int reportId, DayReportDecisionRequest request, int callerUserId);
}

/// <summary>
/// "SOMETHING IS WRONG WITH THIS DAY" (script 110). The procedures are the authority on who may report and who may
/// decide; this layer resolves "my own day", runs the accept as one transaction (correction raised, approved, report
/// marked) and turns every refusal into a WorkflowException with its status.
/// </summary>
public class DayReportService : IDayReportService
{
    private readonly IDayReportRepository _repo;
    private readonly IWorkflowSupportService _support;

    public DayReportService(IDayReportRepository repo, IWorkflowSupportService support)
    {
        _repo = repo;
        _support = support;
    }

    public async Task<int> CreateAsync(DayReportCreateRequest request, int callerUserId)
    {
        var employeeId = request.EmployeeId;
        if (employeeId is null)
        {
            var me = await _support.GetEmployeeByUserIdAsync(callerUserId)
                     ?? throw new WorkflowException(400, "This account has no employee record, so it has no days to report.");
            employeeId = me.EmployeeId;
        }
        return await WorkflowSqlErrors.MapAsync(() => _repo.CreateAsync(request, employeeId.Value, callerUserId));
    }

    public Task<IEnumerable<DayReport>> GetMineAsync(DateTime? fromDate, DateTime? toDate, int callerUserId)
        => _repo.GetListAsync("Mine", null, fromDate, toDate, callerUserId);

    public Task<IEnumerable<DayReport>> GetQueueAsync(string? status, DateTime? fromDate, DateTime? toDate, int callerUserId)
        => _repo.GetListAsync("Queue", string.IsNullOrWhiteSpace(status) ? null : status, fromDate, toDate, callerUserId);

    public Task WithdrawAsync(int reportId, int callerUserId)
        => WorkflowSqlErrors.MapAsync(async () => { await _repo.WithdrawAsync(reportId, callerUserId); return true; });

    public async Task<DayReportDecisionResult> DecideAsync(int reportId, DayReportDecisionRequest request, int callerUserId)
    {
        if (!request.Accept)
            return await WorkflowSqlErrors.MapAsync(() => _repo.RejectAsync(reportId, request.Note, callerUserId));

        var report = await _repo.GetAsync(reportId) ?? throw new WorkflowException(404, "Report not found.");
        if (report.Status != "Open")
            throw new WorkflowException(409, "This report is no longer open. Reload the list.");
        if (report.AttendanceId is null)
            throw new WorkflowException(409,
                "This day has no attendance record yet, so there is nothing to correct. Build the day first (Daily attendance: run the processor or mark absentees), or enter it by hand, then accept.");
        if (report.ClaimedIn is null && report.ClaimedOut is null)
            throw new WorkflowException(400,
                "This report gives no times to write. Fix the day by hand from Daily attendance, then reject the report with a note saying what was done.");
        return await WorkflowSqlErrors.MapAsync(() => _repo.AcceptAsync(report, request.Note, callerUserId));
    }
}
