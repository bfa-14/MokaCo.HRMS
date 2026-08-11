using MokaCo.HRMS.Services.Attendance;
using MokaCo.HRMS.Services.Workflow;
using Quartz;

namespace MokaCo.HRMS.Api.Jobs;

/// <summary>
/// Runs at 01:00 local (see the cron trigger in Program.cs) and brings attendance up to date for
/// the day that has just ended.
///
/// THE ORDER MATTERS, and it is not arbitrary:
///   1. Process raw punches — build the day records for everyone who actually punched.
///   2. Mark absentees — the processor only sees days that HAVE punches, so somebody who never
///      turned up has no record at all until this runs. Without it, payroll never learns they were
///      missing. It must therefore run AFTER step 1, or it would write 'Absent' over people whose
///      punches simply had not been processed yet.
///   3. Mark leave days — reclassify absences that are covered by approved leave, so they are not
///      deducted as though nobody knew about them.
///
/// The scheduler is IN-MEMORY: if the API was down at 01:00, this run is simply MISSED — there is no
/// job store to catch up from. That is exactly why /api/attendance/process and /mark-absentees exist
/// as manual endpoints, and why every step here is idempotent and safe to re-run by hand.
/// </summary>
[DisallowConcurrentExecution]
public class NightlyAttendanceJob : IJob
{
    private readonly IAttendanceService _attendance;
    private readonly IExitPermissionService _exitPermissions;
    private readonly IOvertimeService _overtime;
    private readonly IRequestService _requests;
    private readonly ILogger<NightlyAttendanceJob> _logger;

    public NightlyAttendanceJob(
        IAttendanceService attendance,
        IExitPermissionService exitPermissions,
        IOvertimeService overtime,
        IRequestService requests,
        ILogger<NightlyAttendanceJob> logger)
    {
        _attendance = attendance;
        _exitPermissions = exitPermissions;
        _overtime = overtime;
        _requests = requests;
        _logger = logger;
    }

    public async Task Execute(IJobExecutionContext context)
    {
        // No date: consume EVERYTHING still unprocessed, not just yesterday. If the API was down for
        // two days, a date-scoped run would silently leave the older punches behind forever.
        var processed = await _attendance.ProcessAsync(null);

        var yesterday = DateTime.Today.AddDays(-1);
        var absentees = await _attendance.MarkAbsenteesAsync(yesterday);

        var period = DateTime.Today.ToString("yyyy-MM");
        var leave = await _attendance.MarkLeaveDaysAsync(period);

        // Immediately after the processor: push every approved exit permission whose attendance day
        // now exists into that day. A permission approved before the day happened has been waiting
        // for exactly this moment. No arguments = sweep them all; idempotent, so a double run is safe.
        var applied = await _exitPermissions.ApplyToAttendanceAsync(null, null);

        // And overtime, in the SAME place and for the same reason: an approved request is linked to
        // its day only once that day exists. Until this runs the payload has nothing to compare the
        // approved minutes against, which is why the panel reads "awaiting the worked day".
        var overtimeStamped = await _overtime.ApplyToAttendanceAsync(null);

        // LAST, and the only step here that is not about attendance: a safety net for approvals whose
        // EFFECT never happened. An approved salary advance with no payroll row, a leave request that
        // never reached the ledger, a swap whose roster change was skipped — the request reads as done
        // while the money or the leave silently does not exist, and nothing else would ever notice.
        // Idempotent, so the ordinary result is an empty sweep and one quiet log line.
        var reconciled = await _requests.ReconcileApprovalEffectsAsync();

        _logger.LogInformation(
            "Nightly attendance: processed {Days} employee-day(s), marked {Absentees} absentee(s) for {Yesterday:yyyy-MM-dd}, reclassified {Leave} day(s) as approved leave in {Period}, applied {Applied} exit permission(s) and stamped {Overtime} overtime request(s) to attendance.",
            processed.EmployeeDaysProcessed, absentees.AbsenteesMarked, yesterday, leave.DaysMarkedAsLeave, period, applied.PermissionsApplied, overtimeStamped.Stamped);

        if (reconciled.Repaired.Count > 0)
        {
            _logger.LogWarning(
                "Approval-effect reconciler: applied the missing effects of {Count} approved request(s): {RequestIds}. These closed without them, which should not happen — check how they were approved.",
                reconciled.Repaired.Count, string.Join(", ", reconciled.Repaired));
        }

        // NOT lumped in with the repaired count. These were asked and still did not land, so they are
        // the ones a person has to look at — most likely a swap whose rostered day no longer exists.
        if (reconciled.StillUnapplied.Count > 0)
        {
            _logger.LogError(
                "Approval-effect reconciler: {Count} approved request(s) STILL have no effect after a repair attempt and need looking at by hand: {RequestIds}.",
                reconciled.StillUnapplied.Count, string.Join(", ", reconciled.StillUnapplied));
        }
    }
}
