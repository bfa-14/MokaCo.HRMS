using MokaCo.HRMS.Services.Attendance.AutoRoster;

namespace MokaCo.HRMS.Tests.Attendance.AutoRoster;

/// <summary>D9: the fair-share "owed" balance, Saturday and Sunday kept apart.</summary>
public class WeekendLedgerTests
{
    private static readonly DateOnly Sat = new(2026, 11, 14);
    private static readonly DateOnly Sun = new(2026, 11, 15);

    [Fact]
    public void Everyone_in_the_pool_earns_the_share_and_whoever_rested_is_debited_one()
    {
        var ledger = new WeekendLedger();
        ledger.AddDay(Sat, [1, 2, 3, 4], [2]);

        Assert.Equal(0.25, ledger.Owed(1, DayOfWeek.Saturday), 9);
        Assert.Equal(-0.75, ledger.Owed(2, DayOfWeek.Saturday), 9);
        Assert.Equal(0, ledger.Owed(1, DayOfWeek.Sunday), 9);
        Assert.Equal(1, ledger.Rested(2, DayOfWeek.Saturday));
        Assert.Equal(-0.75, ledger.OwedTotal(2), 9);
    }

    [Fact]
    public void Saturday_and_Sunday_are_separate_balances()
    {
        var ledger = new WeekendLedger();
        ledger.AddDay(Sat, [1, 2], [1]);
        ledger.AddDay(Sun, [1, 2], [2]);

        Assert.Equal(-0.5, ledger.Owed(1, DayOfWeek.Saturday), 9);
        Assert.Equal(0.5, ledger.Owed(1, DayOfWeek.Sunday), 9);
        Assert.Equal(0, ledger.OwedTotal(1), 9);
    }

    [Fact]
    public void Someone_outside_the_pool_neither_earns_nor_loses_and_an_empty_pool_changes_nothing()
    {
        var ledger = new WeekendLedger();
        ledger.AddDay(Sat, [1, 2], [2, 3]);   // 3 was not in the pool (on leave, say): ignored
        ledger.AddDay(Sun, [], [1]);

        Assert.Equal(0, ledger.Owed(3, DayOfWeek.Saturday), 9);
        Assert.Equal(0.5, ledger.Owed(1, DayOfWeek.Saturday), 9);
        Assert.Equal(0, ledger.Owed(1, DayOfWeek.Sunday), 9);
    }

    [Fact]
    public void Only_weekend_days_count()
        => Assert.Throws<ArgumentException>(() => new WeekendLedger().AddDay(new DateOnly(2026, 11, 13), [1], [1]));

    [Fact]
    public void Equal_balances_reached_by_different_sums_tie_for_ordering()
    {
        var a = Enumerable.Repeat(1 / 7.0, 7).Sum();
        Assert.NotEqual(1.0, a);   // floating point: 0.9999999999999998
        Assert.Equal(WeekendLedger.Key(1.0), WeekendLedger.Key(a));
    }

    [Fact]
    public void History_counts_only_this_branchs_weekends_within_the_lookback_and_tracks_worked_weekends()
    {
        var world = new RosterWorld();
        world.Add(1);
        world.Add(2);
        world.Move(2, new DateOnly(2026, 11, 9), RosterWorld.OtherBranch);
        world.Move(2, new DateOnly(2026, 11, 16), RosterWorld.Branch);   // away for the week of 9 Nov
        world.LookbackWeeks = 2;                                          // the window opens 30 Nov: 16 Nov onward

        foreach (var d in new[] { new DateOnly(2026, 11, 14), new DateOnly(2026, 11, 21), new DateOnly(2026, 11, 28) })
        {
            world.Rest(2, d);
            world.Work(1, d);
            world.Work(1, d.AddDays(1));
            world.Work(2, d.AddDays(1));
        }

        var input = AutoRosterInputFactory.Create(world.Context(new DateOnly(2026, 12, 1)), world.Request(new DateOnly(2026, 12, 1)));
        var streaks = new Dictionary<int, int>();
        var ledger = WeekendLedger.FromHistory(input, [1, 2], streaks);

        // Two Saturdays (21, 28 Nov) in the lookback; 14 Nov is older (and in the other branch anyway).
        Assert.Equal(2, ledger.Rested(2, DayOfWeek.Saturday));
        Assert.Equal(1.0, ledger.Owed(1, DayOfWeek.Saturday), 9);
        Assert.Equal(2, streaks[1]);   // worked both weekends
        Assert.Equal(0, streaks[2]);
    }
}
