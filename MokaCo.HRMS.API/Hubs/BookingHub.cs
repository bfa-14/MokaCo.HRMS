using System.Collections.Concurrent;
using System.Text.RegularExpressions;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.SignalR;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Services.Booking;

namespace MokaCo.HRMS.Api.Hubs;

/// <summary>
/// Live booking updates, for two very different audiences on one hub at /hubs/booking.
///
///   • STAFF — group "staff". A connection that arrives with a valid JWT (?access_token=, the only
///     way a browser WebSocket can carry one) whose user may read bookings (BOOKING_VIEW or
///     BOOKING_MANAGE) is put in the group when it connects and receives BookingChanged for every
///     booking, and CalendarChanged when a block or the catalogue (rooms, hours, add-ons) changes.
///     The permission is checked because the message names the guest: it is the same data
///     GET /api/bookings returns, so it is gated by the same right.
///   • A GUEST — group "booking:{ref}". The website's confirmation page connects WITHOUT a token and
///     calls WatchBooking(ref). The reference is the credential, exactly as it is for
///     GET /api/public/booking/{ref}: it must look like MC-XXXXXXXX and the booking must exist, and
///     the connection then hears BookingStatus for that one booking and nothing else.
///
/// UNLIKE LiveHub THIS ONE CARRIES DATA, and deliberately little of it. The guest's message is five
/// fields the guest already sees on the page; the staff message is one calendar row. Neither audience
/// can ask the hub for anything: there is no method that reads, and the only method that exists joins
/// a group. Everything that is sent is sent by <see cref="BookingLivePublisher"/> after a state change.
///
/// NOT AN ORACLE (QA3 BKG-9). WatchBooking answers "joined" or "not_found", which tells a caller
/// whether a reference exists. A connection may miss <see cref="BookingWatchThrottle.MissesPerConnection"/>
/// times and is then dropped; an address may miss <see cref="BookingWatchThrottle.MissesPerAddress"/>
/// times in <see cref="BookingWatchThrottle.Window"/> across all its connections, and is then refused
/// before any lookup. The website's page watches ONE reference it was just given, so it never misses.
///
/// [AllowAnonymous] because the authorization fallback would otherwise demand a token for negotiate,
/// and the guest has none. Being anonymous earns a connection nothing until WatchBooking succeeds.
/// </summary>
[AllowAnonymous]
public partial class BookingHub : Hub
{
    public const string StaffGroup = "staff";

    /// <summary>Event names, as the two clients subscribe to them.</summary>
    public const string BookingChanged = "BookingChanged";
    public const string BookingStatus = "BookingStatus";

    /// <summary>Staff only: a block or the catalogue changed — no booking to name, the calendar refetches (QA3 BKG-14).</summary>
    public const string CalendarChanged = "CalendarChanged";

    /// <summary>A connection may watch a handful of bookings, not enumerate them.</summary>
    private const int MaxWatchedPerConnection = 5;
    private const string WatchedCountKey = "watched";
    private const string MissedCountKey = "missed";

    private readonly IBookingService _bookings;
    private readonly BookingWatchThrottle _throttle;

    [ActivatorUtilitiesConstructor]
    public BookingHub(IBookingService bookings) : this(bookings, BookingWatchThrottle.Shared) { }

    /// <summary>With its own throttle — the tests' constructor; the application shares one per process.</summary>
    public BookingHub(IBookingService bookings, BookingWatchThrottle throttle)
    {
        _bookings = bookings;
        _throttle = throttle;
    }

    public static string GuestGroup(string bookingRef) => "booking:" + bookingRef.ToUpperInvariant();

    public override async Task OnConnectedAsync()
    {
        var user = Context.User;
        if (user?.Identity?.IsAuthenticated == true
            && (user.HasPermission("BOOKING_VIEW") || user.HasPermission("BOOKING_MANAGE")))
            await Groups.AddToGroupAsync(Context.ConnectionId, StaffGroup);

        await base.OnConnectedAsync();
    }

    /// <summary>
    /// Joins the caller to one booking's group. The name and the argument are the website's
    /// (mokanco-lb/src/scripts/confirmed.ts: connection.invoke('WatchBooking', reference)).
    /// A refusal is a HubException with a code, never the reason in prose: "no such booking" and
    /// "badly formed" are the same answer to somebody guessing references. A caller who has missed
    /// too often is answered "too_many" (and its connection dropped) without the booking being read.
    /// </summary>
    public async Task WatchBooking(string bookingRef)
    {
        var address = CallerAddress();
        var missed = Count(MissedCountKey);
        if (missed >= BookingWatchThrottle.MissesPerConnection || _throttle.IsBlocked(address))
        {
            Context.Abort();
            throw new HubException("too_many");
        }

        var reference = (bookingRef ?? string.Empty).Trim().ToUpperInvariant();
        if (!ReferenceShape().IsMatch(reference))
            throw Missed(missed, address);

        var watched = Count(WatchedCountKey);
        if (watched >= MaxWatchedPerConnection)
            throw new HubException("too_many");

        if (await _bookings.GetPublicRecapAsync(reference) is null)
            throw Missed(missed, address);

        Context.Items[WatchedCountKey] = watched + 1;
        await Groups.AddToGroupAsync(Context.ConnectionId, GuestGroup(reference));
    }

    /// <summary>Counts a miss against the connection and the address; the answer stays "not_found".</summary>
    private HubException Missed(int missedSoFar, string? address)
    {
        Context.Items[MissedCountKey] = missedSoFar + 1;
        _throttle.RecordMiss(address);
        return new HubException("not_found");
    }

    private int Count(string key) => Context.Items.TryGetValue(key, out var n) && n is int count ? count : 0;

    /// <summary>The client's address (X-Forwarded-For is applied by the pipeline behind nginx); null when unknown.</summary>
    private string? CallerAddress()
        => Context.Features is null ? null : Context.GetHttpContext()?.Connection.RemoteIpAddress?.ToString();

    [GeneratedRegex("^MC-[A-Z0-9]{8}$")]
    private static partial Regex ReferenceShape();
}

/// <summary>
/// How many WatchBooking misses (a malformed or unknown reference) an address may make before it is
/// refused for a while — across ALL its connections, because opening a new connection is free (QA3
/// BKG-9). In memory, per process: a restart forgets it, which costs a guesser a minute, not more.
/// </summary>
public sealed class BookingWatchThrottle
{
    /// <summary>Misses one connection may make; the next call drops it.</summary>
    public const int MissesPerConnection = 5;

    /// <summary>Misses one address may make in <see cref="Window"/>, across its connections.</summary>
    public const int MissesPerAddress = 20;

    public static readonly TimeSpan Window = TimeSpan.FromMinutes(10);

    /// <summary>The one the application uses (the hub is created per call; the count must outlive it).</summary>
    public static readonly BookingWatchThrottle Shared = new(TimeProvider.System);

    private readonly TimeProvider _clock;
    private readonly ConcurrentDictionary<string, (DateTimeOffset Since, int Misses)> _misses = new();

    public BookingWatchThrottle(TimeProvider clock) => _clock = clock;

    /// <summary>True while this address has used up its misses in the current window. An unknown address is never blocked.</summary>
    public bool IsBlocked(string? address)
    {
        if (string.IsNullOrEmpty(address) || !_misses.TryGetValue(address, out var entry))
            return false;

        return _clock.GetUtcNow() - entry.Since < Window && entry.Misses >= MissesPerAddress;
    }

    public void RecordMiss(string? address)
    {
        if (string.IsNullOrEmpty(address))
            return;

        var now = _clock.GetUtcNow();
        _misses.AddOrUpdate(address, _ => (now, 1),
            (_, entry) => now - entry.Since >= Window ? (now, 1) : (entry.Since, entry.Misses + 1));

        // An address that stopped guessing is forgotten once its window is over; swept only when the
        // table grows, so the ordinary case costs nothing.
        if (_misses.Count > 10_000)
            foreach (var (key, value) in _misses)
                if (now - value.Since >= Window)
                    _misses.TryRemove(key, out _);
    }
}
