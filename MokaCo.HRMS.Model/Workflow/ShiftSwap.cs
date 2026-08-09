namespace MokaCo.HRMS.Model.Workflow;

/// <summary>
/// Shift swap — two people in the SAME ROLE exchange a rostered day.
///
/// Everything that makes a swap legal is checked by usp_ShiftSwap_Create: the consent tick, the
/// same-position rule, both dates being in the future, both people actually having a working shift
/// on their date, and no open swap already touching either shift. The API adds none of it.
/// </summary>
public class ShiftSwapCreated
{
    public int RequestInstanceId { get; set; }
    public string Status { get; set; } = string.Empty;
    public int? CurrentStepNo { get; set; }

    /// <summary>Hours from now to the EARLIER of the two shifts — the one that constrains the roster.</summary>
    public int HoursUntilFirstShift { get; set; }

    /// <summary>
    /// Under 48 hours. ADVISORY: the swap was accepted and is in flight. It is reported so the
    /// requester can be told the roster is being changed at short notice, never to undo anything.
    /// </summary>
    public bool NoticeShorterThanRecommended { get; set; }
}

/// <summary>
/// The swap payload (usp_ShiftSwap_GetPayload) — both sides, who asserted the consent, and whether
/// the roster has actually been rewritten yet.
/// </summary>
public class ShiftSwapPayload
{
    public int ShiftSwapId { get; set; }

    public int RequesterEmployeeId { get; set; }
    public string RequesterName { get; set; } = string.Empty;

    /// <summary>The day the REQUESTER gives up.</summary>
    public DateTime RequesterDate { get; set; }

    public int CounterpartEmployeeId { get; set; }
    public string CounterpartName { get; set; } = string.Empty;

    /// <summary>The day the COUNTERPART gives up.</summary>
    public DateTime CounterpartDate { get; set; }

    /// <summary>
    /// WHO SAID THE COUNTERPART AGREED — the username of whoever ticked the box, not the
    /// counterpart's own confirmation. The system never saw the counterpart consent; it saw someone
    /// assert that they had, and the record should say so plainly.
    /// </summary>
    public string ConsentAssertedBy { get; set; } = string.Empty;

    /// <summary>Set once the roster was actually rewritten, at final approval. Null until then.</summary>
    public DateTime? AppliedAt { get; set; }
}

/// <summary>
/// Raise a shift swap. CounterpartHasAgreed is passed through as sent: the procedure refuses a
/// false, and its wording is what the user should read — the client's own disabled button is a
/// courtesy, not the rule.
/// </summary>
public class ShiftSwapCreateRequest
{
    public int EmployeeId { get; set; }
    public int CounterpartEmployeeId { get; set; }
    public DateTime RequesterDate { get; set; }
    public DateTime CounterpartDate { get; set; }
    public bool CounterpartHasAgreed { get; set; }
    public string? Title { get; set; }
}

/* ---- shared by both typed decide endpoints ---- */

/// <summary>
/// A decision on a typed request that has no adjustable figure. Only a comment and, where policy
/// demands it, the password that signs it.
/// </summary>
public class TypedDecideRequest
{
    public string? Comment { get; set; }

    /// <summary>Verified against the stored Argon2id hash BEFORE anything is written. Never logged or echoed.</summary>
    public string? Password { get; set; }
}

/// <summary>
/// What usp_TipDistribution_Decide / usp_ShiftSwap_Decide return — the engine's approval result,
/// unchanged. The typed effect (finalizing the lines, rewriting the roster) happens inside the
/// procedure at final approval and is visible through the payload, not here.
/// </summary>
public class TypedDecisionResult
{
    public int RequestInstanceId { get; set; }
    public string Status { get; set; } = string.Empty;
    public int? CurrentStepNo { get; set; }
    public string? ClosedReason { get; set; }
    public string? Decision { get; set; }
    public bool SignedAsDeputy { get; set; }
    public bool SignedWithPassword { get; set; }
}
