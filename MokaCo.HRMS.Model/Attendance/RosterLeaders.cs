namespace MokaCo.HRMS.Model.Attendance;

/// <summary>
/// GET / PUT api/roster/auto/leaders (script 123): a branch's SHIFT LEADERS, whom the auto-roster never puts on the
/// same shift of a day when it can avoid it, whichever method plans.
///
/// Two sources make the leaders: the branch's own list (<see cref="EmployeeIds"/>, what the drawer's picker holds and
/// a PUT replaces) and the fixed-rotation list's Lead 1 / Lead 2 (script 116), which stay as they are.
/// <see cref="Leaders"/> is everybody, with where each comes from; <see cref="Candidates"/> who may be added. A PUT
/// ignores both.
/// </summary>
public class RosterLeadersDto
{
    public int BranchId { get; set; }

    /// <summary>The branch's own list (attendance.ROSTER_SHIFT_LEADER). A PUT replaces it; an empty list clears it.</summary>
    public List<int> EmployeeIds { get; set; } = new();

    /// <summary>Read only: every leader of the branch, its own list and the rotation's leads, one row per person.</summary>
    public List<RosterLeaderDto> Leaders { get; set; } = new();

    /// <summary>
    /// Read only (attendance.usp_AutoRoster_GetLeaderCandidates): who may be ADDED to the branch's own list - its people
    /// today, still employed - exactly whom a PUT accepts as new leaders. The picker offers them and the leaders already
    /// stored, so it never offers somebody the save would refuse.
    /// </summary>
    public List<RosterLeaderCandidateDto> Candidates { get; set; } = new();
}

/// <summary>attendance.usp_AutoRoster_GetLeaderCandidates, one row per person.</summary>
public class RosterLeaderCandidateDto
{
    public int EmployeeId { get; set; }
    public string FullName { get; set; } = string.Empty;
}

/// <summary>attendance.usp_AutoRoster_GetLeaders, one row per person.</summary>
public class RosterLeaderDto
{
    public int EmployeeId { get; set; }
    public string FullName { get; set; } = string.Empty;

    /// <summary>On the branch's own list.</summary>
    public bool IsStored { get; set; }

    /// <summary>"L1" or "L2" when Lead 1 / Lead 2 of the rotation list; null otherwise.</summary>
    public string? LeadSlot { get; set; }
}
