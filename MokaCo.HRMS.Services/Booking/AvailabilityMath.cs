using MokaCo.HRMS.Model.Booking;

namespace MokaCo.HRMS.Services.Booking;

/// <summary>
/// The arithmetic the procedures deliberately leave to the caller: what is FREE once the taken time
/// is punched out of a day, the earliest start the lead time allows today, and the one word a
/// calendar paints a day with.
///
/// ARITHMETIC OVER THE DATABASE'S ANSWERS, never a second opinion about them. The slot size, the
/// minimum length, the lead times and the clock all arrive from the same procedure that will enforce
/// them at creation. What this produces is a hint for painting a form; a slot it calls free can
/// still be refused a millisecond later, and that refusal is the truth. Static and pure so the unit
/// tests can hold every line to its stated rule.
/// </summary>
public static class AvailabilityMath
{
    /// <summary>
    /// Fills in <see cref="DayAvailability.EarliestStartMin"/> and <see cref="DayAvailability.Free"/>.
    /// A day in the past, or further ahead than BookingLeadMaxDays, is reported CLOSED with no free
    /// time — "outside the window" is not a state the wizard has a colour for.
    /// </summary>
    public static void Derive(DayAvailability day)
    {
        var today = day.LocalNow.Date;
        var onDate = day.OnDate.Date;

        if (onDate < today || onDate > today.AddDays(day.LeadMaxDays)
            || day.IsClosed || day.OpenMin is not { } openMin || day.CloseMin is not { } closeMin)
        {
            day.IsClosed = true;
            day.Free = [];
            day.EarliestStartMin = day.OpenMin ?? 0;
            return;
        }

        day.EarliestStartMin = EarliestStart(openMin, onDate, day.LocalNow, day.LeadMinHours, day.SlotMinutes);
        day.Free = FreeRanges(openMin, closeMin, day.Taken, day.EarliestStartMin, day.MinHours * 60, day.TurnaroundMinutes);
    }

    /// <summary>
    /// Opening time on any other day; on TODAY, localNow + leadMinHours rounded UP to the next slot
    /// (never below the opening time). Rounding down would offer a start inside the lead time the
    /// procedure is about to refuse.
    /// </summary>
    public static int EarliestStart(int openMin, DateTime onDate, DateTime localNow, int leadMinHours, int slotMinutes)
    {
        if (onDate.Date != localNow.Date)
            return openMin;

        var earliest = RoundUpToSlot(localNow.Hour * 60 + localNow.Minute + leadMinHours * 60, slotMinutes);
        return Math.Max(openMin, earliest);
    }

    /// <summary>
    /// [openMin, closeMin) minus the taken ranges, with <paramref name="turnaroundMinutes"/> added
    /// after each taken range, trimmed to <paramref name="earliestStartMin"/>, pieces shorter than
    /// <paramref name="minLength"/> dropped.
    ///
    /// THE TAKEN LIST IS SORTED AND MERGED by a running maximum of the end, so overlapping or nested
    /// ranges (a booking inside a staff block is legal) never produce a gap running backwards.
    /// </summary>
    public static List<FreeRange> FreeRanges(
        int openMin, int closeMin, IEnumerable<TakenRange> taken, int earliestStartMin, int minLength, int turnaroundMinutes = 0)
    {
        var free = new List<FreeRange>();
        var cursor = Math.Max(openMin, earliestStartMin);
        var gap = Math.Max(0, turnaroundMinutes);

        foreach (var range in taken.OrderBy(t => t.StartMin).ThenBy(t => t.EndMin))
        {
            if (range.StartMin > cursor)
                Add(free, cursor, Math.Min(range.StartMin, closeMin), minLength);

            cursor = Math.Max(cursor, range.EndMin + gap);
        }

        Add(free, cursor, closeMin, minLength);
        return free;
    }

    private static void Add(List<FreeRange> free, int startMin, int endMin, int minLength)
    {
        var length = endMin - startMin;
        if (length > 0 && length >= Math.Max(minLength, 1))
            free.Add(new FreeRange { StartMin = startMin, EndMin = endMin });
    }

    /// <summary>past | unavailable | closed | full | partial | open — FIRST MATCH WINS, in that order.</summary>
    public static string StatusOf(MonthDayAvailability day, DateTime today, DateTime lastBookable, int minMinutes)
    {
        var date = day.OnDate.Date;

        if (date < today.Date) return "past";
        if (date > lastBookable.Date) return "unavailable";
        if (day.IsClosed || day.OpenMinutes <= 0) return "closed";
        if (day.MaxFreeRun < minMinutes) return "full";
        if (day.TakenMinutes > 0) return "partial";
        return "open";
    }

    /// <summary>Rounds UP to the next slot boundary. A slot size of 0 or less means "no grid".</summary>
    public static int RoundUpToSlot(int minutes, int slotMinutes)
    {
        if (slotMinutes <= 0)
            return minutes;

        var remainder = minutes % slotMinutes;
        return remainder == 0 ? minutes : minutes + (slotMinutes - remainder);
    }
}
