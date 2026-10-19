using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Services.Attendance.AutoRoster;

namespace MokaCo.HRMS.Tests.Attendance.AutoRoster;

/// <summary>
/// §2.7 on an arbitrary SUBMITTED grid — what the commit runs before it writes. The rows as they are,
/// the submitted cells on top, the same rules as the preview.
/// </summary>
public class RosterPlanValidatorTests
{
    private static readonly DateOnly Dec = new(2026, 12, 1);
    private static readonly DateOnly Mon14 = new(2026, 12, 14);

    private static (RosterWorld World, RosterWorld.Run Run, AutoRosterCommitRequest Commit) Clean(int staff = 3, Action<RosterWorld>? setup = null)
    {
        var world = new RosterWorld().WithStaff(staff);
        setup?.Invoke(world);
        var run = world.Plan(Dec);
        return (world, run, RosterWorld.CommitRequestFor(run.Request, run.Preview));
    }

    private static void Set(AutoRosterCommitRequest commit, int e, DateOnly d, int? shift, bool rest = false, string action = "upsert")
    {
        commit.Cells.RemoveAll(c => c.EmployeeId == e && c.WorkDate == d);
        commit.Cells.Add(new AutoRosterCommitCell { EmployeeId = e, WorkDate = d, ShiftId = shift, IsRestDay = rest, Action = action });
    }

    private static List<AutoRosterIssue> Validate(RosterWorld.Run run, AutoRosterCommitRequest commit)
        => RosterPlanValidator.ValidateSubmission(run.Input, commit.Cells, commit.Rhythm);

    [Fact]
    public void The_unedited_preview_validates_without_errors_or_rhythm_warnings()
    {
        var (_, run, commit) = Clean(5);
        var issues = Validate(run, commit);
        Assert.False(RosterPlanValidator.HasErrors(issues));
        Assert.DoesNotContain(issues, i => i.Code is "RHYTHM_SHORT" or "RHYTHM_OVER" or "CONSECUTIVE_CAP");
    }

    [Fact]
    public void A_rest_on_a_holiday_is_an_error()
    {
        var christmas = new DateOnly(2026, 12, 25);
        var (_, run, commit) = Clean(setup: w => w.Holiday(christmas, "Christmas"));
        Set(commit, 1, christmas, null, rest: true);

        var issue = Assert.Single(Validate(run, commit), i => i.Code == "REST_ON_HOLIDAY");
        Assert.Equal(("error", 1, (DateOnly?)christmas), (issue.Severity, issue.EmployeeId, issue.Date));
        Assert.Contains("Christmas", issue.Message);
    }

    [Theory]
    [InlineData(null)]
    [InlineData(RosterWorld.Retired)]
    [InlineData(99)]
    public void A_working_day_needs_an_active_shift(int? shift)
    {
        var (_, run, commit) = Clean();
        Set(commit, 2, new DateOnly(2026, 12, 9), shift);   // shift NULL + not rest = the (NULL, 0) row

        var issue = Assert.Single(Validate(run, commit), i => i.Code == "WORK_WITHOUT_SHIFT");
        Assert.Equal("error", issue.Severity);
    }

    [Fact]
    public void Eight_submitted_working_days_in_a_row_are_an_error()
    {
        var (_, run, commit) = Clean();
        Set(commit, 1, new DateOnly(2026, 12, 6), null, rest: true);
        foreach (var d in RosterCalendar.Days(new DateOnly(2026, 12, 7), new DateOnly(2026, 12, 14)))
            Set(commit, 1, d, RosterWorld.Day);

        var issue = Assert.Single(Validate(run, commit), i => i.Code == "CONSECUTIVE_CAP");
        Assert.Equal("error", issue.Severity);
        Assert.Equal(new DateOnly(2026, 12, 14), issue.Date);   // the first day past the cap
    }

    [Fact]
    public void A_run_of_existing_rows_the_commit_does_not_touch_is_only_a_warning()
    {
        var world = new RosterWorld().WithStaff(2);
        foreach (var d in RosterCalendar.Days(new DateOnly(2026, 12, 7), new DateOnly(2026, 12, 15)))
            world.Work(1, d);
        var run = world.Plan(Dec);
        var commit = RosterWorld.CommitRequestFor(run.Request, run.Preview);
        commit.Cells.RemoveAll(c => c.EmployeeId == 1);

        var issue = Assert.Single(Validate(run, commit), i => i.Code == "CONSECUTIVE_CAP");
        Assert.Equal("warning", issue.Severity);
    }

    [Fact]
    public void Ghost_days_are_open_so_a_month_end_week_is_neither_short_nor_too_long()
    {
        var (_, run, commit) = Clean(1);
        // The last week: Mon 28 – Thu 31 Dec in the month, 1–3 Jan ghosts nobody has decided yet.
        foreach (var d in RosterCalendar.Days(new DateOnly(2026, 12, 24), new DateOnly(2026, 12, 31)))
            Set(commit, 1, d, RosterWorld.Day);

        var issues = Validate(run, commit);
        Assert.DoesNotContain(issues, i => i.Code == "RHYTHM_SHORT" && i.Date >= new DateOnly(2026, 12, 28));
        // 24 Dec – 31 Dec is eight days in the month, though: that one is real.
        Assert.Contains(issues, i => i.Code == "CONSECUTIVE_CAP" && i.Severity == "error");
    }

    [Fact]
    public void Taking_a_rest_away_is_RHYTHM_SHORT_and_adding_one_is_RHYTHM_OVER()
    {
        var (_, run, commit) = Clean(1);
        var rests = commit.Cells.Where(c => c.IsRestDay && c.WorkDate >= Mon14 && c.WorkDate < Mon14.AddDays(7)).ToList();
        Set(commit, 1, rests[0].WorkDate, RosterWorld.Day);
        var shortIssue = Assert.Single(Validate(run, commit), i => i.Code == "RHYTHM_SHORT");
        Assert.Equal(("warning", (DateOnly?)Mon14), (shortIssue.Severity, shortIssue.Date));

        (_, run, commit) = Clean(1);
        var work = commit.Cells.First(c => !c.IsRestDay && c.WorkDate >= Mon14 && c.WorkDate < Mon14.AddDays(7));
        Set(commit, 1, work.WorkDate, null, rest: true);
        Assert.Contains(Validate(run, commit), i => i.Code == "RHYTHM_OVER" && i.Severity == "info");
    }

    [Fact]
    public void Evening_then_Morning_is_a_turnaround_warning()
    {
        var (_, run, commit) = Clean(1);
        var days = commit.Cells.Where(c => !c.IsRestDay).Select(c => c.WorkDate).Order().ToList();
        var pair = days.Zip(days.Skip(1)).First(p => p.Second == p.First.AddDays(1));
        Set(commit, 1, pair.First, RosterWorld.Evening);
        Set(commit, 1, pair.Second, RosterWorld.Morning);

        var issue = Assert.Single(Validate(run, commit), i => i.Code == "TURNAROUND");
        Assert.Equal("warning", issue.Severity);
        Assert.Contains("8 hours", issue.Message);
    }

    [Fact]
    public void A_weekly_rest_shorter_than_36_hours_is_a_warning()
    {
        var (_, run, commit) = Clean(1);
        // Mon 14 – Sat 19 at work, Saturday until 23:00, Sunday off, Monday from 07:00: 32 hours.
        foreach (var d in RosterCalendar.Days(Mon14, Mon14.AddDays(4)))
            Set(commit, 1, d, RosterWorld.Day);
        Set(commit, 1, Mon14.AddDays(5), RosterWorld.Evening);
        Set(commit, 1, Mon14.AddDays(6), null, rest: true);
        Set(commit, 1, Mon14.AddDays(7), RosterWorld.Morning);
        foreach (var d in RosterCalendar.Days(new DateOnly(2026, 12, 7), new DateOnly(2026, 12, 13)))
            Set(commit, 1, d, RosterWorld.Day, rest: d == new DateOnly(2026, 12, 13));

        var issues = Validate(run, commit);
        var weekly = Assert.Single(issues, i => i.Code == "WEEKLY_REST_HOURS" && i.Date == Mon14);
        Assert.Contains("32 hours", weekly.Message);
    }

    [Fact]
    public void A_waiting_approval_is_an_error_whatever_is_submitted()
    {
        var world = new RosterWorld { OpenRequestId = 12 }.WithStaff(1);
        var run = world.Plan(Dec);
        var issues = RosterPlanValidator.ValidateSubmission(run.Input, [new AutoRosterCommitCell { EmployeeId = 1, WorkDate = Mon14, ShiftId = RosterWorld.Day }]);
        Assert.Contains(issues, i => i.Code == "MONTH_LOCKED" && i.Severity == "error");
    }

    [Fact]
    public void Cells_outside_the_month_or_the_branch_are_left_to_the_procedure()
    {
        var (_, run, commit) = Clean(1);
        commit.Cells.Add(new AutoRosterCommitCell { EmployeeId = 1, WorkDate = new DateOnly(2027, 1, 2), IsRestDay = true });
        commit.Cells.Add(new AutoRosterCommitCell { EmployeeId = 42, WorkDate = Mon14, ShiftId = null });
        Assert.False(RosterPlanValidator.HasErrors(Validate(run, commit)));
    }

    [Fact]
    public void Off_rotation_in_the_commit_rhythm_switches_the_rhythm_checks_off()
    {
        var (_, run, commit) = Clean(1);
        foreach (var c in commit.Cells.Where(c => c.IsRestDay).ToList())
            Set(commit, 1, c.WorkDate, RosterWorld.Day);
        foreach (var d in RosterCalendar.Days(Dec, new DateOnly(2026, 12, 31)).Where(d => d.DayOfWeek == DayOfWeek.Sunday))
            Set(commit, 1, d, null, rest: true);   // keep the runs legal
        Assert.Contains(Validate(run, commit), i => i.Code == "RHYTHM_SHORT");

        commit.Rhythm = [new AutoRosterCommitRhythm { EmployeeId = 1, AnchorWeekStart = new DateOnly(2026, 11, 30), AnchorWorkDays = 6, OnRotation = false }];
        Assert.DoesNotContain(Validate(run, commit), i => i.Code == "RHYTHM_SHORT");
    }

    [Fact]
    public void Working_a_weekly_pattern_rest_day_is_info()
    {
        var (_, run, commit) = Clean(1, w => w.Patterns.Add(new AutoRosterPatternRow { EmployeeId = 1, DayOfWeek = 3, IsRestDay = true }));
        var wednesday = new DateOnly(2026, 12, 16);
        Set(commit, 1, wednesday, RosterWorld.Day);
        Assert.Contains(Validate(run, commit), i => i.Code == "PATTERN_REST_WORKED" && i.Date == wednesday && i.Severity == "info");
    }

    [Fact]
    public void Issues_are_sorted_errors_first_then_by_date()
    {
        var christmas = new DateOnly(2026, 12, 25);
        var (_, run, commit) = Clean(2, w => w.Holiday(christmas, "Christmas"));
        Set(commit, 1, christmas, null, rest: true);
        Set(commit, 2, new DateOnly(2026, 12, 2), null);
        var issues = Validate(run, commit);

        var ranks = issues.Select(i => i.Severity switch { "error" => 0, "warning" => 1, _ => 2 }).ToList();
        Assert.Equal(ranks.Order(), ranks);
        Assert.Equal("WORK_WITHOUT_SHIFT", issues[0].Code);   // 2 Dec before 25 Dec
    }
}
