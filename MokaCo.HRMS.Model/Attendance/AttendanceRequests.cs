namespace MokaCo.HRMS.Model.Attendance;

/* ---- Devices & enrollment ---- */

public class DeviceCreateRequest
{
    /// <summary>The terminal's own serial. It is the identity a pushing device authenticates with, so it must match the hardware exactly.</summary>
    public string SerialNumber { get; set; } = string.Empty;

    /// <summary>Required: a terminal is a physical object and sits at a physical site.</summary>
    public int BranchId { get; set; }

    public int? DepartmentId { get; set; }
}

public class DeviceUpdateRequest
{
    public string SerialNumber { get; set; } = string.Empty;
    public int BranchId { get; set; }
    public int? DepartmentId { get; set; }

    /// <summary>Deactivating a device makes the punch endpoint reject it — the kill switch for a lost or stolen terminal.</summary>
    public bool IsActive { get; set; }
}

/// <summary>
/// Maps a device PIN to a person. Retroactive by design: punches already sitting unresolved on that
/// (device, PIN) are claimed immediately, which is why the response reports how many were recovered.
/// </summary>
public class EnrollmentMapRequest
{
    public int EmployeeId { get; set; }
    public int DeviceId { get; set; }

    /// <summary>A STRING, not a number — '0042' and '42' are different PINs to the device.</summary>
    public string EnrollPin { get; set; } = string.Empty;
}

/* ---- Shifts ---- */

public class ShiftCreateRequest
{
    public string Name { get; set; } = string.Empty;
    public TimeSpan StartTime { get; set; }
    public TimeSpan EndTime { get; set; }

    /// <summary>Arriving within this many minutes of the start is not late at all.</summary>
    public int GraceMinutes { get; set; }

    /// <summary>Set for an overnight shift (e.g. 22:00–06:00), or its length computes as negative.</summary>
    public bool CrossesMidnight { get; set; }

    /// <summary>Unpaid break, charged once — from the mid-day gap if there was one, otherwise off gross.</summary>
    public int BreakMinutes { get; set; }
}

public class ShiftUpdateRequest : ShiftCreateRequest
{
    public bool IsActive { get; set; }
}

/* ---- Roster ---- */

/// <summary>Sets ONE employee-day. What a click on a single calendar cell calls.</summary>
public class RosterDayRequest
{
    public int EmployeeId { get; set; }
    public DateTime WorkDate { get; set; }

    /// <summary>NULL together with IsRestDay = true means a rostered day off.</summary>
    public int? ShiftId { get; set; }

    public bool IsRestDay { get; set; }
}

/// <summary>
/// Generates one employee's roster across a range. Days OUTSIDE the weekday mask are written as
/// REST DAYS rather than left blank, so the roster comes out COMPLETE — a blank day is the one
/// thing the processor cannot interpret.
/// </summary>
public class RosterGenerateRequest
{
    public int EmployeeId { get; set; }
    public DateTime FromDate { get; set; }
    public DateTime ToDate { get; set; }
    public int ShiftId { get; set; }

    /// <summary>A 7-character mask, Monday first: '1111100' = Mon–Fri. '1' means a working day.</summary>
    public string Weekdays { get; set; } = "1111100";

    /// <summary>OFF by default, and it matters: leaving it off preserves manual changes HR has already made to days in this range.</summary>
    public bool Overwrite { get; set; }
}

/// <summary>The same generation for a whole team in one action.</summary>
public class RosterGenerateBulkRequest
{
    public List<int> EmployeeIds { get; set; } = new();
    public DateTime FromDate { get; set; }
    public DateTime ToDate { get; set; }
    public int ShiftId { get; set; }
    public string Weekdays { get; set; } = "1111100";
    public bool Overwrite { get; set; }
}

/// <summary>
/// Copies one month's roster onto another, aligned by WEEKDAY — a Monday shift lands on a Monday,
/// not on the same date number. This is how HR actually works: copy last month, then fix the
/// exceptions.
/// </summary>
public class RosterCopyPeriodRequest
{
    /// <summary>e.g. '2026-06'.</summary>
    public string SourceYearMonth { get; set; } = string.Empty;

    /// <summary>e.g. '2026-07'.</summary>
    public string TargetYearMonth { get; set; } = string.Empty;

    /// <summary>NULL = everyone.</summary>
    public int? EmployeeId { get; set; }

    public bool Overwrite { get; set; }
}

/// <summary>Expands employees' saved weekly patterns into real dated roster rows for a month.</summary>
public class RosterApplyPatternRequest
{
    public string YearMonth { get; set; } = string.Empty;
    public int? EmployeeId { get; set; }
    public bool Overwrite { get; set; }
}

/// <summary>One day of an employee's default week. Sent as a set of seven by the weekly-patterns editor.</summary>
public class ShiftPatternUpsertRequest
{
    /// <summary>ISO: 1 = Monday .. 7 = Sunday.</summary>
    public byte DayOfWeek { get; set; }

    public int? ShiftId { get; set; }
    public bool IsRestDay { get; set; }
}

/* ---- Ingestion ---- */

/// <summary>
/// A single punch pushed by a terminal. It carries a SERIAL, not a DeviceId — the device does not
/// know its database id. Authenticated by the device's own API key, not a user's JWT: there is no
/// human at a fingerprint reader.
/// </summary>
public class PunchRequest
{
    public string DeviceSerial { get; set; } = string.Empty;
    public string EnrollPin { get; set; } = string.Empty;
    public DateTime PunchTimeUtc { get; set; }

    /// <summary>0 = IN, 1 = OUT.</summary>
    public short PunchType { get; set; }
}

/* ---- HR overrides ---- */

/// <summary>
/// Creates or overrides a day by hand — the machine was down, or a punch simply never happened.
/// The day is still measured against the rostered shift by the same rules as a machine-read day,
/// so a manual day is not a special case in payroll's eyes. It sets IsManual, which locks the
/// processor out of the row for good.
/// </summary>
public class ManualAttendanceRequest
{
    public int EmployeeId { get; set; }
    public DateTime WorkDate { get; set; }
    public DateTime? FirstInUtc { get; set; }
    public DateTime? LastOutUtc { get; set; }

    /// <summary>A mid-day absence HR knows about. Comes off worked time.</summary>
    public int ExitMinutes { get; set; }

    /// <summary>How much of that absence was authorised. Kept apart from the actual, always.</summary>
    public int ExitApprovedMins { get; set; }

    /// <summary>Present / Absent / RestDay / Leave. NULL lets the procedure infer it from the roster and the punches.</summary>
    public string? Status { get; set; }

    public int? BranchId { get; set; }
    public string? HrNote { get; set; }
}

/// <summary>
/// Attaches an APPROVED exit permission to a day. It never overwrites what the punches observed —
/// approved and actual are independent facts.
/// </summary>
public class ExitApprovalRequest
{
    public int ExitApprovedMinutes { get; set; }
    public int? ExitPermissionId { get; set; }

    /// <summary>
    /// For the case where an exit WAS approved but the employee never punched for it, so attendance
    /// sees no gap at all. Setting this makes the approved minutes count as the actual and reduces
    /// worked time accordingly. It only ever fills a zero — it cannot overwrite an observed exit.
    /// </summary>
    public bool AlsoSetActual { get; set; }

    public string? HrNote { get; set; }
}

/// <summary>
/// HR's ruling on the difference between what was approved and what happened. This is the decision
/// payroll is waiting for; until it is made, the month cannot be paid.
/// </summary>
public class ExitDispositionRequest
{
    /// <summary>'UnpaidAbsence' (deduct it), 'Overtime' (offset against overtime worked), or 'Ignore' (no effect on pay).</summary>
    public string Disposition { get; set; } = string.Empty;

    /// <summary>Sets EXACTLY how many minutes come off the leave balance, overriding the configured basis. The "HR keeps full power" escape hatch.</summary>
    public int? ExitLeaveMinutesOverride { get; set; }

    public string? HrNote { get; set; }
}

/// <summary>
/// Adds or removes working time on a day for any reason. The note is MANDATORY: this changes pay,
/// and a year from now somebody will ask why.
/// </summary>
public class HrAdjustDayRequest
{
    /// <summary>Provide this OR DayFraction. If both are given, DayFraction wins.</summary>
    public int? WorkedMinutes { get; set; }

    /// <summary>The fraction of a day to credit, e.g. 0.5. Converted to minutes against this day's standard.</summary>
    public decimal? DayFraction { get; set; }

    public string? Status { get; set; }

    /// <summary>Required.</summary>
    public string HrNote { get; set; } = string.Empty;
}

/* ---- Corrections ---- */

/// <summary>
/// Requests a change to a processed day. Only the fields being changed need a value — a NULL means
/// "leave this as it is", not "clear it".
/// </summary>
public class CorrectionCreateRequest
{
    public long AttendanceId { get; set; }
    public DateTime? NewFirstInUtc { get; set; }
    public DateTime? NewLastOutUtc { get; set; }
    public int? NewExitMinutes { get; set; }
    public string? NewStatus { get; set; }

    /// <summary>Required. The record of WHY somebody's hours were changed.</summary>
    public string Reason { get; set; } = string.Empty;
}
