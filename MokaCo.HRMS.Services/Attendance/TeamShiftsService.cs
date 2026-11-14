using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Services.Attendance;

public interface ITeamShiftsService
{
    /// <summary>The caller's branch's shifts from <paramref name="from"/> to <paramref name="to"/>, or null when the
    /// account is not linked to an employee.</summary>
    Task<TeamShifts?> GetAsync(int userId, DateTime from, DateTime to);
}

/// <summary>
/// "MY BRANCH'S SHIFTS" — the Weekly shifts poster for an employee, read-only.
///
/// THE BRANCH IS THE TOKEN'S EMPLOYEE'S, never read from the request, so the roster reads below run unscoped (no
/// caller) yet only ever return that one branch (by the branch each person belonged to ON the work date, like the
/// roster grid). What leaves this service is a name, a day and a shift: rest days, attendance and leave stay out,
/// and somebody on approved leave for the whole day is simply left off (a half day stays on, as on the poster).
/// </summary>
public class TeamShiftsService : ITeamShiftsService
{
    public const int MaxDays = 14;

    private readonly IRosterService _roster;
    private readonly IWorkflowSupportService _support;

    public TeamShiftsService(IRosterService roster, IWorkflowSupportService support)
    {
        _roster = roster;
        _support = support;
    }

    public async Task<TeamShifts?> GetAsync(int userId, DateTime from, DateTime to)
    {
        if (from == default || to == default) throw new WorkflowException(400, "Choose the first and the last day.");
        if (to.Date < from.Date) throw new WorkflowException(400, "The end of the period must be on or after its start.");
        if ((to.Date - from.Date).TotalDays + 1 > MaxDays) throw new WorkflowException(400, $"Choose at most {MaxDays} days at a time.");

        var me = await _support.GetEmployeeByUserIdAsync(userId);
        if (me is null) return null;

        var rows = await _roster.GetAsync(from.Date, to.Date, null, me.BranchId);
        var onLeave = (await _roster.GetLeaveDaysAsync(from.Date, to.Date, me.BranchId, null))
            .Where(l => l.DaysOnLeave >= 1)
            .Select(l => (l.EmployeeId, l.Date.Date))
            .ToHashSet();

        return new TeamShifts
        {
            BranchId = me.BranchId,
            BranchName = me.BranchName,
            From = from.Date,
            To = to.Date,
            Shifts = rows
                .Where(r => !r.IsRestDay && r.ShiftId is not null && !onLeave.Contains((r.EmployeeId, r.WorkDate.Date)))
                .OrderBy(r => r.WorkDate).ThenBy(r => r.StartTime).ThenBy(r => r.FullName)
                .Select(r => new TeamShift
                {
                    EmployeeId = r.EmployeeId,
                    FullName = r.FullName,
                    WorkDate = r.WorkDate.Date,
                    ShiftId = r.ShiftId!.Value,
                    ShiftName = r.ShiftName ?? string.Empty,
                    StartTime = r.StartTime,
                    EndTime = r.EndTime,
                })
                .ToList(),
        };
    }
}
