using System.Threading.RateLimiting;

namespace MokaCo.HRMS.Api.Auth;

/// <summary>
/// THE PER-ACCOUNT HALF OF THE SIGN-IN LIMIT (QA3 SEC-6): at most <see cref="PerUserPerMinute"/>
/// attempts a minute for one username from one address. The per-address half (every username
/// together) is the "auth-login" policy in Program.cs; this one needs the username, which is in the
/// JSON body, and a rate-limiter partition is chosen before the body is read — so the controller
/// asks this after binding.
///
/// GENEROUS ON PURPOSE: a whole café signs in from one NAT address, so the address alone must not
/// lock everybody out; ten tries a minute for ONE name is far beyond a person mistyping and far below
/// a guessing script. The account lockout (5 failures, 15 minutes, in the database) still applies.
///
/// A singleton: the counts must outlive a request.
/// </summary>
public sealed class LoginThrottle : IDisposable
{
    public const int PerUserPerMinute = 10;

    /// <summary>A username longer than this is cut for the key: the count is per real name, and an
    /// attacker's megabyte of name must not become a megabyte of memory.</summary>
    private const int MaxNameInKey = 128;

    private readonly PartitionedRateLimiter<string> _limiter = PartitionedRateLimiter.Create<string, string>(key =>
        RateLimitPartition.GetFixedWindowLimiter(key, _ => new FixedWindowRateLimiterOptions
        {
            PermitLimit = PerUserPerMinute,
            Window = TimeSpan.FromMinutes(1),
            QueueLimit = 0,
        }));

    /// <summary>Counts one attempt; false when this address has used up this name's minute.</summary>
    public bool TryAcquire(string? ip, string? username)
    {
        var name = (username ?? string.Empty).Trim().ToUpperInvariant();     // usernames compare case-insensitively in SQL
        if (name.Length > MaxNameInKey)
            name = name[..MaxNameInKey];

        using var lease = _limiter.AttemptAcquire($"{ip ?? "unknown"}|{name}");
        return lease.IsAcquired;
    }

    public void Dispose() => _limiter.Dispose();
}
