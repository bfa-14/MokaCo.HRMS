using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using MokaCo.HRMS.Model.Security;
using MokaCo.HRMS.Repository.Security;

namespace MokaCo.HRMS.Services.Security.Gate;

/// <summary>
/// What every gate check is judged against, as one immutable reading — the switch, the client ID, the
/// days, the epoch and everyone allowed right now — so a check never mixes the epoch of one refresh with
/// the allowed list of the next.
/// </summary>
/// <param name="Allowed">
/// ("e", EmployeeId) and ("x", GateExtraEmailId) of everyone usp_Gate_GetState says may pass now, each
/// with their normalised email as stored now.
/// </param>
public sealed record GateSnapshot(
    bool Required, string ClientId, int Days, int Epoch, IReadOnlyDictionary<(string Kind, int PersonId), string?> Allowed)
{
    /// <summary>
    /// The answer until a read succeeds: ON, and nobody allowed. A gate whose settings nobody has managed
    /// to load must not open the HRMS — the exempt paths (/health, the gate page) still pass.
    /// </summary>
    public static readonly GateSnapshot Closed = new(
        Required: true, ClientId: string.Empty, Days: 30, Epoch: 0, Allowed: new Dictionary<(string, int), string?>());

    /// <summary>
    /// The person is allowed now WITH this address. Both sides are the procedures' own text for the
    /// same stored address, so they are compared exactly: a corrected Gmail or an edited extra address
    /// ends the old address's cookies, a re-spelling of the same Google account (dots, case) does not.
    /// </summary>
    public bool Allows(string kind, int personId, string? emailNorm)
        => Allowed.TryGetValue((kind, personId), out var stored)
           && string.Equals(stored ?? string.Empty, emailNorm ?? string.Empty, StringComparison.Ordinal);

    /// <summary>
    /// A cookie whose signature, times and epoch are already good (GateCookie.TryRead) passes only if it
    /// was made under the client ID in force now, for a person allowed now with the same address.
    /// </summary>
    public bool Admits(GateCookiePayload cookie)
        => string.Equals(cookie.ClientId, ClientId, StringComparison.Ordinal)
           && Allows(cookie.Kind, cookie.PersonId, cookie.EmailNorm);

    public static GateSnapshot From(GateStateData data)
    {
        var allowed = new Dictionary<(string, int), string?>();
        foreach (var row in data.Allowed)
            allowed.TryAdd(((row.Kind ?? string.Empty).Trim().ToLowerInvariant(), row.PersonId), row.EmailNorm);

        return new GateSnapshot(
            Required: data.State.Required,
            ClientId: (data.State.ClientId ?? string.Empty).Trim(),
            // The procedure clamps already; a reading of 0 would otherwise refuse every cookie.
            Days: Math.Clamp(data.State.Days, 1, 365),
            Epoch: data.State.Epoch,
            Allowed: allowed);
    }
}

/// <summary>The gate's settings and allowed list, cached. An interface so the service and the controller can be tested without a database.</summary>
public interface IGateState
{
    /// <summary>The cached reading (at most <see cref="GateState.CacheFor"/> old). Never throws for a database problem.</summary>
    Task<GateSnapshot> CurrentAsync(CancellationToken cancellationToken = default);

    /// <summary>
    /// A reading made now, bypassing the cache — for the decisions that must not rest on a 20-second-old
    /// answer (the turn-on guard). A failed read THROWS: no decision is better than one on an old reading.
    /// </summary>
    Task<GateSnapshot> GetFreshAsync(CancellationToken cancellationToken = default);

    /// <summary>Drops the cached reading. Called after every admin write, so the change takes effect on the next request.</summary>
    void Invalidate();
}

/// <summary>
/// Reads security.usp_Gate_GetState at most once every 20 seconds and shares the reading with every
/// gate check — which runs for every request nginx serves (each page, script and API call), so it must
/// not reach the database each time. Pattern of PublicBookingGate.
///
/// TWENTY SECONDS is how long a block or a "sign everyone out" made elsewhere (a SQL script, the other
/// API process) can take; a change made through api/access is immediate, because that path calls
/// <see cref="Invalidate"/>.
///
/// A FAILED READ KEEPS THE LAST GOOD READING and logs a warning; before the first good read that is
/// <see cref="GateSnapshot.Closed"/>. It is retried after <see cref="RetryAfterFailure"/>, not on the next
/// request: every request waits for the refresh, and a database that times out must not make each of
/// them wait for its own timeout in turn.
/// </summary>
public sealed class GateState : IGateState
{
    public static readonly TimeSpan CacheFor = TimeSpan.FromSeconds(20);
    public static readonly TimeSpan RetryAfterFailure = TimeSpan.FromSeconds(5);

    private readonly IServiceScopeFactory _scopes;
    private readonly ILogger<GateState> _logger;
    private readonly TimeProvider _time;

    /// <summary>One refresh at a time — a cold start under load must not send every request to the database for the same rows.</summary>
    private readonly SemaphoreSlim _refresh = new(1, 1);

    /// <summary>The snapshot, when it counts as read, and the generation it belongs to — swapped as one object.</summary>
    private sealed record Reading(GateSnapshot Snapshot, DateTimeOffset ReadAt, long Generation);

    private volatile Reading _reading = new(GateSnapshot.Closed, DateTimeOffset.MinValue, Generation: -1);

    /// <summary>Moved on by every Invalidate: a reading from an older generation is stale, even one still being read when the write landed.</summary>
    private long _generation;

    public GateState(IServiceScopeFactory scopes, ILogger<GateState> logger, TimeProvider time)
    {
        _scopes = scopes;
        _logger = logger;
        _time = time;
    }

    public async Task<GateSnapshot> CurrentAsync(CancellationToken cancellationToken = default)
    {
        var reading = _reading;
        if (IsFresh(reading))
            return reading.Snapshot;

        await _refresh.WaitAsync(cancellationToken);
        try
        {
            // Checked again under the lock: the caller ahead has usually just refreshed.
            reading = _reading;
            if (IsFresh(reading))
                return reading.Snapshot;

            var generation = Interlocked.Read(ref _generation);
            try
            {
                return await ReadAsync(generation);
            }
            catch (Exception ex)
            {
                _logger.LogWarning(ex, "Could not read the Google sign-in settings; keeping the previous values.");

                // Counted as read RetryAfterFailure from now, so the requests queued behind this one get
                // the last good answer at once instead of each trying the database again.
                _reading = reading with { ReadAt = _time.GetUtcNow() - CacheFor + RetryAfterFailure, Generation = generation };
                return reading.Snapshot;
            }
        }
        finally
        {
            _refresh.Release();
        }
    }

    public async Task<GateSnapshot> GetFreshAsync(CancellationToken cancellationToken = default)
    {
        await _refresh.WaitAsync(cancellationToken);
        try
        {
            return await ReadAsync(Interlocked.Read(ref _generation));
        }
        finally
        {
            _refresh.Release();
        }
    }

    public void Invalidate() => Interlocked.Increment(ref _generation);

    private async Task<GateSnapshot> ReadAsync(long generation)
    {
        // A SCOPE OF ITS OWN: this is a singleton and the repository is scoped.
        using var scope = _scopes.CreateScope();
        var repository = scope.ServiceProvider.GetRequiredService<IGateRepository>();

        var snapshot = GateSnapshot.From(await repository.GetStateAsync());
        _reading = new Reading(snapshot, _time.GetUtcNow(), generation);
        return snapshot;
    }

    private bool IsFresh(Reading reading)
        => reading.Generation == Interlocked.Read(ref _generation) && _time.GetUtcNow() - reading.ReadAt < CacheFor;
}
