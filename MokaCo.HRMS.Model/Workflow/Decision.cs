namespace MokaCo.HRMS.Model.Workflow;

/// <summary>
/// The decision control — what THIS person may do at a request's current step, and what the UI must
/// collect before they do it.
///
/// The shape of a decision is DATA, not code. workflow.DECISION_TYPE holds the catalogue; a step may
/// narrow it through WORKFLOW_STEP_DECISION; and usp_Step_GetAvailableDecisions returns only what is
/// both configured and permitted for the caller. The client renders its dialog from these flags and
/// branches on ONE field — <see cref="DecisionOption.EngineAction"/> — to pick the endpoint.
///
/// AN EMPTY LIST IS A MEANINGFUL ANSWER: "not yours to decide". It is not an error and not an empty
/// state to apologise for — the caller shows the chain read-only and offers no button at all.
/// </summary>
public class DecisionOption
{
    /// <summary>The stable key stored on the step as its Decision.</summary>
    public string Code { get; set; } = string.Empty;
    public string Label { get; set; } = string.Empty;
    public string? Description { get; set; }

    /// <summary>Approve | Reject | Hold | Delegate — the ONE field the client branches on.</summary>
    public string EngineAction { get; set; } = string.Empty;

    /// <summary>Positive | Negative | Neutral — colours the option, never the whole row.</summary>
    public string Tone { get; set; } = string.Empty;

    public bool RequiresComment { get; set; }
    public bool RequiresAttachment { get; set; }
    public bool RequiresTargetUser { get; set; }

    /// <summary>For a Hold decision: pause AND put the ball in the requester's court.</summary>
    public bool WaitingOnRequester { get; set; }

    /// <summary>
    /// May adjust the typed figure. The procedure has ALREADY AND-ed this with the step's CanAdjust,
    /// so a client that trusts it will never offer an adjustment the engine would refuse.
    /// </summary>
    public bool AllowsValueChange { get; set; }

    /// <summary>At most one is primary — the preselected choice.</summary>
    public bool IsPrimary { get; set; }

    public string? Icon { get; set; }
    public int SortOrder { get; set; }
}

/// <summary>
/// Whether the current step's decision must be signed with the caller's password, and the sentence
/// to show them (usp_Step_GetSignatureRequirement).
///
/// Read WITH THE PAGE, not when a dialog opens: being asked for a password at the moment you commit
/// is a surprise, and a surprise at that moment reads as a security incident rather than a policy.
/// <see cref="Explanation"/> is the database's own wording — show it verbatim and never invent one.
/// </summary>
public class SignatureRequirement
{
    public bool SignatureRequired { get; set; }

    /// <summary>The role that demands it ("Decisions made as HR must be signed…"), or null.</summary>
    public string? RequiredByRole { get; set; }

    /// <summary>True when the STEP demands it, independent of the caller's roles.</summary>
    public bool RequiredByStep { get; set; }

    public int GraceMinutes { get; set; }

    /// <summary>The verbatim sentence to show above the password field.</summary>
    public string? Explanation { get; set; }

    /// <summary>Whether the CALLER has a signature image on file, so the sign popup can show it (or a quiet "no image" line) without a second call.</summary>
    public bool HasSignatureImage { get; set; }
}

/// <summary>
/// A decision saved WITHOUT signing it (usp_Step_GetDraftDecision), so a half-formed judgement
/// survives leaving the page. Deliberately allowed to be incomplete: none of the decision's
/// requirement rules apply until it is actually signed.
///
/// Only ever the CALLER'S OWN draft. A colleague's draft on a shared role step is invisible here —
/// an empty response means "no draft of mine", never "someone else is working on it".
/// </summary>
public class DraftDecision
{
    public int StepNo { get; set; }
    public string StepName { get; set; } = string.Empty;
    public string DraftDecisionCode { get; set; } = string.Empty;

    /// <summary>Null when the decision type it referenced has since been deactivated.</summary>
    public string? DraftDecisionLabel { get; set; }

    public string? DraftComment { get; set; }
    public int? DraftValue { get; set; }
    public int? DraftTargetUserId { get; set; }
    public string? DraftTargetUsername { get; set; }
    public bool DraftWaitingOnRequester { get; set; }
    public DateTime DraftSavedAt { get; set; }
    public int DaysSinceSaved { get; set; }
}

/// <summary>Hands the current step to a named person. They decide instead; the request does not advance.</summary>
public class DelegateRequest
{
    public int ToUserId { get; set; }
    public string Reason { get; set; } = string.Empty;

    /// <summary>The decision code the user chose. Recorded by the engine, not passed to the procedure.</summary>
    public string? Code { get; set; }
}

/// <summary>Saves a decision without signing it. Nothing here is validated — that is the point of a draft.</summary>
public class SaveDraftRequest
{
    public string DecisionCode { get; set; } = string.Empty;
    public string? Comment { get; set; }
    public int? Value { get; set; }
    public int? TargetUserId { get; set; }
    public bool WaitingOnRequester { get; set; }
}
