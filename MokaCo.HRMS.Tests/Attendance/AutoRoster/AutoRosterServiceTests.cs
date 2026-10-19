using Moq;
using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Repository.Attendance;
using MokaCo.HRMS.Services.Attendance;
using MokaCo.HRMS.Services.Attendance.AutoRoster;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Tests.Attendance.AutoRoster;

/// <summary>
/// The service around the planner, against a strict repository fed by <see cref="RosterWorld"/>: a
/// request that cannot be planned never reaches the database, a preview only reads, and a commit is
/// validated on the SUBMITTED cells laid over the rows as they stand — an error refuses the whole save
/// before the procedure is called; warnings are saved past and counted.
/// </summary>
public class AutoRosterServiceTests
{
    private const int Caller = 20;
    private static readonly DateOnly Dec = new(2026, 12, 1);
    private static readonly DateOnly Christmas = new(2026, 12, 25);

    private sealed record Saved(
        int BranchId, DateOnly MonthDate, string Mode, List<AutoRosterCommitCell> Cells, List<AutoRosterCommitRhythm> Rhythm,
        string? ParamsJson, int IssueCount, int? Caller);

    private sealed class Harness
    {
        public RosterWorld World { get; }
        public Mock<IAutoRosterRepository> Repo { get; } = new(MockBehavior.Strict);
        public AutoRosterService Service { get; }
        public Saved? LastSave { get; private set; }

        public Harness(RosterWorld world)
        {
            World = world;
            // Re-read on every call, as the procedure would: a commit sees the rows as they are NOW.
            Repo.Setup(r => r.GetContextAsync(RosterWorld.Branch, Dec, null, Caller)).ReturnsAsync(() => world.Context(Dec));
            Repo.Setup(r => r.CommitAsync(RosterWorld.Branch, Dec, It.IsAny<string>(), It.IsAny<IEnumerable<AutoRosterCommitCell>>(),
                    It.IsAny<IEnumerable<AutoRosterCommitRhythm>>(), It.IsAny<string?>(), It.IsAny<int>(), Caller))
                .Callback<int, DateOnly, string, IEnumerable<AutoRosterCommitCell>, IEnumerable<AutoRosterCommitRhythm>, string?, int, int?>(
                    (b, m, mode, cells, rhythm, p, n, c) => LastSave = new Saved(b, m, mode, cells.ToList(), rhythm.ToList(), p, n, c))
                .ReturnsAsync(new AutoRosterCommitResult { RunId = 7, RowsInserted = 3 });
            Service = new AutoRosterService(Repo.Object);
        }

        public async Task<(AutoRosterRequest Request, AutoRosterPreview Preview, AutoRosterCommitRequest Commit)> PreviewAsync(
            Action<AutoRosterRequest>? configure = null)
        {
            var request = World.Request(Dec);
            configure?.Invoke(request);
            var preview = await Service.PreviewAsync(request, Caller);
            return (request, preview, RosterWorld.CommitRequestFor(request, preview));
        }
    }

    private static Harness With(int staff, Action<RosterWorld>? setup = null)
    {
        var world = new RosterWorld().WithStaff(staff);
        setup?.Invoke(world);
        return new Harness(world);
    }

    private static void Set(AutoRosterCommitRequest commit, int e, DateOnly d, int? shift, bool rest = false)
    {
        commit.Cells.RemoveAll(c => c.EmployeeId == e && c.WorkDate == d);
        commit.Cells.Add(new AutoRosterCommitCell
        {
            EmployeeId = e, WorkDate = d, ShiftId = shift, IsRestDay = rest, Action = "upsert", Expected = new RosterCellExpected(),
        });
    }

    /* ---- the request ---- */

    [Theory]
    [InlineData("12/2026", "FillEmpty", "The month must look like 2026-12.")]
    [InlineData("2026-12", "Everything", "Choose a real mode.")]
    public async Task A_request_that_cannot_be_planned_is_a_400_before_the_database(string month, string mode, string sentence)
    {
        var h = With(3);
        var request = new AutoRosterRequest { BranchId = RosterWorld.Branch, Month = month, Mode = mode };

        var preview = await Assert.ThrowsAsync<WorkflowException>(() => h.Service.PreviewAsync(request, Caller));
        var commit = await Assert.ThrowsAsync<WorkflowException>(() => h.Service.CommitAsync(
            new AutoRosterCommitRequest { BranchId = RosterWorld.Branch, Month = month, Mode = mode }, Caller));

        Assert.Equal((400, sentence), (preview.StatusCode, preview.Message));
        Assert.Equal((400, sentence), (commit.StatusCode, commit.Message));
        h.Repo.VerifyNoOtherCalls();
    }

    /// <summary>"draftCells": null in a JSON body is not a reason for a 500: the lists are read as empty.</summary>
    [Fact]
    public async Task Null_lists_in_the_body_are_read_as_empty()
    {
        var h = With(3);
        var request = h.World.Request(Dec);
        request.DraftCells = null!;
        request.HolidayCover = null!;
        request.RhythmOverrides = null!;

        var preview = await h.Service.PreviewAsync(request, Caller);

        Assert.NotEmpty(preview.Cells);
    }

    /* ---- preview ---- */

    [Fact]
    public async Task Preview_is_the_planners_draft_of_the_context_and_writes_nothing()
    {
        var h = With(5);

        var (request, preview, _) = await h.PreviewAsync();
        var direct = RosterPlanner.Preview(AutoRosterInputFactory.Create(h.World.Context(Dec), request));

        Assert.Equal(direct.Summary.Inserts, preview.Summary.Inserts);
        Assert.True(preview.Summary.Inserts > 0);
        Assert.Equal(
            direct.Cells.Select(c => (c.EmployeeId, c.WorkDate, c.State, c.ShiftId, c.Change)),
            preview.Cells.Select(c => (c.EmployeeId, c.WorkDate, c.State, c.ShiftId, c.Change)));
        h.Repo.Verify(r => r.GetContextAsync(RosterWorld.Branch, Dec, null, Caller), Times.Once);
        h.Repo.VerifyNoOtherCalls();
    }

    /* ---- commit ---- */

    [Fact]
    public async Task The_unedited_preview_is_saved_with_its_cells_rhythm_mode_and_parameters()
    {
        var h = With(4);
        var (_, preview, commit) = await h.PreviewAsync(r => r.DraftCells.Add(new DraftCellDto
        {
            EmployeeId = 2, WorkDate = new DateOnly(2026, 12, 9), ShiftId = RosterWorld.Morning,
        }));
        commit.Mode = "fillempty";      // however the client spells it, the run row gets the real name

        var result = await h.Service.CommitAsync(commit, Caller);

        Assert.Equal(7, result.RunId);
        var saved = Assert.IsType<Saved>(h.LastSave);
        Assert.Equal((RosterWorld.Branch, Dec, "FillEmpty", (int?)Caller), (saved.BranchId, saved.MonthDate, saved.Mode, saved.Caller));
        Assert.Equal(commit.Cells, saved.Cells);
        Assert.Equal(commit.Rhythm, saved.Rhythm);
        Assert.Equal(preview.Summary.Inserts, saved.Cells.Count(c => c.Action == "upsert" && !c.Expected.Exists));

        // The run remembers the drawer's choices, never one preview's draft edits nor the cells.
        Assert.NotNull(saved.ParamsJson);
        Assert.Contains("\"month\":\"2026-12\"", saved.ParamsJson);
        Assert.DoesNotContain("workDate", saved.ParamsJson);

        var expectedIssues = RosterPlanValidator.ValidateSubmission(
            AutoRosterInputFactory.Create(h.World.Context(Dec), commit), commit.Cells, commit.Rhythm);
        Assert.Equal(expectedIssues.Count, saved.IssueCount);
    }

    /// <summary>
    /// The rows hold nothing on Christmas; only the SUBMITTED rest is wrong. The validator must see the
    /// cells laid over the rows, or this would sail through to the procedure.
    /// </summary>
    [Fact]
    public async Task A_submitted_rest_on_a_holiday_refuses_the_save_with_the_issues()
    {
        var h = With(3, w => w.Holiday(Christmas, "Christmas"));
        var (_, _, commit) = await h.PreviewAsync();
        Set(commit, 1, Christmas, null, rest: true);

        var ex = await Assert.ThrowsAsync<AutoRosterRefusedException>(() => h.Service.CommitAsync(commit, Caller));

        Assert.Equal(400, ex.StatusCode);
        Assert.StartsWith("The draft was not saved.", ex.Message);
        var issue = Assert.Single(ex.Issues, i => i.Severity == "error");
        Assert.Equal(("REST_ON_HOLIDAY", (int?)1, (DateOnly?)Christmas), (issue.Code, issue.EmployeeId, issue.Date));
        Assert.Null(h.LastSave);
        h.Repo.Verify(r => r.CommitAsync(It.IsAny<int>(), It.IsAny<DateOnly>(), It.IsAny<string>(), It.IsAny<IEnumerable<AutoRosterCommitCell>>(),
            It.IsAny<IEnumerable<AutoRosterCommitRhythm>>(), It.IsAny<string?>(), It.IsAny<int>(), It.IsAny<int?>()), Times.Never);
    }

    [Fact]
    public async Task A_working_day_without_a_shift_refuses_the_save()
    {
        var h = With(3);
        var (_, _, commit) = await h.PreviewAsync();
        Set(commit, 2, new DateOnly(2026, 12, 9), null);

        var ex = await Assert.ThrowsAsync<AutoRosterRefusedException>(() => h.Service.CommitAsync(commit, Caller));

        Assert.Contains(ex.Issues, i => i.Code == "WORK_WITHOUT_SHIFT" && i.Severity == "error" && i.EmployeeId == 2);
        Assert.Null(h.LastSave);
    }

    /// <summary>The planner's own draft never breaks the cap; an edit that works every rest day does, and it is the edit that is refused.</summary>
    [Fact]
    public async Task Edits_that_break_the_consecutive_cap_refuse_the_save_and_name_every_error()
    {
        var h = With(3);
        var (_, preview, commit) = await h.PreviewAsync();
        Assert.DoesNotContain(preview.Issues, i => i.Severity == "error");
        foreach (var rest in commit.Cells.Where(c => c.EmployeeId == 1 && c.IsRestDay).ToList())
            Set(commit, 1, rest.WorkDate, RosterWorld.Day);

        var ex = await Assert.ThrowsAsync<AutoRosterRefusedException>(() => h.Service.CommitAsync(commit, Caller));

        Assert.Contains(ex.Issues, i => i.Code == "CONSECUTIVE_CAP" && i.Severity == "error" && i.EmployeeId == 1);
        var errors = ex.Issues.Count(i => i.Severity == "error");
        Assert.StartsWith(errors == 1 ? "The draft was not saved." : $"The draft was not saved: {errors} errors.", ex.Message);
        Assert.Null(h.LastSave);
    }

    /// <summary>Rest days beat staffing (D8): a minimum nobody can meet is a warning, and warnings never block.</summary>
    [Fact]
    public async Task Warnings_are_saved_past_and_counted()
    {
        var h = With(3, w => w.Min(5));
        var (_, preview, commit) = await h.PreviewAsync();
        Assert.Contains(preview.Issues, i => i.Code == "SHORT_STAFFED" && i.Severity == "warning");

        await h.Service.CommitAsync(commit, Caller);

        var saved = Assert.IsType<Saved>(h.LastSave);
        Assert.True(saved.IssueCount > 0);
    }

    /// <summary>§2.7 MONTH_LOCKED is an error like any other: a 400 with the issue, the procedure never called.</summary>
    [Fact]
    public async Task A_month_waiting_for_approval_is_refused_before_the_procedure()
    {
        var h = With(3);
        var (_, _, commit) = await h.PreviewAsync();
        h.World.OpenRequestId = 123;

        var ex = await Assert.ThrowsAsync<AutoRosterRefusedException>(() => h.Service.CommitAsync(commit, Caller));

        Assert.Contains(ex.Issues, i => i.Code == "MONTH_LOCKED" && i.Severity == "error");
        Assert.Null(h.LastSave);
    }

    /* ---- setup and the small calls ---- */

    [Fact]
    public async Task Setup_reads_the_context_of_the_month_asked_for()
    {
        var h = With(3);
        h.World.Anchor(2, new DateOnly(2026, 11, 30), 5);

        var setup = await h.Service.GetSetupAsync(RosterWorld.Branch, "2026-12", Caller);

        Assert.Equal((RosterWorld.Branch, Dec), (setup.BranchId, setup.MonthDate));
        Assert.Equal(new[] { 1, 2, 3 }, setup.Staff.Select(s => s.EmployeeId));
        Assert.Equal(5, setup.Staff.Single(s => s.EmployeeId == 2).FirstWeekWorkDays);
        Assert.Equal(new DateOnly(2026, 11, 30), setup.Staff.Single(s => s.EmployeeId == 2).AnchorWeekStart);
        Assert.Contains(setup.Shifts, s => s.ShiftId == RosterWorld.Day);
        Assert.DoesNotContain(setup.Shifts, s => s.ShiftId == RosterWorld.Retired);
    }

    [Theory]
    [InlineData(0, "2026-12", "Choose a branch.")]
    [InlineData(RosterWorld.Branch, "December", "The month must look like 2026-12.")]
    [InlineData(RosterWorld.Branch, null, "The month must look like 2026-12.")]
    public async Task Setup_refuses_a_missing_branch_or_month_before_the_database(int branchId, string? month, string sentence)
    {
        var h = With(1);

        var ex = await Assert.ThrowsAsync<WorkflowException>(() => h.Service.GetSetupAsync(branchId, month, Caller));

        Assert.Equal((400, sentence), (ex.StatusCode, ex.Message));
        h.Repo.VerifyNoOtherCalls();
    }

    [Fact]
    public async Task Cells_need_from_on_or_before_to()
    {
        var repo = new Mock<IAutoRosterRepository>(MockBehavior.Strict);
        var service = new AutoRosterService(repo.Object);

        var ex = await Assert.ThrowsAsync<WorkflowException>(() =>
            service.GetCellsAsync(RosterWorld.Branch, new DateOnly(2026, 12, 31), new DateOnly(2026, 12, 1), Caller));

        Assert.Equal(400, ex.StatusCode);
        repo.VerifyNoOtherCalls();
    }

    [Fact]
    public async Task Pin_staffing_rhythm_and_cells_pass_the_caller_through()
    {
        var repo = new Mock<IAutoRosterRepository>(MockBehavior.Strict);
        var day = new DateOnly(2026, 12, 14);
        var staffing = new List<StaffingRequirementDto> { new() { DayOfWeek = 6, MinOnDuty = 3, TargetOnDuty = 4 } };
        var rhythm = new List<RosterRhythmDto> { new() { EmployeeId = 4, OnRotation = false } };
        repo.Setup(r => r.SetPinAsync(4, day, true, Caller)).Returns(Task.CompletedTask);
        repo.Setup(r => r.SaveStaffingAsync(RosterWorld.Branch, It.Is<IEnumerable<StaffingRequirementDto>>(x => x.Single().MinOnDuty == 3), Caller))
            .Returns(Task.CompletedTask);
        repo.Setup(r => r.SaveRhythmAsync(It.Is<IEnumerable<RosterRhythmDto>>(x => x.Single().EmployeeId == 4 && !x.Single().OnRotation), Caller))
            .Returns(Task.CompletedTask);
        repo.Setup(r => r.GetCellsAsync(RosterWorld.Branch, Dec, day, Caller))
            .ReturnsAsync(new[] { new RosterCellInfo { EmployeeId = 4, WorkDate = day, IsPinned = true } });
        repo.Setup(r => r.GetStaffingAsync(RosterWorld.Branch, Caller)).ReturnsAsync(staffing);
        var service = new AutoRosterService(repo.Object);

        await service.SetPinAsync(new RosterPinRequest { EmployeeId = 4, WorkDate = day, IsPinned = true }, Caller);
        await service.SaveStaffingAsync(RosterWorld.Branch, staffing, Caller);
        await service.SaveRhythmAsync(rhythm, Caller);
        var cells = await service.GetCellsAsync(RosterWorld.Branch, Dec, day, Caller);
        var read = await service.GetStaffingAsync(RosterWorld.Branch, Caller);

        Assert.True(Assert.Single(cells).IsPinned);
        Assert.Equal(3, Assert.Single(read).MinOnDuty);
        repo.VerifyAll();
    }

    [Fact]
    public async Task Staffing_needs_a_branch_and_a_list()
    {
        var repo = new Mock<IAutoRosterRepository>(MockBehavior.Strict);
        var service = new AutoRosterService(repo.Object);

        Assert.Equal(400, (await Assert.ThrowsAsync<WorkflowException>(() => service.SaveStaffingAsync(0, [], Caller))).StatusCode);
        Assert.Equal(400, (await Assert.ThrowsAsync<WorkflowException>(() => service.SaveStaffingAsync(1, null!, Caller))).StatusCode);
        repo.VerifyNoOtherCalls();
    }
}
