using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.SignalR;

namespace MokaCo.HRMS.Api.Hubs;

/// <summary>
/// The live-update hub. It carries SIGNALS, never data.
///
/// A client subscribes to topic names and receives "stale" with the topic when something in that
/// area changed. It then refetches through its ORDINARY endpoints. That is the whole protocol, and
/// the restraint is the point:
///
///   • AUTHORISATION STAYS ON THE REST ENDPOINTS. If payload travelled over the socket, every
///     broadcast would need to re-answer "may THIS connection see this?" for a mixed audience —
///     a second permission system, guaranteed to drift from the first. A topic name tells a
///     subscriber only that an area moved, which is not a secret; what they may then READ is
///     decided by the same [HasPermission] gates as always. A barista learning that "payroll"
///     changed learns nothing, and their refetch still 403s.
///   • NO STATE TO GET STALE. The socket cannot deliver a half-applied view, because it delivers
///     no view. The refetch is the single source of truth, exactly as it is without live updates.
///
/// Topics are area names — "workflow", "payroll", "attendance", "dashboard". They are deliberately
/// coarse: a per-entity topic would multiply groups by every row on screen and still tell a
/// subscriber only what a refetch tells it.
/// </summary>
[Authorize]
public class LiveHub : Hub
{
    /// <summary>
    /// The topics a connection may join.
    ///
    /// A closed set, so a client cannot mint arbitrary group names — an unbounded group table is a
    /// slow memory leak driven by whatever the browser sends. Unknown topics are ignored rather
    /// than faulted: a newer client asking for a topic this server does not have yet should degrade
    /// to "no live updates for that area", not lose its whole connection.
    /// </summary>
    private static readonly HashSet<string> KnownTopics =
        new(StringComparer.OrdinalIgnoreCase)
        { "workflow", "payroll", "attendance", "dashboard", "hr" };

    private readonly ILogger<LiveHub> _log;
    public LiveHub(ILogger<LiveHub> log) => _log = log;

    /// <summary>Joins the caller's connection to a topic group. Idempotent.</summary>
    public async Task Subscribe(string topic)
    {
        if (string.IsNullOrWhiteSpace(topic) || !KnownTopics.Contains(topic))
            return;

        await Groups.AddToGroupAsync(Context.ConnectionId, Normalise(topic));
    }

    /// <summary>
    /// Leaves a topic group. Called when a page unmounts or its feature toggle is switched off.
    ///
    /// Not strictly required — SignalR drops a connection's groups when it disconnects — but a
    /// single-page app keeps ONE connection across every navigation, so without this a user who
    /// visited payroll once would keep waking up for payroll for the rest of the session.
    /// </summary>
    public async Task Unsubscribe(string topic)
    {
        if (string.IsNullOrWhiteSpace(topic))
            return;

        await Groups.RemoveFromGroupAsync(Context.ConnectionId, Normalise(topic));
    }

    public override Task OnConnectedAsync()
    {
        _log.LogDebug("Live hub connected: {ConnectionId} ({User})", Context.ConnectionId, Context.UserIdentifier);
        return base.OnConnectedAsync();
    }

    /// <summary>
    /// Group names are matched by ORDINAL comparison inside SignalR, so the casing a client happens
    /// to send would otherwise create a second, silent group that no broadcast ever reaches.
    /// </summary>
    internal static string Normalise(string topic) => topic.Trim().ToLowerInvariant();
}
