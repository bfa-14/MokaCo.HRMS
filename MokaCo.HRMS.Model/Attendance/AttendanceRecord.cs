namespace MokaCo.HRMS.Model.Attendance;

/// <summary>
/// Maps to attendance.ATTENDANCE_RECORD — the PROCESSED result, one row per employee-day.
/// THIS, never the raw log, is what payroll reads. That is the contract.
///
/// The rule that governs the whole class: attendance REPORTS, workflow AUTHORIZES, HR DECIDES.
/// Every number here is a statement of fact about what the punches said. None of them decides
/// what anyone gets paid — overtime is detected and left alone, an exit variance is measured and
/// handed to HR.
/// </summary>
public class AttendanceRecord
{
    public long AttendanceId { get; set; }
    public int EmployeeId { get; set; }
    public string FullName { get; set; } = string.Empty;

    /// <summary>The roster row this day was judged against. NULL means the day had no roster — nothing to be late for.</summary>
    public int? ShiftAssignmentId { get; set; }

    public DateTime WorkDate { get; set; }

    public DateTime? FirstInUtc { get; set; }
    public DateTime? LastOutUtc { get; set; }

    /// <summary>How many COMPLETE in/out intervals the day contained. An IN with no matching OUT is not a pair — it is an anomaly.</summary>
    public int PunchPairs { get; set; }

    /// <summary>
    /// Sum of the PAIRED intervals — NOT first-in to last-out. 08:00–12:00 plus 14:00–17:00 is 420
    /// minutes, not 540. If it were the latter, a two-hour mid-day absence would be paid and exit
    /// permissions would mean nothing.
    /// </summary>
    public int GrossMinutes { get; set; }

    /// <summary>Total time clocked OUT between intervals. The break is taken from here first; whatever is left over is an exit.</summary>
    public int GapMinutes { get; set; }

    /// <summary>
    /// The break actually charged, counted ONCE. If they punched out for lunch the gap already paid
    /// for it; only the shortfall comes off gross. So punching out for your break is never worse
    /// for you than not punching out.
    /// </summary>
    public int BreakApplied { get; set; }

    /// <summary>Gross minus the part of the break that was not already taken as a gap. The paid time.</summary>
    public int WorkedMinutes { get; set; }

    /// <summary>What a full day means FOR THIS PERSON ON THIS DATE: the rostered shift's length minus its break, or the configured default when no shift is rostered.</summary>
    public int StandardMinutes { get; set; }

    /// <summary>
    /// Worked / Standard, capped at 1.00 — "how much of a day did they earn?". 0.89 means 89% of a
    /// day. Payroll sums these, so someone who left two hours early counts 0.75 of a day, not 1.
    /// </summary>
    public decimal DayFraction { get; set; }

    /// <summary>DayFraction reached the configured FullDayThreshold. Capped fraction means overtime can never inflate this.</summary>
    public bool IsFullDay { get; set; }

    /// <summary>How far UNDER the standard day they fell.</summary>
    public int ShortfallMinutes { get; set; }

    /// <summary>Minutes past (shift start + grace). Zero when there is no rostered shift — you cannot be late for a shift that was never assigned.</summary>
    public int LateMinutes { get; set; }

    /// <summary>
    /// Minutes over the standard day. DETECTED ONLY — attendance never pays this. Pay only what an
    /// APPROVED overtime request authorises; HR may also spend it offsetting an exit variance.
    /// </summary>
    public int OvertimeMinutes { get; set; }

    /// <summary>What the punches SHOW the employee was away for, beyond their break. Observed fact.</summary>
    public int ExitActualMinutes { get; set; }

    /// <summary>
    /// What was AUTHORISED — by workflow, or by HR when the employee had an approved exit but never
    /// punched for it. Independent of <see cref="ExitActualMinutes"/>: neither ever overwrites the other.
    /// </summary>
    public int ExitApprovedMinutes { get; set; }

    /// <summary>
    /// Actual minus approved. POSITIVE means they were away LONGER than allowed; NEGATIVE means they
    /// came back early. Attendance only reports this number — HR decides what it means via
    /// <see cref="ExitVarianceDisposition"/>, and payroll is BLOCKED while any variance is undecided.
    /// </summary>
    public int ExitVarianceMinutes { get; set; }

    /// <summary>
    /// What actually comes off the leave balance. DEFAULT is the ACTUAL minutes (core.SETTING
    /// ExitLeaveBasis = 'Actual') — you are docked for the time you really took. HR can switch the
    /// basis globally, or override this single day.
    /// </summary>
    public int ExitLeaveMinutes { get; set; }

    /// <summary>
    /// HR's ruling on the difference: 'UnpaidAbsence' (payroll deducts it), 'Overtime' (offset
    /// against overtime already worked), or 'Ignore' (no effect on pay). NULL = not yet decided,
    /// and payroll will not run.
    /// </summary>
    public string? ExitVarianceDisposition { get; set; }

    public int? ExitPermissionId { get; set; }

    /// <summary>Present / Absent / RestDay / Leave.</summary>
    public string Status { get; set; } = string.Empty;

    /// <summary>Device / Excel / Manual — where the day's data came from.</summary>
    public string Source { get; set; } = string.Empty;

    public int? DeviceId { get; set; }

    /// <summary>WHERE the day was worked, taken from the device that recorded it — which is how staff who cover several branches are attributed correctly.</summary>
    public int? BranchId { get; set; }
    public string? BranchName { get; set; }

    /// <summary>
    /// The punches did not add up — unpaired in/out, or a missing punch-out. Not an error and not a
    /// judgement: it is the machine admitting it could not read the day confidently and asking a
    /// human to look. Anomalies block payroll.
    /// </summary>
    public bool HasAnomaly { get; set; }

    /// <summary>
    /// 1 = HR entered or corrected this day by hand. The processor MUST NOT touch a manual row —
    /// this is what stops a nightly re-run from silently undoing HR's decision.
    /// </summary>
    public bool IsManual { get; set; }

    /// <summary>Why HR overrode the machine. The audit answer to "who changed this and what were they thinking".</summary>
    public string? HrNote { get; set; }

    public DateTime? ProcessedUtc { get; set; }
}

/// <summary>
/// Maps to attendance.ATTENDANCE_INTERVAL — one PAIRED in/out stretch, the audit trail behind
/// WorkedMinutes. A day with a two-hour mid-day exit has TWO of these, and the gap between them is
/// the exit. Regenerated by the processor; never hand-edited.
/// </summary>
public class AttendanceInterval
{
    public long IntervalId { get; set; }

    /// <summary>1, 2, 3 in time order.</summary>
    public int SeqNo { get; set; }

    public DateTime InTimeUtc { get; set; }
    public DateTime OutTimeUtc { get; set; }

    /// <summary>Minutes actually worked in this stretch. The sum of these — not last-out minus first-in — is gross time.</summary>
    public int Minutes { get; set; }

    /// <summary>Minutes clocked OUT until the next interval opens. This is where the break, and then the exit, come from.</summary>
    public int GapAfterMins { get; set; }
}

/// <summary>
/// One day WITH the intervals behind it (two result sets from usp_Attendance_GetById). The
/// intervals are what let a human SEE why worked time is what it is, instead of being asked to
/// trust a number.
/// </summary>
public class AttendanceDetail : AttendanceRecord
{
    /// <summary>ExitLeaveMinutes expressed in DAYS, using the configured standard day — with an 8h day, a 2-hour exit is 0.25 days.</summary>
    public decimal LeaveDaysToDeduct { get; set; }

    public List<AttendanceInterval> Intervals { get; set; } = new();
}

/// <summary>
/// HR's decision queue: days where what actually happened differs from what was approved, and
/// nobody has yet said what that means. Payroll should not run while this list is not empty.
/// </summary>
public class ExitVariance
{
    public long AttendanceId { get; set; }
    public int EmployeeId { get; set; }
    public string FullName { get; set; } = string.Empty;
    public DateTime WorkDate { get; set; }

    public int ExitActualMinutes { get; set; }
    public int ExitApprovedMinutes { get; set; }
    public int ExitVarianceMinutes { get; set; }
    public int ExitLeaveMinutes { get; set; }
    public string? ExitVarianceDisposition { get; set; }

    /// <summary>Overtime detected on the same day — what HR could choose to offset the variance against.</summary>
    public int OvertimeMinutes { get; set; }

    public decimal LeaveDaysToDeduct { get; set; }
    public string? HrNote { get; set; }
}
