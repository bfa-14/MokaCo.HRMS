namespace MokaCo.HRMS.Model.Attendance;

/// <summary>
/// "MY BRANCH'S SHIFTS" (GET /api/me/team-shifts): who works which shift on which day in the signed-in employee's
/// branch. Only working days with a shift: no rest days, no attendance, and nobody on approved leave for the whole
/// day (the leave itself is never shown).
/// </summary>
public class TeamShifts
{
    public int BranchId { get; set; }
    public string BranchName { get; set; } = string.Empty;
    public DateTime From { get; set; }
    public DateTime To { get; set; }
    public List<TeamShift> Shifts { get; set; } = [];
}

public class TeamShift
{
    public int EmployeeId { get; set; }
    public string FullName { get; set; } = string.Empty;
    public DateTime WorkDate { get; set; }
    public int ShiftId { get; set; }
    public string ShiftName { get; set; } = string.Empty;
    public TimeSpan? StartTime { get; set; }
    public TimeSpan? EndTime { get; set; }
}
