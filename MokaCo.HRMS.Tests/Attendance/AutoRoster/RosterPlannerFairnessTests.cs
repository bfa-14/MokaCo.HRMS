using MokaCo.HRMS.Services.Attendance.AutoRoster;
using Xunit.Abstractions;

namespace MokaCo.HRMS.Tests.Attendance.AutoRoster;

/// <summary>D9 / §2.5 step 4: Saturdays and Sundays off shared by the fair-share "owed" balance, across months and from history.</summary>
public class RosterPlannerFairnessTests
{
    private readonly ITestOutputHelper _out;
    public RosterPlannerFairnessTests(ITestOutputHelper output) => _out = output;

    private static readonly DateOnly[] NovDecJan = [new(2026, 11, 1), new(2026, 12, 1), new(2027, 1, 1)];

    private (int[] Saturdays, int[] Sundays) Count(RosterWorld world, int size, DateOnly from, DateOnly to)
    {
        var sat = new int[size];
        var sun = new int[size];
        for (var e = 1; e <= size; e++)
        {
            foreach (var d in RosterCalendar.Days(from, to))
            {
                if (!world.IsRest(e, d)) continue;
                if (d.DayOfWeek == DayOfWeek.Saturday) sat[e - 1]++;
                if (d.DayOfWeek == DayOfWeek.Sunday) sun[e - 1]++;
            }
        }
        _out.WriteLine($"Sat: {string.Join(",", sat)}  Sun: {string.Join(",", sun)}");
        return (sat, sun);
    }

    [Theory]
    [InlineData(7, "Aligned")]
    [InlineData(8, "Aligned")]
    [InlineData(7, "Staggered")]
    [InlineData(8, "Staggered")]
    public void Equal_people_over_13_weeks_share_Saturdays_and_Sundays_within_one(int size, string start)
    {
        var world = new RosterWorld().WithStaff(size);
        foreach (var month in NovDecJan)
        {
            var (run, issues) = world.PlanAndCommit(month, "FillEmpty", r => r.RhythmStart = start);
            Assert.Empty(run.Preview.Errors());
            Assert.DoesNotContain(issues, i => i.Severity == "error");
        }

        // Every saved weekend day, 1 Nov 2026 – 31 Jan 2027: 13 complete weeks plus Sun 1 Nov — the
        // same rows the ledger reads (26–31 Oct were ghosts, never saved).
        var (sat, sun) = Count(world, size, new DateOnly(2026, 11, 1), new DateOnly(2027, 1, 31));
        Assert.True(sat.Max() - sat.Min() <= 1, $"Saturday spread {sat.Max() - sat.Min()}");
        Assert.True(sun.Max() - sun.Min() <= 1, $"Sunday spread {sun.Max() - sun.Min()}");
    }

    [Theory]
    [InlineData(7)]
    [InlineData(8)]
    public void Over_8_weeks_the_spread_is_already_within_one(int size)
    {
        var world = new RosterWorld().WithStaff(size);
        world.PlanAndCommit(new DateOnly(2026, 11, 1));
        world.PlanAndCommit(new DateOnly(2026, 12, 1));

        // 1 Nov – 27 Dec: 8 complete weeks (and Sun 1 Nov).
        var (sat, sun) = Count(world, size, new DateOnly(2026, 11, 1), new DateOnly(2026, 12, 27));
        Assert.True(sat.Max() - sat.Min() <= 1);
        Assert.True(sun.Max() - sun.Min() <= 1);
    }

    private static void History(RosterWorld world, DateOnly windowFrom, int weeks, Func<int, DateOnly, bool> rests)
    {
        for (var d = windowFrom.AddDays(-7 * weeks); d < windowFrom; d = d.AddDays(1))
            foreach (var e in world.People.Keys)
            {
                if (rests(e, d)) world.Rest(e, d);
                else world.Work(e, d);
            }
    }

    [Fact]
    public void History_counts_someone_who_rested_every_Sunday_waits_while_the_others_catch_up()
    {
        var world = new RosterWorld().WithStaff(6);
        // Ten weeks before the November window: employee 1 rested every Sunday, the others on a weekday.
        History(world, new DateOnly(2026, 10, 26), 10,
            (e, d) => e == 1 ? d.DayOfWeek == DayOfWeek.Sunday : RosterCalendar.IsoDayOfWeek(d) == e - 1);

        var (nov, _) = world.PlanAndCommit(new DateOnly(2026, 11, 1));
        world.PlanAndCommit(new DateOnly(2026, 12, 1));

        // Two months on, employee 1 has still had no Sunday off: every one went to the others, and
        // evenly among them (within one).
        var sundays = RosterCalendar.Days(new DateOnly(2026, 11, 1), new DateOnly(2026, 12, 31)).Where(d => d.DayOfWeek == DayOfWeek.Sunday).ToList();
        Assert.DoesNotContain(sundays, d => world.IsRest(1, d));
        var others = Enumerable.Range(2, 5).Select(e => sundays.Count(d => world.IsRest(e, d))).ToList();
        Assert.True(others.Sum() >= 3);
        Assert.True(others.Max() - others.Min() <= 1);

        var counters = nov.Preview.PerEmployee.ToDictionary(c => c.EmployeeId);
        Assert.Equal(0, counters[1].SundaysOff);
        Assert.True(counters[1].OwedSunday < counters.Values.Where(c => c.EmployeeId != 1).Min(c => c.OwedSunday));

        // Saturdays are a separate balance: nobody rested one, so employee 1 is not held back there.
        Assert.True(counters[1].SaturdaysOff >= counters.Values.Min(c => c.SaturdaysOff));
    }

    [Fact]
    public void Someone_who_worked_every_weekend_in_history_is_the_first_to_get_one()
    {
        var world = new RosterWorld().WithStaff(6);
        // Employees 2–6 took turns on Saturdays and Sundays; employee 1 worked every weekend and rested on Fridays.
        History(world, new DateOnly(2026, 10, 26), 10, (e, d) =>
        {
            var week = RosterCalendar.WeekIndex(d);
            return e == 1
                ? d.DayOfWeek == DayOfWeek.Friday
                : (d.DayOfWeek == DayOfWeek.Saturday && RosterCalendar.Mod(week, 5) == e - 2)
                  || (d.DayOfWeek == DayOfWeek.Sunday && RosterCalendar.Mod(week + 2, 5) == e - 2)
                  || (d.DayOfWeek == DayOfWeek.Wednesday && RosterCalendar.Mod(week, 5) != e - 2 && RosterCalendar.Mod(week + 2, 5) != e - 2);
        });

        var p = world.Plan(new DateOnly(2026, 11, 1)).Preview;

        // The first weekend of the window (Sat 31 Oct is a ghost, Sun 1 Nov) goes to employee 1.
        var firstWeekend = p.Cells.Where(c => c.EmployeeId == 1 && c.WorkDate >= new DateOnly(2026, 10, 31) && c.WorkDate <= new DateOnly(2026, 11, 1));
        Assert.Contains(firstWeekend, c => c.State == "rest" && c.ReasonCode == "REST_WEEKEND_OWED");
        var counters = p.PerEmployee.ToDictionary(c => c.EmployeeId);
        Assert.True(counters[1].SaturdaysOff + counters[1].SundaysOff >= counters.Values.Max(c => c.SaturdaysOff + c.SundaysOff) - 1);
    }
}
