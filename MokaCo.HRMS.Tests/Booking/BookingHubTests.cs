using System.Net;
using System.Security.Claims;
using System.Text.Json;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Http.Connections.Features;
using Microsoft.AspNetCore.Http.Features;
using Microsoft.AspNetCore.SignalR;
using Moq;
using MokaCo.HRMS.Api.Hubs;
using MokaCo.HRMS.Model.Booking;
using MokaCo.HRMS.Services.Booking;

namespace MokaCo.HRMS.Tests.Booking;

/// <summary>
/// /hubs/booking: who lands in which group, and what the two messages look like on the wire. The
/// names are a CONTRACT with two clients that are not in this repository's build — the website's
/// confirmation page ('WatchBooking', 'BookingStatus') and the HRMS web app ('BookingChanged').
/// </summary>
public class BookingHubTests
{
    private static (BookingHub Hub, Mock<IGroupManager> Groups) HubFor(ClaimsPrincipal? user, IBookingService bookings)
    {
        var context = new Mock<HubCallerContext>();
        context.SetupGet(c => c.ConnectionId).Returns("c1");
        context.SetupGet(c => c.User).Returns(user);
        context.SetupGet(c => c.Items).Returns(new Dictionary<object, object?>());
        var groups = new Mock<IGroupManager>();
        return (new BookingHub(bookings) { Context = context.Object, Groups = groups.Object }, groups);
    }

    private static ClaimsPrincipal Staff(params string[] permissions) => new(new ClaimsIdentity(
        permissions.Select(p => new Claim("perm", p)).Append(new Claim(ClaimTypes.NameIdentifier, "7")), "jwt"));

    [Theory]
    [InlineData("BOOKING_VIEW", true)]
    [InlineData("BOOKING_MANAGE", true)]
    [InlineData("ATTENDANCE_VIEW", false)]   // authenticated, but may not read bookings: hears nothing
    public async Task A_token_joins_the_staff_group_only_with_a_booking_permission(string permission, bool joins)
    {
        var (hub, groups) = HubFor(Staff(permission), Mock.Of<IBookingService>());

        await hub.OnConnectedAsync();

        groups.Verify(g => g.AddToGroupAsync("c1", "staff", It.IsAny<CancellationToken>()), joins ? Times.Once() : Times.Never());
    }

    [Fact]
    public async Task An_anonymous_connection_is_in_no_group_until_it_watches_a_real_reference()
    {
        var bookings = new Mock<IBookingService>();
        bookings.Setup(b => b.GetPublicRecapAsync("MC-1A2B3C4D")).ReturnsAsync(new PublicBookingRecap { Ref = "MC-1A2B3C4D" });
        var (hub, groups) = HubFor(new ClaimsPrincipal(new ClaimsIdentity()), bookings.Object);

        await hub.OnConnectedAsync();
        groups.Verify(g => g.AddToGroupAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<CancellationToken>()), Times.Never());

        await hub.WatchBooking("mc-1a2b3c4d");      // the group name is the upper-cased reference, however it was typed
        groups.Verify(g => g.AddToGroupAsync("c1", "booking:MC-1A2B3C4D", It.IsAny<CancellationToken>()), Times.Once());
    }

    [Theory]
    [InlineData("")]
    [InlineData("staff")]                 // a group name is not a reference
    [InlineData("MC-1A2B3C4")]            // 7 characters
    [InlineData("MC-1A2B3C4D'; --")]
    [InlineData("MC-00000000")]           // well formed, no such booking
    public async Task A_reference_that_is_malformed_or_unknown_joins_nothing(string reference)
    {
        var bookings = new Mock<IBookingService>();
        bookings.Setup(b => b.GetPublicRecapAsync(It.IsAny<string>())).ReturnsAsync((PublicBookingRecap?)null);
        var (hub, groups) = HubFor(null, bookings.Object);

        var refusal = await Assert.ThrowsAsync<HubException>(() => hub.WatchBooking(reference));

        Assert.Equal("not_found", refusal.Message);
        groups.Verify(g => g.AddToGroupAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<CancellationToken>()), Times.Never());
    }

    [Fact]
    public async Task One_connection_cannot_walk_the_reference_space()
    {
        var bookings = new Mock<IBookingService>();
        bookings.Setup(b => b.GetPublicRecapAsync(It.IsAny<string>())).ReturnsAsync(new PublicBookingRecap());
        var (hub, _) = HubFor(null, bookings.Object);

        for (var i = 0; i < 5; i++)
            await hub.WatchBooking($"MC-0000000{i}");

        var refusal = await Assert.ThrowsAsync<HubException>(() => hub.WatchBooking("MC-00000009"));
        Assert.Equal("too_many", refusal.Message);
    }

    /* ---- QA3 BKG-9: WatchBooking is not an oracle of which references exist ------------------- */

    private sealed class Clock(DateTimeOffset now) : TimeProvider
    {
        public DateTimeOffset Now { get; set; } = now;
        public override DateTimeOffset GetUtcNow() => Now;
    }

    private sealed class HttpContextFeature : IHttpContextFeature
    {
        public HttpContext? HttpContext { get; set; }
    }

    /// <summary>An anonymous guest connection from <paramref name="address"/>, on a throttle the test owns.</summary>
    private static (BookingHub Hub, Mock<HubCallerContext> Context, Mock<IGroupManager> Groups) GuestHub(
        IBookingService bookings, BookingWatchThrottle throttle, string address = "203.0.113.7", string connectionId = "c1")
    {
        var http = new DefaultHttpContext();
        http.Connection.RemoteIpAddress = IPAddress.Parse(address);
        var features = new FeatureCollection();
        features.Set<IHttpContextFeature>(new HttpContextFeature { HttpContext = http });

        var context = new Mock<HubCallerContext>();
        context.SetupGet(c => c.ConnectionId).Returns(connectionId);
        context.SetupGet(c => c.User).Returns((ClaimsPrincipal?)null);
        context.SetupGet(c => c.Items).Returns(new Dictionary<object, object?>());
        context.SetupGet(c => c.Features).Returns(features);
        var groups = new Mock<IGroupManager>();
        return (new BookingHub(bookings, throttle) { Context = context.Object, Groups = groups.Object }, context, groups);
    }

    private static Mock<IBookingService> Knows(params string[] references)
    {
        var bookings = new Mock<IBookingService>();
        bookings.Setup(b => b.GetPublicRecapAsync(It.IsAny<string>()))
            .ReturnsAsync((string r) => references.Contains(r) ? new PublicBookingRecap { Ref = r } : null);
        return bookings;
    }

    [Fact]
    public async Task A_connection_that_keeps_guessing_is_dropped_and_its_next_call_is_not_looked_up()
    {
        var bookings = Knows("MC-REAL0001");
        var (hub, context, groups) = GuestHub(bookings.Object, new BookingWatchThrottle(new Clock(DateTimeOffset.UtcNow)));

        for (var i = 0; i < BookingWatchThrottle.MissesPerConnection; i++)
            Assert.Equal("not_found", (await Assert.ThrowsAsync<HubException>(() => hub.WatchBooking($"MC-GUESS00{i}"))).Message);

        // the sixth call — even for a reference that exists — is refused and the connection dropped
        Assert.Equal("too_many", (await Assert.ThrowsAsync<HubException>(() => hub.WatchBooking("MC-REAL0001"))).Message);
        context.Verify(c => c.Abort(), Times.Once());
        bookings.Verify(b => b.GetPublicRecapAsync("MC-REAL0001"), Times.Never());
        groups.Verify(g => g.AddToGroupAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<CancellationToken>()), Times.Never());
    }

    [Fact]
    public async Task A_new_connection_does_not_reset_the_count_of_the_address()
    {
        var throttle = new BookingWatchThrottle(new Clock(DateTimeOffset.UtcNow));
        var bookings = Knows("MC-REAL0001");

        // twenty misses spread over four connections from one address
        for (var connection = 0; connection < 4; connection++)
        {
            var (hub, _, _) = GuestHub(bookings.Object, throttle, connectionId: $"c{connection}");
            for (var i = 0; i < 5; i++)
                await Assert.ThrowsAsync<HubException>(() => hub.WatchBooking($"MC-GUESS{connection}{i:D2}"));
        }

        var (fresh, freshContext, _) = GuestHub(bookings.Object, throttle, connectionId: "c9");
        Assert.Equal("too_many", (await Assert.ThrowsAsync<HubException>(() => fresh.WatchBooking("MC-REAL0001"))).Message);
        freshContext.Verify(c => c.Abort(), Times.Once());

        // another address is not affected
        var (other, _, otherGroups) = GuestHub(bookings.Object, throttle, address: "198.51.100.4");
        await other.WatchBooking("MC-REAL0001");
        otherGroups.Verify(g => g.AddToGroupAsync("c1", "booking:MC-REAL0001", It.IsAny<CancellationToken>()), Times.Once());
    }

    [Fact]
    public async Task The_address_is_forgiven_once_its_window_is_over()
    {
        var clock = new Clock(DateTimeOffset.UtcNow);
        var throttle = new BookingWatchThrottle(clock);
        for (var i = 0; i < BookingWatchThrottle.MissesPerAddress; i++)
            throttle.RecordMiss("203.0.113.7");
        Assert.True(throttle.IsBlocked("203.0.113.7"));

        clock.Now += BookingWatchThrottle.Window;
        Assert.False(throttle.IsBlocked("203.0.113.7"));

        var (hub, _, groups) = GuestHub(Knows("MC-REAL0001").Object, throttle);
        await hub.WatchBooking("MC-REAL0001");
        groups.Verify(g => g.AddToGroupAsync("c1", "booking:MC-REAL0001", It.IsAny<CancellationToken>()), Times.Once());
    }

    [Fact]
    public async Task The_websites_page_watching_its_own_reference_is_never_counted()
    {
        var throttle = new BookingWatchThrottle(new Clock(DateTimeOffset.UtcNow));
        var bookings = Knows("MC-REAL0001");

        for (var reload = 0; reload < 30; reload++)       // a guest reloading the confirmation page all evening
        {
            var (hub, _, _) = GuestHub(bookings.Object, throttle, connectionId: $"c{reload}");
            await hub.WatchBooking("MC-REAL0001");
        }

        Assert.False(throttle.IsBlocked("203.0.113.7"));
    }

    [Fact]
    public void The_two_messages_carry_the_contract_fields_under_the_contract_names()
    {
        var booking = new BookingRefDetail
        {
            BookingId = 1074, BookingRef = "MC-DD92705D", Status = "Cancelled", RoomCode = "r1",
            BookDate = new DateTime(2026, 9, 29), StartMin = 1380, EndMin = 1500, GuestName = "Rami Haddad",
            Source = "Website", RefundStatus = "Due", PaidAmount = 12m, BalanceDue = 48m,
        };
        // SignalR's JSON protocol camel-cases; the property names here are already the wire names
        var options = new JsonSerializerOptions(JsonSerializerDefaults.Web);

        using var staff = JsonDocument.Parse(JsonSerializer.Serialize(BookingLivePublisher.StaffMessage(booking), options));
        Assert.Equal(
            ["bookingId", "ref", "status", "roomCode", "date", "startMin", "endMin", "guestName", "source"],
            staff.RootElement.EnumerateObject().Select(p => p.Name));
        Assert.Equal("2026-09-29", staff.RootElement.GetProperty("date").GetString());
        Assert.Equal(1500, staff.RootElement.GetProperty("endMin").GetInt32());     // after midnight stays minutes, not a wrapped clock

        using var guest = JsonDocument.Parse(JsonSerializer.Serialize(BookingLivePublisher.GuestMessage(booking), options));
        Assert.Equal(
            ["ref", "status", "refundStatus", "paid", "balance", "changedAt"],
            guest.RootElement.EnumerateObject().Select(p => p.Name));
        Assert.Equal("Due", guest.RootElement.GetProperty("refundStatus").GetString());
        Assert.Equal(0m, guest.RootElement.GetProperty("balance").GetDecimal());     // a cancelled booking owes nothing (QA3 BKG-8)
        Assert.DoesNotContain("Rami", guest.RootElement.GetRawText());               // the guest channel names nobody

        booking.Status = "Confirmed";
        using var live = JsonDocument.Parse(JsonSerializer.Serialize(BookingLivePublisher.GuestMessage(booking), options));
        Assert.Equal(48m, live.RootElement.GetProperty("balance").GetDecimal());
    }
}
