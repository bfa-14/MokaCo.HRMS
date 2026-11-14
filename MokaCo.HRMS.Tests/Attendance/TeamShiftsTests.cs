using System.Reflection;
using Moq;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Api.Controllers;
using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Model.Workflow;
using MokaCo.HRMS.Services.Attendance;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Tests.Attendance;

/// <summary>
/// My branch's shifts (GET /api/me/team-shifts, script 112): the token's employee's branch only, working days with a
/// shift only, nobody on approved leave for the whole day, at most two weeks.
/// </summary>
public class TeamShiftsTests
{
    private static readonly DateTime Mon = new(2026, 11, 16);

    private static ShiftAssignment Row(int employeeId, string name, DateTime day, int? shiftId, bool rest = false) => new()
    {
        EmployeeId = employeeId,
        FullName = name,
        WorkDate = day,
        ShiftId = shiftId,
        ShiftName = shiftId is null ? null : $"Shift {shiftId}",
        StartTime = shiftId is null ? null : TimeSpan.FromHours(shiftId == 1 ? 7 : 14),
        EndTime = shiftId is null ? null : TimeSpan.FromHours(shiftId == 1 ? 14 : 21),
        IsRestDay = rest,
    };

    private static (TeamShiftsService Service, Mock<IRosterService> Roster) Make(MyEmployee? me)
    {
        var support = new Mock<IWorkflowSupportService>();
        support.Setup(s => s.GetEmployeeByUserIdAsync(42)).ReturnsAsync(me);
        var roster = new Mock<IRosterService>();
        roster.Setup(r => r.GetAsync(Mon, Mon.AddDays(6), null, 7, null)).ReturnsAsync(
        [
            Row(1, "Lina Saab", Mon, 1),
            Row(2, "Rami Khoury", Mon, 2),
            Row(3, "Nour Fares", Mon, null, rest: true),
            Row(4, "Maya Haddad", Mon, 1),          // whole day of leave: left off
            Row(5, "Ahmad Nasser", Mon, 2),         // half a day of leave: stays on
        ]);
        roster.Setup(r => r.GetLeaveDaysAsync(Mon, Mon.AddDays(6), 7, null)).ReturnsAsync(
        [
            new RosterLeaveDay { EmployeeId = 4, Date = Mon, DaysOnLeave = 1m },
            new RosterLeaveDay { EmployeeId = 5, Date = Mon, DaysOnLeave = 0.5m },
        ]);
        return (new TeamShiftsService(roster.Object, support.Object), roster);
    }

    [Fact]
    public async Task The_branch_is_the_employees_and_only_working_shifts_leave_the_service()
    {
        var (service, roster) = Make(new MyEmployee { EmployeeId = 1, BranchId = 7, BranchName = "Hamra" });

        var result = await service.GetAsync(42, Mon, Mon.AddDays(6));

        Assert.NotNull(result);
        Assert.Equal("Hamra", result.BranchName);
        Assert.Equal(["Lina Saab", "Ahmad Nasser", "Rami Khoury"], result.Shifts.Select(s => s.FullName));
        // Read unscoped (no caller), for the employee's branch only.
        roster.Verify(r => r.GetAsync(Mon, Mon.AddDays(6), null, 7, null), Times.Once);
    }

    [Fact]
    public async Task An_account_without_an_employee_gets_nothing()
    {
        var (service, roster) = Make(null);
        Assert.Null(await service.GetAsync(42, Mon, Mon.AddDays(6)));
        roster.VerifyNoOtherCalls();
    }

    [Theory]
    [InlineData(-1)]   // the end before the start
    [InlineData(14)]   // 15 days
    public async Task A_bad_period_is_refused(int lastDayOffset)
    {
        var (service, _) = Make(new MyEmployee { EmployeeId = 1, BranchId = 7 });
        var ex = await Assert.ThrowsAsync<WorkflowException>(() => service.GetAsync(42, Mon, Mon.AddDays(lastDayOffset)));
        Assert.Equal(400, ex.StatusCode);
    }

    [Fact]
    public void The_endpoint_needs_its_own_permission()
    {
        var attr = typeof(MeController).GetMethod(nameof(MeController.TeamShifts))!.GetCustomAttribute<HasPermissionAttribute>();
        Assert.NotNull(attr);
        Assert.Contains("SHIFTS_VIEW_BRANCH", attr.Policy);
    }
}
