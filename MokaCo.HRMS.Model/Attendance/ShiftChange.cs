namespace MokaCo.HRMS.Model.Attendance;

/// <summary>
/// One line of a shift's change log (attendance.SHIFT_CHANGE, script 122): who changed what, when, from what to what.
/// The log is written by the database itself (triggers) and is never deleted, so it keeps what the hours timeline
/// (<see cref="ShiftHours"/>) cannot: a version overwritten, a change taken back, a rename, a shift switched off.
/// </summary>
public class ShiftChange
{
    /// <summary>Created, HoursChanged, HoursRemoved, Renamed, Deactivated, Activated, DaysNotRederived.</summary>
    public static class Actions
    {
        public const string Created = "Created";
        public const string HoursChanged = "HoursChanged";
        public const string HoursRemoved = "HoursRemoved";
        public const string Renamed = "Renamed";
        public const string Deactivated = "Deactivated";
        public const string Activated = "Activated";
        public const string DaysNotRederived = "DaysNotRederived";
    }

    public int ShiftChangeId { get; set; }
    public int ShiftId { get; set; }
    public DateTime ChangedAtUtc { get; set; }

    /// <summary>The day of the change, in Beirut.</summary>
    public DateTime ChangedOn { get; set; }

    public int? ChangedByUserId { get; set; }

    /// <summary>The person's name, else their user name; null when not known.</summary>
    public string? ChangedBy { get; set; }

    public string Action { get; set; } = string.Empty;

    /// <summary>Hours: the first day they apply (2000-01-01 = every day). Null for a name or active change.</summary>
    public DateTime? EffectiveFrom { get; set; }

    /// <summary>Hours: the last day they apply, when that was known at the change; null = until the next change.</summary>
    public DateTime? EffectiveTo { get; set; }

    public TimeSpan? OldStartTime { get; set; }
    public TimeSpan? NewStartTime { get; set; }
    public TimeSpan? OldEndTime { get; set; }
    public TimeSpan? NewEndTime { get; set; }
    public bool? OldCrossesMidnight { get; set; }
    public bool? NewCrossesMidnight { get; set; }
    public int? OldBreakMinutes { get; set; }
    public int? NewBreakMinutes { get; set; }

    /// <summary>On an hours line, null = the AttendanceToleranceMinutes setting.</summary>
    public int? OldGraceMinutes { get; set; }
    public int? NewGraceMinutes { get; set; }

    public string? OldName { get; set; }
    public string? NewName { get; set; }

    /// <summary>DaysNotRederived: how many days kept their old figures.</summary>
    public int? DaysCount { get; set; }

    public string? Note { get; set; }
}
