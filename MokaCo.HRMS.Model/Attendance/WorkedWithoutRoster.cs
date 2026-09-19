namespace MokaCo.HRMS.Model.Attendance;

/// <summary>
/// An employee-day that has punches but NO attendance record, because the approved roster of the month gives the
/// employee no row for that day (SQL 83). Nothing is deducted for it and nothing is paid for it: HR either adds the
/// day to the roster — the next reprocess then derives it — or leaves it.
/// </summary>
public class WorkedWithoutRoster
{
    public int EmployeeId { get; set; }
    public string EmployeeName { get; set; } = string.Empty;
    public int BranchId { get; set; }
    public string BranchName { get; set; } = string.Empty;
    public DateTime WorkDate { get; set; }

    /// <summary>The terminal's wall clock, like every punch.</summary>
    public DateTime FirstPunch { get; set; }
    public DateTime LastPunch { get; set; }
    public int PunchCount { get; set; }

    /// <summary>First punch to last punch. A rough figure for HR's eye, not a measured day.</summary>
    public int WorkedMinutes { get; set; }
}

/// <summary>
/// One UNKNOWN DEVICE USER (D9): punches that arrived under a (device, PIN) enrolled to nobody. They are never
/// lost — they wait in attendance.DEVICE_PUNCH_QUARANTINE until HR says whose PIN it is.
/// </summary>
public class QuarantinedDeviceUser
{
    public int DeviceId { get; set; }
    public string? SerialNumber { get; set; }
    public string? DeviceName { get; set; }
    public int? BranchId { get; set; }
    public string? BranchName { get; set; }
    public string EnrollPin { get; set; } = string.Empty;
    public int PunchCount { get; set; }
    public DateTime FirstPunch { get; set; }
    public DateTime LastPunch { get; set; }
}

public class QuarantineMapRequest
{
    public int DeviceId { get; set; }
    public string EnrollPin { get; set; } = string.Empty;
    public int EmployeeId { get; set; }
}

/// <summary>What "map to employee" did: the punches that changed hands and the days they were replayed into.</summary>
public class QuarantineMapResult
{
    public int PunchesResolved { get; set; }
    public int DaysDerived { get; set; }

    /// <summary>Days the punches belong to that are already paid for this employee: left as they were paid.</summary>
    public int DaysAlreadyPaid { get; set; }
}
