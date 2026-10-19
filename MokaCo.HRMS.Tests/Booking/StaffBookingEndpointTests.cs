using Microsoft.AspNetCore.Mvc;
using Moq;
using MokaCo.HRMS.Api.Controllers;
using MokaCo.HRMS.Api.Hubs;
using MokaCo.HRMS.Model.Booking;
using MokaCo.HRMS.Services.Booking;

namespace MokaCo.HRMS.Tests.Booking;

/// <summary>
/// The staff side (api/bookings), QA3:
///   BKG-2   a block or a booking across midnight (22:00–01:00) is one span, the next-morning rule;
///   WEB-9   the New booking form is priced by the server (POST quote), not by rate × hours;
///   BKG-14  a block or a catalogue edit is announced to the staff calendars (CalendarChanged).
/// </summary>
public class StaffBookingEndpointTests
{
    private static (BookingsController Controller, Mock<IBookingService> Bookings, Mock<IRoomService> Rooms, Mock<IBookingLivePublisher> Live) Controller()
    {
        var bookings = new Mock<IBookingService>();
        var rooms = new Mock<IRoomService>();
        var live = new Mock<IBookingLivePublisher>();
        var controller = new BookingsController(bookings.Object, rooms.Object, live.Object) { ControllerContext = TestPrincipal.For(7) };
        return (controller, bookings, rooms, live);
    }

    private static TimeSpan T(int hours, int minutes = 0) => new(hours, minutes, 0);

    [Theory]
    [InlineData(22, 1, true)]      // 22:00–01:00, the next morning
    [InlineData(23, 6, true)]      // up to 06:00
    [InlineData(10, 12, true)]
    [InlineData(22, 7, false)]     // past 06:00 is not "the next morning"
    [InlineData(10, 10, false)]    // no length
    public void A_staff_span_ending_at_or_before_its_start_is_the_next_morning(int start, int end, bool valid)
        => Assert.Equal(valid, BookingsController.SpanProblem(T(start), T(end)) is null);

    [Fact]
    public async Task A_block_across_midnight_is_passed_to_the_procedure_and_announced()
    {
        var (controller, bookings, _, live) = Controller();
        bookings.Setup(b => b.CreateBlockAsync(It.IsAny<BlockCreateRequest>(), It.IsAny<int>())).ReturnsAsync(new BlockCreated { BlockId = 9 });
        var request = new BlockCreateRequest { RoomId = 3, BlockDate = new DateTime(2026, 11, 2), StartTime = T(23), EndTime = T(1), Reason = "deep clean" };

        var result = await controller.CreateBlock(request);

        Assert.IsType<OkObjectResult>(result);
        bookings.Verify(b => b.CreateBlockAsync(request, It.IsAny<int>()), Times.Once());
        live.Verify(l => l.PublishCalendarAsync(CalendarKind.Block, 3, new DateTime(2026, 11, 2)), Times.Once());
    }

    [Fact]
    public async Task A_block_past_six_in_the_morning_is_refused_before_the_procedure()
    {
        var (controller, bookings, _, live) = Controller();

        var result = await controller.CreateBlock(new BlockCreateRequest { RoomId = 3, BlockDate = new DateTime(2026, 11, 2), StartTime = T(22), EndTime = T(7) });

        Assert.IsType<BadRequestObjectResult>(result);
        bookings.Verify(b => b.CreateBlockAsync(It.IsAny<BlockCreateRequest>(), It.IsAny<int>()), Times.Never());
        live.Verify(l => l.PublishCalendarAsync(It.IsAny<string>(), It.IsAny<int?>(), It.IsAny<DateTime?>()), Times.Never());
    }

    [Fact]
    public async Task Lifting_a_block_and_editing_the_catalogue_tell_the_calendars()
    {
        var (controller, _, rooms, live) = Controller();
        rooms.Setup(r => r.UpsertRoomAsync(4, It.IsAny<RoomUpsertRequest>())).ReturnsAsync(new Room { RoomId = 4, Code = "r4", Name = "Aden" });

        await controller.DeleteBlock(9);
        await controller.UpdateRoom(4, new RoomUpsertRequest { Code = "r4", Name = "Aden", Seats = 6, PricePerHour = 20 });
        await controller.SetHours(4, [new RoomHoursRequest { DayOfWeek = 1, OpenTime = T(7), CloseTime = T(1) }]);
        await controller.CreateAddon(4, new RoomAddonUpsertRequest { Name = "Projector", PriceType = "Fixed", Price = 10 });

        live.Verify(l => l.PublishCalendarAsync(CalendarKind.Block, null, null), Times.Once());
        live.Verify(l => l.PublishCalendarAsync(CalendarKind.Room, 4, null), Times.Exactly(3));
    }

    /// <summary>
    /// WEB-9: the form shows the server's price — the procedure's discount, lead-time tier and floor —
    /// for the room by id, with the next-morning end. Here 22:00–01:00 with a 10 % three-hour discount
    /// and the 50 % short-notice tier.
    /// </summary>
    [Fact]
    public async Task The_staff_quote_is_the_procedures_answer()
    {
        var (controller, bookings, _, _) = Controller();
        var priced = new BookingQuote
        {
            RoomId = 1, RoomCode = "r1", RoomName = "Mokha", Hours = 3, PricePerHour = 20, RoomGross = 60,
            DiscountPercent = 10, DiscountAmount = 6, RoomTotal = 54, AddonTotal = 10, TotalAmount = 64,
            DepositPercent = 50, DepositDue = 32, CurrencyCode = "USD",
        };
        StaffQuoteRequest? asked = null;
        bookings.Setup(b => b.QuoteForStaffAsync(It.IsAny<StaffQuoteRequest>())).Callback<StaffQuoteRequest>(r => asked = r).ReturnsAsync(priced);

        var result = await controller.Quote(new StaffQuoteRequest { RoomId = 1, BookDate = new DateTime(2026, 11, 2), StartTime = T(22), EndTime = T(1), AddonIds = [5] });

        Assert.Same(priced, Assert.IsType<OkObjectResult>(result).Value);
        Assert.Equal((1, T(22), T(1)), (asked!.RoomId, asked.StartTime, asked.EndTime));
        Assert.Equal(1500, MinuteClock.EndMinOf(asked.StartTime, asked.EndTime));     // what the repository sends as @EndMin
    }

    [Fact]
    public async Task A_staff_quote_without_a_room_or_with_no_length_is_refused_before_the_procedure()
    {
        var (controller, bookings, _, _) = Controller();

        Assert.IsType<BadRequestObjectResult>(await controller.Quote(new StaffQuoteRequest { RoomId = 0, StartTime = T(10), EndTime = T(11) }));
        Assert.IsType<BadRequestObjectResult>(await controller.Quote(new StaffQuoteRequest { RoomId = 1, StartTime = T(10), EndTime = T(10) }));
        bookings.Verify(b => b.QuoteForStaffAsync(It.IsAny<StaffQuoteRequest>()), Times.Never());
    }
}
