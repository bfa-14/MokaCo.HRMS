using System.Collections.Frozen;

namespace MokaCo.HRMS.Services.Attendance.AutoRoster;

/// <summary>One person's line of the rotation list (attendance.ROSTER_ROTATION_MEMBER, script 116). Weekdays are 0 = Monday … 6 = Sunday.</summary>
public sealed record RotationMember(int EmployeeId, int Group, int SingleRestDay, int PairRestDay, string? LeadSlot, int SortOrder);

/// <summary>A branch's rotation: where week 0 starts (a Monday), its two shifts, and the list.</summary>
public sealed record RotationSetup(DateOnly StartDate, int MorningShiftId, int EveningShiftId, IReadOnlyDictionary<int, RotationMember> Members)
{
    public static IReadOnlyDictionary<int, RotationMember> NoMembers { get; } = FrozenDictionary<int, RotationMember>.Empty;
}

/// <summary>
/// THE FIXED ROTATION — the auto-roster's second method, the rule the owner rostered by in a spreadsheet:
///
///   =LET(d,F$3, w,INT((d-$B$1)/7), sh,MOD(2*INT(w/2),7), dy,WEEKDAY(d,3),
///    off,IF(MOD(w+$B4,2)=0, OR(dy=MOD($D4+sh,7),dy=MOD($D4+1+sh,7)), dy=MOD($C4+sh,7)),
///    m,COUNTIF(F$3:F3,"M"), e,COUNTIF(F$3:F3,"E"),
///    IF(off,"OFF", IF($E4="L1",IF(MOD(w,2)=0,"M","E"), IF($E4="L2",IF(MOD(w,2)=0,"E","M"),
///     IF(m&lt;e,"M",IF(e&lt;m,"E",IF(MOD(w+dy+ROW(),2)=0,"M","E")))))))
///
/// with B1 = <see cref="RotationSetup.StartDate"/>, column B = Group, C = SingleRestDay, D = PairRestDay,
/// E = LeadSlot, and the sheet's rows = the list in SortOrder (its first person is on row 4).
///
///   · DAYS OFF alternate week by week - two when (w + Group) is even, one when odd - and MOVE two weekdays later
///     every two weeks, so nobody keeps the same days off (back to the start after 14 weeks).
///   · A WORKING DAY is a morning or an evening. L1 has mornings on even weeks and evenings on odd ones, L2 the
///     opposite: each shift keeps a lead. Everybody else goes, in the order of the list, to the shift with fewer
///     people so far that day; on a tie the weeks, the days and the rows take turns.
///
/// The sheet knows nothing of the real world; the auto-roster does, and it wins: a day the run may not change
/// (paid, past, recorded, pinned, a hand edit the mode protects), a leave day and a public holiday are handled as
/// in the other method, and the rule fills only the days that are free. What it balances the two shifts against
/// is therefore what is really on the roster that day - a fixed row counts like a row of the rule, and somebody on
/// leave for the whole day counts for neither shift.
///
/// Pure: no clock, no database. Excel's INT and MOD floor and stay non-negative, so the arithmetic here does too
/// (a month planned before the start date still follows the rule).
/// </summary>
public static class RotationRule
{
    public const string ReasonRest = "REST_ROTATION";
    public const string ReasonLead = "WORK_ROTATION_LEAD";
    public const string ReasonBalance = "WORK_ROTATION";

    /// <summary>The sheet's first person is on row 4 (rows 1-3 hold the start date and the dates): the tie-break reads ROW().</summary>
    public const int FirstSheetRow = 4;

    private static int FloorDiv(int a, int b) => a >= 0 ? a / b : -((-a + b - 1) / b);

    /// <summary>w: whole weeks since the start date (negative before it).</summary>
    public static int Week(DateOnly start, DateOnly date) => FloorDiv(date.DayNumber - start.DayNumber, 7);

    /// <summary>dy: 0 = Monday … 6 = Sunday (Excel's WEEKDAY(d,3)).</summary>
    public static int Weekday(DateOnly date) => RosterCalendar.IsoDayOfWeek(date) - 1;

    /// <summary>sh: how far the days off have moved - two weekdays every two weeks.</summary>
    public static int Shift(int week) => RosterCalendar.Mod(2 * FloorDiv(week, 2), 7);

    /// <summary>A two-days-off week for this group (a 5-day week); otherwise one day off (a 6-day week).</summary>
    public static bool IsTwoOffWeek(int week, int group) => RosterCalendar.Mod(week + group, 2) == 0;

    public static bool IsOff(RotationSetup setup, RotationMember member, DateOnly date)
    {
        var w = Week(setup.StartDate, date);
        var sh = Shift(w);
        var dy = Weekday(date);
        return IsTwoOffWeek(w, member.Group)
            ? dy == RosterCalendar.Mod(member.PairRestDay + sh, 7) || dy == RosterCalendar.Mod(member.PairRestDay + 1 + sh, 7)
            : dy == RosterCalendar.Mod(member.SingleRestDay + sh, 7);
    }

    /// <summary>
    /// Morning (true) or evening for a working day. <paramref name="mornings"/> and <paramref name="evenings"/> are the
    /// people already on each shift that day among those earlier in the list; <paramref name="sheetRow"/> is the
    /// person's row on the sheet (<see cref="FirstSheetRow"/> + position in the list).
    /// </summary>
    public static bool IsMorning(RotationSetup setup, RotationMember member, DateOnly date, int mornings, int evenings, int sheetRow)
    {
        var w = Week(setup.StartDate, date);
        var evenWeek = RosterCalendar.Mod(w, 2) == 0;
        if (member.LeadSlot == "L1") return evenWeek;
        if (member.LeadSlot == "L2") return !evenWeek;
        if (mornings < evenings) return true;
        if (evenings < mornings) return false;
        return RosterCalendar.Mod(w + Weekday(date) + sheetRow, 2) == 0;
    }

    /// <summary>The list in sheet order: SortOrder, then EmployeeId.</summary>
    public static IReadOnlyList<RotationMember> Ordered(RotationSetup setup, IEnumerable<int> employeeIds)
        => employeeIds.Where(setup.Members.ContainsKey).Select(e => setup.Members[e])
            .OrderBy(m => m.SortOrder).ThenBy(m => m.EmployeeId).ToList();

    /// <summary>The rule on an empty sheet: "OFF", "M" or "E" for every person (in list order) on one day. What the tests hold against the spreadsheet.</summary>
    public static IReadOnlyList<string> Column(RotationSetup setup, IReadOnlyList<RotationMember> ordered, DateOnly date)
    {
        var column = new List<string>(ordered.Count);
        int mornings = 0, evenings = 0;
        for (var i = 0; i < ordered.Count; i++)
        {
            if (IsOff(setup, ordered[i], date))
            {
                column.Add("OFF");
                continue;
            }
            var morning = IsMorning(setup, ordered[i], date, mornings, evenings, FirstSheetRow + i);
            if (morning) mornings++; else evenings++;
            column.Add(morning ? "M" : "E");
        }
        return column;
    }

    /// <summary>
    /// The 6/5 rhythm the rule implies, in the auto-roster's own terms: anchored on the start date's week, a 5-day
    /// week there for group 0 and a 6-day week for group 1. Saved with the plan, so the week strip, the validator
    /// and a later run of the other method all read the same alternation.
    /// </summary>
    public static IReadOnlyDictionary<int, ResolvedRhythm> ResolveRhythms(PlannerInput input)
    {
        var setup = input.Rotation!;
        var anchor = RosterCalendar.WeekStart(setup.StartDate);
        var result = new SortedDictionary<int, ResolvedRhythm>();
        foreach (var employee in input.Staff.Where(s => s.OnRotation))
        {
            if (!setup.Members.TryGetValue(employee.EmployeeId, out var member))
                continue;
            var workDays = member.Group == 0 ? 5 : 6;
            var isNew = !input.Rhythms.TryGetValue(employee.EmployeeId, out var stored)
                        || RosterCalendar.WorkDaysInWeek(RosterCalendar.WeekIndex(stored.AnchorWeekStart), stored.AnchorWorkDays, RosterCalendar.WeekIndex(anchor)) != workDays;
            result[employee.EmployeeId] = isNew
                ? new ResolvedRhythm(employee.EmployeeId, anchor, workDays, true)
                : new ResolvedRhythm(employee.EmployeeId, stored!.AnchorWeekStart, stored.AnchorWorkDays, false);
        }
        return result;
    }

    /// <summary>
    /// Fills the grid's free days by the rule, day by day and down the list. Run after the holidays (their cover is
    /// chosen as in the other method) and instead of the weekly rest choice and the shift cover.
    /// </summary>
    public static void Apply(PlannerInput input, RosterGrid grid)
    {
        var setup = input.Rotation!;
        var ordered = Ordered(setup, input.Staff.Where(s => s.OnRotation).Select(s => s.EmployeeId));

        foreach (var date in grid.Days)
        {
            int mornings = 0, evenings = 0;
            for (var i = 0; i < ordered.Count; i++)
            {
                var member = ordered[i];
                var cell = grid[member.EmployeeId, date];
                if (!cell.Employed)
                    continue;

                if (cell.IsPlannable)
                {
                    if (IsOff(setup, member, date))
                    {
                        cell.State = CellState.Rest;
                        cell.ShiftId = null;
                        cell.ReasonCode = ReasonRest;
                        cell.ReasonArgs = null;
                    }
                    else
                    {
                        cell.State = CellState.Work;
                        cell.ShiftId = IsMorning(setup, member, date, mornings, evenings, FirstSheetRow + i) ? setup.MorningShiftId : setup.EveningShiftId;
                        cell.ReasonCode = member.LeadSlot is null ? ReasonBalance : ReasonLead;
                        cell.ReasonArgs = null;
                    }
                }
                else if (!cell.IsFact && cell.State == CellState.Work && cell.ShiftId is null)
                {
                    // A working day somebody else decided and that still needs its shift: an empty leave day (it gets a
                    // working row so the leave costs what it was priced at), a holiday's cover, a draft edit without one.
                    cell.ShiftId = IsMorning(setup, member, date, mornings, evenings, FirstSheetRow + i) ? setup.MorningShiftId : setup.EveningShiftId;
                }

                // What the next people balance against: who is really on each shift here today.
                if (cell.InBranch && cell.State == CellState.Work && cell.Leave != LeaveKind.Full)
                {
                    if (cell.ShiftId == setup.MorningShiftId) mornings++;
                    else if (cell.ShiftId == setup.EveningShiftId) evenings++;
                }
            }
        }
    }
}
