using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Model.Report;
using MokaCo.HRMS.Repository.Report;
using MokaCo.HRMS.Services.Attendance;
using MokaCo.HRMS.Services.Booking;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Services.Report;

public interface IWorkedTimeReportService
{
    /// <summary>The Worked time report for the period; <paramref name="sees"/> keeps the employees the caller may see.</summary>
    Task<WorkedTimeReport> GetAsync(DateTime from, DateTime to, int? branchId, int? employeeId, Func<int, bool> sees);
}

/// <summary>
/// WORKED TIME — days and hours worked and the progress against the standard month, for any period, with or without
/// a roster (see <see cref="WorkedTimeReport"/> for the rules).
///
/// NOTHING IS RE-COMPUTED FROM RAW PUNCHES. The worked side is the attendance days the processor already builds (the
/// Daily attendance grid's read): punches paired, double presses removed, HR's corrections and manual days included -
/// so the report never disagrees with the day an employee is shown or paid on. Without an approved roster those days
/// are measured against the standard day, which is exactly the "attendance only" view. Punched days in an approved
/// month that are missing from its roster have no attendance day yet: they are listed apart as "to decide" with their
/// punch span, and stay out of the totals until somebody decides them.
///
/// The reads run unscoped and the caller's scope is applied here, to every row, day and total, like the other reports.
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

    public async Task<WorkedTimeReport> GetAsync(DateTime from, DateTime to, int? branchId, int? employeeId, Func<int, bool> sees)
    {
        if (from == default || to == default) throw new WorkflowException(400, "Choose the first and the last day.");
        from = from.Date;
        to = to.Date;
        if (to < from) throw new WorkflowException(400, "The end of the period must be on or after its start.");
        if ((to - from).TotalDays + 1 > MaxDays) throw new WorkflowException(400, $"Choose at most {MaxDays} days at a time.");

        var (standard, employeeDays) = await _reports.GetWorkedTimeDaysAsync(from, to, branchId, employeeId);
        var records = await _attendance.GetAsync(from, to, employeeId, branchId);
        var unrostered = await _attendance.GetUnrosteredDaysAsync(from, to, branchId, employeeId, null);
        var leave = await _roster.GetLeaveDaysAsync(from, to, branchId, null);

        return Build(new WorkedTimeInput
        {
            From = from,
            To = to,
            Today = BeirutTime.Now.Date,
            BranchId = branchId,
            Standard = standard,
            EmployeeDays = employeeDays.ToList(),
            Records = records.ToList(),
            Unrostered = unrostered.ToList(),
            Leave = leave.Where(l => employeeId is null || l.EmployeeId == employeeId).ToList(),
            Sees = sees,
            GeneratedUtc = DateTime.UtcNow,
        });
    }

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

        var rows = new Dictionary<int, WorkedTimeRow>();
        var expected = new Dictionary<int, decimal>();
        WorkedTimeRow RowOf(int employeeId, string name, string branch, string department = "")
        {
            if (!rows.TryGetValue(employeeId, out var row))
            {
                row = new WorkedTimeRow { EmployeeId = employeeId, FullName = name, BranchName = branch, DepartmentName = department };
                rows[employeeId] = row;
                expected[employeeId] = 0;
            }
            return row;
        }

        var leave = input.Leave
            .Where(l => input.Sees(l.EmployeeId) && l.DaysOnLeave > 0)
            .GroupBy(l => (l.EmployeeId, l.Date.Date))
            .ToDictionary(g => g.Key, g => Math.Min(1m, g.Sum(l => l.DaysOnLeave)));
        var recordDays = input.Records
            .Where(r => input.Sees(r.EmployeeId))
            .Select(r => (r.EmployeeId, r.WorkDate.Date))
            .ToHashSet();

        // EXPECTED: the standard month spread over its calendar days, for the days employed (in the branch, when one
        // is chosen). A public holiday expects nothing; approved leave expects nothing (half a day of leave, half).
        foreach (var day in input.EmployeeDays.Where(d => input.Sees(d.EmployeeId)).OrderBy(d => d.WorkDate))
        {
            var row = RowOf(day.EmployeeId, day.FullName, day.BranchName, day.DepartmentName);
            row.FullName = day.FullName;
            row.DepartmentName = day.DepartmentName;
            row.BranchName = day.BranchName; // the latest day's branch wins: where they are now in this period
            if (!IsCounted(day.WorkDate)) continue;

            var date = day.WorkDate.Date;
            var hasRecord = recordDays.Contains((day.EmployeeId, date));
            if (day.HolidayName is not null)
            {
                row.HolidayDays++;
                if (!hasRecord)
                    report.Days.Add(new WorkedTimeDay
                    {
                        EmployeeId = day.EmployeeId, WorkDate = date, BranchName = day.BranchName, Kind = "Holiday", Note = day.HolidayName,
                    });
                continue;
            }

            var perDay = input.Standard.StandardDaysPerMonth * input.Standard.StandardDayMinutes / DateTime.DaysInMonth(date.Year, date.Month);
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

        // WORKED: the attendance days. A day counts as worked when it has a first punch and is not a leave or an
        // absence (a worked rest day or holiday counts).
        foreach (var r in input.Records.Where(r => input.Sees(r.EmployeeId) && IsCounted(r.WorkDate)))
        {
            var row = RowOf(r.EmployeeId, r.FullName, r.BranchName ?? string.Empty);
            var worked = r.FirstInUtc is not null && r.Status is "Present" or "RestDay" or "Holiday";
            if (worked)
            {
                row.DaysWorked++;
                row.WorkedMinutes += r.WorkedMinutes;
                row.OvertimeMinutes += r.OvertimeMinutes;
                if (r.HasAnomaly) row.MissingPunchDays++;
            }
            report.Days.Add(new WorkedTimeDay
            {
                EmployeeId = r.EmployeeId,
                WorkDate = r.WorkDate.Date,
                BranchName = r.BranchName ?? string.Empty,
                Kind = r.Status,
                FirstIn = r.FirstInUtc,
                LastOut = r.LastOutUtc,
                WorkedMinutes = worked ? r.WorkedMinutes : 0,
                OvertimeMinutes = worked ? r.OvertimeMinutes : 0,
                MissingPunch = worked && r.HasAnomaly,
                IsManual = r.IsManual,
            });
        }

        // TO DECIDE: punched, not on the approved roster, no attendance day yet. Apart, never in the totals.
        foreach (var u in input.Unrostered.Where(u => input.Sees(u.EmployeeId) && u.State == "Open" && IsCounted(u.WorkDate)))
        {
            var row = RowOf(u.EmployeeId, u.EmployeeName, u.BranchName);
            row.NotOnRosterDays++;
            row.NotOnRosterMinutes += u.WorkedMinutes;
            report.Days.Add(new WorkedTimeDay
            {
                EmployeeId = u.EmployeeId,
                WorkDate = u.WorkDate.Date,
                BranchName = u.BranchName,
                Kind = "NotOnRoster",
                FirstIn = u.FirstPunch,
                LastOut = u.PunchCount > 1 ? u.LastPunch : null,
                WorkedMinutes = u.WorkedMinutes,
            });
        }

        foreach (var row in rows.Values)
        {
            row.ExpectedMinutes = (int)Math.Round(expected[row.EmployeeId], MidpointRounding.AwayFromZero);
            row.AverageMinutes = row.DaysWorked == 0 ? 0 : (int)Math.Round((decimal)row.WorkedMinutes / row.DaysWorked, MidpointRounding.AwayFromZero);
            row.ProgressPercent = Progress(row.WorkedMinutes, row.ExpectedMinutes);
        }

        report.Rows = rows.Values.OrderBy(r => r.FullName, StringComparer.OrdinalIgnoreCase).ThenBy(r => r.EmployeeId).ToList();
        report.Days = report.Days.OrderBy(d => report.Rows.FindIndex(r => r.EmployeeId == d.EmployeeId)).ThenBy(d => d.WorkDate).ToList();
        report.Header.BranchName = input.BranchId is null
            ? null
            : input.EmployeeDays.FirstOrDefault(d => d.BranchId == input.BranchId)?.BranchName
              ?? input.Records.FirstOrDefault(r => r.BranchId == input.BranchId)?.BranchName;

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
    public List<UnrosteredDay> Unrostered { get; set; } = [];
    public List<RosterLeaveDay> Leave { get; set; } = [];
    public Func<int, bool> Sees { get; set; } = _ => true;
    public DateTime GeneratedUtc { get; set; }
}
