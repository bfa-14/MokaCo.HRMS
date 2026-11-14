using MokaCo.HRMS.Model.Attendance;

namespace MokaCo.HRMS.Services.Attendance;

public interface IAttendanceService
{
    Task<ProcessResult> ProcessAsync(DateTime? workDate);

    /// <summary>
    /// Re-derives ONE day under the current punch-interpretation settings. The ordinary processor
    /// is incremental, so a day already built is never revisited when the rules for reading its
    /// punches change — this is what makes such a change reach yesterday.
    /// </summary>
    Task<ProcessResult> ReprocessDayAsync(DateTime workDate);

    Task<MarkAbsenteesResult> MarkAbsenteesAsync(DateTime workDate);

    /// <summary>Re-process every day of a range (at most DayRange.MaxDays), one day after the other.</summary>
    Task<ProcessResult> ReprocessRangeAsync(DateTime fromDate, DateTime toDate);

    /// <summary>Mark absentees on every day of a range (at most DayRange.MaxDays).</summary>
    Task<MarkAbsenteesResult> MarkAbsenteesRangeAsync(DateTime fromDate, DateTime toDate);
    Task<MarkLeaveDaysResult> MarkLeaveDaysAsync(string periodYearMonth);

    Task<IEnumerable<AttendanceRecord>> GetAsync(DateTime fromDate, DateTime toDate, int? employeeId, int? branchId, int? callerUserId = null);
    Task<AttendanceDetail?> GetByIdAsync(long attendanceId);
    Task<IEnumerable<AttendanceAnomaly>> GetAnomaliesAsync(DateTime fromDate, DateTime toDate, bool onlyUndecided, int? branchId, int? callerUserId = null);
    Task<IEnumerable<RawLog>> GetRawAsync(int employeeId, DateTime workDate);
    Task<IEnumerable<ExitVariance>> GetExitVariancesAsync(DateTime fromDate, DateTime toDate, bool onlyUndecided, int? callerUserId = null);

    Task<AttendanceRecord?> ManualUpsertAsync(ManualAttendanceRequest request);
    Task<AttendanceRecord?> SetExitApprovalAsync(long attendanceId, ExitApprovalRequest request);
    Task<AttendanceRecord?> SetExitDispositionAsync(long attendanceId, ExitDispositionRequest request);
    Task<AttendanceRecord?> AdjustDayAsync(long attendanceId, HrAdjustDayRequest request, int? modifiedBy);

    /// <summary>HR's ruling on one anomaly (Excuse / Deduct / Correct); the day is re-derived with it — script 77.</summary>
    Task<AnomalyDecisionResult?> DecideAnomalyAsync(long anomalyId, AnomalyDecisionRequest request, int decidedByUserId);

    /// <summary>The same ruling for every undecided late arrival / early departure of a month (optionally one branch).</summary>
    Task<AnomalyDecideAllResult> DecideAllAnomaliesAsync(AnomalyDecideAllRequest request, int decidedByUserId);

    Task<PayrollReadiness> GetPayrollReadinessAsync(string periodYearMonth);
    Task<AttendanceSummary?> GetSummaryAsync(int employeeId, string periodYearMonth);
    Task<IEnumerable<AttendanceSummary>> GetSummaryAllAsync(string periodYearMonth);
    Task<IEnumerable<AttendanceBranchSummary>> GetSummaryByBranchAsync(string periodYearMonth, int? employeeId);

    /// <summary>
    /// Where one branch-month of roster has got to — Draft, Pending or Approved. NULL when no row
    /// exists yet, which is the ordinary state of a month nobody has put up for approval.
    /// </summary>
    Task<RosterMonthStatus?> GetRosterMonthAsync(int branchId, DateTime monthDate);

    /// <summary>Employee-days with punches but no record because the approved roster has no row for them (SQL 83).</summary>
    Task<IEnumerable<WorkedWithoutRoster>> GetWorkedWithoutRosterAsync(DateTime fromDate, DateTime toDate, int? branchId, int? callerUserId = null);

    /// <summary>
    /// The same days, each with its state (open / dismissed) and whether THIS caller may decide it (script 108).
    /// </summary>
    Task<IEnumerable<UnrosteredDay>> GetUnrosteredDaysAsync(DateTime fromDate, DateTime toDate, int? branchId, int? employeeId, int? callerUserId);

    /// <summary>
    /// What one such day was: a shift, a rest day that was worked, or not work. The first two add the
    /// roster row and derive the day at once. A refusal is a <see cref="Workflow.WorkflowException"/>
    /// carrying the procedure's own sentence.
    /// </summary>
    Task<UnrosteredDayDecisionResult> DecideUnrosteredDayAsync(UnrosteredDayDecisionRequest request, int? callerUserId);

    /// <summary>Takes a dismissal back: the day is open again.</summary>
    Task ReopenUnrosteredDayAsync(UnrosteredDayReopenRequest request, int? callerUserId);

    /// <summary>D9: the unknown device users, one line per (device, PIN).</summary>
    Task<IEnumerable<QuarantinedDeviceUser>> GetDeviceQuarantineAsync(int? branchId);

    /// <summary>D9: enrol the PIN to the employee, hand over the quarantined punches and REPLAY them into their days.</summary>
    Task<QuarantineMapResult> MapQuarantinedDeviceUserAsync(QuarantineMapRequest request, int actedByUserId);

    /// <summary>QA3: set aside the waiting punches of a PIN that belongs to nobody, with the reason.</summary>
    Task<QuarantineDismissResult> DismissQuarantinedDeviceUserAsync(QuarantineDismissRequest request, int actedByUserId);
}
