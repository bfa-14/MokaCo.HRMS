using System.Reflection;
using Dapper;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Routing;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Logging;
using Moq;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Api.Controllers;
using MokaCo.HRMS.Api.Hubs;
using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Repository.Attendance;
using MokaCo.HRMS.Repository.Common;
using MokaCo.HRMS.Services.Attendance;
using MokaCo.HRMS.Services.Core;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Tests.Attendance;

/// <summary>
/// Script 123's shift leaders through the API: the service turns the procedure's rows into the branch's own list and
/// everybody who counts as a leader, sends each person once, and says plainly (503) when the script is missing; the
/// controller has the rotation's routes and permissions and answers a save with the list as stored. Against a real
/// database (skipped without one): the three procedures bind and map, and the planning context carries the dated
/// shift hours and the leaders.
/// </summary>
[Collection(DatabaseCollection.Name)]
public class RosterLeadersTests
{
    private const int Caller = 20;
    private const string NotYourBranch = "You can only plan rosters for the branches you manage.";

    private static readonly IReadOnlyList<RosterLeaderDto> Rows =
    [
        new() { EmployeeId = 4, FullName = "Amal", IsStored = true, LeadSlot = "L2" },
        new() { EmployeeId = 7, FullName = "Bilal", IsStored = true },
        new() { EmployeeId = 9, FullName = "Carla", IsStored = false, LeadSlot = "L1" },
    ];

    private static object? Field(object? value, string name) => value?.GetType().GetProperty(name)?.GetValue(value);

    private static MissingScriptException Missing(string procedure) => new(Scripts.RosterLeaders123, procedure, MissingScriptException.ProcedureNotFound);

    /// <summary>Keeps every line it was asked to log, with its level.</summary>
    private sealed class ListLogger<T> : ILogger<T>
    {
        public List<(LogLevel Level, string Text)> Lines { get; } = [];
        public IEnumerable<string> Warnings => Lines.Where(l => l.Level == LogLevel.Warning).Select(l => l.Text);
        public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;
        public bool IsEnabled(LogLevel logLevel) => true;
        public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception, Func<TState, Exception?, string> formatter)
            => Lines.Add((logLevel, formatter(state, exception)));
    }

    /* ---- the service ---- */

    [Fact]
    public async Task The_read_splits_the_branchs_own_list_from_everybody_who_leads()
    {
        var repo = new Mock<IAutoRosterRepository>(MockBehavior.Strict);
        repo.Setup(r => r.GetLeadersAsync(3, Caller)).ReturnsAsync(Rows);

        var leaders = await new AutoRosterService(repo.Object).GetLeadersAsync(3, Caller);

        Assert.Equal(3, leaders.BranchId);
        Assert.Equal([4, 7], leaders.EmployeeIds);                                 // the picker: the stored list only
        Assert.Equal([4, 7, 9], leaders.Leaders.Select(l => l.EmployeeId));        // everybody kept apart, rotation leads too
        Assert.Equal("L1", leaders.Leaders.Single(l => l.EmployeeId == 9).LeadSlot);
    }

    [Fact]
    public async Task The_save_sends_each_person_once_for_the_branch_and_the_caller()
    {
        var repo = new Mock<IAutoRosterRepository>(MockBehavior.Strict);
        List<int>? sent = null;
        repo.Setup(r => r.SaveLeadersAsync(3, It.IsAny<IEnumerable<int>>(), Caller))
            .Callback<int, IEnumerable<int>, int?>((_, ids, _) => sent = ids.ToList())
            .Returns(Task.CompletedTask);

        await new AutoRosterService(repo.Object).SaveLeadersAsync(new RosterLeadersDto { BranchId = 3, EmployeeIds = [7, 4, 7] }, Caller);

        Assert.Equal([7, 4], sent);
    }

    [Fact]
    public async Task An_empty_list_clears_and_a_missing_one_is_empty()
    {
        var repo = new Mock<IAutoRosterRepository>(MockBehavior.Strict);
        var sends = new List<List<int>>();
        repo.Setup(r => r.SaveLeadersAsync(3, It.IsAny<IEnumerable<int>>(), Caller))
            .Callback<int, IEnumerable<int>, int?>((_, ids, _) => sends.Add(ids.ToList()))
            .Returns(Task.CompletedTask);
        var service = new AutoRosterService(repo.Object);

        await service.SaveLeadersAsync(new RosterLeadersDto { BranchId = 3, EmployeeIds = [] }, Caller);
        await service.SaveLeadersAsync(new RosterLeadersDto { BranchId = 3, EmployeeIds = null! }, Caller);

        Assert.Equal(2, sends.Count);
        Assert.All(sends, Assert.Empty);
    }

    [Theory]
    [InlineData(0, new[] { 4 }, "Choose a branch.")]
    [InlineData(3, new[] { 4, 0 }, "Every line of the shift leaders list needs its employee.")]
    public async Task A_request_that_cannot_be_saved_never_reaches_the_database(int branchId, int[] ids, string message)
    {
        var repo = new Mock<IAutoRosterRepository>(MockBehavior.Strict);     // any call fails the test

        var ex = await Assert.ThrowsAsync<WorkflowException>(() =>
            new AutoRosterService(repo.Object).SaveLeadersAsync(new RosterLeadersDto { BranchId = branchId, EmployeeIds = [.. ids] }, Caller));

        Assert.Equal(400, ex.StatusCode);
        Assert.Equal(message, ex.Message);
        await Assert.ThrowsAsync<WorkflowException>(() => new AutoRosterService(repo.Object).GetLeadersAsync(0, Caller));
    }

    [Fact]
    public async Task Without_script_123_the_read_and_the_save_say_so_plainly_and_the_log_names_the_script()
    {
        var repo = new Mock<IAutoRosterRepository>(MockBehavior.Strict);
        repo.Setup(r => r.GetLeadersAsync(3, Caller)).ThrowsAsync(Missing("attendance.usp_AutoRoster_GetLeaders"));
        repo.Setup(r => r.SaveLeadersAsync(3, It.IsAny<IEnumerable<int>>(), Caller)).ThrowsAsync(Missing("attendance.usp_AutoRoster_SaveLeaders"));
        var log = new ListLogger<MissingScriptWarning>();
        var service = new AutoRosterService(repo.Object, new MissingScriptWarning(log));

        var read = await Assert.ThrowsAsync<WorkflowException>(() => service.GetLeadersAsync(3, Caller));
        var save = await Assert.ThrowsAsync<WorkflowException>(() => service.SaveLeadersAsync(new RosterLeadersDto { BranchId = 3, EmployeeIds = [4] }, Caller));

        Assert.All(new[] { read, save }, ex =>
        {
            Assert.Equal(503, ex.StatusCode);
            Assert.Equal(AutoRosterService.LeadersNotAvailable, ex.Message);
        });
        // The manager reads the sentence in the drawer: no file, no script number, no database words.
        foreach (var jargon in new[] { "docs/", ".sql", "123", "script", "database", "procedure" })
            Assert.DoesNotContain(jargon, AutoRosterService.LeadersNotAvailable, StringComparison.OrdinalIgnoreCase);
        // The operator reads the server's log: one warning that names the file to apply.
        var warning = Assert.Single(log.Warnings);
        Assert.StartsWith($"DATABASE SCRIPT NOT APPLIED: {Scripts.RosterLeaders123}", warning);
        Assert.Contains("attendance.usp_AutoRoster_GetLeaders", warning);
    }

    [Theory]
    [InlineData(NotYourBranch, 403)]
    [InlineData("Lina Haddad is not in this branch: only its own people can be its shift leaders.", 400)]
    [InlineData("Somebody on the shift leaders list was not found.", 400)]
    [InlineData("The shift leaders list could not be read.", 400)]
    public void The_procedures_sentences_keep_their_text_and_get_their_status(string message, int status)
    {
        var ex = WorkflowSqlErrors.MapMessage(message);

        Assert.Equal(status, ex.StatusCode);
        Assert.Equal(message, ex.Message);
    }

    /* ---- the controller ---- */

    [Theory]
    [InlineData(nameof(AutoRosterController.GetLeaders), "GET", "ATTENDANCE_VIEW")]
    [InlineData(nameof(AutoRosterController.SaveLeaders), "PUT", "ATTENDANCE_MANAGE")]
    [InlineData(nameof(AutoRosterController.SaveRotation), "PUT", "ATTENDANCE_MANAGE")]   // the rotation they mirror
    public void The_leaders_endpoints_have_the_rotations_route_and_permissions(string action, string verb, string permission)
    {
        var type = typeof(AutoRosterController);
        Assert.Equal("api/roster/auto", type.GetCustomAttribute<RouteAttribute>()?.Template);

        var method = type.GetMethod(action)!;
        var http = Assert.Single(method.GetCustomAttributes<HttpMethodAttribute>());
        Assert.Equal(verb, Assert.Single(http.HttpMethods));
        Assert.Equal(action == nameof(AutoRosterController.SaveRotation) ? "rotation" : "leaders", http.Template);
        var permissions = method.GetCustomAttributes<HasPermissionAttribute>().Select(a => a.Policy!.Substring(HasPermissionAttribute.Prefix.Length));
        Assert.Equal(permission, Assert.Single(permissions));
    }

    private static (AutoRosterController Controller, Mock<IAutoRosterService> Auto, Mock<ILiveNotifier> Live) Build()
    {
        var auto = new Mock<IAutoRosterService>(MockBehavior.Strict);
        var live = new Mock<ILiveNotifier>(MockBehavior.Strict);
        return (new AutoRosterController(auto.Object, live.Object) { ControllerContext = TestPrincipal.For(userId: Caller) }, auto, live);
    }

    [Fact]
    public async Task A_save_answers_with_the_leaders_as_stored_and_tells_no_live_screen()
    {
        var (controller, auto, live) = Build();
        var body = new RosterLeadersDto { BranchId = 3, EmployeeIds = [4, 7] };
        var stored = new RosterLeadersDto { BranchId = 3, EmployeeIds = [4, 7], Leaders = [.. Rows] };
        var order = new List<string>();
        auto.Setup(a => a.SaveLeadersAsync(body, Caller)).Callback(() => order.Add("save")).Returns(Task.CompletedTask);
        auto.Setup(a => a.GetLeadersAsync(3, Caller)).Callback(() => order.Add("read")).ReturnsAsync(stored);

        var result = await controller.SaveLeaders(body);

        Assert.Same(stored, Assert.IsType<OkObjectResult>(result).Value);
        Assert.Equal(["save", "read"], order);
        live.VerifyNoOtherCalls();
    }

    [Fact]
    public async Task The_read_answers_for_the_caller()
    {
        var (controller, auto, live) = Build();
        var stored = new RosterLeadersDto { BranchId = 3, EmployeeIds = [4], Leaders = [Rows[0]] };
        auto.Setup(a => a.GetLeadersAsync(3, Caller)).ReturnsAsync(stored);

        Assert.Same(stored, Assert.IsType<OkObjectResult>(await controller.GetLeaders(3)).Value);
        live.VerifyNoOtherCalls();
    }

    [Fact]
    public async Task A_refusal_keeps_its_status_and_sentence_and_a_refused_save_reads_nothing()
    {
        var (controller, auto, _) = Build();
        auto.Setup(a => a.GetLeadersAsync(9, Caller)).ThrowsAsync(WorkflowSqlErrors.MapMessage(NotYourBranch));
        auto.Setup(a => a.SaveLeadersAsync(It.IsAny<RosterLeadersDto>(), Caller))
            .ThrowsAsync(new WorkflowException(503, AutoRosterService.LeadersNotAvailable));

        var read = Assert.IsAssignableFrom<ObjectResult>(await controller.GetLeaders(9));
        var save = Assert.IsAssignableFrom<ObjectResult>(await controller.SaveLeaders(new RosterLeadersDto { BranchId = 3, EmployeeIds = [4] }));

        Assert.Equal(403, read.StatusCode);
        Assert.Equal(NotYourBranch, Field(read.Value, "error"));
        Assert.Null(Field(read.Value, "code"));
        Assert.Equal(503, save.StatusCode);
        Assert.Equal(AutoRosterService.LeadersNotAvailable, Field(save.Value, "error"));
        // The code lets the web say it in the reader's language (a slow database is a 503 too, without it).
        Assert.Equal("leaders_not_ready", Field(save.Value, "code"));
        auto.Verify(a => a.GetLeadersAsync(3, It.IsAny<int?>()), Times.Never);
    }

    /* ---- against the database (script 123 applied), skipped without one ---- */

    private static AutoRosterRepository Repo() => new(new SqlConnectionFactory(DbFactAttribute.ConnectionString));

    private static async Task<List<string>> ColumnsOf(string procedure)
    {
        await using var db = new SqlConnection(DbFactAttribute.ConnectionString);
        return (await db.QueryAsync<string>(
            "SELECT name FROM sys.dm_exec_describe_first_result_set_for_object(OBJECT_ID(@p), 0) ORDER BY column_ordinal",
            new { p = procedure })).ToList();
    }

    [DbFact]
    public async Task The_procedures_give_exactly_the_columns_the_models_read()
    {
        Assert.Equal(["ShiftId", "EffectiveFrom", "StartTime", "EndTime", "CrossesMidnight", "BreakMinutes"],
            await ColumnsOf("attendance.usp_AutoRoster_GetShiftHours"));
        Assert.Equal(["EmployeeId", "FullName", "IsStored", "LeadSlot"], await ColumnsOf("attendance.usp_AutoRoster_GetLeaders"));
    }

    [DbFact]
    public async Task The_leaders_calls_bind_and_refuse_an_unknown_branch_by_its_sentence()
    {
        var read = await Assert.ThrowsAsync<SqlException>(() => Repo().GetLeadersAsync(-1, null));
        var save = await Assert.ThrowsAsync<SqlException>(() => Repo().SaveLeadersAsync(-1, [1, 2], null));

        Assert.Equal("Branch not found.", read.Errors[0].Message);
        Assert.Equal("Branch not found.", save.Errors[0].Message);
    }

    [DbFact]
    public async Task Every_shift_has_hours_in_force_and_they_map()
    {
        var rows = await Repo().GetShiftHoursAsync(new DateOnly(2026, 1, 1), new DateOnly(2026, 12, 31));

        await using var db = new SqlConnection(DbFactAttribute.ConnectionString);
        var shifts = (await db.QueryAsync<int>("SELECT ShiftId FROM attendance.SHIFT")).ToList();
        Assert.All(shifts, id => Assert.Contains(rows, r => r.ShiftId == id && r.EffectiveFrom <= new DateTime(2026, 1, 1)));
        Assert.All(rows, r => Assert.True(r.StartTime >= TimeSpan.Zero && r.StartTime < TimeSpan.FromDays(1) && r.BreakMinutes >= 0));
    }

    [DbFact]
    public async Task The_planning_context_carries_the_dated_hours_and_the_leaders()
    {
        await using var db = new SqlConnection(DbFactAttribute.ConnectionString);
        var branch = await db.QueryFirstOrDefaultAsync<int?>("SELECT TOP 1 BranchId FROM hr.BRANCH ORDER BY BranchId");
        Assert.NotNull(branch);

        var context = await Repo().GetContextAsync(branch.Value, new DateOnly(2026, 12, 1), 4, null);

        var leaders = await Repo().GetLeadersAsync(branch.Value, null);
        Assert.Equal(leaders.Select(l => l.EmployeeId).Order(), context.ShiftLeaders.Order());
        Assert.NotEmpty(context.ShiftHours);
        Assert.All(context.Shifts, s => Assert.Contains(context.ShiftHours,
            h => h.ShiftId == s.ShiftId && h.EffectiveFrom <= context.Header.HistoryFrom));
    }
}
