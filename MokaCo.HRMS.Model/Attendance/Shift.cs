namespace MokaCo.HRMS.Model.Attendance;

/// <summary>
/// Maps to attendance.SHIFT. A shift is what gives the words "late", "a full day" and "overtime"
/// a meaning for a given person on a given date. Without a rostered shift the processor falls back
/// to core.SETTING.StandardWorkDayHours and CANNOT judge lateness at all (there is no start time
/// to be late against).
/// </summary>
public class Shift
{
    public int ShiftId { get; set; }
    public string Name { get; set; } = string.Empty;

    public TimeSpan StartTime { get; set; }
    public TimeSpan EndTime { get; set; }

    /// <summary>
    /// This shift's own tolerance, in minutes, or NULL to follow the AttendanceToleranceMinutes
    /// setting (script 77). An arrival this many minutes or more after the start, or a departure
    /// this many minutes or more before the end, is an anomaly for HR to decide; below it the day
    /// counts as on time.
    /// </summary>
    public int? GraceMinutes { get; set; }

    /// <summary>
    /// 1 = the shift ends the NEXT day (e.g. 22:00–06:00). Such a shift belongs to the day it
    /// STARTS on, and its length is computed with +1440 minutes rather than coming out negative.
    /// </summary>
    public bool CrossesMidnight { get; set; }

    /// <summary>
    /// Unpaid break. Charged ONCE: if the employee punched out for it the gap already covers it,
    /// so only the shortfall is taken off gross. Someone who never punches out for lunch does not
    /// get a free extra half hour.
    /// </summary>
    public int BreakMinutes { get; set; }

    public bool IsActive { get; set; }
}
