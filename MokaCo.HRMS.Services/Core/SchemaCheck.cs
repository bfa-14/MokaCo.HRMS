using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Services.Core;

/// <summary>What /health says about the database's scripts: "ok", "behind" (one is missing) or "unknown" (the check failed).</summary>
public sealed record SchemaReading(string Status, IReadOnlyList<string> MissingScripts, DateTimeOffset ReadAt)
{
    public const string Ok = "ok", Behind = "behind", Unknown = "unknown";
    public bool IsOk => Status == Ok;
}

/// <summary>
/// QA3 DEPLOY GUARD. The deploy runs the code and the SQL as separate manual steps, so an API can start
/// on a database that lacks a script it calls; most of its calls then fail one by one, far from the
/// cause. This looks for every script of <see cref="Scripts.Required"/> once at startup and names the
/// missing ones in ONE critical log line ("DATABASE SCRIPTS NOT APPLIED"), which the deploy scripts read.
///
/// Until all are there it looks again at most every <see cref="RecheckAfter"/> (only when asked, by
/// /health), so applying a script needs no restart. Once all are there it stops looking: a script is
/// never taken back out of a database.
///
/// A singleton; the repository is scoped, so each check makes a scope of its own.
/// </summary>
public sealed class SchemaCheck
{
    public static readonly TimeSpan RecheckAfter = TimeSpan.FromSeconds(30);

    private readonly IServiceScopeFactory _scopes;
    private readonly ILogger<SchemaCheck> _logger;
    private readonly TimeProvider _time;
    private readonly IReadOnlyList<ScriptMarker> _required;
    private readonly SemaphoreSlim _check = new(1, 1);
    private volatile SchemaReading? _reading;
    private string? _lastLogged;

    public SchemaCheck(IServiceScopeFactory scopes, ILogger<SchemaCheck> logger, TimeProvider time)
        : this(scopes, logger, time, Scripts.Required) { }

    /// <summary>For tests: a list of its own instead of <see cref="Scripts.Required"/>.</summary>
    public SchemaCheck(IServiceScopeFactory scopes, ILogger<SchemaCheck> logger, TimeProvider time, IReadOnlyList<ScriptMarker> required)
    {
        _scopes = scopes;
        _logger = logger;
        _time = time;
        _required = required;
    }

    /// <summary>The last reading, or a new one when there is none yet or it was not "ok" and is older than <see cref="RecheckAfter"/>. Never throws.</summary>
    public async Task<SchemaReading> CurrentAsync(CancellationToken cancellationToken = default)
    {
        var reading = _reading;
        if (IsCurrent(reading))
            return reading!;

        await _check.WaitAsync(cancellationToken);
        try
        {
            // Again under the lock: the caller ahead has usually just checked.
            reading = _reading;
            if (IsCurrent(reading))
                return reading!;

            reading = await ReadAsync();
            _reading = reading;
            Log(reading);
            return reading;
        }
        finally
        {
            _check.Release();
        }
    }

    private bool IsCurrent(SchemaReading? reading)
        => reading is not null && (reading.IsOk || _time.GetUtcNow() - reading.ReadAt < RecheckAfter);

    private async Task<SchemaReading> ReadAsync()
    {
        try
        {
            using var scope = _scopes.CreateScope();
            var missing = await scope.ServiceProvider.GetRequiredService<ISchemaRepository>().MissingAsync(_required);
            return new SchemaReading(missing.Count == 0 ? SchemaReading.Ok : SchemaReading.Behind,
                missing.Select(m => m.Script).ToList(), _time.GetUtcNow());
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Could not check which database scripts are applied; /health says \"schema\":\"unknown\" and asks again in {Seconds} s.",
                RecheckAfter.TotalSeconds);
            return new SchemaReading(SchemaReading.Unknown, [], _time.GetUtcNow());
        }
    }

    /// <summary>One line per change of state: not every 30 seconds while the same scripts are missing.</summary>
    private void Log(SchemaReading reading)
    {
        if (reading.Status == SchemaReading.Unknown)
            return;
        var key = string.Join(",", reading.MissingScripts);
        if (key == _lastLogged)
            return;
        _lastLogged = key;

        if (reading.IsOk)
            _logger.LogInformation("Database scripts: all {Count} scripts this API needs are applied (last: {Last}).",
                _required.Count, _required.Count > 0 ? _required[^1].Script : "none");
        else
            _logger.LogCritical(
                "DATABASE SCRIPTS NOT APPLIED: {Scripts}. This API calls them: apply each, in number order, with sqlcmd -I -b "
                + "(the test database: deploy/test-env/apply-sql-test.sh). Until then the features they carry fail and /health "
                + "says \"schema\":\"behind\". No restart is needed afterwards.",
                string.Join(", ", reading.MissingScripts));
    }
}
