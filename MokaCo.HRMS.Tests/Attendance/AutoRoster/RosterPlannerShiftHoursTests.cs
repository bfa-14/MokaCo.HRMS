using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Services.Attendance.AutoRoster;

namespace MokaCo.HRMS.Tests.Attendance.AutoRoster;

/// <summary>
/// R1 for rosters: the turnaround and weekly-rest maths read the hours in force ON each date (attendance.SHIFT_HOURS,
/// script 117, read through usp_AutoRoster_GetShiftHours), and today's hours when no dated version is known.
/// </summary>
public class RosterPlannerShiftHoursTests
{
    private static readonly DateOnly Dec = new(2026, 12, 1);

    [Fact]
    public void The_hours_in_force_on_a_date_are_the_latest_version_on_or_before_it()
    {
        var world = new RosterWorld().WithStaff(1);
        world.Hours(RosterWorld.Morning, new DateOnly(2000, 1, 1), 7, 15);
        world.Hours(RosterWorld.Morning, new DateOnly(2026, 12, 10), 11, 19);
        world.Hours(RosterWorld.Morning, new DateOnly(2026, 12, 10), 12, 20);   // a second version on one date: the first is kept
        world.Hours(99, new DateOnly(2026, 12, 1), 1, 2);                        // an unknown shift: ignored
        var input = world.Plan(Dec).Input;

        Assert.Equal(TimeSpan.FromHours(7), input.HoursOn(RosterWorld.Morning, new DateOnly(2026, 12, 9))!.StartTime);
        Assert.Equal(TimeSpan.FromHours(11), input.HoursOn(RosterWorld.Morning, new DateOnly(2026, 12, 10))!.StartTime);
        Assert.Equal(TimeSpan.FromHours(11), input.HoursOn(RosterWorld.Morning, new DateOnly(2027, 1, 3))!.StartTime);
        Assert.Equal("Morning", input.HoursOn(RosterWorld.Morning, new DateOnly(2026, 12, 10))!.Name);
        Assert.Equal(TimeSpan.FromHours(15), input.HoursOn(RosterWorld.Evening, new DateOnly(2026, 12, 10))!.StartTime);   // no version: today's
        Assert.Null(input.HoursOn(99, new DateOnly(2026, 12, 10)));
        Assert.Equal(2, input.ShiftHours[RosterWorld.Morning].Count);
    }

    [Fact]
    public void An_evening_then_a_morning_is_judged_with_that_mornings_hours()
    {
        // 23:00 → 07:00 is eight hours: a turnaround. From 10 December the morning starts at 11:00: twelve hours, none.
        static List<AutoRosterIssue> Check(RosterWorld world, DateOnly evening)
        {
            var run = world.Plan(Dec);
            var commit = RosterWorld.CommitRequestFor(run.Request, run.Preview);
            void Set(DateOnly d, int shift)
            {
                commit.Cells.RemoveAll(c => c.EmployeeId == 1 && c.WorkDate == d);
                commit.Cells.Add(new AutoRosterCommitCell { EmployeeId = 1, WorkDate = d, ShiftId = shift });
            }
            Set(evening, RosterWorld.Evening);
            Set(evening.AddDays(1), RosterWorld.Morning);
            return RosterPlanValidator.ValidateSubmission(run.Input, commit.Cells, commit.Rhythm)
                .Where(i => i.Code == "TURNAROUND" && i.EmployeeId == 1 && i.Date == evening.AddDays(1)).ToList();
        }

        var world = new RosterWorld { Today = new DateOnly(2026, 11, 1) }.WithStaff(2);
        world.Hours(RosterWorld.Morning, new DateOnly(2000, 1, 1), 7, 15);
        world.Hours(RosterWorld.Morning, new DateOnly(2026, 12, 10), 11, 19);

        Assert.Single(Check(world, new DateOnly(2026, 12, 2)));    // the morning of 3 December still starts at 07:00
        Assert.Empty(Check(world, new DateOnly(2026, 12, 9)));     // the morning of 10 December starts at 11:00

        world.ShiftHours.Clear();                                    // the script is missing: today's hours for every date
        Assert.Single(Check(world, new DateOnly(2026, 12, 9)));
    }
}
