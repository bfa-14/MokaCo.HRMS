namespace MokaCo.HRMS.Services.Attendance.AutoRoster;

/// <summary>
/// D16 — the shifts a branch RUNS, for a branch that has not said which shifts must be covered every
/// day. Two readings, either one is enough:
///   - its roster in the eight weeks before the window: an active shift worked in the branch on at
///     least a quarter of the days the branch worked at all (and on four days at least) — a branch that
///     works mornings and evenings gets both, even when evenings were short-handed now and then; a
///     shift used for one inventory night does not;
///   - the weekly patterns of the staff on rotation: an active shift a pattern names on two weekdays
///     or more (a new branch has patterns before it has a roster).
/// Each gets a minimum of one, EVERY day (the rule is "every day the morning and the evening are
/// covered"; a past day without an evening is what it fixes, not a reason to skip it). Nothing found
/// means no shift to cover: the drawer says so and the manager ticks the shifts by hand.
/// Pure and deterministic, like the planner.
/// </summary>
public static class ShiftCoverDetector
{
    public const int LookbackDays = 56;
    public const double MinShareOfDays = 0.25;
    public const int MinDays = 4;
    public const int MinPatternWeekdays = 2;

    public static IReadOnlyList<StaffingRule> Detect(PlannerInput input)
    {
        ArgumentNullException.ThrowIfNull(input);

        var worked = new HashSet<DateOnly>();
        var daysOf = new Dictionary<int, HashSet<DateOnly>>();
        var weekdaysOf = new Dictionary<int, HashSet<int>>();
        var from = input.WindowFrom.AddDays(-LookbackDays);

        foreach (var employee in input.Staff)
        {
            var e = employee.EmployeeId;
            for (var d = from; d < input.WindowFrom; d = d.AddDays(1))
            {
                if (input.InBranch(e, d)
                    && input.LeaveOn(e, d) != LeaveKind.Full
                    && input.RowOf(e, d) is { IsWork: true, ShiftId: { } shiftId }
                    && input.IsActiveShift(shiftId))
                {
                    worked.Add(d);
                    Add(daysOf, shiftId, d);
                }
            }

            if (!employee.OnRotation)
                continue;
            for (var dow = 1; dow <= 7; dow++)
            {
                if (input.Patterns.TryGetValue((e, dow), out var p)
                    && p is { IsRestDay: false, ShiftId: { } patternShift }
                    && input.IsActiveShift(patternShift))
                    Add(weekdaysOf, patternShift, dow);
            }
        }

        var regular = daysOf
            .Where(x => x.Value.Count >= MinDays && x.Value.Count >= MinShareOfDays * worked.Count)
            .Select(x => x.Key)
            .Union(weekdaysOf.Where(x => x.Value.Count >= MinPatternWeekdays).Select(x => x.Key));

        return regular
            .Select(id => input.Shifts[id])
            .OrderBy(s => s.StartTime)
            .ThenBy(s => s.ShiftId)
            .Select(s => new StaffingRule(null, s.ShiftId, 1, null))
            .ToList();
    }

    private static void Add<T>(Dictionary<int, HashSet<T>> map, int key, T value)
    {
        if (!map.TryGetValue(key, out var set))
            map[key] = set = new HashSet<T>();
        set.Add(value);
    }
}
