namespace MokaCo.HRMS.Model.Workflow;

/// <summary>
/// One day of a standing availability change: this weekday becomes available (on a shift) or not.
///
/// CAMEL CASE IS LOAD-BEARING, as it is for every JSON parameter in this codebase. The procedures'
/// OPENJSON reads $.dayOfWeek / $.isAvailable / $.shiftId, so PascalCase property names would parse
/// to NULLs and earn "The days could not be read" — a refusal that names the wrong cause.
///
/// ShiftId is meaningful only when <see cref="IsAvailable"/> is true; the procedure discards it
/// otherwise (<c>CASE WHEN IsAvailable=1 THEN ShiftId END</c>), so an unavailable day never keeps a
/// shift behind the scenes.
/// </summary>
public sealed record AvailabilityDay(byte DayOfWeek, bool IsAvailable, int? ShiftId);

/// <summary>
/// Raise a standing availability change — a rewrite of the employee's DEFAULT WEEK from a date
/// onwards, not a one-off absence.
///
/// ONLY THE CHANGED DAYS TRAVEL. The procedure stores exactly what it is sent and, at final approval,
/// MERGEs those rows into attendance.EMPLOYEE_SHIFT_PATTERN — so a day that is not in this list is a
/// day nobody asked to change, and it is left exactly as it was. Sending all seven would silently
/// restate the whole week as a change.
/// </summary>
public sealed class AvailabilityCreateRequest
{
    /// <summary>WHOSE availability this is. The API — not the database — enforces who may set it.</summary>
    public int EmployeeId { get; set; }

    /// <summary>Today or later. The procedure refuses a past date: a standing change cannot start behind you.</summary>
    public DateTime EffectiveFrom { get; set; }

    public List<AvailabilityDay> Days { get; set; } = new();

    public string? Reason { get; set; }

    /// <summary>Optional override. Left blank, the PROCEDURE composes the title, so its format lives in one place.</summary>
    public string? Title { get; set; }
}

/// <summary>
/// What raising an availability change produced.
///
/// <see cref="FutureConflicts"/> is ADVISORY and reported again at every decision: roster rows
/// already written past the effective date that put this person on a day they are asking to drop.
/// Approving does NOT rewrite them — the weekly template is a template, and dated rows somebody
/// already published are theirs to change — so a non-zero count here is a to-do list, not a refusal.
/// </summary>
public sealed class AvailabilityCreated
{
    public int RequestInstanceId { get; set; }
    public string Status { get; set; } = string.Empty;
    public int? CurrentStepNo { get; set; }
    public int FutureConflicts { get; set; }
}

/// <summary>
/// A decision on an availability change, optionally RESTATING the days.
///
/// <see cref="Days"/> is a FULL REPLACEMENT SET for the requested days, never a patch — the procedure
/// deletes the stored days and re-inserts these. Null means "approve as asked", which is the ordinary
/// case. A restatement needs the step's CanAdjust; the engine refuses it otherwise.
/// </summary>
public sealed class AvailabilityDecideRequest
{
    public List<AvailabilityDay>? Days { get; set; }
    public string? Comment { get; set; }

    /// <summary>Verified against the stored Argon2id hash BEFORE anything is written. Never logged or echoed.</summary>
    public string? Password { get; set; }
}

/// <summary>
/// What an availability decision returned: the engine's result, plus the conflict count recomputed
/// against whatever the days now say.
///
/// AT FINAL APPROVAL THE WEEKLY PATTERN IS REWRITTEN, once — the procedure guards on AppliedAt, so a
/// second approval on a reopened request cannot apply it twice. The payload's AppliedAt is what says
/// it happened.
/// </summary>
public sealed class AvailabilityDecisionResult : TypedDecisionResult
{
    public int FutureConflicts { get; set; }
}

/// <summary>The availability header (first result set of usp_Availability_GetPayload).</summary>
public sealed record AvailabilityHeader(
    int AvailabilityChangeId,
    int EmployeeId,
    string EmployeeName,
    DateTime EffectiveFrom,
    string? Reason,
    /// <summary>When the weekly pattern was actually rewritten. Null until the request closes Approved.</summary>
    DateTime? AppliedAt);

/// <summary>One requested day, with its weekday and shift named (second result set).</summary>
public sealed record AvailabilityPayloadDay(
    byte DayOfWeek,
    string DayName,
    bool IsAvailable,
    int? ShiftId,
    string? ShiftName);

/// <summary>Both result sets together — the shape the detail panel renders.</summary>
public sealed record AvailabilityPayload(
    AvailabilityHeader? Header,
    IReadOnlyList<AvailabilityPayloadDay> Days);

/// <summary>
/// A rostered day that contradicts the change: this person is scheduled on a weekday they asked to
/// drop, on or after the effective date.
///
/// THESE KEEP THEIR SHIFTS. Approving rewrites the template, not the dated rows already published, so
/// this is the list somebody has to fix by hand on the roster.
/// </summary>
public sealed record AvailabilityConflict(
    int ShiftAssignmentId,
    DateTime WorkDate,
    string DayName,
    string? ShiftName,
    string EmployeeName);
