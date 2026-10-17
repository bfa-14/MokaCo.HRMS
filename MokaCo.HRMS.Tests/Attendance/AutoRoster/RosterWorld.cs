using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Services.Attendance.AutoRoster;

namespace MokaCo.HRMS.Tests.Attendance.AutoRoster;

/// <summary>
/// An in-memory stand-in for the database side of the auto-roster, so the planner can be driven
/// month after month the way the product uses it: <see cref="Context"/> builds the 15 result sets the
/// way usp_AutoRoster_GetContext does (staff by branch of day, rows of every branch and leave up to
/// the cap past the window, locks before today, holidays and holidays worked, rhythm, cells), and <see cref="Commit"/> applies a
/// commit the way usp_AutoRoster_Commit does (rows, ROSTER_CELL auto values and pins, rhythm). It
/// never decides anything the planner decides.
/// </summary>
public sealed class RosterWorld
{
    public const int Branch = 1;
    public const int OtherBranch = 2;

    public const int Day = 1;       // 09:00–17:00
    public const int Morning = 2;   // 07:00–15:00
    public const int Evening = 3;   // 15:00–23:00
    public const int Night = 4;     // 22:00–06:00, overnight
    public const int Retired = 9;   // inactive

    public DateOnly Today { get; set; } = new(2026, 9, 1);
    public int LookbackWeeks { get; set; } = 26;
    public int? OpenRequestId { get; set; }
    public Dictionary<string, string> Settings { get; } = new();
    public SortedDictionary<int, Person> People { get; } = new();
    public Dictionary<EmpDay, RosterRow> Rows { get; } = new();
    public Dictionary<EmpDay, AutoRosterCellRow> Cells { get; } = new();
    public Dictionary<int, AutoRosterRhythmRow> Rhythms { get; } = new();
    public List<AutoRosterHolidayRow> Holidays { get; } = new();
    public List<AutoRosterLeaveRow> Leaves { get; } = new();
    public List<AutoRosterPatternRow> Patterns { get; } = new();
    public List<AutoRosterStaffingRow> Staffing { get; } = new();
    public Dictionary<EmpDay, string> Locks { get; } = new();

    public List<AutoRosterShiftRow> Shifts { get; } =
    [
        Shift(Day, "Day", 9, 17),
        Shift(Morning, "Morning", 7, 15),
        Shift(Evening, "Evening", 15, 23),
        Shift(Night, "Night", 22, 6, crossesMidnight: true),
        Shift(Retired, "Old split", 10, 18, active: false),
    ];

    public sealed class Person
    {
        public int Id { get; init; }
        public string Name { get; init; } = string.Empty;
        public int? PositionId { get; set; }
        public DateOnly Hire { get; set; }
        public DateOnly? Termination { get; set; }
        public List<(DateOnly From, int Branch)> Moves { get; } = new();
    }

    public static AutoRosterShiftRow Shift(int id, string name, int start, int end, bool crossesMidnight = false, bool active = true) => new()
    {
        ShiftId = id,
        Name = name,
        StartTime = TimeSpan.FromHours(start),
        EndTime = TimeSpan.FromHours(end),
        CrossesMidnight = crossesMidnight,
        IsActive = active,
    };

    /* ---- building the world ---- */

    public Person Add(int id, int branch = Branch, DateOnly? hire = null, DateOnly? termination = null, int? positionId = 1)
    {
        var person = new Person
        {
            Id = id,
            Name = $"Employee {id}",
            PositionId = positionId,
            Hire = hire ?? new DateOnly(2024, 1, 1),
            Termination = termination,
        };
        person.Moves.Add((new DateOnly(2000, 1, 1), branch));
        People[id] = person;
        return person;
    }

    public RosterWorld WithStaff(int count, int firstId = 1)
    {
        for (var i = 0; i < count; i++)
            Add(firstId + i);
        return this;
    }

    public void Move(int id, DateOnly from, int branch) => People[id].Moves.Add((from, branch));

    public int? BranchOn(int id, DateOnly date)
    {
        var p = People[id];
        if (date < p.Hire || (p.Termination is { } t && date > t))
            return null;
        return p.Moves.Where(m => m.From <= date).OrderBy(m => m.From).Select(m => (int?)m.Branch).LastOrDefault()
            ?? p.Moves.OrderBy(m => m.From).First().Branch;
    }

    public void Work(int id, DateOnly date, int shift = Day) => Rows[new EmpDay(id, date)] = new RosterRow(shift, false);
    public void Rest(int id, DateOnly date) => Rows[new EmpDay(id, date)] = new RosterRow(null, true);

    public void Holiday(DateOnly date, string name = "Holiday", bool paid = true, int? branch = null)
        => Holidays.Add(new AutoRosterHolidayRow { HolidayDate = T(date), Name = name, IsPaid = paid, BranchId = branch });

    public void Leave(int id, DateOnly from, DateOnly to, string? halfDay = null, bool paid = true, string status = "Approved")
        => Leaves.Add(new AutoRosterLeaveRow { EmployeeId = id, FromDate = T(from), ToDate = T(to), HalfDay = halfDay, IsPaid = paid, Status = status });

    public void Pin(int id, DateOnly date)
    {
        var key = new EmpDay(id, date);
        if (!Cells.TryGetValue(key, out var cell))
            Cells[key] = cell = new AutoRosterCellRow { EmployeeId = id, WorkDate = T(date) };
        cell.IsPinned = true;
    }

    public void MarkAuto(int id, DateOnly date)
    {
        var row = Rows[new EmpDay(id, date)];
        Cells[new EmpDay(id, date)] = new AutoRosterCellRow
        {
            EmployeeId = id,
            WorkDate = T(date),
            AutoState = row.IsRestDay ? "rest" : "work",
            AutoShiftId = row.IsRestDay ? null : row.ShiftId,
        };
    }

    public void Min(int min, int? dayOfWeek = null, int? shiftId = null, int? target = null)
        => Staffing.Add(new AutoRosterStaffingRow { MinOnDuty = min, DayOfWeek = (byte?)dayOfWeek, ShiftId = shiftId, TargetOnDuty = target });

    public void Anchor(int id, DateOnly weekStart, int workDays, bool onRotation = true)
        => Rhythms[id] = new AutoRosterRhythmRow { EmployeeId = id, AnchorWeekStart = T(weekStart), AnchorWorkDays = (byte)workDays, OnRotation = onRotation };

    /* ---- what usp_AutoRoster_GetContext returns ---- */

    public AutoRosterContext Context(DateOnly month, int branch = Branch)
    {
        var (from, to) = RosterCalendar.Window(month);
        var historyFrom = from.AddDays(-7 * LookbackWeeks);
        var monthStart = RosterCalendar.MonthStart(month);
        var monthEnd = RosterCalendar.MonthEnd(monthStart);
        var staff = People.Values
            .Where(p => RosterCalendar.Days(from, to).Any(d => BranchOn(p.Id, d) == branch))
            .Select(p => p.Id)
            .ToHashSet();

        var ctx = new AutoRosterContext
        {
            Header = new AutoRosterContextHeader
            {
                BranchId = branch,
                BranchName = $"Branch {branch}",
                MonthDate = T(monthStart),
                WindowFrom = T(from),
                WindowTo = T(to),
                HistoryFrom = T(historyFrom),
                Today = T(Today),
                OpenRequestId = OpenRequestId,
                MonthStatus = OpenRequestId is null ? null : "PendingApproval",
            },
            Settings = Settings.Select(s => new AutoRosterSettingRow { SettingKey = s.Key, SettingValue = s.Value }).ToList(),
        };

        foreach (var id in staff.Order())
        {
            var p = People[id];
            ctx.Staff.Add(new AutoRosterStaffRow
            {
                EmployeeId = id,
                FullName = p.Name,
                PositionId = p.PositionId,
                Position = p.PositionId is null ? null : $"Position {p.PositionId}",
                HireDate = T(p.Hire),
                TerminationDate = p.Termination is { } t ? T(t) : null,
            });

            foreach (var d in RosterCalendar.Days(historyFrom, to))
            {
                if (BranchOn(id, d) is { } b)
                    ctx.StaffDays.Add(new AutoRosterStaffDayRow { EmployeeId = id, WorkDate = T(d), BranchId = b });
            }

            foreach (var d in RosterCalendar.Days(monthStart, monthEnd))
            {
                if (BranchOn(id, d) is null)
                    continue;
                var key = new EmpDay(id, d);
                if (Locks.TryGetValue(key, out var reason))
                    ctx.Locks.Add(new AutoRosterLockRow { EmployeeId = id, WorkDate = T(d), Reason = reason });
                else if (d < Today)
                    ctx.Locks.Add(new AutoRosterLockRow { EmployeeId = id, WorkDate = T(d), Reason = "Past" });
            }
        }

        // Rows and leave reach past the window by the cap: the following month may be saved already.
        var horizon = to.AddDays(AutoRosterInputFactory.ReadSettings(ctx.Settings).MaxConsecutiveWorkDays);
        ctx.Rows = Rows
            .Where(r => staff.Contains(r.Key.EmployeeId) && r.Key.Date >= historyFrom && r.Key.Date <= horizon)
            .Select(r => new AutoRosterRowRow { EmployeeId = r.Key.EmployeeId, WorkDate = T(r.Key.Date), ShiftId = r.Value.ShiftId, IsRestDay = r.Value.IsRestDay })
            .ToList();

        var holidayFrom = from.AddDays(-365);
        ctx.Holidays = Holidays
            .Where(h => (h.BranchId is null || h.BranchId == branch) && D(h.HolidayDate) >= holidayFrom && D(h.HolidayDate) <= to)
            .ToList();

        foreach (var id in staff.Order())
        {
            var worked = ctx.Holidays
                .Select(h => D(h.HolidayDate))
                .Where(d => d < from)
                .Distinct()
                .Count(d => Rows.TryGetValue(new EmpDay(id, d), out var row) && row.IsWork);
            if (worked > 0)
                ctx.HolidaysWorked.Add(new AutoRosterHolidaysWorkedRow { EmployeeId = id, Days = worked });
        }

        ctx.Leaves = Leaves.Where(l => staff.Contains(l.EmployeeId) && D(l.ToDate) >= historyFrom && D(l.FromDate) <= horizon).ToList();
        ctx.Shifts = Shifts.ToList();
        ctx.Patterns = Patterns.Where(p => staff.Contains(p.EmployeeId)).ToList();
        ctx.Rhythm = Rhythms.Values.Where(r => staff.Contains(r.EmployeeId)).ToList();
        ctx.Cells = Cells
            .Where(c => staff.Contains(c.Key.EmployeeId) && c.Key.Date >= from && c.Key.Date <= to)
            .Select(c => c.Value)
            .ToList();
        ctx.Staffing = Staffing.ToList();
        return ctx;
    }

    /* ---- planning and committing ---- */

    public sealed record Run(AutoRosterRequest Request, PlannerInput Input, RosterPlan Plan)
    {
        public AutoRosterPreview Preview => Plan.Preview;
    }

    public AutoRosterRequest Request(DateOnly month, string mode = "FillEmpty", int branch = Branch) => new()
    {
        BranchId = branch,
        Month = month.ToString("yyyy-MM"),
        Mode = mode,
    };

    public Run Plan(DateOnly month, string mode = "FillEmpty", Action<AutoRosterRequest>? configure = null, int branch = Branch)
    {
        var request = Request(month, mode, branch);
        configure?.Invoke(request);
        var input = AutoRosterInputFactory.Create(Context(month, branch), request);
        return new Run(request, input, RosterPlanner.Plan(input));
    }

    /// <summary>Plans and saves; returns the run and what the commit's server-side validation said.</summary>
    public (Run Run, List<AutoRosterIssue> CommitIssues) PlanAndCommit(
        DateOnly month, string mode = "FillEmpty", Action<AutoRosterRequest>? configure = null, int branch = Branch)
    {
        var run = Plan(month, mode, configure, branch);
        return (run, Commit(run));
    }

    /// <summary>The commit the web would send for a preview: every month cell this run writes, with its expected state.</summary>
    public static AutoRosterCommitRequest CommitRequestFor(AutoRosterRequest request, AutoRosterPreview preview)
    {
        var commit = new AutoRosterCommitRequest
        {
            BranchId = request.BranchId,
            Month = request.Month,
            Mode = request.Mode,
            RhythmStart = request.RhythmStart,
            DefaultShiftId = request.DefaultShiftId,
            HolidayCover = request.HolidayCover,
            OffRotationEmployeeIds = request.OffRotationEmployeeIds,
            RhythmOverrides = request.RhythmOverrides,
            DraftCells = request.DraftCells,
        };

        var pinned = request.DraftCells.Where(d => d.IsPinned == true).Select(d => new EmpDay(d.EmployeeId, d.WorkDate)).ToHashSet();
        foreach (var c in preview.Cells.Where(c => c.Change is "insert" or "update" or "delete" or "unchanged"))
        {
            commit.Cells.Add(new AutoRosterCommitCell
            {
                EmployeeId = c.EmployeeId,
                WorkDate = c.WorkDate,
                Action = c.State == "none" ? "delete" : "upsert",
                ShiftId = c.State == "work" ? c.ShiftId : null,
                IsRestDay = c.State == "rest",
                Expected = c.Expected,
                IsAuto = c.Origin != "draft",
                ReasonCode = c.ReasonCode,
                IsPinned = pinned.Contains(new EmpDay(c.EmployeeId, c.WorkDate)) ? true : null,
            });
        }

        foreach (var r in preview.Rhythm)
            commit.Rhythm.Add(new AutoRosterCommitRhythm { EmployeeId = r.EmployeeId, AnchorWeekStart = r.AnchorWeekStart, AnchorWorkDays = r.AnchorWorkDays, OnRotation = true });
        return commit;
    }

    /// <summary>Validates the commit as the API would, then applies it as usp_AutoRoster_Commit would.</summary>
    public List<AutoRosterIssue> Commit(Run run)
    {
        var commit = CommitRequestFor(run.Request, run.Preview);
        var issues = RosterPlanValidator.ValidateSubmission(run.Input, commit.Cells, commit.Rhythm);
        Apply(commit);
        return issues;
    }

    public void Apply(AutoRosterCommitRequest commit)
    {
        foreach (var c in commit.Cells)
        {
            var key = new EmpDay(c.EmployeeId, c.WorkDate);
            var delete = c.Action == "delete";
            if (delete)
                Rows.Remove(key);
            else
                Rows[key] = c.IsRestDay ? new RosterRow(null, true) : new RosterRow(c.ShiftId, false);

            Cells.TryGetValue(key, out var existing);
            Cells[key] = new AutoRosterCellRow
            {
                EmployeeId = c.EmployeeId,
                WorkDate = T(c.WorkDate),
                AutoState = c.IsAuto ? (delete ? "none" : c.IsRestDay ? "rest" : "work") : null,
                AutoShiftId = c.IsAuto && !delete && !c.IsRestDay ? c.ShiftId : null,
                ReasonCode = c.ReasonCode,
                IsPinned = c.IsPinned ?? existing?.IsPinned ?? false,
            };
        }

        foreach (var r in commit.Rhythm)
        {
            Rhythms[r.EmployeeId] = new AutoRosterRhythmRow
            {
                EmployeeId = r.EmployeeId,
                AnchorWeekStart = T(r.AnchorWeekStart),
                AnchorWorkDays = (byte)r.AnchorWorkDays,
                OnRotation = r.OnRotation,
            };
        }
    }

    /* ---- reading the saved roster back ---- */

    public RosterRow? RowAt(int id, DateOnly date) => Rows.TryGetValue(new EmpDay(id, date), out var r) ? r : null;
    public bool IsRest(int id, DateOnly date) => RowAt(id, date) is { IsRestDay: true };
    public bool IsWork(int id, DateOnly date) => RowAt(id, date) is { IsWork: true };

    public bool OnLeave(int id, DateOnly date)
        => Leaves.Any(l => l.EmployeeId == id && D(l.FromDate) <= date && D(l.ToDate) >= date);

    /// <summary>Rest rows of the week outside leave — what the 6/5 rule counts.</summary>
    public int RestsInWeek(int id, DateOnly weekStart)
        => Enumerable.Range(0, 7).Select(i => weekStart.AddDays(i)).Count(d => IsRest(id, d) && !OnLeave(id, d));

    /// <summary>The longest run of working rows in [from, to]; a full-day leave breaks it.</summary>
    public int LongestRun(int id, DateOnly from, DateOnly to)
    {
        int run = 0, best = 0;
        foreach (var d in RosterCalendar.Days(from, to))
        {
            var fullLeave = Leaves.Any(l => l.EmployeeId == id && l.HalfDay is null && D(l.FromDate) <= d && D(l.ToDate) >= d);
            run = IsWork(id, d) && !fullLeave ? run + 1 : 0;
            best = Math.Max(best, run);
        }
        return best;
    }

    public static DateTime T(DateOnly d) => d.ToDateTime(TimeOnly.MinValue);
    public static DateOnly D(DateTime d) => DateOnly.FromDateTime(d);
}

/// <summary>Small readers over a preview.</summary>
public static class PreviewExtensions
{
    public static AutoRosterCell Cell(this AutoRosterPreview preview, int employeeId, DateOnly date)
        => preview.Cells.Single(c => c.EmployeeId == employeeId && c.WorkDate == date);

    public static AutoRosterCell? CellOrNull(this AutoRosterPreview preview, int employeeId, DateOnly date)
        => preview.Cells.SingleOrDefault(c => c.EmployeeId == employeeId && c.WorkDate == date);

    public static IEnumerable<AutoRosterIssue> Errors(this AutoRosterPreview preview) => preview.Issues.Where(i => i.Severity == "error");

    public static IEnumerable<AutoRosterIssue> WithCode(this IEnumerable<AutoRosterIssue> issues, string code) => issues.Where(i => i.Code == code);

    /// <summary>Rests of one employee in one week as the preview has them (window cells; leave days excluded).</summary>
    public static int RestsInWeek(this AutoRosterPreview preview, int employeeId, DateOnly weekStart)
        => preview.PerEmployee.Single(p => p.EmployeeId == employeeId).Weeks.Single(w => w.WeekStart == weekStart).Rests;

    public static AutoRosterWeekCounter Week(this AutoRosterPreview preview, int employeeId, DateOnly weekStart)
        => preview.PerEmployee.Single(p => p.EmployeeId == employeeId).Weeks.Single(w => w.WeekStart == weekStart);

    public static int Changes(this AutoRosterPreview preview) => preview.Summary.Inserts + preview.Summary.Updates + preview.Summary.Deletes;
}
