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
    /// The (enabled, interval) pair the log last reported, so the configuration is announced when it
    /// CHANGES rather than restated every cycle.
    ///
    /// Null until the first read, which is what makes the first cycle always announce itself. The
    /// alternative — a line per cycle — is 1,440 identical lines a day at the one-minute interval this
    /// deployment uses, and a log nobody can read is the same as no log, which is the problem being
    /// fixed here in the first place.
    /// </summary>
    private (bool Enabled, int Minutes)? _lastLoggedConfig;

    public MachinePullWorker(IServiceScopeFactory scopes, ILogger<MachinePullWorker> logger)
    {
        _scopes = scopes;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        // THE FIRST LINE IN THE LOG, and it exists because its absence was the whole problem. This
        // worker was silent in every state where it decides NOT to pull, so a worker running
        // perfectly and a worker that had never been constructed produced identical evidence: none.
        // Logged BEFORE the startup delay and before any database call, so it appears even when the
        // settings are unreadable — "it is alive" and "it is configured" are separate facts and this
        // is the first of them.
        _logger.LogInformation(
            "Machine pull worker started. First cycle in {DelaySeconds}s. MachinePullEnabled and " +
            "MachinePullMinutes are re-read before EVERY cycle, so changing them on the Settings page " +
            "takes effect without restarting the API.",
            (int)StartupDelay.TotalSeconds);

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

            // Says, in the log, what this cycle is about to do and why — including the case where the
            // answer is "nothing", which is the one that used to leave no trace at all.
            LogConfigurationChange(enabled, minutes);

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
                    _logger.LogError(ex,
                        "Machine pull cycle failed outright. The worker CONTINUES and will try again " +
                        "in {Minutes} minute(s).",
                        minutes);
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
    /// Announces the switch and the interval whenever either changes — and on the first cycle.
    ///
    /// THE OFF CASE IS A WARNING, deliberately. "It never pulls" is almost always this setting, and
    /// it is the one state where the worker does its job perfectly by doing nothing at all. A line
    /// at Information would sit unread among the request logs; at Warning it is what somebody finds
    /// when they go looking for why attendance stopped moving.
    /// </summary>
    private void LogConfigurationChange(bool enabled, int minutes)
    {
        if (_lastLoggedConfig is { } last && last.Enabled == enabled && last.Minutes == minutes)
            return;

        _lastLoggedConfig = (enabled, minutes);

        if (enabled)
        {
            _logger.LogInformation(
                "Machine pull is ON, interval {Minutes} minute(s).", minutes);
        }
        else
        {
            _logger.LogWarning(
                "Machine pull is OFF (setting MachinePullEnabled), so no machine will be read. The " +
                "setting is re-read every {Minutes} minute(s); this line is logged again the moment " +
                "it changes.",
                minutes);
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

        // RE-READ EVERY CYCLE, like the settings and for the same reason: a machine plugged in, or
        // switched on for pulling, this afternoon must be read this afternoon. Nothing here is cached
        // across cycles, and the fresh scope above is what keeps the connection short-lived too.
        var targets = (await pull.GetTargetsAsync()).ToList();

        if (targets.Count == 0)
        {
            // The other silence that looked exactly like a dead worker. The three criteria are spelled
            // out because they are precisely the three boxes to go and look at on the Devices page.
            _logger.LogWarning(
                "Machine pull found NO machines to read. A machine is on the worklist only when it is " +
                "active, has pulling switched on, and has an IP address recorded.");
            return;
        }

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

            // WHICH TERMINAL PRODUCED WHAT — the one thing the cycle summary below cannot tell you.
            // Logged even when it pulled nothing, because "reached it and it was empty" and "never
            // reached it" are different answers, and only one of them needs somebody to go and look.
            _logger.LogInformation(
                "Machine pull — {Machine} ({Ip}): pulled {Inserted} new punch(es) of {Received} read " +
                "({Duplicates} already known, {Unresolved} on unmapped PIN(s)).",
                target.Label, target.PullIp, result.Inserted, result.Received,
                result.Duplicates, result.UnresolvedPins);
        }

        _logger.LogInformation(
            "Machine pull cycle: {Tried} machine(s) tried, {Landed} new punch(es) landed, {Duplicates} already known, {Unresolved} on unmapped PIN(s), {Failed} machine(s) failed.",
            targets.Count, landed, duplicates, unresolved, failed);

        if (landed > 0)
        {
            // Same signal the push path raises: new raw punches change the unresolved queue and the
            // device heartbeats, both of which are on screens somebody may be watching.
            await live.NotifyAsync("attendance");

            if (autoProcess)
                await AutoProcessAsync(scope.ServiceProvider, landed, ct);
            else
                _logger.LogInformation(
                    "Machine pull: {Landed} new punch(es) stored; MachinePullAutoProcess is OFF, so the nightly job will process them.",
                    landed);
        }
    }

    /// <summary>
    /// MachinePullAutoProcess (BUG-27): after a pull that stored new punches, the affected employee-days
    /// are processed straight away instead of waiting for the nightly job.
    ///
    /// SAFE TO RUN MID-DAY. attendance.usp_Attendance_ProcessRawLogs finds the employee-days that have
    /// anything new (by their ATTRIBUTED date, so an overnight out-punch lands on the shift's day) and
    /// re-derives each one from ALL of its punches — processed and new alike — through the single day
    /// rule (usp_Attendance_ComputeDay, script 76). A pull at 13:00 gives the morning; a pull at 17:00
    /// rebuilds the whole day with the afternoon added. The old warning that said otherwise described
    /// a processor that no longer exists.
    ///
    /// A failure here is logged and does not fail the cycle: the punches are stored, and the nightly
    /// job processes whatever is still unprocessed.
    /// </summary>
    private async Task AutoProcessAsync(IServiceProvider services, int landed, CancellationToken ct)
    {
        try
        {
            var attendance = services.GetRequiredService<IAttendanceService>();
            var result = await attendance.ProcessAsync(null);

            _logger.LogInformation(
                "Machine pull auto-process: {Landed} new punch(es) landed, {Days} employee-day(s) processed into attendance (each rebuilt from all of its punches, by attributed date).",
                landed, result.EmployeeDaysProcessed);

            if (result.EmployeeDaysProcessed > 0)
                await services.GetRequiredService<ILiveNotifier>().NotifyAsync("attendance");
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex,
                "Machine pull auto-process failed after landing {Landed} punch(es); they are stored and the nightly job will process them.",
                landed);
        }
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
