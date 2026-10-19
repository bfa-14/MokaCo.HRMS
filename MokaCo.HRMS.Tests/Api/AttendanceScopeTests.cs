using System.Reflection;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.ModelBinding;
using Moq;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Api.Controllers;
using MokaCo.HRMS.Api.Hubs;
using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Model.HR;
using MokaCo.HRMS.Model.Report;
using MokaCo.HRMS.Repository.HR;
using MokaCo.HRMS.Services.Attendance;
using MokaCo.HRMS.Services.Report;

namespace MokaCo.HRMS.Tests.Api;

/// <summary>
/// QA3 ATT-16 (with REL-15's scoping): the monthly summaries, the raw punches and the printable reports
/// answer within the caller's branch scope — script 87's rule — instead of about every employee.
/// </summary>
public class AttendanceScopeTests
{
    private const int Caller = 5, Self = 11, Colleague = 10, OtherBranch = 99, Branch1 = 1, Branch2 = 2;

    /// <summary>A branch-1 manager: themselves, a colleague of branch 1; branch 2's employee is outside.</summary>
    private static CallerScopeSet Manager() => CallerScopeSet.From(new (string, int?)[]
    {
        ("S", Self), ("B", Branch1), ("E", Self), ("E", Colleague),
    });

    private static Mock<IScopeRepository> Scopes(CallerScopeSet set, Action<DateTime?, DateTime?>? seen = null)
    {
        var scopes = new Mock<IScopeRepository>();
        scopes.Setup(s => s.CallerEmployeesAsync(Caller, It.IsAny<DateTime?>(), It.IsAny<DateTime?>()))
              .Callback((int _, DateTime? f, DateTime? t) => seen?.Invoke(f, t))
              .ReturnsAsync(set);
        return scopes;
    }

    /* ---- the set ---- */

    [Fact]
    public void The_set_is_read_from_the_procedures_rows()
    {
        var everyone = CallerScopeSet.From(new (string, int?)[] { ("A", null) });
        var nobody = CallerScopeSet.From(Array.Empty<(string, int?)>());
        var manager = Manager();

        Assert.True(everyone.SeesAll && everyone.SeesEmployee(OtherBranch) && everyone.SeesBranchRow(OtherBranch, Branch2) && everyone.SeesPunch(null, Branch2));
        Assert.False(nobody.SeesEmployee(Self) || nobody.SeesBranchRow(Self, Branch1) || nobody.SeesPunch(null, Branch1));
        Assert.Equal(Self, manager.CallerEmployeeId);
        Assert.True(manager.SeesEmployee(Colleague));
        Assert.False(manager.SeesEmployee(OtherBranch));
    }

    [Fact]
    public void A_branch_row_goes_to_the_manager_of_its_branch_and_to_the_employee_it_is_about()
    {
        var manager = Manager();

        Assert.True(manager.SeesBranchRow(Colleague, Branch1));
        Assert.True(manager.SeesBranchRow(OtherBranch, Branch1));    // a day another branch's employee worked here
        Assert.False(manager.SeesBranchRow(Colleague, Branch2));     // a day the colleague worked elsewhere is filed there
        Assert.True(manager.SeesBranchRow(Self, Branch2));           // but one's own days, wherever
        Assert.True(manager.SeesBranchRow(Colleague, null));         // no branch on the row: the employee rule
        Assert.False(manager.SeesBranchRow(OtherBranch, null));
    }

    [Fact]
    public void A_punch_goes_by_its_employee_and_an_unmapped_one_by_its_terminal()
    {
        var manager = Manager();

        Assert.True(manager.SeesPunch(Colleague, Branch2));
        Assert.False(manager.SeesPunch(OtherBranch, Branch1));       // another branch's employee, even on our terminal
        Assert.True(manager.SeesPunch(null, Branch1));
        Assert.False(manager.SeesPunch(null, Branch2));
    }

    [Theory]
    [InlineData("2026-08", "2026-08-01", "2026-08-31")]
    [InlineData("2028-02", "2028-02-01", "2028-02-29")]
    public void A_period_is_its_month(string period, string from, string to)
        => Assert.Equal((DateTime.Parse(from), DateTime.Parse(to)), ScopePeriod.Month(period));

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("2026-13")]
    [InlineData("August")]
    public void Anything_else_is_any_day(string? period) => Assert.Equal((null, null), ScopePeriod.Month(period));

    /* ---- the endpoints ---- */

    private static AttendanceController Attendance(Mock<IAttendanceService> service)
        => new(service.Object, Mock.Of<ILiveNotifier>()) { ControllerContext = TestPrincipal.For(Caller) };

    private static List<T> Rows<T>(IActionResult result) => ((IEnumerable<T>)Assert.IsType<OkObjectResult>(result).Value!).ToList();

    [Fact]
    public async Task The_monthly_summary_of_everyone_lists_only_whom_the_caller_may_see_that_month()
    {
        var service = new Mock<IAttendanceService>();
        service.Setup(s => s.GetSummaryAllAsync("2026-08")).ReturnsAsync(new[]
        {
            new AttendanceSummary { EmployeeId = Self }, new AttendanceSummary { EmployeeId = Colleague }, new AttendanceSummary { EmployeeId = OtherBranch },
        });
        (DateTime? From, DateTime? To) asked = default;

        var rows = Rows<AttendanceSummary>(await Attendance(service).GetSummaryAll("2026-08", Scopes(Manager(), (f, t) => asked = (f, t)).Object));

        Assert.Equal(new[] { Self, Colleague }, rows.Select(r => r.EmployeeId));
        Assert.Equal((new DateTime(2026, 8, 1), new DateTime(2026, 8, 31)), asked);
    }

    [Fact]
    public async Task The_per_branch_split_keeps_the_rows_filed_to_the_callers_branches()
    {
        var service = new Mock<IAttendanceService>();
        service.Setup(s => s.GetSummaryByBranchAsync("2026-08", null)).ReturnsAsync(new[]
        {
            new AttendanceBranchSummary { EmployeeId = Colleague, BranchId = Branch1 },
            new AttendanceBranchSummary { EmployeeId = Colleague, BranchId = Branch2 },
            new AttendanceBranchSummary { EmployeeId = OtherBranch, BranchId = Branch2 },
        });

        var rows = Rows<AttendanceBranchSummary>(await Attendance(service).GetSummaryByBranch("2026-08", null, Scopes(Manager()).Object));

        Assert.Equal(new[] { (Colleague, (int?)Branch1) }, rows.Select(r => (r.EmployeeId, r.BranchId)));
    }

    [Fact]
    public async Task The_punches_of_a_day_are_those_the_caller_may_see_that_day()
    {
        var import = new Mock<IImportService>();
        var day = new DateTime(2026, 8, 3);
        import.Setup(s => s.GetPunchesByDateAsync(day, null, false)).ReturnsAsync(new[]
        {
            new RawPunch { RawLogId = 1, EmployeeId = Colleague, BranchId = Branch1 },
            new RawPunch { RawLogId = 2, EmployeeId = OtherBranch, BranchId = Branch1 },
            new RawPunch { RawLogId = 3, EmployeeId = null, BranchId = Branch1 },
            new RawPunch { RawLogId = 4, EmployeeId = null, BranchId = Branch2 },
        });
        var controller = new AttendanceIngestionController(import.Object, Mock.Of<ILiveNotifier>()) { ControllerContext = TestPrincipal.For(Caller) };
        (DateTime? From, DateTime? To) asked = default;

        var rows = Rows<RawPunch>(await controller.GetPunches(day, null, Scopes(Manager(), (f, t) => asked = (f, t)).Object));

        Assert.Equal(new long[] { 1, 3 }, rows.Select(r => r.RawLogId));
        Assert.Equal(((DateTime?)day, (DateTime?)day), asked);
    }

    [Fact]
    public async Task The_reports_list_only_whom_the_caller_may_see()
    {
        var reports = new Mock<IReportService>();
        reports.Setup(r => r.GetMonthlyAttendanceAsync("2026-08", null)).ReturnsAsync(new ReportResult<MonthlyAttendanceHeader, MonthlyAttendanceRow>
        {
            Header = new MonthlyAttendanceHeader(),
            Rows = { new MonthlyAttendanceRow { EmployeeId = Colleague }, new MonthlyAttendanceRow { EmployeeId = OtherBranch } },
        });
        reports.Setup(r => r.GetDailyAttendanceAsync(new DateTime(2026, 8, 3), null)).ReturnsAsync(new ReportResult<DailyAttendanceHeader, DailyAttendanceRow>
        {
            Header = new DailyAttendanceHeader(),
            Rows = { new DailyAttendanceRow { EmployeeId = OtherBranch }, new DailyAttendanceRow { EmployeeId = Self } },
        });
        reports.Setup(r => r.GetLeaveBalanceAsync("2026-08", null, null)).ReturnsAsync(new ReportResult<LeaveBalanceHeader, LeaveBalanceRow>
        {
            Header = new LeaveBalanceHeader(),
            Rows = { new LeaveBalanceRow { EmployeeId = OtherBranch }, new LeaveBalanceRow { EmployeeId = Colleague } },
        });
        var controller = new ReportsController(reports.Object) { ControllerContext = TestPrincipal.For(Caller) };
        var scopes = Scopes(Manager()).Object;

        var monthly = (ReportResult<MonthlyAttendanceHeader, MonthlyAttendanceRow>)Assert.IsType<OkObjectResult>(await controller.MonthlyAttendance("2026-08", null, scopes)).Value!;
        var daily = (ReportResult<DailyAttendanceHeader, DailyAttendanceRow>)Assert.IsType<OkObjectResult>(await controller.DailyAttendance(new DateTime(2026, 8, 3), null, scopes)).Value!;
        var leave = (ReportResult<LeaveBalanceHeader, LeaveBalanceRow>)Assert.IsType<OkObjectResult>(await controller.LeaveBalance("2026-08", null, null, scopes)).Value!;

        Assert.Equal(new[] { Colleague }, monthly.Rows.Select(r => r.EmployeeId));
        Assert.Equal(new[] { Self }, daily.Rows.Select(r => r.EmployeeId));
        Assert.Equal(new[] { Colleague }, leave.Rows.Select(r => r.EmployeeId));
        Assert.NotNull(monthly.Header);
    }

    /* ---- reads of one employee or one day: the lead's [InCallerScope] (script 98) ---- */

    [Theory]
    [InlineData(typeof(AttendanceController), nameof(AttendanceController.GetRaw), ScopeTarget.Employee, "employeeId")]
    [InlineData(typeof(AttendanceController), nameof(AttendanceController.GetSummary), ScopeTarget.Employee, "employeeId")]
    [InlineData(typeof(AttendanceCorrectionsController), nameof(AttendanceCorrectionsController.GetByRecord), ScopeTarget.Attendance, "attendanceId")]
    public void Reads_of_one_employee_or_day_are_scoped(Type controller, string action, ScopeTarget target, string routeKey)
    {
        var scope = controller.GetMethod(action)!.GetCustomAttribute<InCallerScopeAttribute>();

        Assert.NotNull(scope);
        Assert.Equal(target, scope!.Target);
        Assert.Equal(routeKey, scope.RouteKey);
    }

    /// <summary>The summary's employee is a query value: missing, it must be a 400 from the model state, not an unscoped read.</summary>
    [Fact]
    public void The_summarys_employee_is_required()
    {
        var parameter = typeof(AttendanceController).GetMethod(nameof(AttendanceController.GetSummary))!.GetParameters().Single(p => p.Name == "employeeId");
        Assert.NotNull(parameter.GetCustomAttribute<BindRequiredAttribute>());
    }
}
