using System.Collections.Concurrent;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using MokaCo.HRMS.Repository.Security;

namespace MokaCo.HRMS.Services.Security;

/// <summary>Whether an access token still opens a session (QA3 SEC-5). An interface so callers can be tested without a database.</summary>
public interface ISessionGuard
{
    /// <summary>Whether a token of <paramref name="userId"/> carrying <paramref name="tokenStamp"/> (null: none) is still good.</summary>
    Task<bool> IsCurrentAsync(int userId, Guid? tokenStamp, CancellationToken cancellationToken = default);

    /// <summary>The account changed here (its sessions were ended): read it again on its next request.</summary>
    void Forget(int userId);
}

/// <summary>
/// THE PER-REQUEST HALF OF ENDING SESSIONS (QA3 SEC-5). A password change or a disable revokes the
/// account's refresh tokens and renews its session stamp (security.usp_User_EndSessions); this refuses
/// every access token issued before that — one that carries another stamp, or none while the account
/// has one — and every token of an account that is disabled or gone. Without it an access token kept
/// working until it expired (15 minutes), whatever happened to the account.
///
/// Called by the JWT handler for each authenticated request, so the account is read at most once
/// every <see cref="CacheFor"/> per user. A change made through this API (UserService) calls
/// <see cref="Forget"/> and takes effect on the next request; one made elsewhere (SQL, another API
/// process) within <see cref="CacheFor"/>.
///
/// A FAILED READ DOES NOT SIGN ANYBODY OUT: the last reading is kept (or, with none, the token is let
/// through) and a warning logged. The request itself needs the database and will fail on its own if it
/// is down; refusing the token here would only turn a blip into everybody being sent to the login page.
/// </summary>
public sealed class SessionGuard : ISessionGuard
{
    public static readonly TimeSpan CacheFor = TimeSpan.FromSeconds(30);
    public static readonly TimeSpan RetryAfterFailure = TimeSpan.FromSeconds(5);

    private readonly IServiceScopeFactory _scopes;
    private readonly ILogger<SessionGuard> _logger;
    private readonly TimeProvider _time;

    /// <summary>What the token is judged against: the account as last read. Unknown = the read failed with nothing to fall back on.</summary>
    private sealed record Reading(bool Exists, bool IsActive, Guid? Stamp, bool Unknown, DateTimeOffset ReadAt, long Generation);

    private readonly ConcurrentDictionary<int, Reading> _readings = new();

    /// <summary>Per user, moved on by every Forget: a reading started before a change is stale even if it lands after it.</summary>
    private readonly ConcurrentDictionary<int, long> _generations = new();

    public SessionGuard(IServiceScopeFactory scopes, ILogger<SessionGuard> logger, TimeProvider time)
    {
        _scopes = scopes;
        _logger = logger;
        _time = time;
    }

    /// <summary>
    /// Whether a token of <paramref name="userId"/> that carries <paramref name="tokenStamp"/> (null: the
    /// token has none) still opens a session.
    /// </summary>
    public async Task<bool> IsCurrentAsync(int userId, Guid? tokenStamp, CancellationToken cancellationToken = default)
    {
        var reading = await ReadingFor(userId, cancellationToken);
        if (reading.Unknown)
            return true;
        return reading.Exists && reading.IsActive && reading.Stamp == tokenStamp;
    }

    /// <summary>The account changed here: read it again on its next request.</summary>
    public void Forget(int userId)
    {
        _generations.AddOrUpdate(userId, 1, (_, g) => g + 1);
        _readings.TryRemove(userId, out _);
    }

    private async Task<Reading> ReadingFor(int userId, CancellationToken cancellationToken)
    {
        var now = _time.GetUtcNow();
        var generation = _generations.GetValueOrDefault(userId);
        if (_readings.TryGetValue(userId, out var cached) && cached.Generation == generation && now - cached.ReadAt < CacheFor)
            return cached;

        Reading reading;
        try
        {
            // A SCOPE OF ITS OWN: this is a singleton and the repository is scoped.
            using var scope = _scopes.CreateScope();
            var user = await scope.ServiceProvider.GetRequiredService<IUserRepository>().GetByIdAsync(userId);
            reading = new Reading(user is not null, user?.IsActive ?? false, user?.SessionStamp, Unknown: false, now, generation);
        }
        catch (Exception ex) when (!cancellationToken.IsCancellationRequested)
        {
            _logger.LogWarning(ex, "Could not read user {UserId} to check their session; keeping the previous answer.", userId);
            // Counted as read RetryAfterFailure from now: the next requests do not each wait on a database that is not answering.
            var retryAt = now - CacheFor + RetryAfterFailure;
            reading = cached is not null
                ? cached with { ReadAt = retryAt, Generation = generation }
                : new Reading(false, false, null, Unknown: true, retryAt, generation);
        }

        _readings[userId] = reading;
        return reading;
    }
}
