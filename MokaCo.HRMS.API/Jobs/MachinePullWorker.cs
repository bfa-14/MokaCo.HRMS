using MokaCo.HRMS.Services.Attendance;
using MokaCo.HRMS.Services.Core;

namespace MokaCo.HRMS.Api.Jobs;

/// <summary>
/// Polls every attendance machine that has pulling switched on, and lands what it finds.
///
/// This is the counterpart to the iclock/ADMS endpoint. There the terminal calls US; here we call the
/// terminal. Either is enough on its own, both together are safe (the dedup hash is what makes that
/// true), and for firmware with no ADMS menu this is the only way punches ever arrive.
///
/// A BackgroundService rather than a Quartz job, deliberately. The two Quartz jobs in this folder run
/// on a CRON — "01:00, whatever else is happening" — and are about a calendar. This is a HEARTBEAT
/// whose period is a setting a user changes on the Settings page and expects to take effect without
/// anyone restarting the API, which is a plain timing loop, not a schedule.
///
/// FAILURE POLICY: one unreachable machine must never stop the others. Every device is attempted
/// inside MachinePullService, which records its own outcome against the device and returns rather
/// than throws; this loop's own try/catch is the backstop for the unexpected, because a
/// BackgroundService that throws is a BackgroundService that never runs again.
/// </summary>
public class MachinePullWorker : BackgroundService
{
    /// <summary>Used when the setting is missing or unparseable — the same 5 the SQL seeds.</summary>
    private const int DefaultMinutes = 5;

    /// <summary>
    /// The clamp the prompt specifies. Below a minute we would hammer terminals that are also doing
    /// door duty; above an hour "pull" stops meaning anything a user would recognise as automatic.
    /// </summary>
    private const int MinMinutes = 1;
    private const int MaxMinutes = 60;

    /// <summary>How long to wait before the first cycle, so startup is not competing with a pull.</summary>
    private static readonly TimeSpan StartupDelay = TimeSpan.FromSeconds(20);

    private readonly IServiceScopeFactory _scopes;
    private readonly ILogger<MachinePullWorker> _logger;

    /// <summary>
    /// Latches the one-time warning about the auto-process setting, so a switch somebody left on does
    /// not produce an identical warning every five minutes for the rest of the service's life.
    /// </summary>
    private bool _warnedAboutAutoProcess;

    public MachinePullWorker(IServiceScopeFactory scopes, ILogger<MachinePullWorker> logger)
    {
        _scopes = scopes;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        try
        {
            await Task.Delay(StartupDelay, stoppingToken);
        }
        catch (OperationCanceledException)
        {
            return;
        }

        while (!stoppingToken.IsCancellationRequested)
        {
            // Re-read EVERY cycle rather than caching: the whole point of putting these on the
            // Settings page is that changing them takes effect without a restart.
            var (enabled, minutes, autoProcess) = await ReadSettingsAsync(stoppingToken);

            if (enabled)
            {
                try
                {
                    await RunCycleAsync(autoProcess, stoppingToken);
                }
                catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
                {
                    return;
                }
                catch (Exception ex)
                {
                    // The backstop. Anything that escapes the per-device handling is logged and the
                    // loop continues — a worker that dies here would stop pulling silently, and the
                    // only symptom would be attendance quietly going stale.
                    _logger.LogError(ex, "Machine pull cycle failed outright. The loop continues; the next cycle is in {Minutes} minute(s).", minutes);
                }
            }

            try
            {
                await Task.Delay(TimeSpan.FromMinutes(minutes), stoppingToken);
            }
            catch (OperationCanceledException)
            {
                return;
            }
        }
    }

    /// <summary>
    /// One pass over every configured machine, in the order the worklist gives them.
    ///
    /// SEQUENTIAL on purpose. These are 10Mbit devices on an office LAN whose day job is opening a
    /// door, and four simultaneous 2MB buffer reads is a noticeable way to make the door slow. There
    /// are never enough machines for the wall-clock saving to matter.
    /// </summary>
    private async Task RunCycleAsync(bool autoProcess, CancellationToken ct)
    {
        using var scope = _scopes.CreateScope();

        var pull = scope.ServiceProvider.GetRequiredService<IMachinePullService>();
        var live = scope.ServiceProvider.GetRequiredService<ILiveNotifier>();

        var targets = (await pull.GetTargetsAsync()).ToList();

        if (targets.Count == 0)
            return;

        var landed = 0;
        var duplicates = 0;
        var unresolved = 0;
        var failed = 0;

        foreach (var target in targets)
        {
            if (ct.IsCancellationRequested)
                return;

            var result = await pull.PullAsync(target.DeviceId, ct);

            foreach (var warning in result.Warnings)
                _logger.LogWarning("Machine pull — {Machine}: {Warning}", target.Label, warning);

            if (result.Error is not null)
            {
                failed++;

                // Warning, not Error: an attendance terminal being off overnight, or somebody
                // unplugging it to clean behind it, is ordinary. The device page carries the state,
                // and this is the trail for whoever goes looking.
                _logger.LogWarning("Machine pull — {Machine} ({Ip}) failed: {Error}",
                    target.Label, target.PullIp, result.Error);

                continue;
            }

            landed += result.Inserted;
            duplicates += result.Duplicates;
            unresolved += result.UnresolvedPins;
        }

        _logger.LogInformation(
            "Machine pull cycle: {Tried} machine(s) tried, {Landed} new punch(es) landed, {Duplicates} already known, {Unresolved} on unmapped PIN(s), {Failed} machine(s) failed.",
            targets.Count, landed, duplicates, unresolved, failed);

        if (landed > 0)
        {
            // Same signal the push path raises: new raw punches change the unresolved queue and the
            // device heartbeats, both of which are on screens somebody may be watching.
            await live.NotifyAsync("attendance");

            WarnAboutAutoProcessOnce(autoProcess, landed);
        }
    }

    /// <summary>
    /// THE AUTO-PROCESS SETTING IS DELIBERATELY NOT ACTED ON. This is the one thing P15 asked for that
    /// is not wired, and the reason is in attendance.usp_Attendance_ProcessRawLogs.
    ///
    /// That procedure is idempotent but NOT incremental. It builds each employee-day from the punches
    /// that are still IsProcessed = 0, then OVERWRITES the whole ATTENDANCE_RECORD for that day with
    /// what it computed and DELETES and rewrites the day's ATTENDANCE_INTERVAL rows. Run it at 13:00
    /// and it consumes the morning; run it again at 17:00 and the only unprocessed punches are the
    /// afternoon's, so the day is rewritten as if the person arrived after lunch — first-in moves,
    /// the morning interval is deleted, and worked minutes drop. Nothing flags it, because the result
    /// is a perfectly well-formed shorter day.
    ///
    /// The nightly job avoids this by running once, after the day is over, with everything still
    /// unprocessed. So pull leaves processing to it, as the brief instructed for exactly this case.
    /// Making it safe means teaching the procedure to rebuild a day from ALL of its punches rather
    /// than only the unconsumed ones — a change to the processor, not to this worker.
    /// </summary>
    private void WarnAboutAutoProcessOnce(bool autoProcess, int landed)
    {
        if (!autoProcess || _warnedAboutAutoProcess)
            return;

        _warnedAboutAutoProcess = true;

        _logger.LogWarning(
            "MachinePullAutoProcess is ON, but {Landed} pulled punch(es) were NOT processed into attendance. " +
            "usp_Attendance_ProcessRawLogs rebuilds an employee-day from only the punches still unprocessed and " +
            "overwrites the whole day with the result, so running it mid-day would rewrite this morning out of " +
            "existence. The punches are stored and the nightly job will process them correctly. " +
            "This warning is logged once per service lifetime.",
            landed);
    }

    /// <summary>
    /// Reads the three settings, failing SAFE in every direction: unreadable settings mean "do not
    /// pull this cycle" rather than "pull as fast as possible against an unknown configuration".
    /// </summary>
    private async Task<(bool Enabled, int Minutes, bool AutoProcess)> ReadSettingsAsync(CancellationToken ct)
    {
        try
        {
            using var scope = _scopes.CreateScope();
            var settings = scope.ServiceProvider.GetRequiredService<ISettingService>();

            var enabled = await settings.GetAsync("MachinePullEnabled");
            var minutes = await settings.GetAsync("MachinePullMinutes");
            var autoProcess = await settings.GetAsync("MachinePullAutoProcess");

            return (
                IsTrue(enabled?.SettingValue),
                Clamp(minutes?.SettingValue),
                IsTrue(autoProcess?.SettingValue));
        }
        catch (Exception ex) when (!ct.IsCancellationRequested)
        {
            // Almost always the database being unavailable — during a restart, or a failover. Skipping
            // the cycle and trying again shortly is right; crashing the worker is not.
            _logger.LogWarning(ex, "Could not read the machine-pull settings; skipping this cycle.");
            return (false, DefaultMinutes, false);
        }
    }

    /// <summary>'1' and 'true' both mean on — the SQL seeds '1', and the Settings UI writes 'true'.</summary>
    private static bool IsTrue(string? value)
        => value is not null
           && (value == "1" || string.Equals(value, "true", StringComparison.OrdinalIgnoreCase));

    private static int Clamp(string? value)
        => int.TryParse(value, out var minutes)
            ? Math.Clamp(minutes, MinMinutes, MaxMinutes)
            : DefaultMinutes;
}
