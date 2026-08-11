namespace MokaCo.HRMS.Model.Workflow;

/// <summary>
/// The header of one request instance (result set 1 of usp_Request_GetById).
///
/// WHOSE REQUEST vs WHO TYPED IT are different facts: <see cref="EmployeeId"/> is the person the
/// request is FOR; <see cref="RaisedByUserId"/> is the account that submitted it. HR raising on
/// somebody's behalf is a first-class case, and <see cref="RaisedOnBehalf"/> is how the UI shows it
/// rather than hiding it.
/// </summary>
public class RequestHeader
{
    public int RequestInstanceId { get; set; }
    public int RequestTypeId { get; set; }
    public string RequestTypeCode { get; set; } = string.Empty;
    public string RequestTypeName { get; set; } = string.Empty;

    public int EmployeeId { get; set; }
    public string EmployeeName { get; set; } = string.Empty;
    public string BranchName { get; set; } = string.Empty;

    public int RaisedByUserId { get; set; }
    public string RaisedByUsername { get; set; } = string.Empty;

    /// <summary>True when the submitter is not the employee — "Raised by sara.hr on behalf of Rami Haddad".</summary>
    public bool RaisedOnBehalf { get; set; }

    /// <summary>Pending / Approved / Rejected / Cancelled.</summary>
    public string Status { get; set; } = string.Empty;

    /// <summary>Which step is currently waiting. NULL once the request is closed.</summary>
    public int? CurrentStepNo { get; set; }

    public string? Title { get; set; }
    public DateTime SubmittedAt { get; set; }
    public DateTime? ClosedAt { get; set; }
    public string? ClosedReason { get; set; }

    /// <summary>The chain version this request locked onto at submit. History always shows the rules that actually applied.</summary>
    public int WorkflowVersion { get; set; }
}

/// <summary>
/// One materialised step of a live request (result set 2 of usp_Request_GetById).
///
/// Unlike a definition step, this one has been RESOLVED to an actual person and carries its own
/// state — the record of who must sign and, once acted, who did.
/// </summary>
public class RequestStep
{
    public int StepNo { get; set; }
    public string Name { get; set; } = string.Empty;
    public string ApproverType { get; set; } = string.Empty;

    /// <summary>The specific person this step resolved to (NULL for a role step, which any role-holder may sign).</summary>
    public int? ResolvedUserId { get; set; }
    public string? ResolvedUsername { get; set; }

    public int? ApproverRoleId { get; set; }
    public string? ApproverRoleName { get; set; }

    /// <summary>Pending / Approved / Rejected / Skipped.</summary>
    public string Status { get; set; } = string.Empty;

    public int? ActedByUserId { get; set; }
    public string? ActedByUsername { get; set; }
    public DateTime? ActedAt { get; set; }
    public string? Comment { get; set; }

    /// <summary>
    /// Why this step was SKIPPED rather than signed — because the approver was the requester (nobody
    /// approves their own request), or the post was vacant. An org-chart gap must never block a
    /// request, but it must never be invisible either: the UI renders this text where a signature
    /// would otherwise appear, so a skip never reads as an unsigned gap.
    /// </summary>
    public string? SkipReason { get; set; }

    /// <summary>The step-instance row id — the identity a note or hold hangs off, distinct from the human StepNo.</summary>
    public int RequestStepInstanceId { get; set; }

    /// <summary>The deputy role that may ALSO sign this step, if one is configured.</summary>
    public int? FallbackRoleId { get; set; }
    public string? FallbackRoleName { get; set; }

    /// <summary>The recorded decision on the step, when it says more than the status (e.g. an overrule). Null until acted.</summary>
    public string? Decision { get; set; }

    /// <summary>Whether a rejection here ends the whole request, or only sends it back. Frozen from the chain at submit.</summary>
    public bool RejectionEndsRequest { get; set; }

    /// <summary>While the step is on hold: what it is waiting for, when the hold began, and who set it.</summary>
    public string? HoldReason { get; set; }
    public DateTime? HoldSetAt { get; set; }

    /// <summary>True when the hold is waiting on the requester to answer, rather than on the approver.</summary>
    public bool WaitingOnRequester { get; set; }
    public string? HoldSetByUsername { get; set; }

    /// <summary>Whether the approver may adjust the request on this step, and whether a comment is required to act.</summary>
    public bool CanAdjust { get; set; }
    public bool RequiresComment { get; set; }

    /// <summary>True when a later authority overruled the decision recorded on this step.</summary>
    public bool WasOverruled { get; set; }

    /// <summary>
    /// How many proof attachments hang off THIS step (the decision's supporting files). Counted so the
    /// UI can show a badge without a second call.
    /// </summary>
    public int ProofCount { get; set; }

    /// <summary>
    /// True when the caller (the ForUserId the steps were read for) may still take back their decision
    /// on this step — the request is open, they acted here, and nobody has acted after them. Answered by
    /// the procedure so a Withdraw button appears only where the withdraw would actually succeed.
    /// </summary>
    public bool CanWithdraw { get; set; }

    /// <summary>
    /// True when TAKING THIS DECISION BACK must be password-signed — because it was signed, or the step
    /// demands it, or the caller's role always does.
    ///
    /// This is a SEPARATE question from whether a fresh decision needs signing, and it can be true
    /// where that one is false: undoing a signed act is itself a signed act. Anything deciding whether
    /// to ask for a password before a WITHDRAWAL must read this, never SignatureRequired.
    /// </summary>
    public bool WithdrawNeedsSignature { get; set; }

    /// <summary>True when the decision here was made with a password — the chain renders a lock beside it.</summary>
    public bool SignedWithPassword { get; set; }

    /// <summary>
    /// True when this step's signer has a FROZEN signature image on file for this decision — the cue to
    /// render an &lt;img&gt;. False with SignedWithPassword still true means "signed, no image": show the
    /// lock and "signed", never a broken image. The bytes are NOT here — they load one at a time from
    /// GET /api/signatures/{SignedSignatureId}/image.
    /// </summary>
    public bool HasSignatureImage { get; set; }

    /// <summary>The signature-log row id carrying that frozen image — the id the image endpoint takes. Null when there is none.</summary>
    public int? SignedSignatureId { get; set; }

    /// <summary>
    /// True only for the person who DELEGATED this step, and only while the delegate has not decided.
    /// Reclaiming is not a withdrawal — nothing was signed — so it asks for no password.
    /// </summary>
    public bool CanReclaim { get; set; }

    /// <summary>
    /// Who is holding this step after a delegation, and who handed it over. DelegatedToUserId being
    /// non-null IS the "was delegated" signal — never infer it from ApproverType, which still describes
    /// the step's own underlying rule.
    /// </summary>
    public int? DelegatedToUserId { get; set; }
    public string? DelegatedToUsername { get; set; }
    public int? DelegatedFromUserId { get; set; }
    public string? DelegatedFromUsername { get; set; }
    public DateTime? DelegatedAt { get; set; }
}

/// <summary>
/// One row of the APPEND-ONLY signature log (result set 3 of usp_Request_GetById).
///
/// The step rows carry the current state; this log carries the history. Every action — submit,
/// approve, reject, skip, cancel, version-move — is one immutable row, and together they are the
/// audit trail. A skip has ActedByUsername null, because the engine acted, not a person.
/// </summary>
public class SignatureLogEntry
{
    public int SignatureId { get; set; }
    public int? StepNo { get; set; }

    /// <summary>Submitted / Approved / Rejected / Skipped / Cancelled / VersionMoved.</summary>
    public string Action { get; set; } = string.Empty;

    public int? ActedByUserId { get; set; }
    public string? ActedByUsername { get; set; }
    public DateTime ActedAt { get; set; }
    public string? Comment { get; set; }

    /// <summary>Whether this step has a frozen signature image to fetch (set by the signature-image patch). The bytes never travel here.</summary>
    public bool HasSignatureImage { get; set; }

    /// <summary>
    /// When this signature was STRUCK by a retract or a reopen. Null on a signature that still
    /// stands, which is nearly all of them.
    ///
    /// A struck signature is never deleted — it stays in the log, rendered struck through, with the
    /// reason beside it. Removing it would make the record say the decision was never taken, which
    /// is the one thing an append-only audit trail exists to prevent.
    /// </summary>
    public DateTime? RetractedAt { get; set; }

    /// <summary>Why it was struck — the retractor's own words, or "Reopened by GM + Owner".</summary>
    public string? RetractedReason { get; set; }
}

/// <summary>
/// A reversal — undoing a decision, recorded as its OWN event rather than as another signature.
///
/// TWO KINDS, differing in who may do it and when. A RETRACT is the last signer taking back their
/// own decision on the same UTC day: it completes immediately, so FirstSignRole is 'Self' and
/// CompletedAt is set at once. A REOPEN needs the General Manager AND the Owner, in either order —
/// whichever signs first creates the row with CompletedAt NULL, and the OTHER role completes it.
///
/// So a row with CompletedAt still null is a reopen half-signed and waiting, which is exactly what
/// the request page reads to say it is waiting on the other of the two.
/// </summary>
public class RequestReversal
{
    public int ReversalId { get; set; }

    /// <summary>'Retract' or 'Reopen'.</summary>
    public string Kind { get; set; } = string.Empty;

    public string Reason { get; set; } = string.Empty;

    public int FirstSignUserId { get; set; }
    public string? FirstSignUsername { get; set; }

    /// <summary>'Self' for a retract; 'Owner' or 'GeneralManager' for a reopen.</summary>
    public string FirstSignRole { get; set; } = string.Empty;

    public int? SecondSignUserId { get; set; }
    public string? SecondSignUsername { get; set; }
    public string? SecondSignRole { get; set; }

    /// <summary>Null while a reopen waits on the other of GM/Owner; set the moment it takes effect.</summary>
    public DateTime? CompletedAt { get; set; }

    public DateTime CreatedAt { get; set; }
}

/// <summary>
/// What a reopen attempt did. ONE OF TWO THINGS, and the caller must handle both.
///
/// The first of GM/Owner to sign gets State 'AwaitingSecond' with FirstSignRole naming who signed —
/// nothing has moved yet. The second gets State 'Reopened' with the request's new standing. Modelling
/// only the second is how a UI ends up reporting a half-signed reopen as a completed one.
/// </summary>
public class ReopenResult
{
    /// <summary>'AwaitingSecond' or 'Reopened'.</summary>
    public string State { get; set; } = string.Empty;

    /// <summary>Which of GM/Owner has signed so far. Set only on 'AwaitingSecond'.</summary>
    public string? FirstSignRole { get; set; }

    /// <summary>The request's new standing. Set only on 'Reopened'.</summary>
    public int? RequestInstanceId { get; set; }
    public string? Status { get; set; }
    public int? CurrentStepNo { get; set; }
}

/// <summary>
/// A full request: header, its materialised chain, its history, and any reversals — the four result
/// sets of usp_Request_GetById, together. All four must be read; a request without its chain is just
/// a title, without its history has no audit trail, and without its reversals cannot explain why a
/// signature in that history is struck through.
/// </summary>
public class RequestDetail
{
    public RequestHeader Header { get; set; } = new();
    public List<RequestStep> Steps { get; set; } = new();
    public List<SignatureLogEntry> History { get; set; } = new();
    public List<RequestReversal> Reversals { get; set; } = new();
}

/// <summary>
/// One request a user is connected to in ANY capacity (usp_Request_GetForUser), with flags saying
/// HOW. Feeds the whole Requests hub from a single call — the frontend slices it into tabs without
/// asking the server again. A request can carry several flags at once.
/// </summary>
public class ForUserRequest
{
    public int RequestInstanceId { get; set; }
    public string RequestTypeCode { get; set; } = string.Empty;
    public string RequestTypeName { get; set; } = string.Empty;
    public int EmployeeId { get; set; }
    public string EmployeeName { get; set; } = string.Empty;
    public string BranchName { get; set; } = string.Empty;
    public string? Title { get; set; }
    public string Status { get; set; } = string.Empty;
    public int? CurrentStepNo { get; set; }
    public string? CurrentStepName { get; set; }
    public DateTime SubmittedAt { get; set; }
    public DateTime? ClosedAt { get; set; }
    public string? ClosedReason { get; set; }
    public int WorkflowVersion { get; set; }
    public int DaysOpen { get; set; }

    /// <summary>Sitting on my signature this moment — as the named approver, or a holder of the current step's role.</summary>
    public bool WaitingOnMe { get; set; }

    /// <summary>Raised FOR me — I am the employee it is about.</summary>
    public bool IsMine { get; set; }

    /// <summary>I typed it — mine, or on someone else's behalf.</summary>
    public bool RaisedByMe { get; set; }

    /// <summary>I approved, rejected or signed a step at some point — even a request that is now nobody's to act on.</summary>
    public bool IActedOnIt { get; set; }

    /// <summary>What I did on the step I most recently acted on — 'Approved' / 'Rejected'. Null if I never acted.</summary>
    public string? MyStepStatus { get; set; }

    /// <summary>The recorded decision on that step (the step's Decision column), when distinct from its status. Null if I never acted.</summary>
    public string? MyDecision { get; set; }

    /// <summary>When I did it — so the hub can say "you approved this on 3 Aug".</summary>
    public DateTime? MyActedAt { get; set; }

    /// <summary>The note I left with my decision — e.g. a rejection reason, shown on the closed card. Null if none.</summary>
    public string? MyComment { get; set; }

    /// <summary>The current step's own status (e.g. Pending / OnHold), distinct from the request's overall Status.</summary>
    public string? CurrentStepStatus { get; set; }

    /// <summary>While the current step is on hold: what it is waiting for, and when the hold began.</summary>
    public string? HoldReason { get; set; }
    public DateTime? HoldSetAt { get; set; }

    /// <summary>True when the current hold is waiting on the requester rather than the approver.</summary>
    public bool WaitingOnRequester { get; set; }

    /// <summary>True when this request is on hold waiting on ME to answer — the "needs my answer" tab.</summary>
    public bool NeedsMyAnswer { get; set; }

    /// <summary>How many notes the conversation carries, so the card can show a count without a second call.</summary>
    public int NoteCount { get; set; }
}

/// <summary>The hub's tab-badge counts, in one round trip (usp_Request_GetCountsForUser).</summary>
public class RequestCounts
{
    /// <summary>Requests sitting on my signature right now — the number people look for.</summary>
    public int WaitingOnMe { get; set; }

    /// <summary>My own requests still open.</summary>
    public int MyOpenRequests { get; set; }

    /// <summary>Every request raised for me, open or closed.</summary>
    public int MyTotalRequests { get; set; }

    /// <summary>Requests I have parked on hold, waiting on an answer — the ones I must not forget.</summary>
    public int OnHoldWithMe { get; set; }

    /// <summary>My own requests on hold waiting on ME to answer — the "needs my answer" badge.</summary>
    public int NeedsMyAnswer { get; set; }
}

/// <summary>A row in "my requests" (usp_Request_GetForEmployee) — everything a person has raised.</summary>
public class MyRequest
{
    public int RequestInstanceId { get; set; }
    public string RequestTypeCode { get; set; } = string.Empty;
    public string RequestTypeName { get; set; } = string.Empty;
    public string? Title { get; set; }
    public string Status { get; set; } = string.Empty;
    public int? CurrentStepNo { get; set; }
    public string? CurrentStepName { get; set; }
    public DateTime SubmittedAt { get; set; }
    public DateTime? ClosedAt { get; set; }
    public string? ClosedReason { get; set; }
}

/// <summary>
/// A row in the approver's inbox (usp_Request_GetPendingForUser) — everything waiting on ME right
/// now, whether because I am the named approver or hold the role the step requires.
/// </summary>
public class InboxItem
{
    public int RequestInstanceId { get; set; }
    public string RequestTypeCode { get; set; } = string.Empty;
    public string RequestTypeName { get; set; } = string.Empty;
    public int EmployeeId { get; set; }
    public string EmployeeName { get; set; } = string.Empty;
    public string BranchName { get; set; } = string.Empty;
    public string? Title { get; set; }
    public int StepNo { get; set; }
    public string StepName { get; set; } = string.Empty;
    public string ApproverType { get; set; } = string.Empty;
    public DateTime SubmittedAt { get; set; }

    /// <summary>How long this has been waiting. The inbox nags with colour past a few days.</summary>
    public int DaysWaiting { get; set; }

    /// <summary>True when it is in my inbox because I am the step's DEPUTY (fallback role), not its primary approver.</summary>
    public bool AsDeputy { get; set; }

    /// <summary>The deputy role name, when this row is one I may sign as a fallback approver.</summary>
    public string? FallbackRoleName { get; set; }
}

/// <summary>A pending request still on a superseded chain (usp_Request_GetOnOldVersions) — HR's move-version queue.</summary>
public class OldVersionRequest
{
    public int RequestInstanceId { get; set; }
    public string RequestTypeCode { get; set; } = string.Empty;
    public string RequestTypeName { get; set; } = string.Empty;
    public int EmployeeId { get; set; }
    public string EmployeeName { get; set; } = string.Empty;
    public string BranchName { get; set; } = string.Empty;
    public string? Title { get; set; }
    public DateTime SubmittedAt { get; set; }
    public int? CurrentStepNo { get; set; }
    public string? CurrentStepName { get; set; }

    /// <summary>The version this request is on now, versus the active one it could be moved to.</summary>
    public int CurrentVersion { get; set; }
    public int ActiveVersion { get; set; }
    public int ActiveWorkflowDefinitionId { get; set; }

    public int DaysWaiting { get; set; }
}

/* ---- actions ---- */

/// <summary>Result of an approve — the request's new status and which step (if any) is now waiting.</summary>
public class ApproveResult
{
    public int RequestInstanceId { get; set; }
    public string Status { get; set; } = string.Empty;
    public int? CurrentStepNo { get; set; }
}

/// <summary>Result of a reject/cancel — the request is now closed with the given reason.</summary>
public class RequestClosedResult
{
    public int RequestInstanceId { get; set; }
    public string Status { get; set; } = string.Empty;
    public string? ClosedReason { get; set; }
}

/// <summary>
/// The FROZEN signature image from one signed step (workflow.usp_Request_GetSignatureImage).
///
/// This reads the copy that was taken at signing time — NOT the signer's current image. An audit
/// trail must not restyle itself when somebody changes their signature next year, so a printed
/// approval always shows the signature that was actually used, on that day.
/// </summary>
public class FrozenSignatureImage
{
    public int SignatureId { get; set; }
    public int? StepNo { get; set; }
    public string Action { get; set; } = string.Empty;
    public int? ActedByUserId { get; set; }
    public string? ActedByUsername { get; set; }
    public DateTime ActedAt { get; set; }
    public byte[]? SignatureImage { get; set; }
    public string? SignatureContentType { get; set; }
}

/// <summary>An approver's comment on approving. The comment is optional; approving is not.</summary>
public class ApproveRequest
{
    public string? Comment { get; set; }

    /// <summary>An optional note on what the approver changed before signing, recorded on the step for the history.</summary>
    public string? ChangeSummary { get; set; }

    /// <summary>
    /// The decision the user actually chose ("Approved", "ApprovedWithChanges"). Sent so the record
    /// can keep the chosen label; the approve procedure derives the stored Decision itself, so this
    /// is carried for the audit trail rather than passed through.
    /// </summary>
    public string? Code { get; set; }

    /// <summary>
    /// The caller's own password, sent ONLY when the step or their role demands a signature. Verified
    /// against their account here and never stored, logged or echoed — the database is told whether
    /// the signature happened, never what it was.
    /// </summary>
    public string? Password { get; set; }
}

/// <summary>
/// Parks a live request on hold while the approver waits for something. The reason is mandatory —
/// the database refuses a blank one. WaitingOnRequester says whether the ball is in the employee's
/// court (answer needed) or the approver's own.
/// </summary>
public class PutOnHoldRequest
{
    public string Reason { get; set; } = string.Empty;
    public bool WaitingOnRequester { get; set; }

    /// <summary>The decision the user chose — "Put on hold" and "Ask the employee" are both Holds.</summary>
    public string? Code { get; set; }

    /// <summary>
    /// Verified when the caller's role demands a signature. NOTE: usp_Request_PutOnHold takes no
    /// SignedWithPassword, so a hold cannot RECORD that it was signed — the password is still checked
    /// before the hold is allowed, so nobody can act under a signature policy without proving identity.
    /// </summary>
    public string? Password { get; set; }
}

/// <summary>
/// Lifts a hold. The note is OPTIONAL — the hold's own reason already says what was being waited for,
/// and the answer usually arrives as a request note rather than here. No password: resuming asserts
/// nothing and decides nothing, it just hands the step back to the approver.
/// </summary>
public class ResumeRequest
{
    public string? Note { get; set; }
}

/// <summary>
/// One note in a request's conversation (usp_RequestNote_GetForRequest). A note never changes state;
/// it carries context, questions and answers, with enough about the author for the UI to show who
/// was speaking in what capacity.
/// </summary>
public class RequestNote
{
    public int NoteId { get; set; }
    public int RequestInstanceId { get; set; }

    /// <summary>The step the note was written against, if any — pairs a question with the step that asked it.</summary>
    public int? StepNo { get; set; }
    public string? StepName { get; set; }

    public int AuthorUserId { get; set; }
    public string? AuthorUsername { get; set; }
    public string? AuthorFullName { get; set; }

    /// <summary>True when the author is the employee the request is about — so the UI can mark their side of the thread.</summary>
    public bool AuthorIsRequester { get; set; }

    public string NoteText { get; set; } = string.Empty;

    /// <summary>True when this note is the answer to a hold — the UI pairs it with the question that set the hold.</summary>
    public bool IsHoldResponse { get; set; }

    public DateTime CreatedAt { get; set; }
}

/// <summary>Adds a note to a request's conversation. The text is required — the database refuses an empty one.</summary>
public class AddNoteRequest
{
    public string NoteText { get; set; } = string.Empty;

    /// <summary>The step this note is written against, if any.</summary>
    public int? StepNo { get; set; }

    /// <summary>True when this note answers a hold, so it is paired with the question that set it.</summary>
    public bool IsHoldResponse { get; set; }
}

/// <summary>
/// A request that has been sitting on hold too long (usp_Request_GetLongHolds) — HR's stuck-requests
/// queue, so a hold that everyone forgot does not quietly become a permanent block.
/// </summary>
public class LongHold
{
    public int RequestInstanceId { get; set; }
    public string RequestTypeName { get; set; } = string.Empty;
    public string EmployeeName { get; set; } = string.Empty;
    public string BranchName { get; set; } = string.Empty;
    public string? Title { get; set; }
    public int StepNo { get; set; }
    public string StepName { get; set; } = string.Empty;
    public string? HoldReason { get; set; }
    public DateTime? HoldSetAt { get; set; }
    public bool WaitingOnRequester { get; set; }

    /// <summary>The username of whoever set the hold.</summary>
    public string? HeldBy { get; set; }

    public int DaysOnHold { get; set; }

    /// <summary>A one-line plain-language read on who the hold is stuck on and why.</summary>
    public string Detail { get; set; } = string.Empty;
}

/// <summary>A reason. Required for reject, cancel and move-version — collected in the UI, because the database demands it.</summary>
public class ReasonRequest
{
    public string Reason { get; set; } = string.Empty;

    /// <summary>The decision the user chose, where this reason came from a decision dialog. Ignored elsewhere.</summary>
    public string? Code { get; set; }

    /// <summary>
    /// The caller's password, where the act must be signed — a rejection under a signature policy, or
    /// a withdrawal (undoing a signed act is itself a signed act). Verified here, never stored.
    /// </summary>
    public string? Password { get; set; }
}

/// <summary>Moves one live request onto the active chain version. The reason is mandatory — this rewrites who must sign a request already in flight.</summary>
public class MoveVersionRequest
{
    /// <summary>The version to move to. NULL means "the current active version", which is the normal case.</summary>
    public int? TargetWorkflowDefinitionId { get; set; }
    public string Reason { get; set; } = string.Empty;
}

/// <summary>Result of a version move — where it moved from and to, recorded on the request forever.</summary>
public class MoveVersionResult
{
    public int RequestInstanceId { get; set; }
    public string Status { get; set; } = string.Empty;
    public int? CurrentStepNo { get; set; }
    public int MovedFromVersion { get; set; }
    public int MovedToVersion { get; set; }
    public DateTime? VersionMovedAt { get; set; }
    public int? VersionMovedBy { get; set; }
}
