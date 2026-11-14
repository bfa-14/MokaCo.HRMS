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
