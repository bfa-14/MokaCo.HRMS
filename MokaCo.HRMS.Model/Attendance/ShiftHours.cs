namespace MokaCo.HRMS.Model.Attendance;

/// <summary>
/// One row of a shift's history (attendance.SHIFT_HOURS, script 117): "from this day the shift runs these hours".
/// The hours of a day are the row in force on that day, so a change never re-judges the days before it.
/// </summary>
public class ShiftHours
{
    public int ShiftHoursId { get; set; }
    public int ShiftId { get; set; }

    /// <summary>The first day these hours apply (the shift's first row: 2000-01-01, i.e. "from the start").</summary>
    public DateTime EffectiveFrom { get; set; }

    /// <summary>The last day they apply - the day before the next row. Null on the latest row.</summary>
    public DateTime? EffectiveTo { get; set; }

    public TimeSpan StartTime { get; set; }
    public TimeSpan EndTime { get; set; }
    public bool CrossesMidnight { get; set; }
    public int BreakMinutes { get; set; }
    public int? GraceMinutes { get; set; }

    /// <summary>End - start - break: the length of a working day on these hours.</summary>
    public int StandardMinutes { get; set; }

    public string? Note { get; set; }
    public string? CreatedBy { get; set; }
    public DateTime CreatedAtUtc { get; set; }

    /// <summary>The shift's first hours: they cannot be removed.</summary>
    public bool IsFirst { get; set; }

    /// <summary>The row in force today.</summary>
    public bool IsCurrent { get; set; }
}

/// <summary>What taking a change of hours back did.</summary>
public class ShiftHoursChangeResult
{
    /// <summary>Days derived again against the hours now in force for them.</summary>
    public int DaysRederived { get; set; }
}
