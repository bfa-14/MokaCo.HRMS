using System.Reflection;
using Moq;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Api.Controllers;
using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Model.Report;
using MokaCo.HRMS.Repository.Report;
using MokaCo.HRMS.Services.Attendance;
using MokaCo.HRMS.Services.Report;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Tests.Report;

/// <summary>
/// Worked time (Reports > Worked time): worked time from the attendance days, expected time from the standard month
/// (26 x 8 h spread over the calendar days), holidays and leave expect nothing, today is not counted, days not on the
/// roster are apart, and the caller's scope applies to everything.
/// </summary>
public class WorkedTimeReportTests
{
    private static readonly DateTime Nov1 = new(2026, 11, 1);
    private static readonly WorkedTimeStandard Std = new() { StandardDayMinutes = 480, StandardDaysPerMonth = 26 };

    private static List<WorkedTimeEmployeeDay> Employed(int employeeId, string name, DateTime from, DateTime to, string? holidayOn = null)
    {
        var days = new List<WorkedTimeEmployeeDay>();
        for (var d = from; d <= to; d = d.AddDays(1))
            days.Add(new WorkedTimeEmployeeDay
            {
                EmployeeId = employeeId, FullName = name, DepartmentName = "Bar", WorkDate = d, BranchId = 7, BranchName = "Hamra",
                HolidayName = holidayOn == d.ToString("yyyy-MM-dd") ? "Independence Day" : null,
            });
        return days;
    }

    private static AttendanceRecord Day(int employeeId, string name, DateTime day, int worked, string status = "Present", bool anomaly = false, int overtime = 0) => new()
    {
        EmployeeId = employeeId, FullName = name, WorkDate = day, Status = status, WorkedMinutes = worked, OvertimeMinutes = overtime,
        FirstInUtc = status is "Absent" or "Leave" ? null : day.AddHours(8), LastOutUtc = status is "Absent" or "Leave" ? null : day.AddHours(16),
        HasAnomaly = anomaly, BranchId = 7, BranchName = "Hamra",
    };

    private static WorkedTimeInput Input(DateTime from, DateTime to, DateTime today) => new()
    {
        From = from, To = to, Today = today, Standard = Std, GeneratedUtc = DateTime.UtcNow,
    };

    [Fact]
    public void Without_a_roster_the_attendance_days_are_the_worked_time_and_the_standard_month_the_target()
    {
        var input = Input(Nov1, Nov1.AddDays(13), Nov1.AddDays(14));
        input.EmployeeDays = Employed(1, "Lina Saab", Nov1, Nov1.AddDays(13));
        input.Records =
        [
            Day(1, "Lina Saab", Nov1, 480, overtime: 0),
            Day(1, "Lina Saab", Nov1.AddDays(1), 450, anomaly: true),
            Day(1, "Lina Saab", Nov1.AddDays(2), 240, status: "RestDay", overtime: 240),
            Day(1, "Lina Saab", Nov1.AddDays(3), 0, status: "Absent"),
        ];

        var report = WorkedTimeReportService.Build(input);

        var row = Assert.Single(report.Rows);
        Assert.Equal(3, row.DaysWorked);              // the absence is not a day worked
        Assert.Equal(1170, row.WorkedMinutes);
        Assert.Equal(390, row.AverageMinutes);
        Assert.Equal(240, row.OvertimeMinutes);
        Assert.Equal(1, row.MissingPunchDays);
        Assert.Equal(14 * 416, row.ExpectedMinutes);  // 26 x 480 / 30 = 416 a calendar day of November
        Assert.Equal(20.1m, row.ProgressPercent);
        Assert.Equal(new DateTime(2026, 11, 14), report.Header.CountedTo);
        Assert.Equal(4, report.Days.Count);
    }

    [Fact]
    public void Holidays_and_leave_expect_nothing_and_half_a_day_of_leave_half()
    {
        var input = Input(Nov1, Nov1.AddDays(9), Nov1.AddDays(20));
        input.EmployeeDays = Employed(1, "Lina Saab", Nov1, Nov1.AddDays(9), holidayOn: "2026-11-03");
        input.Leave =
        [
            new RosterLeaveDay { EmployeeId = 1, Date = Nov1.AddDays(4), DaysOnLeave = 1m },
            new RosterLeaveDay { EmployeeId = 1, Date = Nov1.AddDays(5), DaysOnLeave = 0.5m },
            new RosterLeaveDay { EmployeeId = 1, Date = Nov1.AddDays(2), DaysOnLeave = 1m }, // on the holiday: the holiday wins
        ];

        var row = Assert.Single(WorkedTimeReportService.Build(input).Rows);

        Assert.Equal(1, row.HolidayDays);
        Assert.Equal(1.5m, row.LeaveDays);
        Assert.Equal((int)Math.Round(7.5m * 416), row.ExpectedMinutes); // 10 days - holiday - 1.5 days of leave
        Assert.Equal(0m, row.ProgressPercent);
    }

    [Fact]
    public void Today_is_not_counted_and_a_period_not_yet_begun_counts_nothing()
    {
        var today = Nov1.AddDays(5);
        var input = Input(Nov1, Nov1.AddDays(29), today);
        input.EmployeeDays = Employed(1, "Lina Saab", Nov1, Nov1.AddDays(29));
        input.Records = [Day(1, "Lina Saab", Nov1, 480), Day(1, "Lina Saab", today, 300)];

        var report = WorkedTimeReportService.Build(input);
        Assert.Equal(today.AddDays(-1), report.Header.CountedTo);
        Assert.Equal(480, report.Rows[0].WorkedMinutes);
        Assert.Equal(5 * 416, report.Rows[0].ExpectedMinutes);

        var future = Input(today, today.AddDays(6), today);
        future.EmployeeDays = Employed(1, "Lina Saab", today, today.AddDays(6));
        var none = WorkedTimeReportService.Build(future);
        Assert.Null(none.Header.CountedTo);
        Assert.Null(none.Rows[0].ProgressPercent);
        Assert.Null(none.Totals.ProgressPercent);
    }

    [Fact]
    public void Days_not_on_the_roster_are_apart_and_a_dismissed_one_is_left_out()
    {
        var input = Input(Nov1, Nov1.AddDays(6), Nov1.AddDays(10));
        input.EmployeeDays = Employed(1, "Lina Saab", Nov1, Nov1.AddDays(6));
        input.Records = [Day(1, "Lina Saab", Nov1, 480)];
        input.Unrostered =
        [
            new UnrosteredDay { EmployeeId = 1, EmployeeName = "Lina Saab", BranchName = "Hamra", WorkDate = Nov1.AddDays(1), FirstPunch = Nov1.AddDays(1).AddHours(9), LastPunch = Nov1.AddDays(1).AddHours(15), PunchCount = 2, WorkedMinutes = 360, State = "Open" },
            new UnrosteredDay { EmployeeId = 1, EmployeeName = "Lina Saab", BranchName = "Hamra", WorkDate = Nov1.AddDays(2), WorkedMinutes = 200, PunchCount = 2, State = "Dismissed" },
        ];

        var report = WorkedTimeReportService.Build(input);
        var row = Assert.Single(report.Rows);
        Assert.Equal(480, row.WorkedMinutes);
        Assert.Equal(1, row.DaysWorked);
        Assert.Equal(1, row.NotOnRosterDays);
        Assert.Equal(360, row.NotOnRosterMinutes);
        Assert.Contains(report.Days, d => d.Kind == "NotOnRoster" && d.WorkedMinutes == 360);
        Assert.DoesNotContain(report.Days, d => d.WorkDate == Nov1.AddDays(2));
    }

    [Fact]
    public void The_scope_applies_to_rows_days_and_totals()
    {
        var input = Input(Nov1, Nov1.AddDays(6), Nov1.AddDays(10));
        input.EmployeeDays = [.. Employed(1, "Lina Saab", Nov1, Nov1.AddDays(6)), .. Employed(2, "Rami Khoury", Nov1, Nov1.AddDays(6))];
        input.Records = [Day(1, "Lina Saab", Nov1, 480), Day(2, "Rami Khoury", Nov1, 300)];
        input.Sees = id => id == 2;

        var report = WorkedTimeReportService.Build(input);
        Assert.Equal([2], report.Rows.Select(r => r.EmployeeId));
        Assert.All(report.Days, d => Assert.Equal(2, d.EmployeeId));
        Assert.Equal(300, report.Totals.WorkedMinutes);
    }

    [Theory]
    [InlineData(-1)]
    [InlineData(93)] // 94 days
    public async Task A_bad_period_is_refused_before_anything_is_read(int lastDayOffset)
    {
        var reports = new Mock<IReportRepository>(MockBehavior.Strict);
        var service = new WorkedTimeReportService(reports.Object, Mock.Of<IAttendanceService>(), Mock.Of<IRosterService>());
        var ex = await Assert.ThrowsAsync<WorkflowException>(() => service.GetAsync(Nov1, Nov1.AddDays(lastDayOffset), null, null, _ => true));
        Assert.Equal(400, ex.StatusCode);
    }

    [Fact]
    public void The_endpoint_needs_REPORT_VIEW()
    {
        var attr = typeof(ReportsController).GetMethod(nameof(ReportsController.WorkedTime))!.GetCustomAttribute<HasPermissionAttribute>();
        Assert.NotNull(attr);
        Assert.EndsWith("REPORT_VIEW", attr.Policy);
    }
}
