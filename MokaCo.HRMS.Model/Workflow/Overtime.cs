namespace MokaCo.HRMS.Model.Workflow;

/// <summary>
/// Overtime — hours beyond the scheduled shift, approved in advance and paid at a multiplier.
///
/// The create response carries the ROSTER CONTEXT the requester needs to see they asked for the
/// right thing: which shift they were on that day, and whether they were on one at all.
/// </summary>
public class OvertimeCreated
{
    public int RequestInstanceId { get; set; }
    public string Status { get; set; } = string.Empty;
    public int? CurrentStepNo { get; set; }

    /// <summary>The shift rostered that day, or null when there was none.</summary>
    public string? ShiftName { get; set; }
    public TimeSpan? StartTime { get; set; }
    public TimeSpan? EndTime { get; set; }

    /// <summary>
    /// A rest day, or a day with no roster entry at all. Not a refusal: the whole worked time counts
    /// as overtime then, which is precisely when the request matters most.
    /// </summary>
    public bool IsRestDayOrUnrostered { get; set; }
}

/// <summary>
/// The overtime payload (usp_Overtime_GetPayload).
///
/// THE THREE FIGURES ONLY EXIST ONCE THE DAY IS PROCESSED. Before that, WorkedMinutes and the
/// detected/payable pair are null and <see cref="AttendanceProcessed"/> is false — the request is
/// approved for hours nobody has yet observed being worked. The panel must say "awaiting the worked
/// day" rather than render zeros, which would read as "worked nothing".
/// </summary>
public class OvertimePayload
{
    public int OvertimeRequestId { get; set; }
    public int EmployeeId { get; set; }
    public string EmployeeName { get; set; } = string.Empty;
    public DateTime WorkDate { get; set; }

    public int RequestedMinutes { get; set; }
    /// <summary>Null until an approver has decided. May be less than requested.</summary>
    public int? ApprovedMinutes { get; set; }

    /// <summary>The pay multiplier — 1.50 for the standard overtime rate.</summary>
    public decimal RateMultiplier { get; set; }

    public string? Reason { get; set; }
    /// <summary>When the sweep linked this to the attendance day. Null until then.</summary>
    public DateTime? AppliedToAttendanceAt { get; set; }

    public string? ShiftName { get; set; }
    public TimeSpan? StartTime { get; set; }
    public TimeSpan? EndTime { get; set; }

    /* ---- all null until the day is processed ---- */

    /// <summary>What the punches actually showed was worked.</summary>
    public int? WorkedMinutes { get; set; }
    /// <summary>The scheduled length of the day, for comparison.</summary>
    public int? StandardMinutes { get; set; }
    /// <summary>Worked minus standard — what attendance says was extra, independent of what was approved.</summary>
    public int? DetectedOvertimeMinutes { get; set; }
    /// <summary>The lesser of detected and approved: neither approving nor working alone earns it.</summary>
    public int? PayableOvertimeMinutes { get; set; }

    /// <summary>False until the worked day exists. Everything above it is null while this is false.</summary>
    public bool AttendanceProcessed { get; set; }
}

/// <summary>One row of an employee's own overtime history (usp_Overtime_GetForEmployee).</summary>
public class MyOvertime
{
    public int OvertimeRequestId { get; set; }
    public int RequestInstanceId { get; set; }
    public string Status { get; set; } = string.Empty;
    public DateTime WorkDate { get; set; }
    public int RequestedMinutes { get; set; }
    public int? ApprovedMinutes { get; set; }
    public decimal RateMultiplier { get; set; }
    public string? Reason { get; set; }
    public DateTime SubmittedAt { get; set; }
}

/// <summary>How many approved overtime requests a sweep linked to their attendance day.</summary>
public class OvertimeApplyResult
{
    public int Stamped { get; set; }
}

/* ---- requests ---- */

/// <summary>
/// Raise overtime. As with the other typed requests, EmployeeId is WHOSE request it is and the API
/// — not the database — enforces that a caller without REQUEST_RAISE_OTHERS may only pass their own.
/// </summary>
public class OvertimeCreateRequest
{
    public int EmployeeId { get; set; }
    public DateTime WorkDate { get; set; }
    public int RequestedMinutes { get; set; }
    public string? Reason { get; set; }
    public string? Title { get; set; }
}

/// <summary>
/// Approve overtime. THE FIGURE IS STATED ON EVERY APPROVAL — there is no "as it stands" default any
/// more, because the minutes signed for are the cap payroll pays to and nobody should sign one they
/// did not look at.
/// </summary>
public class OvertimeDecideRequest
{
    /// <summary>
    /// REQUIRED by the procedure, and deliberately still nullable HERE: an omitted field then arrives
    /// as NULL and earns the procedure's precise "State the approved minutes" message, whereas a
    /// non-nullable int would bind to 0 and produce the wrong complaint ("must be above zero").
    /// </summary>
    public int? ApprovedMinutes { get; set; }

    public string? Comment { get; set; }
    /// <summary>Verified against the stored Argon2id hash BEFORE anything is written. Never logged or echoed.</summary>
    public string? Password { get; set; }
}

/// <summary>
/// What an overtime decision returned: the engine's result, the cap that now stands, and how it got
/// there.
///
/// THE FIGURE ONLY EVER TIGHTENS. A later approver may cut the cap but never raise it — the procedure
/// refuses that with a sentence naming the standing figure — so <see cref="ApprovedMinutes"/> is the
/// binding cap from this decision onwards, and <see cref="RequestedMinutes"/> is what was originally
/// asked for, kept so a reduced approval can be read as a reduction rather than as the whole story.
/// </summary>
public class OvertimeDecisionResult : TypedDecisionResult
{
    /// <summary>The cap now standing, in minutes.</summary>
    public int ApprovedMinutes { get; set; }

    /// <summary>What was originally asked for.</summary>
    public int RequestedMinutes { get; set; }

    /// <summary>This decision cut the figure below what stood before it — the chain records the change.</summary>
    public bool FigureTightened { get; set; }

    /// <summary>
    /// The request closed Approved on this decision, so the cap is settled and the sweep has already
    /// linked it to the attendance day.
    /// </summary>
    public bool IsFinal { get; set; }
}
