namespace MokaCo.HRMS.Services.Attendance.AutoRoster;

/// <summary>
/// D9 — who is OWED a Saturday (or a Sunday) off. The carpool fair-share method, kept separately for
/// the two days: on each weekend date everyone in the pool earns rested/|pool| and whoever rested is
/// debited 1, so owed = earned − rested. Positive = owed rest, negative = had more than a fair share.
///
/// Nothing is stored: the balances are rebuilt every run from real rows (history) plus the plan so
/// far, so a swap, a hand edit, a hire or a transfer is counted as the roster now stands. People
/// outside the pool that day (on leave, off for a holiday, not in the branch, no row) earn nothing
/// and lose nothing, which is what makes the balance indifferent to leave and hires.
/// </summary>
public sealed class WeekendLedger
{
    private readonly SortedDictionary<int, Balance> _balances = new();

    /// <summary>
    /// The balances the window starts from: every weekend date of the lookback (RosterFairnessLookbackWeeks,
    /// never before the context's HistoryFrom) up to the day before the window, from real rows only.
    /// Pool = the given employees who were in this branch that day, employed, not on a full-day leave,
    /// with a working or rest row. Rows INSIDE the window are deliberately not read: those the run may
    /// re-plan count once, through the plan, never twice. <paramref name="streaks"/> receives the
    /// consecutive weekends each person has worked going into the window.
    /// </summary>
    public static WeekendLedger FromHistory(PlannerInput input, IReadOnlyList<int> employees, IDictionary<int, int>? streaks = null)
    {
        var ledger = new WeekendLedger();
        streaks ??= new Dictionary<int, int>();
        var from = input.WindowFrom.AddDays(-7 * input.Settings.FairnessLookbackWeeks);
        if (from < input.HistoryFrom)
            from = input.HistoryFrom;

        for (var ws = RosterCalendar.WeekStart(from); ws < input.WindowFrom; ws = ws.AddDays(7))
        {
            var inPool = new HashSet<int>();
            var rested = new HashSet<int>();
            foreach (var date in new[] { ws.AddDays(5), ws.AddDays(6) })
            {
                if (date < from || date >= input.WindowFrom)
                    continue;

                var pool = new List<int>();
                var restedToday = new List<int>();
                foreach (var e in employees)
                {
                    if (!input.InBranch(e, date) || input.LeaveOn(e, date) == LeaveKind.Full)
                        continue;
                    if (input.RowOf(e, date) is not { } row || !(row.IsRestDay || row.IsWork))
                        continue;
                    pool.Add(e);
                    inPool.Add(e);
                    if (row.IsRestDay)
                    {
                        restedToday.Add(e);
                        rested.Add(e);
                    }
                }
                ledger.AddDay(date, pool, restedToday);
            }
            UpdateStreaks(streaks, employees, inPool, rested);
        }

        return ledger;
    }

    /// <summary>Consecutive weekends worked: reset by a weekend day off, unchanged by a weekend spent outside the pool.</summary>
    public static void UpdateStreaks(IDictionary<int, int> streaks, IEnumerable<int> employees, ISet<int> inPool, ISet<int> rested)
    {
        foreach (var e in employees)
        {
            if (rested.Contains(e))
                streaks[e] = 0;
            else if (inPool.Contains(e))
                streaks[e] = (streaks.TryGetValue(e, out var s) ? s : 0) + 1;
        }
    }

    /// <summary>Adds one weekend date. <paramref name="rested"/> outside <paramref name="pool"/> is ignored.</summary>
    public void AddDay(DateOnly date, IEnumerable<int> pool, IEnumerable<int> rested)
    {
        if (!RosterCalendar.IsWeekend(date))
            throw new ArgumentException("Only a Saturday or a Sunday counts in the weekend ledger.", nameof(date));

        var members = pool.Distinct().Order().ToList();
        if (members.Count == 0)
            return;

        var inPool = members.ToHashSet();
        var resters = rested.Distinct().Where(inPool.Contains).Order().ToList();
        var share = resters.Count / (double)members.Count;
        var saturday = RosterCalendar.IsSaturday(date);

        foreach (var e in members)
        {
            var b = BalanceOf(e);
            if (saturday) b.EarnedSaturday += share; else b.EarnedSunday += share;
        }

        foreach (var e in resters)
        {
            var b = BalanceOf(e);
            if (saturday) b.RestedSaturday++; else b.RestedSunday++;
        }
    }

    /// <summary>owed(e, Saturday) or owed(e, Sunday).</summary>
    public double Owed(int employeeId, DayOfWeek day)
    {
        if (!_balances.TryGetValue(employeeId, out var b))
            return 0;
        return day switch
        {
            DayOfWeek.Saturday => b.EarnedSaturday - b.RestedSaturday,
            DayOfWeek.Sunday => b.EarnedSunday - b.RestedSunday,
            _ => throw new ArgumentException("Saturday or Sunday.", nameof(day)),
        };
    }

    public double OwedTotal(int employeeId) => Owed(employeeId, DayOfWeek.Saturday) + Owed(employeeId, DayOfWeek.Sunday);

    public int Rested(int employeeId, DayOfWeek day)
        => !_balances.TryGetValue(employeeId, out var b) ? 0 : day == DayOfWeek.Saturday ? b.RestedSaturday : b.RestedSunday;

    /// <summary>
    /// A balance rounded for ORDERING. Shares are fractions like 1/7, and the same total reached by a
    /// different sum can differ in the last bit; two people who are equally owed must tie and fall
    /// through to the next rule, not be split by floating-point noise.
    /// </summary>
    public static double Key(double owed) => Math.Round(owed, 6);

    private Balance BalanceOf(int employeeId)
    {
        if (!_balances.TryGetValue(employeeId, out var b))
            _balances[employeeId] = b = new Balance();
        return b;
    }

    private sealed class Balance
    {
        public double EarnedSaturday;
        public double EarnedSunday;
        public int RestedSaturday;
        public int RestedSunday;
    }
}
