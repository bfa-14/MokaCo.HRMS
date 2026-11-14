namespace MokaCo.HRMS.Model.Attendance;

/// <summary>
/// A day somebody punched on that the APPROVED roster of the month does not know (script 108,
/// attendance.usp_UnrosteredDay_GetList). No attendance record exists for it: nothing is paid and nothing is
/// deducted until a person decides what it was. The system never guesses a shift and never adds the roster row itself.
/// </summary>
public class UnrosteredDay
{
    public int EmployeeId { get; set; }
    public string EmployeeName { get; set; } = string.Empty;
    public int BranchId { get; set; }
    public string BranchName { get; set; } = string.Empty;
    public DateTime WorkDate { get; set; }

    /// <summary>The terminal's wall clock, like every punch: every raw punch of the day, either direction.</summary>
    public DateTime FirstPunch { get; set; }
    public DateTime LastPunch { get; set; }
    public int PunchCount { get; set; }

    /// <summary>First punch to last punch. A rough figure for the reader's eye, not a measured day.</summary>
    public int WorkedMinutes { get; set; }

    /// <summary>The day is the company's today (Beirut): the permission for today decides it, not the one for past days.</summary>
    public bool IsToday { get; set; }

    /// <summary>The period is already paid for this employee: nothing can be decided, a payroll adjustment is the only way.</summary>
    public bool IsPaid { get; set; }

    /// <summary>Before the hire date or after the termination date: it can be dismissed, not added to the roster.</summary>
    public bool OutsideEmployment { get; set; }

    /// <summary>A public holiday of the branch that day, when there is one (worked holidays carry a premium once the day is added).</summary>
    public string? HolidayName { get; set; }
    public string? HolidayNameAr { get; set; }

    /// <summary>The roster of the branch-month is waiting for approval: adding the day waits for that decision; dismissing does not.</summary>
    public int? OpenRosterRequestId { get; set; }

    /// <summary>Overtime already approved for the day. A rest day worked is paid only up to it.</summary>
    public int ApprovedOvertimeMinutes { get; set; }

    /// <summary>Open | Dismissed. A dismissal stands only while the day's punches are the ones it answered.</summary>
    public string State { get; set; } = "Open";

    /// <summary>The latest dismissal: its reason, who and when - also shown when <see cref="PunchesChanged"/> reopened the day.</summary>
    public string? DismissNote { get; set; }
    public string? DismissedBy { get; set; }
    public DateTime? DismissedAtUtc { get; set; }

    /// <summary>It was dismissed, and punches have arrived or changed since: the day is open again.</summary>
    public bool PunchesChanged { get; set; }

    /// <summary>May THIS caller decide THIS day: the permission of its date, the branch, and not a paid period. Read live from the role tables.</summary>
    public bool CanDecide { get; set; }
}

/// <summary>
/// POST /api/attendance/unrostered-days/decide. Shift (with ShiftId): the day joins the roster on that shift;
/// RestDay: it joins as a rest day that was worked; Dismiss (with Note): the punches were not work.
/// The first two derive the attendance day from its punches at once.
/// </summary>
public class UnrosteredDayDecisionRequest
{
    public int EmployeeId { get; set; }
    public DateTime WorkDate { get; set; }
    public string Decision { get; set; } = string.Empty;
    public int? ShiftId { get; set; }
    public string? Note { get; set; }
}

/// <summary>What the decision left behind: the roster row and the attendance day it derived (both null for a dismissal).</summary>
public class UnrosteredDayDecisionResult
{
    public int EmployeeId { get; set; }
    public DateTime WorkDate { get; set; }

    /// <summary>Shift | RestDay | Dismissed.</summary>
    public string Decision { get; set; } = string.Empty;
    public int? ShiftAssignmentId { get; set; }
    public long? AttendanceId { get; set; }
}

/// <summary>POST /api/attendance/unrostered-days/reopen: a dismissal taken back, the day is open again.</summary>
public class UnrosteredDayReopenRequest
{
    public int EmployeeId { get; set; }
    public DateTime WorkDate { get; set; }
}
