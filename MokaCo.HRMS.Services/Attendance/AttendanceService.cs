using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Repository.Attendance;

namespace MokaCo.HRMS.Services.Attendance;

/// <summary>
/// Processed attendance: the facts payroll reads, and the HR overrides that can change them.
///
/// The rule this whole class serves: ATTENDANCE REPORTS, WORKFLOW AUTHORIZES, HR DECIDES. Nothing
/// here decides what anyone is paid. Overtime is detected and left alone. An exit that ran long is
/// measured and handed to a human. If a method in this file ever starts deciding what something is
/// worth, it belongs in payroll and not here.
///
/// It is deliberately thin: every calculation lives in the stored procedures, so a manual day, a
/// corrected day and a machine-read day are all measured by exactly the same arithmetic. Duplicating
/// any of that maths in C# would mean two answers to the same question.
/// </summary>
public class AttendanceService : IAttendanceService
{
    private readonly IAttendanceRepository _repo;
    private readonly IIngestionRepository _ingestion;

    public AttendanceService(IAttendanceRepository repo, IIngestionRepository ingestion)
    {
        _repo = repo;
        _ingestion = ingestion;
    }

    /// <summary>
    /// Builds employee-day records from raw punches. Passing no date consumes everything outstanding.
    /// Safe to run repeatedly: it only ever consumes unprocessed punches, and it will not touch a day
    /// HR has marked manual.
    /// </summary>
    public Task<ProcessResult> ProcessAsync(DateTime? workDate) => _repo.ProcessRawLogsAsync(workDate);

    /// <summary>
    /// Re-derives one day under the CURRENT punch-interpretation settings.
    ///
    /// It exists because <see cref="ProcessAsync"/> is incremental: it consumes only punches it has
    /// not seen, so changing how punches are READ — the direction mode, the debounce window — means
    /// nothing to the days already built under the old reading. This is how yesterday catches up.
    /// </summary>
    public Task<ProcessResult> ReprocessDayAsync(DateTime workDate) => _repo.ReprocessDayAsync(workDate);

    /// <summary>Run AFTER the processor: it writes the records for people who were rostered but never punched at all.</summary>
    public Task<MarkAbsenteesResult> MarkAbsenteesAsync(DateTime workDate) => _repo.MarkAbsenteesAsync(workDate);

    public Task<MarkLeaveDaysResult> MarkLeaveDaysAsync(string periodYearMonth) => _repo.MarkLeaveDaysAsync(periodYearMonth);

    public Task<IEnumerable<AttendanceRecord>> GetAsync(DateTime fromDate, DateTime toDate, int? employeeId, int? branchId)
        => _repo.GetByDateRangeAsync(fromDate, toDate, employeeId, branchId);

    public Task<AttendanceDetail?> GetByIdAsync(long attendanceId) => _repo.GetByIdAsync(attendanceId);

    /// <summary>
    /// The HR decision queue for the tolerance rule (script 77): every late arrival or early
    /// departure at or beyond the tolerance, and every missing punch, one row each. Undecided
    /// minutes are covered in pay until somebody rules; payroll is blocked while any remain.
    /// </summary>
    public Task<IEnumerable<AttendanceAnomaly>> GetAnomaliesAsync(DateTime fromDate, DateTime toDate, bool onlyUndecided, int? branchId)
        => _repo.GetAnomaliesAsync(fromDate, toDate, onlyUndecided, branchId);

    /// <summary>
    /// Excuse keeps the minutes covered, Deduct takes them off the day, Correct stores the punch as
    /// it should have been through the manual path. The procedure re-derives the day, so this is
    /// thin on purpose: one arithmetic, in SQL.
    /// </summary>
    public Task<AnomalyDecisionResult?> DecideAnomalyAsync(long anomalyId, AnomalyDecisionRequest request, int decidedByUserId)
        => _repo.DecideAnomalyAsync(anomalyId, request.Decision, request.CorrectedTime, request.Note, decidedByUserId);

    public Task<AnomalyDecideAllResult> DecideAllAnomaliesAsync(AnomalyDecideAllRequest request, int decidedByUserId)
        => _repo.DecideAllAnomaliesAsync(request.Month, request.Decision, request.BranchId, request.Note, decidedByUserId);

    /// <summary>The raw punches behind a day — what the machine actually said, before anyone processed or corrected it.</summary>
    public Task<IEnumerable<RawLog>> GetRawAsync(int employeeId, DateTime workDate)
        => _ingestion.GetByEmployeeDayAsync(employeeId, workDate);

    public Task<IEnumerable<ExitVariance>> GetExitVariancesAsync(DateTime fromDate, DateTime toDate, bool onlyUndecided)
        => _repo.GetExitVariancesAsync(fromDate, toDate, onlyUndecided);

    /// <summary>
    /// HR enters a day by hand — the machine was down, or a punch never happened. The day is still
    /// measured against the rostered shift, so it is not a special case downstream. It sets IsManual,
    /// which permanently locks the processor out of the row: that is what stops tonight's run from
    /// silently undoing HR's work.
    /// </summary>
    public Task<AttendanceRecord?> ManualUpsertAsync(ManualAttendanceRequest request) => _repo.ManualUpsertAsync(request);

    /// <summary>
    /// Records what was AUTHORISED. It does not touch what the punches OBSERVED — approved and actual
    /// are two independent facts, and an approval for two hours does not make a 90-minute absence
    /// into a two-hour one.
    /// </summary>
    public Task<AttendanceRecord?> SetExitApprovalAsync(long attendanceId, ExitApprovalRequest request)
        => _repo.SetExitApprovalAsync(attendanceId, request.ExitApprovedMinutes, request.ExitPermissionId,
            request.AlsoSetActual, request.HrNote);

    /// <summary>
    /// HR rules on the difference between approved and actual: deduct it, offset it against overtime,
    /// or ignore it. This is the decision payroll is blocked on — the month cannot be paid while any
    /// variance is still undecided.
    /// </summary>
    public Task<AttendanceRecord?> SetExitDispositionAsync(long attendanceId, ExitDispositionRequest request)
        => _repo.SetExitDispositionAsync(attendanceId, request.Disposition, request.ExitLeaveMinutesOverride, request.HrNote);

    public Task<AttendanceRecord?> AdjustDayAsync(long attendanceId, HrAdjustDayRequest request, int? modifiedBy)
        => _repo.HrAdjustDayAsync(attendanceId, request.WorkedMinutes, request.DayFraction,
            request.Status, request.HrNote, modifiedBy);

    /// <summary>The pre-flight check. Payroll reads attendance, so an incomplete month pays the wrong amounts — quietly.</summary>
    public Task<PayrollReadiness> GetPayrollReadinessAsync(string periodYearMonth) => _repo.GetPayrollReadinessAsync(periodYearMonth);

    public Task<AttendanceSummary?> GetSummaryAsync(int employeeId, string periodYearMonth)
        => _repo.GetMonthlySummaryAsync(employeeId, periodYearMonth);

    public Task<IEnumerable<AttendanceSummary>> GetSummaryAllAsync(string periodYearMonth)
        => _repo.GetMonthlySummaryAllAsync(periodYearMonth);

    public Task<IEnumerable<AttendanceBranchSummary>> GetSummaryByBranchAsync(string periodYearMonth, int? employeeId)
        => _repo.GetMonthlyByBranchAsync(periodYearMonth, employeeId);

    /// <summary>
    /// Where one branch-month of roster has got to. A pure read — the roster is put up for approval
    /// through the workflow engine and activated by it, never from here.
    /// </summary>
    public Task<RosterMonthStatus?> GetRosterMonthAsync(int branchId, DateTime monthDate)
        => _repo.GetRosterMonthAsync(branchId, monthDate);
}
