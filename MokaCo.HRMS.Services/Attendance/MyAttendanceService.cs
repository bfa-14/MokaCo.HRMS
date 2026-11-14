using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Services.Booking;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Services.Attendance;

public interface IMyAttendanceService
{
    /// <summary>The caller's own attendance, or null when the account is not linked to an employee.</summary>
    Task<MyAttendance?> GetAsync(int userId, string? month);
}

/// <summary>
/// "MY ATTENDANCE" — every employee's own days, for any account linked to an employee.
///
/// THE EMPLOYEE IS THE TOKEN'S, AND ONLY THE TOKEN'S: it is resolved from the user id and never read from the
/// request, so the reads below run unscoped (no caller) yet can only ever return this one person's rows. HR's notes
/// (the anomaly note, the dismissal note, the day's HR note) are left out on purpose: the employee sees WHAT was
/// decided and when, not HR's working.
/// </summary>
public class MyAttendanceService : IMyAttendanceService
{
    private readonly IAttendanceService _attendance;
    private readonly IRosterService _roster;
    private readonly IWorkflowSupportService _support;

    public MyAttendanceService(IAttendanceService attendance, IRosterService roster, IWorkflowSupportService support)
    {
        _attendance = attendance;
        _roster = roster;
        _support = support;
    }

    public async Task<MyAttendance?> GetAsync(int userId, string? month)
    {
        var me = await _support.GetEmployeeByUserIdAsync(userId);
        if (me is null) return null;

        var today = BeirutTime.Now.Date;
        var first = ParseMonth(month) ?? new DateTime(today.Year, today.Month, 1);
        var last = first.AddMonths(1).AddDays(-1);
        // One read per source covering the month AND the next seven days.
        var from = first < today ? first : today;
        var to = last > today.AddDays(7) ? last : today.AddDays(7);

        var roster = (await _roster.GetAsync(from, to, me.EmployeeId)).ToList();
        var records = (await _attendance.GetAsync(from, to, me.EmployeeId, null)).ToList();
        var leave = (await _roster.GetLeaveDaysAsync(from, to, null, null)).Where(l => l.EmployeeId == me.EmployeeId).ToList();
        var anomalies = (await _attendance.GetAnomaliesAsync(first, last, false, null)).Where(a => a.EmployeeId == me.EmployeeId).ToList();
        var offRoster = (await _attendance.GetUnrosteredDaysAsync(first, last, null, me.EmployeeId, null)).ToList();
        var punches = (await _attendance.GetRawAsync(me.EmployeeId, today)).ToList();

        MyAttendanceDay Day(DateTime date)
        {
            var plan = roster.FirstOrDefault(r => r.WorkDate.Date == date);
            var record = records.FirstOrDefault(r => r.WorkDate.Date == date);
            var day = new MyAttendanceDay
            {
                WorkDate = date,
                Rostered = plan is not null,
                IsRestDay = plan?.IsRestDay ?? false,
                ShiftName = plan?.ShiftName,
                StartTime = plan?.StartTime,
                EndTime = plan?.EndTime,
                LeaveDays = leave.Where(l => l.Date.Date == date).Sum(l => l.DaysOnLeave),
                OffRosterState = offRoster.FirstOrDefault(u => u.WorkDate.Date == date)?.State,
            };
            if (record is not null)
            {
                day.Status = record.Status;
                day.FirstIn = record.FirstInUtc;
                day.LastOut = record.LastOutUtc;
                day.WorkedMinutes = record.WorkedMinutes;
                day.DayFraction = record.DayFraction;
                day.LateMinutes = record.LateMinutes;
                day.ShortfallMinutes = record.ShortfallMinutes;
                day.HasAnomaly = record.HasAnomaly;
                day.IsManual = record.IsManual;
            }
            day.Decisions = anomalies
                .Where(a => a.WorkDate.Date == date)
                .Select(a => new MyDayDecision { Type = a.Type, Minutes = a.Minutes, Decision = a.Decision, DecidedAt = a.DecidedAt })
                .ToList();
            return day;
        }

        var days = Enumerable.Range(0, (last - first).Days + 1).Select(i => Day(first.AddDays(i))).ToList();
        var worked = days.Where(d => d.Status == "Present" && d.WorkDate < today).ToList();
        return new MyAttendance
        {
            EmployeeId = me.EmployeeId,
            FullName = me.FullName,
            Month = first.ToString("yyyy-MM"),
            Today = today,
            TodayPunches = punches
                .OrderBy(p => p.PunchTimeUtc)
                .Select(p => new MyPunch { PunchTime = p.PunchTimeUtc, PunchType = p.PunchType, Source = p.Source })
                .ToList(),
            NextDays = Enumerable.Range(1, 7).Select(i => Day(today.AddDays(i))).ToList(),
            Days = days,
            Totals = new MyAttendanceTotals
            {
                DaysWorked = worked.Count,
                WorkedMinutes = worked.Sum(d => d.WorkedMinutes),
                LateDays = worked.Count(d => d.LateMinutes > 0),
                LateMinutes = worked.Sum(d => d.LateMinutes),
                AbsentDays = days.Count(d => d.Status == "Absent"),
                ShortDays = worked.Count(d => d.ShortfallMinutes > 0 && d.DayFraction is < 1),
                // Today's open day is a shift in progress, not something waiting for HR.
                WaitingForHr = days.Count(d => d.OffRosterState == "Open" || (d.WorkDate < today && d.Decisions.Any(x => x.Decision is null))),
            },
        };
    }

    /// <summary>'yyyy-MM' to the first of that month; anything else is null (the current month is used).</summary>
    public static DateTime? ParseMonth(string? month)
        => DateTime.TryParseExact(month, "yyyy-MM", System.Globalization.CultureInfo.InvariantCulture,
               System.Globalization.DateTimeStyles.None, out var d) && d.Year >= 2000
            ? d
            : null;
}
