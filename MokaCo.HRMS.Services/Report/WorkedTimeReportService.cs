using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Model.Report;
using MokaCo.HRMS.Repository.Report;
using MokaCo.HRMS.Services.Attendance;
using MokaCo.HRMS.Services.Booking;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Services.Report;

public interface IWorkedTimeReportService
{
    /// <summary>The Worked time report for the period. <paramref name="sees"/> (employee, branch of the day) keeps the
    /// days the caller may see - per day, so a transferred employee's days in another branch stay out.</summary>
    Task<WorkedTimeReport> GetAsync(DateTime from, DateTime to, int? branchId, int? employeeId, Func<int, int?, bool> sees);
}

/// <summary>
/// WORKED TIME — days and hours worked and the progress against the standard month, for any period, with or without
/// a roster (see <see cref="WorkedTimeReport"/> for the rules).
///
/// NOTHING IS RE-COMPUTED FROM RAW PUNCHES. The worked side is the attendance days the processor already builds (the
/// Daily attendance grid's read): punches paired, double presses removed, HR's corrections and manual days included -
/// so the report never disagrees with the day an employee is shown or paid on. Without an approved roster those days
/// are measured against the standard day, which is exactly the "attendance only" view. Punched days in an approved
/// month that are missing from its roster have no attendance day yet: script 114 measures them from their punches
/// exactly as the processor measures a day with no shift, and they count like any other day worked (marked "not on
/// the roster" so they can still be decided). A day somebody dismissed is not counted.
///
/// ONE CALENDAR FOR EVERYTHING: the days each person was employed, with the branch of each day (script 113). Every
/// attendance day, leave day and "to decide" day is kept only when it falls on one of those days - so a branch filter
/// puts a day's worked and expected time in the same branch, and a day outside the employment is never counted.
/// The reads run unscoped and the caller's scope is applied here per day (employee + branch of the day), like the
/// Daily attendance read.
/// </summary>
public class WorkedTimeReportService : IWorkedTimeReportService
{
    /// <summary>About a quarter: long enough for a quarter's review, short enough to stay a one-screen read.</summary>
    public const int MaxDays = 93;

    private readonly IReportRepository _reports;
    private readonly IAttendanceService _attendance;
    private readonly IRosterService _roster;

    public WorkedTimeReportService(IReportRepository reports, IAttendanceService attendance, IRosterService roster)
    {
        _reports = reports;
        _attendance = attendance;
        _roster = roster;
    }

    public async Task<WorkedTimeReport> GetAsync(DateTime from, DateTime to, int? branchId, int? employeeId, Func<int, int?, bool> sees)
    {
        if (from == default || to == default) throw new WorkflowException(400, "Choose the first and the last day.");
        from = from.Date;
        to = to.Date;
        if (to < from) throw new WorkflowException(400, "The end of the period must be on or after its start.");
        if ((to - from).TotalDays + 1 > MaxDays) throw new WorkflowException(400, $"Choose at most {MaxDays} days at a time.");

        // The calendar is filtered by branch (as of each day); the rest is read for the people and matched to it.
        var (standard, employeeDays) = await _reports.GetWorkedTimeDaysAsync(from, to, branchId, employeeId);
        var records = await _attendance.GetAsync(from, to, employeeId, null);
        var punchDays = await _reports.GetWorkedTimePunchDaysAsync(from, to, employeeId);
        var leave = await _roster.GetLeaveDaysAsync(from, to, null, null);

        return Build(new WorkedTimeInput
        {
            From = from,
            To = to,
            Today = BeirutTime.Now.Date,
            BranchId = branchId,
            Standard = standard,
            EmployeeDays = employeeDays.ToList(),
            Records = records.ToList(),
            PunchDays = punchDays.ToList(),
            Leave = leave.Where(l => employeeId is null || l.EmployeeId == employeeId).ToList(),
            Sees = sees,
            GeneratedUtc = DateTime.UtcNow,
        });
    }

    /// <summary>Is an attendance day a day worked? A first punch on a working, rest or holiday day; or a day HR
    /// credited with worked time (an adjusted day keeps its status, an absence included). Never a leave day.</summary>
    public static bool IsWorked(AttendanceRecord r)
        => r.Status != "Leave"
           && ((r.FirstInUtc is not null && r.Status is "Present" or "RestDay" or "Holiday") || (r.IsManual && r.WorkedMinutes > 0));

    /// <summary>The time worked on an attendance day, extra time included. On a day with an approved roster shift the
    /// day's WorkedMinutes is the shift window and the time after it is OvertimeMinutes; elsewhere WorkedMinutes is
    /// already first in to last out (its overtime is inside it).</summary>
    public static int WorkedOf(AttendanceRecord r, bool hasRosterShift)
        => r.WorkedMinutes + (hasRosterShift && r.Status != "RestDay" ? r.OvertimeMinutes : 0);

    /// <summary>Pure: everything the report shows, from what was read.</summary>
    public static WorkedTimeReport Build(WorkedTimeInput input)
    {
        var countedTo = input.To < input.Today ? input.To : input.Today.AddDays(-1);
        DateTime? counted = countedTo >= input.From ? countedTo : null;
        bool IsCounted(DateTime day) => counted is not null && day.Date >= input.From && day.Date <= counted.Value;

        var report = new WorkedTimeReport
        {
            Header = new WorkedTimeHeader
            {
                From = input.From,
                To = input.To,
                CountedTo = counted,
                BranchId = input.BranchId,
                StandardDayMinutes = input.Standard.StandardDayMinutes,
                StandardDaysPerMonth = input.Standard.StandardDaysPerMonth,
                GeneratedUtc = input.GeneratedUtc,
            },
        };

        // The calendar: the employed days the caller may see (branch of the day), in the chosen branch.
        var calendar = input.EmployeeDays
            .Where(d => input.Sees(d.EmployeeId, d.BranchId))
            .GroupBy(d => (d.EmployeeId, d.WorkDate.Date))
            .ToDictionary(g => g.Key, g => g.First());
        WorkedTimeEmployeeDay? DayOf(int employeeId, DateTime date) => calendar.GetValueOrDefault((employeeId, date.Date));

        var records = input.Records
            .Where(r => DayOf(r.EmployeeId, r.WorkDate) is { } d && input.Sees(r.EmployeeId, r.BranchId ?? d.BranchId))
            .ToList();
        var recordDays = records.Select(r => (r.EmployeeId, r.WorkDate.Date)).ToHashSet();
        var leave = input.Leave
            .Where(l => l.DaysOnLeave > 0 && DayOf(l.EmployeeId, l.Date) is not null)
            .GroupBy(l => (l.EmployeeId, l.Date.Date))
            .ToDictionary(g => g.Key, g => Math.Min(1m, g.Sum(l => l.DaysOnLeave)));

        var rows = new Dictionary<int, WorkedTimeRow>();
        var expected = new Dictionary<int, decimal>();

        // THE LENGTH OF A PERSON'S DAY is their shift's (script 117), not one figure for everybody: the standard their
        // days of the period were measured against - the most frequent one, the longer on a tie - and the default day
        // (a shift's length too) for somebody with no measured day yet.
        var dayLengths = records.Where(r => r.StandardMinutes > 0).Select(r => (r.EmployeeId, r.StandardMinutes))
            .Concat(input.PunchDays.Where(p => p.StandardMinutes > 0).Select(p => (p.EmployeeId, p.StandardMinutes)))
            .GroupBy(x => x.EmployeeId)
            .ToDictionary(g => g.Key, g => g.GroupBy(x => x.StandardMinutes).OrderByDescending(m => m.Count()).ThenByDescending(m => m.Key).First().Key);
        int DayLengthOf(int employeeId) => dayLengths.GetValueOrDefault(employeeId, input.Standard.StandardDayMinutes);

        // EXPECTED: the standard month spread over its calendar days, for the days employed (in the branch, when one
        // is chosen). A public holiday expects nothing; approved leave expects nothing (half a day of leave, half).
        foreach (var day in calendar.Values.OrderBy(d => d.WorkDate))
        {
            if (!rows.TryGetValue(day.EmployeeId, out var row))
            {
                row = new WorkedTimeRow { EmployeeId = day.EmployeeId };
                rows[day.EmployeeId] = row;
                expected[day.EmployeeId] = 0;
            }
            row.FullName = day.FullName;
            row.DepartmentName = day.DepartmentName;
            row.BranchName = day.BranchName; // the latest day's branch wins: where they are now in this period
            row.StandardDayMinutes = DayLengthOf(day.EmployeeId);
            if (!IsCounted(day.WorkDate)) continue;

            var date = day.WorkDate.Date;
            var hasRecord = recordDays.Contains((day.EmployeeId, date));
            if (day.HolidayName is not null)
            {
                row.HolidayDays++;
                if (!hasRecord)
                    report.Days.Add(new WorkedTimeDay
                    {
                        EmployeeId = day.EmployeeId, WorkDate = date, BranchName = day.BranchName, Kind = "Holiday",
                        Note = day.HolidayName, NoteAr = day.HolidayNameAr,
                    });
                continue;
            }

            var perDay = input.Standard.StandardDaysPerMonth * DayLengthOf(day.EmployeeId) / DateTime.DaysInMonth(date.Year, date.Month);
            var onLeave = leave.GetValueOrDefault((day.EmployeeId, date));
            row.LeaveDays += onLeave;
            expected[day.EmployeeId] += perDay * (1 - onLeave);
            if (onLeave > 0 && !hasRecord)
                report.Days.Add(new WorkedTimeDay
                {
                    EmployeeId = day.EmployeeId, WorkDate = date, BranchName = day.BranchName, Kind = "Leave",
                    Note = onLeave < 1 ? "HalfDay" : null,
                });
        }

        // WORKED: the attendance days on the calendar.
        foreach (var r in records.Where(r => IsCounted(r.WorkDate)))
        {
            var day = DayOf(r.EmployeeId, r.WorkDate)!;
            var row = rows[r.EmployeeId];
            var worked = IsWorked(r);
            var minutes = worked ? WorkedOf(r, day.HasRosterShift) : 0;
            if (worked)
            {
                row.DaysWorked++;
                row.WorkedMinutes += minutes;
                row.OvertimeMinutes += r.OvertimeMinutes;
                if (r.HasAnomaly) row.MissingPunchDays++;
            }
            report.Days.Add(new WorkedTimeDay
            {
                EmployeeId = r.EmployeeId,
                WorkDate = r.WorkDate.Date,
                BranchName = r.BranchName ?? day.BranchName,
                Kind = r.Status,
                FirstIn = r.FirstInUtc,
                LastOut = r.LastOutUtc,
                WorkedMinutes = minutes,
                OvertimeMinutes = worked ? r.OvertimeMinutes : 0,
                MissingPunch = worked && r.HasAnomaly,
                IsManual = r.IsManual,
                Note = r.Status == "Holiday" ? day.HolidayName : null,
                NoteAr = r.Status == "Holiday" ? day.HolidayNameAr : null,
            });
        }

        // NOT ON THE ROSTER: punched, missing from an approved roster, no attendance day yet - measured from the
        // punches as a day with no rostered shift (script 114) and counted like any day worked. Extra time is what such
        // a day has: beyond the length of the shift its first punch fits (script 117).
        foreach (var p in input.PunchDays.Where(p => IsCounted(p.WorkDate) && !recordDays.Contains((p.EmployeeId, p.WorkDate.Date))))
        {
            if (DayOf(p.EmployeeId, p.WorkDate) is not { } day || !input.Sees(p.EmployeeId, p.BranchId ?? day.BranchId)) continue;
            var row = rows[p.EmployeeId];
            var extra = Math.Max(0, p.WorkedMinutes - (p.StandardMinutes > 0 ? p.StandardMinutes : DayLengthOf(p.EmployeeId)));
            row.DaysWorked++;
            row.WorkedMinutes += p.WorkedMinutes;
            row.OvertimeMinutes += extra;
            if (p.MissingPunch) row.MissingPunchDays++;
            row.NotOnRosterDays++;
            row.NotOnRosterMinutes += p.WorkedMinutes;
            report.Days.Add(new WorkedTimeDay
            {
                EmployeeId = p.EmployeeId,
                WorkDate = p.WorkDate.Date,
                BranchName = day.BranchName,
                Kind = "NotOnRoster",
                FirstIn = p.FirstIn,
                LastOut = p.LastOut,
                WorkedMinutes = p.WorkedMinutes,
                OvertimeMinutes = extra,
                MissingPunch = p.MissingPunch,
                Note = day.HolidayName,
                NoteAr = day.HolidayNameAr,
            });
        }

        foreach (var row in rows.Values)
        {
            row.ExpectedMinutes = (int)Math.Round(expected[row.EmployeeId], MidpointRounding.AwayFromZero);
            row.AverageMinutes = row.DaysWorked == 0 ? 0 : (int)Math.Round((decimal)row.WorkedMinutes / row.DaysWorked, MidpointRounding.AwayFromZero);
            row.ProgressPercent = Progress(row.WorkedMinutes, row.ExpectedMinutes);
        }

        report.Rows = rows.Values.OrderBy(r => r.FullName, StringComparer.OrdinalIgnoreCase).ThenBy(r => r.EmployeeId).ToList();
        var order = report.Rows.Select((r, i) => (r.EmployeeId, i)).ToDictionary(x => x.EmployeeId, x => x.i);
        report.Days = report.Days.OrderBy(d => order.GetValueOrDefault(d.EmployeeId, int.MaxValue)).ThenBy(d => d.WorkDate).ToList();
        report.Header.BranchName = input.BranchId is null
            ? null
            : input.EmployeeDays.FirstOrDefault(d => d.BranchId == input.BranchId)?.BranchName;

        var totals = new WorkedTimeRow
        {
            DaysWorked = report.Rows.Sum(r => r.DaysWorked),
            WorkedMinutes = report.Rows.Sum(r => r.WorkedMinutes),
            OvertimeMinutes = report.Rows.Sum(r => r.OvertimeMinutes),
            MissingPunchDays = report.Rows.Sum(r => r.MissingPunchDays),
            LeaveDays = report.Rows.Sum(r => r.LeaveDays),
            HolidayDays = report.Rows.Sum(r => r.HolidayDays),
            ExpectedMinutes = report.Rows.Sum(r => r.ExpectedMinutes),
            NotOnRosterDays = report.Rows.Sum(r => r.NotOnRosterDays),
            NotOnRosterMinutes = report.Rows.Sum(r => r.NotOnRosterMinutes),
        };
        totals.AverageMinutes = totals.DaysWorked == 0 ? 0 : (int)Math.Round((decimal)totals.WorkedMinutes / totals.DaysWorked, MidpointRounding.AwayFromZero);
        totals.ProgressPercent = Progress(totals.WorkedMinutes, totals.ExpectedMinutes);
        report.Totals = totals;
        return report;
    }

    private static decimal? Progress(int worked, int expected)
        => expected <= 0 ? null : Math.Round(worked * 100m / expected, 1, MidpointRounding.AwayFromZero);
}

/// <summary>What <see cref="WorkedTimeReportService.Build"/> needs.</summary>
public class WorkedTimeInput
{
    public DateTime From { get; set; }
    public DateTime To { get; set; }

    /// <summary>Beirut's today: the period is counted up to the day before.</summary>
    public DateTime Today { get; set; }

    public int? BranchId { get; set; }
    public WorkedTimeStandard Standard { get; set; } = new();
    public List<WorkedTimeEmployeeDay> EmployeeDays { get; set; } = [];
    public List<AttendanceRecord> Records { get; set; } = [];
    /// <summary>Punched days missing from an approved roster, measured from their punches (script 114).</summary>
    public List<WorkedTimePunchDay> PunchDays { get; set; } = [];
    public List<RosterLeaveDay> Leave { get; set; } = [];

    /// <summary>(employee, branch of the day) the caller may see.</summary>
    public Func<int, int?, bool> Sees { get; set; } = (_, _) => true;
    public DateTime GeneratedUtc { get; set; }
}
