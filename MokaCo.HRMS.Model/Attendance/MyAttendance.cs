namespace MokaCo.HRMS.Model.Attendance;

/// <summary>
/// GET /api/me/attendance: the signed-in employee's own attendance — today's punches, the next seven days'
/// shifts and one month day by day, with HR's decisions on each day. HR's notes are never part of it.
/// </summary>
public class MyAttendance
{
    public int EmployeeId { get; set; }
    public string FullName { get; set; } = string.Empty;
    /// <summary>'yyyy-MM'.</summary>
    public string Month { get; set; } = string.Empty;
    /// <summary>The company's today (Beirut).</summary>
    public DateTime Today { get; set; }
    public List<MyPunch> TodayPunches { get; set; } = new();
    public List<MyAttendanceDay> NextDays { get; set; } = new();
    public List<MyAttendanceDay> Days { get; set; } = new();
    public MyAttendanceTotals Totals { get; set; } = new();
}

/// <summary>One punch as the machine recorded it (the terminal's own clock).</summary>
public class MyPunch
{
    public DateTime PunchTime { get; set; }
    /// <summary>0 = in, 1 = out, anything else = a device key.</summary>
    public short PunchType { get; set; }
    public string Source { get; set; } = string.Empty;
}

/// <summary>One day: what the roster planned and what attendance made of it.</summary>
public class MyAttendanceDay
{
    public DateTime WorkDate { get; set; }
    /// <summary>The roster has a row for the day (a shift or a rest day).</summary>
    public bool Rostered { get; set; }
    public bool IsRestDay { get; set; }
    public string? ShiftName { get; set; }
    public TimeSpan? StartTime { get; set; }
    public TimeSpan? EndTime { get; set; }
    /// <summary>Approved leave on the day: 1 = the whole day, 0.5 = half.</summary>
    public decimal LeaveDays { get; set; }
    /// <summary>Null = no attendance day (not yet processed, in the future, or not on the roster).</summary>
    public string? Status { get; set; }
    public DateTime? FirstIn { get; set; }
    public DateTime? LastOut { get; set; }
    public int WorkedMinutes { get; set; }
    public decimal? DayFraction { get; set; }
    public int LateMinutes { get; set; }
    public int ShortfallMinutes { get; set; }
    public bool HasAnomaly { get; set; }
    public bool IsManual { get; set; }
    /// <summary>Punched although the approved roster had no row: 'Open' (waiting for HR) or 'Dismissed'.</summary>
    public string? OffRosterState { get; set; }
    public List<MyDayDecision> Decisions { get; set; } = new();
}

/// <summary>A late arrival, an early departure or a missing punch, and what HR decided (without the note).</summary>
public class MyDayDecision
{
    /// <summary>LateArrival | EarlyDeparture | MissingPunch | HalfDayAbsence.</summary>
    public string Type { get; set; } = string.Empty;
    public int Minutes { get; set; }
    /// <summary>Excused | Deducted | Corrected, or null while HR has not decided.</summary>
    public string? Decision { get; set; }
    public DateTime? DecidedAt { get; set; }
}

public class MyAttendanceTotals
{
    public int DaysWorked { get; set; }
    public int WorkedMinutes { get; set; }
    public int LateDays { get; set; }
    public int LateMinutes { get; set; }
    public int AbsentDays { get; set; }
    public int ShortDays { get; set; }
    public int WaitingForHr { get; set; }
}
