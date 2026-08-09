namespace MokaCo.HRMS.Model.Workflow;

/// <summary>
/// One VERSION of an approval chain for a request type. Maps to workflow.WORKFLOW_DEFINITION.
///
/// A chain is DATA, not code, and it is VERSIONED, NEVER EDITED: changing an approval path means
/// publishing a new version, not editing this one. A Draft can be built and published; an Active
/// version is the one new requests lock onto; a Retired version is a past chain kept for history.
/// Requests already in flight keep the version they were submitted under, so this row is never
/// rewritten underneath a request mid-approval.
/// </summary>
public class WorkflowDefinition
{
    public int WorkflowDefinitionId { get; set; }
    public int RequestTypeId { get; set; }
    public string RequestTypeCode { get; set; } = string.Empty;
    public string RequestTypeName { get; set; } = string.Empty;

    public int Version { get; set; }

    /// <summary>Draft / Active / Retired. Only a Draft may be edited; Active and Retired are read-only.</summary>
    public string Status { get; set; } = string.Empty;

    public string? Notes { get; set; }
    public DateTime? PublishedAt { get; set; }
    public DateTime CreatedAt { get; set; }

    /// <summary>
    /// Which population this chain serves: NULL = everyone (the default chain), 2 = management and
    /// above, 3 = executive only. A requester follows the most specific active chain their tier
    /// qualifies for, so two active chains per type is normal, not a conflict.
    /// </summary>
    public int? MinRequesterTier { get; set; }

    /// <summary>How many steps this version has. Shown so a chain's shape is visible without opening it.</summary>
    public int StepCount { get; set; }
}

/// <summary>
/// One step of a chain definition. Maps to workflow.WORKFLOW_STEP.
///
/// APPROVERS ARE RESOLVED, NOT NAMED: a step says what KIND of approver it needs, and the engine
/// works out the actual person at submit time. That is why the chain keeps working when people
/// change roles or branches.
/// </summary>
public class WorkflowStep
{
    public int WorkflowStepId { get; set; }
    public int StepNo { get; set; }
    public string Name { get; set; } = string.Empty;

    /// <summary>BranchManager / Role / SpecificUser / LineManager (climbs the requester's reporting line).</summary>
    public string ApproverType { get; set; } = string.Empty;

    public int? ApproverRoleId { get; set; }
    public string? ApproverRoleName { get; set; }
    public int? ApproverUserId { get; set; }
    public string? ApproverUsername { get; set; }

    public bool IsMandatory { get; set; }

    /// <summary>For a LineManager step: how many levels up the reporting line it climbs (1 = direct manager).</summary>
    public int? EscalationLevels { get; set; }

    /// <summary>The deputy role that may ALSO sign this step, when one is configured on the chain.</summary>
    public int? FallbackRoleId { get; set; }
    public string? FallbackRoleName { get; set; }

    /// <summary>This approver may grant less than was requested (e.g. 120 of 180 minutes).</summary>
    public bool CanAdjust { get; set; }

    /// <summary>A comment is required with EVERY decision here, not only when something is changed or rejected.</summary>
    public bool RequiresComment { get; set; }

    /// <summary>
    /// Every decision at this step must be password-signed, whoever signs — independent of the
    /// signer's role signature setting. For the final step of high-stakes chains.
    /// </summary>
    public bool RequiresSignature { get; set; }

    // NOTE: there is no per-step "rejection ends the request" here. That rule moved onto the ROLE
    // (Settings → "When a role rejects"); the WORKFLOW_STEP column was dropped, and the definition
    // procedures no longer read or write it.
}

/// <summary>One step of the ACTIVE chain, as shown to a requester before they submit (usp_Definition_GetActive).</summary>
public class ActiveDefinitionStep
{
    public int WorkflowDefinitionId { get; set; }
    public int Version { get; set; }
    public DateTime? PublishedAt { get; set; }
    public int StepNo { get; set; }
    public string Name { get; set; } = string.Empty;
    public string ApproverType { get; set; } = string.Empty;
    public int? ApproverRoleId { get; set; }
    public bool IsMandatory { get; set; }

    /// <summary>For a LineManager step: how many levels up the reporting line it climbs (1 = direct manager).</summary>
    public int? EscalationLevels { get; set; }

    /// <summary>
    /// For a LineManager step read WITH a ForEmployeeId: the ACTUAL person it resolves to for that
    /// requester, so the preview shows a real name. Null off the top of the tree (the step will skip),
    /// or when no requester was given.
    /// </summary>
    public string? ResolvedApproverName { get; set; }
}

/* ---- requests to configure a chain ---- */

/// <summary>Starts a new DRAFT version for a request type. The engine picks the next version number.</summary>
public class DefinitionCreateRequest
{
    public int RequestTypeId { get; set; }
    public string? Notes { get; set; }
}

/// <summary>Result of creating a draft — the new id and the version number it was given.</summary>
public class DefinitionCreated
{
    public int WorkflowDefinitionId { get; set; }
    public int Version { get; set; }
}

/// <summary>
/// Adds (or replaces) one step on a DRAFT definition. The engine rejects this on a published version
/// — the way to change a live chain is a new draft, never an edit.
/// </summary>
public class DefinitionAddStepRequest
{
    public int StepNo { get; set; }
    public string Name { get; set; } = string.Empty;

    /// <summary>BranchManager / Role / SpecificUser.</summary>
    public string ApproverType { get; set; } = string.Empty;

    /// <summary>Required when ApproverType = 'Role'.</summary>
    public int? ApproverRoleId { get; set; }

    /// <summary>Required when ApproverType = 'SpecificUser'.</summary>
    public int? ApproverUserId { get; set; }

    public bool IsMandatory { get; set; } = true;

    /// <summary>
    /// For ApproverType = 'LineManager': how many levels up the requester's reporting line to climb
    /// (1 = direct manager). Ignored for other types; maps to the proc's @EscalationLevels.
    /// </summary>
    public int? EscalationLevels { get; set; }

    /// <summary>An optional deputy role that may also sign this step — maps to the proc's @FallbackRoleId.</summary>
    public int? DeputyRoleId { get; set; }

    /// <summary>This approver may grant less than requested. Default false — a plain endorsement cannot cut the figure.</summary>
    public bool CanAdjust { get; set; }

    /// <summary>A comment is required with every decision here. Default false — only changes/rejections force one.</summary>
    public bool RequiresComment { get; set; }

    /// <summary>Every decision here must be password-signed, whoever signs. Default false — role policy still applies either way.</summary>
    public bool RequiresSignature { get; set; }

    // No per-step "rejection ends the request": that rule lives on the ROLE now (Settings), and the
    // WORKFLOW_STEP column and its proc parameter were both removed.
}

/// <summary>Result of publishing a draft: it becomes the Active version and the previous Active retires.</summary>
public class DefinitionPublished
{
    public int WorkflowDefinitionId { get; set; }
    public int RequestTypeId { get; set; }
    public int Version { get; set; }
    public string Status { get; set; } = string.Empty;
    public DateTime? PublishedAt { get; set; }
}

/// <summary>What usp_Definition_SetMinTier returns — the draft's new population setting.</summary>
public class DefinitionMinTier
{
    public int WorkflowDefinitionId { get; set; }
    public int Version { get; set; }
    public int? MinRequesterTier { get; set; }
}

/// <summary>
/// A chain a DRAFT can be started from (usp_Definition_GetCopySources) — any version, of any type,
/// that actually has steps. Retired and draft versions are offered too: the useful precedent is
/// often the one that was just superseded.
/// </summary>
public class DefinitionCopySource
{
    public int WorkflowDefinitionId { get; set; }
    public string RequestTypeCode { get; set; } = string.Empty;
    public string RequestTypeName { get; set; } = string.Empty;
    public int Version { get; set; }
    public string Status { get; set; } = string.Empty;
    public int? MinRequesterTier { get; set; }

    /// <summary>
    /// MinRequesterTier in words — "Everyone", "Management+", "Executive".
    ///
    /// Read as its own field rather than derived from the tier, because the SOURCE's audience is
    /// needed after a copy to say plainly that it did NOT come along: applies-to belongs to the
    /// draft, and a chain copied from an executive-only version still serves whoever this draft does.
    /// </summary>
    public string? AppliesTo { get; set; }

    /// <summary>Ready to show — "Overtime · v1 (active) · Everyone". Composed in SQL so one wording serves every caller.</summary>
    public string Label { get; set; } = string.Empty;

    public int StepCount { get; set; }

    /// <summary>"1. Branch manager → 2. Owner" — the whole chain in a line, for help text under the picker.</summary>
    public string? StepsPreview { get; set; }
}

/// <summary>
/// Copy the steps of one chain into a DRAFT.
///
/// A SNAPSHOT, NOT A LINK: nothing records where the steps came from, so later edits to either
/// chain leave the other alone. That is the promise the builder makes, and it holds because there
/// is nothing to keep them in step.
/// </summary>
public class DefinitionCopyFromRequest
{
    public int SourceDefinitionId { get; set; }

    /// <summary>
    /// False first, always. The procedure REFUSES a draft that already has steps and names how many,
    /// and that refusal is what the UI turns into an explicit "Replace existing steps" confirm —
    /// so nobody discards work they had forgotten was there.
    /// </summary>
    public bool ReplaceExisting { get; set; }
}

/// <summary>What a copy did. StepsReplaced is 0 unless the draft's own steps were discarded first.</summary>
public class DefinitionCopyResult
{
    public int WorkflowDefinitionId { get; set; }
    public int StepsCopied { get; set; }
    public int StepsReplaced { get; set; }
}

/// <summary>Body of PUT /api/workflow/definitions/{id}/min-tier — 2, 3, or null for the default (everyone) chain.</summary>
public class MinTierRequest
{
    public int? MinRequesterTier { get; set; }
}
