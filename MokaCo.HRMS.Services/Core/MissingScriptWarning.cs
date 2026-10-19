using System.Collections.Concurrent;
using Microsoft.Extensions.Logging;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Services.Core;

/// <summary>
/// ONE CLEAR WARNING WHEN THE API RUNS AHEAD OF ITS SQL. The deploy applies the code and the SQL as
/// separate manual steps, so an API can start on a database that lacks a script it calls. The calls
/// that can carry on the way they did before the script (they throw <see cref="MissingScriptException"/>)
/// do, and say so here: the first time per script, a warning that names the file to apply; after that
/// debug lines only, so a sign-in does not add a warning each time.
///
/// Nothing about the database is remembered: every call tries the script's procedure first, so once
/// the script is applied the very next call uses it, without a restart.
///
/// A singleton (one warning per process). Optional in the services that use it, so a test that does
/// not look at the log can leave it out.
/// </summary>
public sealed class MissingScriptWarning
{
    private readonly ILogger<MissingScriptWarning> _logger;
    private readonly ConcurrentDictionary<string, bool> _warned = new(StringComparer.OrdinalIgnoreCase);

    public MissingScriptWarning(ILogger<MissingScriptWarning> logger) => _logger = logger;

    /// <summary>
    /// <paramref name="missing"/>'s script is not applied, and the caller did <paramref name="fallback"/>
    /// (what it did instead, in a few words) rather than fail.
    /// </summary>
    public void FellBack(MissingScriptException missing, string fallback)
    {
        if (_warned.TryAdd(missing.Script, true))
            _logger.LogWarning(
                "DATABASE SCRIPT NOT APPLIED: {Script} ({Procedure} is missing, SQL error {SqlError}). Apply it to this "
                + "database; no restart is needed. Until then the API runs without that script's fixes and keeps the "
                + "behaviour from before it (here: {Fallback}; the other fallbacks are listed in the script's header). "
                + "Logged once per process.",
                missing.Script, missing.Procedure, missing.SqlErrorNumber, fallback);
        else
            _logger.LogDebug("{Script} not applied: {Procedure} missing, {Fallback}.", missing.Script, missing.Procedure, fallback);
    }
}
