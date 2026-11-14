using MokaCo.HRMS.Services.Attendance;

namespace MokaCo.HRMS.Tests.Attendance;

/// <summary>My attendance: the month asked for is 'yyyy-MM'; anything else means the current month.</summary>
public class MyAttendanceTests
{
    [Theory]
    [InlineData("2026-11", 2026, 11)]
    [InlineData("2027-01", 2027, 1)]
    public void A_year_month_is_read(string month, int year, int number)
        => Assert.Equal(new DateTime(year, number, 1), MyAttendanceService.ParseMonth(month));

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("11-2026")]
    [InlineData("2026-13")]
    [InlineData("1999-12")]
    [InlineData("2026-11-01")]
    public void Anything_else_means_the_current_month(string? month)
        => Assert.Null(MyAttendanceService.ParseMonth(month));
}

/// <summary>From-to ranges for punches, re-process and mark absentees: at most a month, the end not before the start.</summary>
public class DayRangeTests
{
    [Fact]
    public void A_month_is_fine()
        => Assert.Null(DayRange.Problem(new DateTime(2026, 10, 1), new DateTime(2026, 10, 31)));

    [Fact]
    public void More_than_31_days_is_refused()
        => Assert.Contains("at most 31", DayRange.Problem(new DateTime(2026, 10, 1), new DateTime(2026, 11, 1)));

    [Fact]
    public void An_end_before_the_start_is_refused()
        => Assert.Contains("on or after", DayRange.Problem(new DateTime(2026, 10, 2), new DateTime(2026, 10, 1)));

    [Fact]
    public void Every_day_once_in_order()
        => Assert.Equal(3, DayRange.Days(new DateTime(2026, 10, 30), new DateTime(2026, 11, 1)).Count());
}
