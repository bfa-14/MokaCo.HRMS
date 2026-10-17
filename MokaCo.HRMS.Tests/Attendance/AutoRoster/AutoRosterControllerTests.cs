using System.Reflection;
using System.Text.Json;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Routing;
using Moq;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Api.Controllers;
using MokaCo.HRMS.Api.Hubs;
using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Services.Attendance;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Tests.Attendance.AutoRoster;

/// <summary>
/// The API half of docs/AUTO_ROSTER.md §4: the routes and permissions of the table, a preview that
/// never tells a live screen anything, a commit that notifies once and only when something was saved,
/// a refused draft as 400 { error, issues }, and the new procedure sentences as 409 / 403.
/// The live notifier is STRICT everywhere: a call nobody set up fails the test.
/// </summary>
public class AutoRosterControllerTests
{
    private const int Caller = 20;
    private const string Stale = "The roster changed since the preview — preview again.";
    private const string Pinned = "This day is pinned — unpin it before re-planning it.";
    private const string NotYourBranch = "You can only plan rosters for the branches you manage.";

    private static readonly DateOnly Day = new(2026, 12, 14);

    private static (AutoRosterController Controller, Mock<IAutoRosterService> Auto, Mock<ILiveNotifier> Live) Build()
    {
        var auto = new Mock<IAutoRosterService>(MockBehavior.Strict);
        var live = new Mock<ILiveNotifier>(MockBehavior.Strict);
        var controller = new AutoRosterController(auto.Object, live.Object) { ControllerContext = TestPrincipal.For(userId: Caller) };
        return (controller, auto, live);
    }

    private static AutoRosterRequest Request() => new() { BranchId = 1, Month = "2026-12", Mode = "FillEmpty" };
    private static AutoRosterCommitRequest CommitRequest() => new() { BranchId = 1, Month = "2026-12", Mode = "FillEmpty" };

    private static object? Field(object? value, string name) => value?.GetType().GetProperty(name)?.GetValue(value);

    private static void AssertRefusal(IActionResult result, int status, string message)
    {
        var obj = Assert.IsAssignableFrom<ObjectResult>(result);
        Assert.Equal(status, obj.StatusCode);
        Assert.Equal(message, Field(obj.Value, "error"));
    }

    /* ---- the procedures' new sentences ---- */

    [Theory]
    [InlineData(Stale, 409)]
    [InlineData(Pinned, 409)]
    [InlineData(NotYourBranch, 403)]
    [InlineData("Rana Haddad belongs to another branch now — their rotation and rhythm are set there.", 403)]
    public void The_auto_roster_refusals_map_to_their_status_with_the_sentence_intact(string message, int status)
    {
        var ex = WorkflowSqlErrors.MapMessage(message);

        Assert.Equal(status, ex.StatusCode);
        Assert.Equal(message, ex.Message);
    }

    [Theory]
    [InlineData("Choose a real mode.", 400)]
    [InlineData("Only a saved day can be pinned.", 400)]
    [InlineData("A holiday is not a rest day — leave the day empty.", 400)]
    [InlineData("Waiting for approval — request #123. Withdraw or wait for the decision before editing.", 409)]
    [InlineData("You are not the approver for this step.", 403)]
    public void The_other_sentences_keep_their_status(string message, int status)
        => Assert.Equal(status, WorkflowSqlErrors.MapMessage(message).StatusCode);

    /* ---- the §4 table ---- */

    public static TheoryData<string, string, string, string> Endpoints() => new()
    {
        { nameof(AutoRosterController.GetSetup), "GET", "setup", "ATTENDANCE_VIEW" },
        { nameof(AutoRosterController.Preview), "POST", "preview", "ATTENDANCE_MANAGE" },
        { nameof(AutoRosterController.Commit), "POST", "commit", "ATTENDANCE_MANAGE" },
        { nameof(AutoRosterController.GetCells), "GET", "cells", "ATTENDANCE_VIEW" },
        { nameof(AutoRosterController.SetPin), "PUT", "pin", "ATTENDANCE_MANAGE" },
        { nameof(AutoRosterController.SaveStaffing), "PUT", "staffing", "ATTENDANCE_MANAGE" },
        { nameof(AutoRosterController.SaveRhythm), "PUT", "rhythm", "ATTENDANCE_MANAGE" },
    };

    [Theory]
    [MemberData(nameof(Endpoints))]
    public void Each_endpoint_has_the_route_verb_and_permission_of_the_spec(string action, string verb, string template, string permission)
    {
        var type = typeof(AutoRosterController);
        Assert.Equal("api/roster/auto", type.GetCustomAttribute<RouteAttribute>()?.Template);

        var method = type.GetMethod(action)!;
        var http = Assert.Single(method.GetCustomAttributes<HttpMethodAttribute>());
        Assert.Equal(verb, Assert.Single(http.HttpMethods));
        Assert.Equal(template, http.Template);
        var permissions = type.GetCustomAttributes<HasPermissionAttribute>()
            .Concat(method.GetCustomAttributes<HasPermissionAttribute>())
            .Select(a => a.Policy!.Substring(HasPermissionAttribute.Prefix.Length));
        Assert.Equal(permission, Assert.Single(permissions));
    }

    [Fact]
    public void The_controller_has_exactly_the_seven_endpoints()
        => Assert.Equal(7, typeof(AutoRosterController)
            .GetMethods(BindingFlags.Public | BindingFlags.Instance | BindingFlags.DeclaredOnly)
            .Count(m => m.GetCustomAttributes<HttpMethodAttribute>().Any()));

    /// <summary>The existing roster endpoints are not touched: RosterController is still built from (IRosterService, ILiveNotifier).</summary>
    [Fact]
    public void RosterController_constructor_is_unchanged()
    {
        var ctor = Assert.Single(typeof(RosterController).GetConstructors());
        Assert.Equal(new[] { typeof(IRosterService), typeof(ILiveNotifier) }, ctor.GetParameters().Select(p => p.ParameterType));
    }

    /* ---- preview ---- */

    [Fact]
    public async Task Preview_never_notifies()
    {
        var (controller, auto, live) = Build();
        var preview = new AutoRosterPreview { BranchId = 1, MonthDate = new DateOnly(2026, 12, 1) };
        auto.Setup(a => a.PreviewAsync(It.IsAny<AutoRosterRequest>(), Caller)).ReturnsAsync(preview);

        var result = await controller.Preview(Request());

        Assert.Same(preview, Assert.IsType<OkObjectResult>(result).Value);
        live.VerifyNoOtherCalls();
    }

    [Fact]
    public async Task A_refused_preview_keeps_its_status_and_never_notifies()
    {
        var (controller, auto, live) = Build();
        auto.Setup(a => a.PreviewAsync(It.IsAny<AutoRosterRequest>(), Caller)).ThrowsAsync(WorkflowSqlErrors.MapMessage(NotYourBranch));

        AssertRefusal(await controller.Preview(Request()), 403, NotYourBranch);
        live.VerifyNoOtherCalls();
    }

    /* ---- commit ---- */

    [Fact]
    public async Task A_saved_commit_notifies_attendance_and_dashboard_once()
    {
        var (controller, auto, live) = Build();
        var saved = new AutoRosterCommitResult { RunId = 7, RowsInserted = 40, RowsUpdated = 2, RowsDeleted = 1 };
        auto.Setup(a => a.CommitAsync(It.IsAny<AutoRosterCommitRequest>(), Caller)).ReturnsAsync(saved);
        live.Setup(l => l.NotifyAsync("attendance", "dashboard")).Returns(Task.CompletedTask);

        var result = await controller.Commit(CommitRequest());

        Assert.Same(saved, Assert.IsType<OkObjectResult>(result).Value);
        live.Verify(l => l.NotifyAsync("attendance", "dashboard"), Times.Once);
        live.VerifyNoOtherCalls();
    }

    [Fact]
    public async Task A_draft_with_errors_is_a_400_with_the_issues_and_never_notifies()
    {
        var (controller, auto, live) = Build();
        var issues = new List<AutoRosterIssue>
        {
            new() { Severity = "error", Code = "REST_ON_HOLIDAY", EmployeeId = 3, Date = new DateOnly(2026, 12, 25), Message = "A rest day on Christmas." },
            new() { Severity = "warning", Code = "SHORT_STAFFED", Date = new DateOnly(2026, 12, 26), Message = "2 on duty, minimum 3." },
        };
        auto.Setup(a => a.CommitAsync(It.IsAny<AutoRosterCommitRequest>(), Caller))
            .ThrowsAsync(new AutoRosterRefusedException("The draft was not saved. A rest day on Christmas.", issues));

        var result = await controller.Commit(CommitRequest());

        var bad = Assert.IsType<BadRequestObjectResult>(result);
        Assert.Equal(400, bad.StatusCode);
        Assert.Equal("The draft was not saved. A rest day on Christmas.", Field(bad.Value, "error"));
        Assert.Same(issues, Field(bad.Value, "issues"));

        // The wire shape the web reads: camelCase, the date as yyyy-MM-dd.
        using var json = JsonDocument.Parse(JsonSerializer.Serialize(bad.Value, new JsonSerializerOptions(JsonSerializerDefaults.Web)));
        var first = json.RootElement.GetProperty("issues")[0];
        Assert.Equal("REST_ON_HOLIDAY", first.GetProperty("code").GetString());
        Assert.Equal("error", first.GetProperty("severity").GetString());
        Assert.Equal("2026-12-25", first.GetProperty("date").GetString());
        Assert.Equal(3, first.GetProperty("employeeId").GetInt32());

        live.VerifyNoOtherCalls();
    }

    [Theory]
    [InlineData(Stale, 409)]
    [InlineData(Pinned, 409)]
    [InlineData(NotYourBranch, 403)]
    [InlineData("Shift Old split is not active.", 400)]
    public async Task A_commit_the_procedure_refuses_keeps_its_status_and_never_notifies(string message, int status)
    {
        var (controller, auto, live) = Build();
        auto.Setup(a => a.CommitAsync(It.IsAny<AutoRosterCommitRequest>(), Caller)).ThrowsAsync(WorkflowSqlErrors.MapMessage(message));

        var result = await controller.Commit(CommitRequest());

        AssertRefusal(result, status, message);
        Assert.Null(Field(((ObjectResult)result).Value, "issues"));
        live.VerifyNoOtherCalls();
    }

    /* ---- reads ---- */

    [Fact]
    public async Task Setup_and_cells_read_for_the_caller_and_never_notify()
    {
        var (controller, auto, live) = Build();
        var setup = new AutoRosterSetup { BranchId = 1, MonthDate = new DateOnly(2026, 12, 1) };
        var cells = new[] { new RosterCellInfo { EmployeeId = 3, WorkDate = Day, IsPinned = true, IsAuto = true } };
        auto.Setup(a => a.GetSetupAsync(1, "2026-12", Caller)).ReturnsAsync(setup);
        auto.Setup(a => a.GetCellsAsync(1, new DateOnly(2026, 11, 30), new DateOnly(2027, 1, 3), Caller)).ReturnsAsync(cells);

        Assert.Same(setup, Assert.IsType<OkObjectResult>(await controller.GetSetup(1, "2026-12")).Value);
        Assert.Same(cells, Assert.IsType<OkObjectResult>(await controller.GetCells(1, new DateOnly(2026, 11, 30), new DateOnly(2027, 1, 3))).Value);
        auto.VerifyAll();
        live.VerifyNoOtherCalls();
    }

    [Fact]
    public async Task A_refused_read_keeps_its_status()
    {
        var (controller, auto, _) = Build();
        auto.Setup(a => a.GetSetupAsync(9, "2026-12", Caller)).ThrowsAsync(WorkflowSqlErrors.MapMessage(NotYourBranch));
        auto.Setup(a => a.GetCellsAsync(1, Day, Day.AddDays(-1), Caller)).ThrowsAsync(new WorkflowException(400, "'from' must be on or before 'to'."));

        AssertRefusal(await controller.GetSetup(9, "2026-12"), 403, NotYourBranch);
        AssertRefusal(await controller.GetCells(1, Day, Day.AddDays(-1)), 400, "'from' must be on or before 'to'.");
    }

    /* ---- the small writes: 204 and "attendance", or the refusal and silence ---- */

    [Fact]
    public async Task Pin_staffing_and_rhythm_answer_204_and_notify_attendance_once_each()
    {
        var (controller, auto, live) = Build();
        var pin = new RosterPinRequest { EmployeeId = 3, WorkDate = Day, IsPinned = true };
        var staffing = new List<StaffingRequirementDto> { new() { DayOfWeek = 6, MinOnDuty = 3 } };
        var rhythm = new List<RosterRhythmDto> { new() { EmployeeId = 3, OnRotation = false } };
        auto.Setup(a => a.SetPinAsync(pin, Caller)).Returns(Task.CompletedTask);
        auto.Setup(a => a.SaveStaffingAsync(1, staffing, Caller)).Returns(Task.CompletedTask);
        auto.Setup(a => a.SaveRhythmAsync(rhythm, Caller)).Returns(Task.CompletedTask);
        live.Setup(l => l.NotifyAsync("attendance")).Returns(Task.CompletedTask);

        Assert.IsType<NoContentResult>(await controller.SetPin(pin));
        Assert.IsType<NoContentResult>(await controller.SaveStaffing(1, staffing));
        Assert.IsType<NoContentResult>(await controller.SaveRhythm(rhythm));

        auto.VerifyAll();
        live.Verify(l => l.NotifyAsync("attendance"), Times.Exactly(3));
        live.VerifyNoOtherCalls();
    }

    [Fact]
    public async Task A_refused_small_write_keeps_its_status_and_never_notifies()
    {
        var (controller, auto, live) = Build();
        auto.Setup(a => a.SetPinAsync(It.IsAny<RosterPinRequest>(), Caller)).ThrowsAsync(WorkflowSqlErrors.MapMessage("Only a saved day can be pinned."));
        auto.Setup(a => a.SaveStaffingAsync(1, It.IsAny<IEnumerable<StaffingRequirementDto>>(), Caller))
            .ThrowsAsync(WorkflowSqlErrors.MapMessage("The target on duty cannot be below the minimum."));
        auto.Setup(a => a.SaveRhythmAsync(It.IsAny<IEnumerable<RosterRhythmDto>>(), Caller)).ThrowsAsync(WorkflowSqlErrors.MapMessage(NotYourBranch));

        AssertRefusal(await controller.SetPin(new RosterPinRequest { EmployeeId = 3, WorkDate = Day, IsPinned = true }), 400, "Only a saved day can be pinned.");
        AssertRefusal(await controller.SaveStaffing(1, [new() { MinOnDuty = 3, TargetOnDuty = 2 }]), 400, "The target on duty cannot be below the minimum.");
        AssertRefusal(await controller.SaveRhythm([new() { EmployeeId = 3, OnRotation = false }]), 403, NotYourBranch);
        live.VerifyNoOtherCalls();
    }
}
