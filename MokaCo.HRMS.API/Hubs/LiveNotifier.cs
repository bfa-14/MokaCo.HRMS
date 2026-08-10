using Microsoft.AspNetCore.SignalR;

namespace MokaCo.HRMS.Api.Hubs;

/// <summary>
/// Tells subscribers that an area changed. Controllers call this AFTER a mutation succeeds.
/// </summary>
public interface ILiveNotifier
{
    /// <summary>
    /// Signals one or more topics. Never throws, never blocks the caller's response on the socket.
    /// </summary>
    Task NotifyAsync(params string[] topics);
}

/// <summary>
/// The signal side of live updates.
///
/// THIS MUST NEVER BREAK A REQUEST. A payroll run that was approved has been approved; if the
/// broadcast then fails, the correct outcome is a client that refreshes a few seconds later by
/// hand, not a 500 on an operation that already committed. So every failure is caught and logged,
/// and the method is safe to await without a try/catch at each of its ~30 call sites.
///
/// It is called after the mutation rather than inside the repository on purpose. A repository does
/// not know whether its transaction is part of a larger one that may still roll back — signalling
/// from there would announce changes that never happened. The controller knows the request
/// succeeded, which is exactly when "something changed" becomes true.
/// </summary>
public class LiveNotifier : ILiveNotifier
{
    private readonly IHubContext<LiveHub> _hub;
    private readonly ILogger<LiveNotifier> _log;

    public LiveNotifier(IHubContext<LiveHub> hub, ILogger<LiveNotifier> log)
    {
        _hub = hub;
        _log = log;
    }

    public async Task NotifyAsync(params string[] topics)
    {
        if (topics is null || topics.Length == 0)
            return;

        foreach (var topic in topics)
        {
            if (string.IsNullOrWhiteSpace(topic))
                continue;

            var name = LiveHub.Normalise(topic);
            try
            {
                // The topic name is the entire message. A client that receives it refetches through
                // its normal, permission-gated endpoints.
                await _hub.Clients.Group(name).SendAsync("stale", name);
            }
            catch (Exception ex)
            {
                _log.LogWarning(ex, "Live notify failed for topic {Topic}; the mutation itself stands.", name);
            }
        }
    }
}
