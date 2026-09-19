using System.Security.Claims;
using System.Text.Json;
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
        Assert.Equal(48m, guest.RootElement.GetProperty("balance").GetDecimal());
        Assert.DoesNotContain("Rami", guest.RootElement.GetRawText());               // the guest channel names nobody
    }
}
