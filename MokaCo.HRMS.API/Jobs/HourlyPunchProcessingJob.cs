using MokaCo.HRMS.Api.Hubs;
using MokaCo.HRMS.Services.Attendance;
using MokaCo.HRMS.Services.Booking;
using Quartz;

namespace MokaCo.HRMS.Api.Jobs;

/// <summary>
/// Every hour (at half past, see Program.cs): turns the punches that have arrived into attendance days, so the
/// Worked time report, Daily attendance and the Today board are never more than an hour behind - with or without a
/// roster.
///
/// It is step 1 of the nightly run and nothing else: the processor takes EVERY unprocessed punch (not one day), and
/// it runs one at a time under an application lock, so this, the nightly job, a machine pull and the manual
/// Process button can never build the same day twice. Absentees, leave days, exit permissions and overtime stay
/// nightly: they are about a day that has ended. A day still running is built as it goes (an In with no Out yet reads
/// as a missing punch until the Out arrives; the pages show today's open day as a shift in progress).
///
/// The scheduler is in-memory: a run missed while the API was down is skipped, which is harmless - the next run takes
/// everything still unprocessed.
/// </summary>
[DisallowConcurrentExecution]
public class HourlyPunchProcessingJob : IJob
{
    private readonly IAttendanceService _attendance;
    private readonly ILiveNotifier _live;
    private readonly ILogger<HourlyPunchProcessingJob> _logger;

    public HourlyPunchProcessingJob(IAttendanceService attendance, ILiveNotifier live, ILogger<HourlyPunchProcessingJob> logger)
    {
        _attendance = attendance;
        _live = live;
        _logger = logger;
    }

    public async Task Execute(IJobExecutionContext context)
    {
        try
        {
            var processed = await _attendance.ProcessAsync(null);
            // Silent on the ordinary outcome: 24 runs a day, most with a handful of punches or none.
            if (processed.EmployeeDaysProcessed == 0) return;

            await _live.NotifyAsync("attendance", "dashboard");
            _logger.LogInformation("Hourly punch processing (Beirut {Now:HH:mm}): {Days} employee-day(s) built from new punches, {Late} of them again.",
                BeirutTime.Now, processed.EmployeeDaysProcessed, processed.LateDaysReprocessed);
        }
        catch (Exception ex)
        {
            // Never fatal: the next hour (or the nightly run) takes the same punches again.
            _logger.LogError(ex, "Hourly punch processing failed; the punches stay unprocessed and the next run takes them.");
        }
    }
}
