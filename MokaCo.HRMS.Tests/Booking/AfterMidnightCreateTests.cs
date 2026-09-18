using Microsoft.AspNetCore.Mvc;
using Moq;
using MokaCo.HRMS.Api.Controllers;
using MokaCo.HRMS.Api.PublicBooking;
using MokaCo.HRMS.Model.Booking;
using MokaCo.HRMS.Services.Booking;

namespace MokaCo.HRMS.Tests.Booking;

/// <summary>
/// BUG-22: a booking that crosses midnight (22:00→01:00 = 1320→1500) was refused with "end must be
/// after start" because the check compared the WRAPPED clock times. The rule is on the minutes; the
/// wrap happens once, on the way to the procedure's two TIME parameters (MinuteClock), and the
/// response carries the minutes and the moments with their Beirut offset.
/// </summary>
public class AfterMidnightCreateTests
{
    private static PublicBookingRequest Request(int startMin, int endMin) => new()
    {
        RoomCode = "r1", Date = new DateTime(2026, 9, 29), StartMin = startMin, EndMin = endMin,
        Persons = 2, Name = "Rami Haddad", Phone = "+961 70 000 001", Email = "rami@example.invalid",
    };

    [Fact]
    public void Shape_rules_accept_an_end_after_midnight_and_refuse_the_real_mistakes()
    {
        Assert.Null(PublicBookingRules.Validate(Request(1320, 1500)));
        Assert.Null(PublicBookingRules.Validate(Request(1380, 1800)));

        Assert.Equal("endMin", PublicBookingRules.Validate(Request(600, 600))?.Field);
        Assert.Equal("endMin", PublicBookingRules.Validate(Request(1320, 60))?.Field);      // 01:00 written as a clock time is wrong
        Assert.Equal("endMin", PublicBookingRules.Validate(Request(1320, 1801))?.Field);
        Assert.Equal("startMin", PublicBookingRules.Validate(Request(1440, 1500))?.Field);  // a start at midnight is the next date
        Assert.Equal("startMin", PublicBookingRules.Validate(Request(-1, 60))?.Field);
    }

    [Theory]
    [InlineData("+96170000001")]
    [InlineData("70 000 001")]
    [InlineData("03 123-456")]
    [InlineData("03 (123) 456")]
    [InlineData("0096170000001")]
    public void Phone_shape_accepts_digits_plus_spaces_dashes_brackets(string phone)
    {
        var request = Request(600, 720);
        request.Phone = phone;
        Assert.Null(PublicBookingRules.Validate(request));
    }

    [Theory]
    [InlineData("")]
    [InlineData("12345")]
    [InlineData("abc def ghi")]
    [InlineData("(03) 123-456")]                 // must START with a digit or '+'
    [InlineData("+961 70 000 001 ext 12")]
    public void Phone_shape_refuses_the_rest(string phone)
    {
        var request = Request(600, 720);
        request.Phone = phone;
        Assert.Equal("phone", PublicBookingRules.Validate(request)?.Field);
    }

    [Fact]
    public void Persons_name_email_and_notes_are_bounded()
    {
        var r = Request(600, 720); r.Persons = 31;
        Assert.Equal("persons", PublicBookingRules.Validate(r)?.Field);
        r = Request(600, 720); r.Persons = 0;
        Assert.Equal("persons", PublicBookingRules.Validate(r)?.Field);
        r = Request(600, 720); r.Name = new string('x', 121);
        Assert.Equal("name", PublicBookingRules.Validate(r)?.Field);
        r = Request(600, 720); r.Email = "not-an-address";
        Assert.Equal("email", PublicBookingRules.Validate(r)?.Field);
        r = Request(600, 720); r.Notes = new string('n', 501);
        Assert.Equal("notes", PublicBookingRules.Validate(r)?.Field);
    }

    [Fact]
    public void Minutes_become_the_procedures_two_times_with_the_end_wrapped()
    {
        Assert.Equal(new TimeSpan(22, 0, 0), MinuteClock.StartTime(1320));
        Assert.Equal(new TimeSpan(1, 0, 0), MinuteClock.EndTime(1500));
        Assert.Equal(new TimeSpan(0, 0, 0), MinuteClock.EndTime(1440));
        Assert.Equal(new TimeSpan(12, 0, 0), MinuteClock.EndTime(720));
        Assert.Equal(1500, MinuteClock.EndMinOf(new TimeSpan(22, 0, 0), new TimeSpan(1, 0, 0)));
        Assert.Equal(720, MinuteClock.EndMinOf(new TimeSpan(10, 0, 0), new TimeSpan(12, 0, 0)));
    }

    [Fact]
    public void Beirut_moments_carry_their_offset_and_roll_the_date_past_1440()
    {
        var endAt = BeirutTime.At(new DateTime(2026, 9, 29), 1500);
        Assert.Equal(new DateTime(2026, 9, 30, 1, 0, 0), endAt.DateTime);
        Assert.Equal(TimeSpan.FromHours(3), endAt.Offset);     // Lebanon is on summer time in September

        var winter = BeirutTime.At(new DateTime(2026, 1, 10), 600);
        Assert.Equal(TimeSpan.FromHours(2), winter.Offset);
        Assert.Equal("Asia/Beirut", BeirutTime.IanaId);
    }

    [Fact]
    public async Task Create_passes_the_minutes_through_and_answers_201_with_the_reference()
    {
        var bookings = new Mock<IBookingService>();
        PublicBookingRequest? received = null;
        bookings.Setup(b => b.CreateFromWebsiteAsync(It.IsAny<PublicBookingRequest>()))
            .Callback<PublicBookingRequest>(r => received = r)
            .ReturnsAsync(new BookingCreated
            {
                BookingId = 7, BookingRef = "MC-ABCD1234", Status = "Pending", TotalAmount = 60, DepositDue = 12,
                DepositPercent = 20, CurrencyCode = "USD", Hours = 3, RoomName = "Mokha",
            });
        bookings.Setup(b => b.IsDepositRequiredAsync()).ReturnsAsync(false);

        var controller = new PublicBookingController(bookings.Object, Mock.Of<IRoomService>());
        var result = await controller.Create(Request(1320, 1500));

        var created = Assert.IsType<ObjectResult>(result);
        Assert.Equal(201, created.StatusCode);

        Assert.NotNull(received);
        Assert.Equal(1320, received!.StartMin);
        Assert.Equal(1500, received.EndMin);                    // NOT wrapped before the service
        Assert.Equal("+961 70 000 001", received.Phone);

        var body = created.Value!;
        object? Prop(string name) => body.GetType().GetProperty(name)?.GetValue(body);
        Assert.Equal("MC-ABCD1234", Prop("ref"));
        Assert.Equal(1500, Prop("endMin"));
        Assert.Equal("2026-09-29", Prop("date"));
        Assert.Equal("Asia/Beirut", Prop("timeZone"));
        Assert.Equal(new DateTime(2026, 9, 30, 1, 0, 0), ((DateTimeOffset)Prop("endAt")!).DateTime);
        Assert.Null(Prop("holdExpiresUtc"));
    }

    [Fact]
    public async Task Create_refuses_a_wrapped_end_before_touching_the_service()
    {
        var bookings = new Mock<IBookingService>(MockBehavior.Strict);
        var controller = new PublicBookingController(bookings.Object, Mock.Of<IRoomService>());

        var result = await controller.Create(Request(1320, 60));

        var bad = Assert.IsType<BadRequestObjectResult>(result);
        var body = bad.Value!;
        Assert.Equal("invalid_input", body.GetType().GetProperty("code")?.GetValue(body));
        Assert.Equal("endMin", body.GetType().GetProperty("field")?.GetValue(body));
    }
}
