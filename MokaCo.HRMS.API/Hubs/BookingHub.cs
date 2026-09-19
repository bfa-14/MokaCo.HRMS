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
///     booking. The permission is checked because the message names the guest: it is the same data
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

    /// <summary>A connection may watch a handful of bookings, not enumerate them.</summary>
    private const int MaxWatchedPerConnection = 5;
    private const string WatchedCountKey = "watched";

    private readonly IBookingService _bookings;
    public BookingHub(IBookingService bookings) => _bookings = bookings;

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
    /// "badly formed" are the same answer to somebody guessing references.
    /// </summary>
    public async Task WatchBooking(string bookingRef)
    {
        var reference = (bookingRef ?? string.Empty).Trim().ToUpperInvariant();
        if (!ReferenceShape().IsMatch(reference))
            throw new HubException("not_found");

        var watched = Context.Items.TryGetValue(WatchedCountKey, out var n) && n is int count ? count : 0;
        if (watched >= MaxWatchedPerConnection)
            throw new HubException("too_many");

        if (await _bookings.GetPublicRecapAsync(reference) is null)
            throw new HubException("not_found");

        Context.Items[WatchedCountKey] = watched + 1;
        await Groups.AddToGroupAsync(Context.ConnectionId, GuestGroup(reference));
    }

    [GeneratedRegex("^MC-[A-Z0-9]{8}$")]
    private static partial Regex ReferenceShape();
}
