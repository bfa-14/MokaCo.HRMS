using MokaCo.HRMS.Model.Booking;
using MokaCo.HRMS.Services.Booking;

namespace MokaCo.HRMS.Tests.Booking;

/// <summary>
/// The free-range computation and the month words, held to their stated rules. Everything is in
/// MINUTES FROM MIDNIGHT (BUG-23): a 01:00 close is 1500, and a 22:00–01:00 booking is 1320–1500.
/// </summary>
public class AvailabilityMathTests
{
    private static TakenRange Taken(int start, int end) => new() { StartMin = start, EndMin = end };

    private static string Print(IEnumerable<FreeRange> free)
        => string.Join(",", free.Select(f => $"{f.StartMin}-{f.EndMin}"));

    [Fact]
    public void Free_is_the_opening_hours_minus_the_taken_ranges()
    {
        var free = AvailabilityMath.FreeRanges(540, 1500, [Taken(600, 720), Taken(1320, 1500)], earliestStartMin: 540, minLength: 60);
        Assert.Equal("540-600,720-1320", Print(free));
    }

    [Fact]
    public void Turnaround_is_added_after_each_taken_range_only()
    {
        var free = AvailabilityMath.FreeRanges(540, 1500, [Taken(600, 720)], 540, 60, turnaroundMinutes: 5);
        Assert.Equal("540-600,725-1500", Print(free));
    }

    [Fact]
    public void Pieces_shorter_than_the_minimum_are_dropped()
    {
        // 540–600 is one hour; with a two-hour minimum it is useless and must not be offered.
        var free = AvailabilityMath.FreeRanges(540, 1500, [Taken(600, 720)], 540, minLength: 120);
        Assert.Equal("720-1500", Print(free));
    }

    [Fact]
    public void Overlapping_and_nested_taken_ranges_never_produce_a_backwards_gap()
    {
        var free = AvailabilityMath.FreeRanges(420, 1500, [Taken(600, 900), Taken(660, 720), Taken(840, 960)], 420, 60);
        Assert.Equal("420-600,960-1500", Print(free));
    }

    [Fact]
    public void A_fully_taken_day_has_no_free_time_and_a_free_day_is_one_range()
    {
        Assert.Empty(AvailabilityMath.FreeRanges(540, 1500, [Taken(540, 1500)], 540, 60));
        Assert.Equal("420-1500", Print(AvailabilityMath.FreeRanges(420, 1500, [], 420, 60)));
    }

    [Fact]
    public void Free_time_starts_at_the_earliest_start_not_the_opening()
    {
        var free = AvailabilityMath.FreeRanges(540, 1500, [Taken(1320, 1500)], earliestStartMin: 900, minLength: 60);
        Assert.Equal("900-1320", Print(free));
    }

    [Fact]
    public void Earliest_start_is_the_opening_on_another_day_and_the_lead_time_rounded_up_today()
    {
        var localNow = new DateTime(2026, 9, 18, 10, 20, 0);

        Assert.Equal(540, AvailabilityMath.EarliestStart(540, new DateTime(2026, 9, 19), localNow, leadMinHours: 1, slotMinutes: 60));
        // 10:20 + 1 h = 11:20 → rounded UP to 12:00 (720), never down to 11:00.
        Assert.Equal(720, AvailabilityMath.EarliestStart(540, new DateTime(2026, 9, 18), localNow, 1, 60));
        // Never before the opening time.
        Assert.Equal(900, AvailabilityMath.EarliestStart(900, new DateTime(2026, 9, 18), localNow, 1, 60));
        // Exactly on a slot boundary stays put.
        Assert.Equal(660, AvailabilityMath.EarliestStart(540, new DateTime(2026, 9, 18), new DateTime(2026, 9, 18, 10, 0, 0), 1, 60));
    }

    [Theory]
    [InlineData(61, 60, 120)]
    [InlineData(120, 60, 120)]
    [InlineData(0, 60, 0)]
    [InlineData(95, 30, 120)]
    [InlineData(95, 0, 95)]
    public void Rounding_up_to_the_slot(int minutes, int slot, int expected)
        => Assert.Equal(expected, AvailabilityMath.RoundUpToSlot(minutes, slot));

    [Fact]
    public void Derive_reports_a_day_outside_the_window_as_closed_with_no_free_time()
    {
        var day = new DayAvailability
        {
            OnDate = new DateTime(2026, 9, 10), LocalNow = new DateTime(2026, 9, 18, 12, 0, 0),
            IsClosed = false, OpenMin = 540, CloseMin = 1500, SlotMinutes = 60, MinHours = 1, LeadMinHours = 1, LeadMaxDays = 30,
        };
        AvailabilityMath.Derive(day);
        Assert.True(day.IsClosed);
        Assert.Empty(day.Free);

        day.OnDate = new DateTime(2026, 10, 30); day.IsClosed = false;
        AvailabilityMath.Derive(day);
        Assert.True(day.IsClosed);
        Assert.Empty(day.Free);
    }

    [Fact]
    public void Derive_fills_free_and_earliest_for_a_day_inside_the_window()
    {
        var day = new DayAvailability
        {
            OnDate = new DateTime(2026, 9, 29), LocalNow = new DateTime(2026, 9, 18, 12, 0, 0),
            IsClosed = false, OpenMin = 540, CloseMin = 1500, SlotMinutes = 60, MinHours = 1, LeadMinHours = 1, LeadMaxDays = 30,
            TurnaroundMinutes = 5,
            Taken = [Taken(1320, 1500)],
        };
        AvailabilityMath.Derive(day);
        Assert.False(day.IsClosed);
        Assert.Equal(540, day.EarliestStartMin);
        Assert.Equal("540-1320", Print(day.Free));
    }

    [Theory]
    [InlineData("2026-09-10", false, 900, 0, 900, "past")]
    [InlineData("2026-10-30", false, 900, 0, 900, "unavailable")]
    [InlineData("2026-09-20", true, 0, 0, 0, "closed")]
    [InlineData("2026-09-20", false, 0, 0, 0, "closed")]
    [InlineData("2026-09-20", false, 900, 850, 50, "full")]
    [InlineData("2026-09-20", false, 900, 120, 780, "partial")]
    [InlineData("2026-09-20", false, 900, 0, 900, "open")]
    public void Month_words_first_match_wins(string date, bool closed, int open, int taken, int maxFree, string expected)
    {
        var day = new MonthDayAvailability { OnDate = DateTime.Parse(date), IsClosed = closed, OpenMinutes = open, TakenMinutes = taken, MaxFreeRun = maxFree };
        var today = new DateTime(2026, 9, 18);

        Assert.Equal(expected, AvailabilityMath.StatusOf(day, today, today.AddDays(30), minMinutes: 60));
    }
}
