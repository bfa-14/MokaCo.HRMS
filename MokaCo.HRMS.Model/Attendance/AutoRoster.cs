namespace MokaCo.HRMS.Model.Attendance;

/*
 * AUTO-ROSTER (6/5 rhythm, fair weekends) — docs/AUTO_ROSTER.md is the specification.
 *
 * Two families of types live here:
 *   - the API's JSON (§4): camelCase, dates as DateOnly ("yyyy-MM-dd"), every enumeration a plain
 *     string so a value from a newer server renders as itself instead of failing to deserialize;
 *   - the rows of attendance.usp_AutoRoster_GetContext (§3.3), named exactly like the procedure's
 *     columns and typed DateTime, because that is what Dapper maps a DATE column to.
 * The planner (Services/Attendance/AutoRoster) reads the second family and answers in the first.
 */

/* ======================================================================================
 * Request
 * ==================================================================================== */

/// <summary>
/// One run of the auto-roster for a branch and month: what the drawer sends to POST preview, and
/// (with the cells) to POST commit. Nothing in it is saved by a preview; the commit saves the rhythm
/// and remembers these parameters (ROSTER_AUTO_RUN.ParamsJson) as the drawer's next defaults.
/// </summary>
public class AutoRosterRequest
{
    public int BranchId { get; set; }

    /// <summary>"yyyy-MM", e.g. "2026-12".</summary>
    public string Month { get; set; } = string.Empty;

    /// <summary>FillEmpty · ReplanAuto · ReplanAll (D11).</summary>
    public string Mode { get; set; } = "FillEmpty";

    /// <summary>Aligned · Staggered; null = the RosterRhythmStart setting. Only decides rhythms not stored yet.</summary>
    public string? RhythmStart { get; set; }

    /// <summary>The shift a working day gets when neither the weekly pattern nor the last four weeks name one.</summary>
    public int? DefaultShiftId { get; set; }

    /// <summary>How many people work each public holiday. A holiday not listed is closed (cover 0).</summary>
    public List<HolidayCoverDto> HolidayCover { get; set; } = new();

    /// <summary>
    /// The staff the drawer has taken OFF rotation (shown, never planned). NULL means "as stored"
    /// (ROSTER_RHYTHM.OnRotation); a list — even an empty one — is the complete answer and overrides
    /// the stored flags, because the drawer always sends the whole staff list's state.
    /// </summary>
    public List<int>? OffRotationEmployeeIds { get; set; }

    /// <summary>"This week is a 5-day week": re-anchors an employee's 6/5 rhythm. Saved by the commit.</summary>
    public List<RhythmOverrideDto> RhythmOverrides { get; set; } = new();

    /// <summary>
    /// The manager's edits to the draft so far. Regenerate plans AROUND them: each is fixed exactly as
    /// sent, so a hand edit is never undone by the button that was meant to fill in the rest.
    /// </summary>
    public List<DraftCellDto> DraftCells { get; set; } = new();
}

/// <summary>Cover for one public holiday: how many people work it (0 = the branch is closed).</summary>
public class HolidayCoverDto
{
    public DateOnly Date { get; set; }
    public int Count { get; set; }
}

/// <summary>Re-anchor one employee: the week starting <see cref="WeekStart"/> has <see cref="WorkDays"/> (6 or 5) working days.</summary>
public class RhythmOverrideDto
{
    public int EmployeeId { get; set; }

    /// <summary>Any day of the week; the planner moves it back to that week's Monday.</summary>
    public DateOnly WeekStart { get; set; }

    public int WorkDays { get; set; }
}

/// <summary>
/// One cell the manager set by hand in the draft. A working day carries its shift; a rest day has
/// IsRestDay = true and no shift; no shift and not a rest day means "leave the day empty".
/// </summary>
public class DraftCellDto
{
    public int EmployeeId { get; set; }
    public DateOnly WorkDate { get; set; }
    public int? ShiftId { get; set; }
    public bool IsRestDay { get; set; }

    /// <summary>"Keep when regenerating" — saved as a pin by the commit.</summary>
    public bool? IsPinned { get; set; }
}

/* ======================================================================================
 * Preview
 * ==================================================================================== */

/// <summary>
/// The draft a preview returns. It WRITES NOTHING: the cells are drawn over the roster grid, edited
/// there, and only the commit saves them — each with the state it expected to find, so a roster that
/// changed in between is refused rather than overwritten.
/// </summary>
public class AutoRosterPreview
{
    public int BranchId { get; set; }

    /// <summary>The 1st of the target month.</summary>
    public DateOnly MonthDate { get; set; }

    /// <summary>Monday on/before the 1st — the planner works in whole Monday–Sunday weeks.</summary>
    public DateOnly WindowFrom { get; set; }

    /// <summary>Sunday on/after the last day.</summary>
    public DateOnly WindowTo { get; set; }

    /// <summary>
    /// Every cell of the window for the branch's staff on the days they belong to it. Only target-month
    /// cells are ever saved; the other days are context ("outside") or plans that were needed to make
    /// the straddling week work and that next month's run will redo ("ghost").
    /// </summary>
    public List<AutoRosterCell> Cells { get; set; } = new();

    public List<AutoRosterRhythm> Rhythm { get; set; } = new();
    public List<AutoRosterEmployeeCounters> PerEmployee { get; set; } = new();
    public List<AutoRosterDayCounters> PerDay { get; set; } = new();
    public List<AutoRosterIssue> Issues { get; set; } = new();
    public AutoRosterSummary Summary { get; set; } = new();
}

/// <summary>One employee-day of the draft.</summary>
public class AutoRosterCell
{
    public int EmployeeId { get; set; }
    public DateOnly WorkDate { get; set; }

    /// <summary>work · rest · none (none = no row: a public holiday off, or nothing known).</summary>
    public string State { get; set; } = "none";

    public int? ShiftId { get; set; }

    /// <summary>planned · fact · locked · pinned · leave · holiday · draft · ghost · outside.</summary>
    public string Origin { get; set; } = "planned";

    /// <summary>
    /// insert · update · delete · unchanged · kept. "kept" is a cell this run may not touch (a fact,
    /// a locked or pinned day, a ghost) and is never sent back to the commit.
    /// </summary>
    public string Change { get; set; } = "kept";

    public string? ReasonCode { get; set; }

    /// <summary>A small JSON object with the reason's figures (e.g. {"owed":0.86}); null when there are none.</summary>
    public string? ReasonArgs { get; set; }

    /// <summary>The row as the preview found it — echoed back by the commit as its optimistic-concurrency check.</summary>
    public RosterCellExpected Expected { get; set; } = new();
}

/// <summary>The SHIFT_ASSIGNMENT row a cell had when it was read (Exists = false: no row).</summary>
public class RosterCellExpected
{
    public bool Exists { get; set; }
    public int? ShiftId { get; set; }
    public bool? IsRestDay { get; set; }
}

/// <summary>An employee's 6/5 anchor: the week <see cref="AnchorWeekStart"/> has <see cref="AnchorWorkDays"/> working days, then it alternates.</summary>
public class AutoRosterRhythm
{
    public int EmployeeId { get; set; }

    /// <summary>A Monday.</summary>
    public DateOnly AnchorWeekStart { get; set; }

    /// <summary>6 or 5.</summary>
    public int AnchorWorkDays { get; set; }

    /// <summary>Not stored yet, or changed by an override: the commit will save it.</summary>
    public bool IsNew { get; set; }
}

/// <summary>The counters beside an employee's row of the grid.</summary>
public class AutoRosterEmployeeCounters
{
    public int EmployeeId { get; set; }

    /// <summary>Working days in the target month, in this branch (D14: compare with payroll's 26).</summary>
    public int WorkDays { get; set; }

    public int RestDays { get; set; }
    public int SaturdaysOff { get; set; }
    public int SundaysOff { get; set; }

    /// <summary>
    /// The weekend fair-share balance after this plan: positive = owed Saturdays (Sundays) off,
    /// negative = has had more than a fair share. Recomputed from real rows; nothing stores it (D9).
    /// </summary>
    public double OwedSaturday { get; set; }

    public double OwedSunday { get; set; }

    /// <summary>The 6·5 strip, one entry per window week. Empty for staff off rotation.</summary>
    public List<AutoRosterWeekCounter> Weeks { get; set; } = new();
}

/// <summary>One week of the 6·5 strip.</summary>
public class AutoRosterWeekCounter
{
    public DateOnly WeekStart { get; set; }

    /// <summary>The rhythm's type for this week: 6 or 5.</summary>
    public int WorkDays { get; set; }

    /// <summary>Rest days the week holds (any branch, leave days excluded).</summary>
    public int Rests { get; set; }

    /// <summary>Rest days the week should hold (§2.3) — less than 7 − WorkDays when part of the week is not employed.</summary>
    public int Quota { get; set; }

    /// <summary>Rests = Quota, or the shortfall was absorbed by a leave. Drawn red when false.</summary>
    public bool Ok { get; set; }
}

/// <summary>The footer cell under a day: on duty against the branch's minimum.</summary>
public class AutoRosterDayCounters
{
    public DateOnly Date { get; set; }
    public int OnDuty { get; set; }

    /// <summary>The minimum for this day (on a public holiday, the cover asked for); null when none is set.</summary>
    public int? Min { get; set; }

    public int? Target { get; set; }
}

/// <summary>
/// Something the planner could not satisfy, or a rule an edit breaks. Nothing is silently broken:
/// an error blocks the commit (400), a warning and an info are shown and saved past.
/// </summary>
public class AutoRosterIssue
{
    /// <summary>error · warning · info.</summary>
    public string Severity { get; set; } = "info";

    /// <summary>The §2.7 code (MONTH_LOCKED, WORK_WITHOUT_SHIFT, REST_ON_HOLIDAY, CONSECUTIVE_CAP, …); the web translates it.</summary>
    public string Code { get; set; } = string.Empty;

    public int? EmployeeId { get; set; }
    public DateOnly? Date { get; set; }

    /// <summary>An English sentence with the figures, for logs and for a client that does not know the code.</summary>
    public string Message { get; set; } = string.Empty;
}

/// <summary>What saving the draft would do to the target month's rows.</summary>
public class AutoRosterSummary
{
    public int Inserts { get; set; }
    public int Updates { get; set; }
    public int Deletes { get; set; }
    public int Unchanged { get; set; }
    public int Kept { get; set; }
}

/* ======================================================================================
 * Commit
 * ==================================================================================== */

/// <summary>
/// Save a (possibly edited) draft in one atomic call. The request part is re-planned server side only
/// to re-validate; what is written is exactly <see cref="Cells"/>, and each cell is checked against
/// its <see cref="AutoRosterCommitCell.Expected"/> state under lock.
/// </summary>
public class AutoRosterCommitRequest : AutoRosterRequest
{
    public List<AutoRosterCommitCell> Cells { get; set; } = new();
    public List<AutoRosterCommitRhythm> Rhythm { get; set; } = new();
}

/// <summary>One target-month cell to write: upsert a working/rest row, or delete the row (a holiday off).</summary>
public class AutoRosterCommitCell
{
    public int EmployeeId { get; set; }
    public DateOnly WorkDate { get; set; }

    /// <summary>upsert · delete.</summary>
    public string Action { get; set; } = "upsert";

    public int? ShiftId { get; set; }
    public bool IsRestDay { get; set; }
    public RosterCellExpected Expected { get; set; } = new();

    /// <summary>
    /// True when the planner chose this value (ROSTER_CELL remembers it as the AUTO value, so
    /// ReplanAuto may change it later); false for the manager's own edit, which then survives ReplanAuto.
    /// </summary>
    public bool IsAuto { get; set; }

    public string? ReasonCode { get; set; }

    /// <summary>null = leave the pin as it is.</summary>
    public bool? IsPinned { get; set; }
}

/// <summary>A rhythm (and the on-rotation flag) the commit stores in attendance.ROSTER_RHYTHM.</summary>
public class AutoRosterCommitRhythm
{
    public int EmployeeId { get; set; }
    public DateOnly AnchorWeekStart { get; set; }
    public int AnchorWorkDays { get; set; }
    public bool OnRotation { get; set; } = true;
}

/// <summary>What usp_AutoRoster_Commit wrote. Unchanged cells are not counted: they were not touched.</summary>
public class AutoRosterCommitResult
{
    public int RunId { get; set; }
    public int RowsInserted { get; set; }
    public int RowsUpdated { get; set; }
    public int RowsDeleted { get; set; }
}

/* ======================================================================================
 * Setup (GET setup) and the small endpoints
 * ==================================================================================== */

/// <summary>Everything the drawer opens with.</summary>
public class AutoRosterSetup
{
    public int BranchId { get; set; }
    public DateOnly MonthDate { get; set; }
    public AutoRosterSettings Settings { get; set; } = new();
    public List<AutoRosterSetupStaff> Staff { get; set; } = new();
    public List<StaffingRequirementDto> Staffing { get; set; } = new();
    public List<AutoRosterSetupHoliday> Holidays { get; set; } = new();

    /// <summary>Active shifts only — an inactive shift is never written.</summary>
    public List<AutoRosterSetupShift> Shifts { get; set; } = new();

    /// <summary>The parameters of the branch's last saved run, as the drawer's defaults. Null before the first run.</summary>
    public AutoRosterRequest? LastParams { get; set; }

    public string? MonthStatus { get; set; }

    /// <summary>A roster approval waiting on this month: the whole month is read-only until it is decided.</summary>
    public int? OpenRequestId { get; set; }
}

/// <summary>The §3.2 settings (section 'Roster'), typed; the JSON names are the keys in camelCase.</summary>
public class AutoRosterSettings
{
    public string RosterRhythmStart { get; set; } = "Aligned";
    public bool RosterHolidayCountsAsRest { get; set; }
    public int RosterMaxConsecutiveWorkDays { get; set; } = 7;
    public int RosterPreferredMaxConsecutiveWorkDays { get; set; } = 6;
    public int RosterFairnessLookbackWeeks { get; set; } = 26;
    public bool RosterPairRestDays { get; set; } = true;
    public string RosterPatternRestDays { get; set; } = "Preference";
    public int RosterMinHoursBetweenShifts { get; set; } = 11;
    public int RosterMinWeeklyRestHours { get; set; } = 36;
}

/// <summary>A row of the drawer's staff list.</summary>
public class AutoRosterSetupStaff
{
    public int EmployeeId { get; set; }
    public string FullName { get; set; } = string.Empty;
    public string? Position { get; set; }
    public bool OnRotation { get; set; } = true;

    /// <summary>The stored anchor, if any.</summary>
    public DateOnly? AnchorWeekStart { get; set; }

    public int? AnchorWorkDays { get; set; }

    /// <summary>6 or 5: the type of the month's first week as the planner would use it now (stored, or the default rule).</summary>
    public int FirstWeekWorkDays { get; set; }
}

public class AutoRosterSetupHoliday
{
    public DateOnly Date { get; set; }
    public string Name { get; set; } = string.Empty;
    public bool IsPaid { get; set; }
}

public class AutoRosterSetupShift
{
    public int ShiftId { get; set; }
    public string Name { get; set; } = string.Empty;
}

/// <summary>
/// A pin/auto marker of a saved day (GET cells). IsAuto: the row still equals what the generator
/// wrote — any other writer (a hand edit, copy-period, a swap) makes it manual without being changed.
/// </summary>
public class RosterCellInfo
{
    public int EmployeeId { get; set; }
    public DateOnly WorkDate { get; set; }
    public bool IsPinned { get; set; }
    public bool IsAuto { get; set; }
    public string? ReasonCode { get; set; }
}

/// <summary>
/// The Dapper row of attendance.usp_RosterCell_GetRange (DATE arrives as DateTime); <see cref="ToDto"/>
/// gives the API's <see cref="RosterCellInfo"/>.
/// </summary>
public class RosterCellInfoRow
{
    public int EmployeeId { get; set; }
    public DateTime WorkDate { get; set; }
    public bool IsPinned { get; set; }
    public bool IsAuto { get; set; }
    public string? ReasonCode { get; set; }

    public RosterCellInfo ToDto() => new()
    {
        EmployeeId = EmployeeId,
        WorkDate = DateOnly.FromDateTime(WorkDate),
        IsPinned = IsPinned,
        IsAuto = IsAuto,
        ReasonCode = ReasonCode,
    };
}

/// <summary>
/// Minimum (and optional target) on duty for a branch. DayOfWeek 1 = Monday .. 7 = Sunday, NULL = every
/// day; ShiftId NULL = any shift. A weekday row beats an every-day row for the same shift.
/// Rest days beat staffing: a day below the minimum is reported, nobody loses a rest day to cover it.
/// </summary>
public class StaffingRequirementDto
{
    public int? DayOfWeek { get; set; }
    public int? ShiftId { get; set; }
    public int MinOnDuty { get; set; }
    public int? TargetOnDuty { get; set; }
}

/// <summary>PUT rhythm: take someone off (or back on) rotation, and optionally set their anchor.</summary>
public class RosterRhythmDto
{
    public int EmployeeId { get; set; }
    public bool OnRotation { get; set; } = true;
    public DateOnly? AnchorWeekStart { get; set; }
    public int? AnchorWorkDays { get; set; }
}

/// <summary>PUT pin.</summary>
public class RosterPinRequest
{
    public int EmployeeId { get; set; }
    public DateOnly WorkDate { get; set; }
    public bool IsPinned { get; set; }
}

/* ======================================================================================
 * attendance.usp_AutoRoster_GetContext — the 15 result sets, in order (§3.3)
 * ==================================================================================== */

/// <summary>Everything the planner reads, one list per result set. Filled by the repository; read only by the planner.</summary>
public class AutoRosterContext
{
    public AutoRosterContextHeader Header { get; set; } = new();
    public List<AutoRosterSettingRow> Settings { get; set; } = new();
    public List<AutoRosterStaffRow> Staff { get; set; } = new();
    public List<AutoRosterStaffDayRow> StaffDays { get; set; } = new();
    public List<AutoRosterRowRow> Rows { get; set; } = new();
    public List<AutoRosterLockRow> Locks { get; set; } = new();
    public List<AutoRosterHolidayRow> Holidays { get; set; } = new();
    public List<AutoRosterHolidaysWorkedRow> HolidaysWorked { get; set; } = new();
    public List<AutoRosterLeaveRow> Leaves { get; set; } = new();
    public List<AutoRosterShiftRow> Shifts { get; set; } = new();
    public List<AutoRosterPatternRow> Patterns { get; set; } = new();
    public List<AutoRosterRhythmRow> Rhythm { get; set; } = new();
    public List<AutoRosterCellRow> Cells { get; set; } = new();
    public List<AutoRosterStaffingRow> Staffing { get; set; } = new();

    /// <summary>0 or 1 row.</summary>
    public List<AutoRosterLastRunRow> LastRun { get; set; } = new();
}

/// <summary>Result set 1. Today is the Beirut date, read by the database so the planner never looks at a clock.</summary>
public class AutoRosterContextHeader
{
    public int BranchId { get; set; }
    public string BranchName { get; set; } = string.Empty;
    public DateTime MonthDate { get; set; }
    public DateTime WindowFrom { get; set; }
    public DateTime WindowTo { get; set; }
    public DateTime HistoryFrom { get; set; }
    public DateTime Today { get; set; }
    public string? MonthStatus { get; set; }
    public int? OpenRequestId { get; set; }
}

/// <summary>Result set 2: core.SETTING rows whose key starts with 'Roster'.</summary>
public class AutoRosterSettingRow
{
    public string SettingKey { get; set; } = string.Empty;
    public string? SettingValue { get; set; }
}

/// <summary>Result set 3: employees employed on at least one window day whose branch of that day is the target.</summary>
public class AutoRosterStaffRow
{
    public int EmployeeId { get; set; }
    public string FullName { get; set; } = string.Empty;
    public int? PositionId { get; set; }
    public string? Position { get; set; }
    public DateTime? HireDate { get; set; }
    public DateTime? TerminationDate { get; set; }
}

/// <summary>Result set 4: every EMPLOYED day HistoryFrom..WindowTo with the branch of that day. A missing day = not employed. (After the window the planner goes by HireDate/TerminationDate.)</summary>
public class AutoRosterStaffDayRow
{
    public int EmployeeId { get; set; }
    public DateTime WorkDate { get; set; }
    public int BranchId { get; set; }
}

/// <summary>
/// Result set 5: SHIFT_ASSIGNMENT rows of the staff, all branches, HistoryFrom..WindowTo + RosterMaxConsecutiveWorkDays:
/// the days after the window are the following month's (saved first, perhaps), whose opening run joins this window's last.
/// </summary>
public class AutoRosterRowRow
{
    public int EmployeeId { get; set; }
    public DateTime WorkDate { get; set; }
    public int? ShiftId { get; set; }
    public bool IsRestDay { get; set; }
}

/// <summary>Result set 6: target-month days the guard would refuse — Reason Paid · Past · Recorded.</summary>
public class AutoRosterLockRow
{
    public int EmployeeId { get; set; }
    public DateTime WorkDate { get; set; }
    public string Reason { get; set; } = string.Empty;
}

/// <summary>Result set 7: public holidays (all-branch rows and the branch's own), 12 months before the window to its end.</summary>
public class AutoRosterHolidayRow
{
    public DateTime HolidayDate { get; set; }
    public int? BranchId { get; set; }
    public bool IsPaid { get; set; }
    public string Name { get; set; } = string.Empty;
}

/// <summary>Result set 8: working rows on those holidays in the 12 months before the window — who has covered most.</summary>
public class AutoRosterHolidaysWorkedRow
{
    public int EmployeeId { get; set; }
    public int Days { get; set; }
}

/// <summary>Result set 9: Approved/Pending/OnHold leave overlapping HistoryFrom..WindowTo + RosterMaxConsecutiveWorkDays (as the rows). HalfDay AM/PM, NULL = full days.</summary>
public class AutoRosterLeaveRow
{
    public int EmployeeId { get; set; }
    public DateTime FromDate { get; set; }
    public DateTime ToDate { get; set; }
    public string? HalfDay { get; set; }
    public string Status { get; set; } = string.Empty;
    public bool IsPaid { get; set; }
}

/// <summary>Result set 10: every shift, active or not (facts may still point at an inactive one).</summary>
public class AutoRosterShiftRow
{
    public int ShiftId { get; set; }
    public string Name { get; set; } = string.Empty;
    public TimeSpan StartTime { get; set; }
    public TimeSpan EndTime { get; set; }
    public bool CrossesMidnight { get; set; }
    public int BreakMinutes { get; set; }
    public bool IsActive { get; set; }
}

/// <summary>Result set 11: active weekly-pattern rows. DayOfWeek 1 = Monday .. 7 = Sunday.</summary>
public class AutoRosterPatternRow
{
    public int EmployeeId { get; set; }
    public byte DayOfWeek { get; set; }
    public int? ShiftId { get; set; }
    public bool IsRestDay { get; set; }
}

/// <summary>Result set 12: attendance.ROSTER_RHYTHM.</summary>
public class AutoRosterRhythmRow
{
    public int EmployeeId { get; set; }
    public DateTime AnchorWeekStart { get; set; }
    public byte AnchorWorkDays { get; set; }
    public bool OnRotation { get; set; }
}

/// <summary>Result set 13: attendance.ROSTER_CELL over the window — what the generator last wrote, and the pins.</summary>
public class AutoRosterCellRow
{
    public int EmployeeId { get; set; }
    public DateTime WorkDate { get; set; }

    /// <summary>work · rest · none; NULL = the cell was last written by hand.</summary>
    public string? AutoState { get; set; }

    public int? AutoShiftId { get; set; }
    public string? ReasonCode { get; set; }
    public bool IsPinned { get; set; }
}

/// <summary>Result set 14: the branch's active staffing rows.</summary>
public class AutoRosterStaffingRow
{
    public byte? DayOfWeek { get; set; }
    public int? ShiftId { get; set; }
    public int MinOnDuty { get; set; }
    public int? TargetOnDuty { get; set; }
}

/// <summary>Result set 15: the branch's latest saved run (0 or 1 row).</summary>
public class AutoRosterLastRunRow
{
    public int RunId { get; set; }
    public DateTime MonthDate { get; set; }
    public string Mode { get; set; } = string.Empty;
    public string? ParamsJson { get; set; }
    public DateTime CreatedAt { get; set; }
}
