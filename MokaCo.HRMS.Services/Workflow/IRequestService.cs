using MokaCo.HRMS.Model.Workflow;

namespace MokaCo.HRMS.Services.Workflow;

/// <summary>The caller's identity and rights, as the controller resolved them from the token. Passed in so the service can enforce visibility.</summary>
public record RequestCaller(int UserId, int? EmployeeId, bool HasViewAll);

public interface IRequestService
{
    /// <summary>
    /// One request in full, but ONLY if the caller may see it: they hold REQUEST_VIEW_ALL, or it is
    /// their own, or they raised it, or they are an approver on one of its steps. Throws
    /// <see cref="WorkflowException"/> 403 otherwise, and returns null when there is no such request.
    /// </summary>
    Task<RequestDetail?> GetByIdAsync(int requestInstanceId, RequestCaller caller);

    /// <summary>
    /// The request's chain, but ONLY if the caller may see the request (same rule as the detail). Read
    /// for the caller, so each step's CanWithdraw reflects what THEY may take back. Throws
    /// <see cref="WorkflowException"/> 403 when the request is not theirs to see.
    /// </summary>
    Task<IEnumerable<RequestStep>> GetStepsAsync(int requestInstanceId, RequestCaller caller);

    Task<IEnumerable<MyRequest>> GetForEmployeeAsync(int employeeId, string? status);
    Task<IEnumerable<InboxItem>> GetInboxAsync(int userId);

    /// <summary>Everything the user is connected to, in any capacity — the single call the hub slices into tabs.</summary>
    Task<IEnumerable<ForUserRequest>> GetForUserAsync(int userId, string? status, bool includeClosed, int? requestTypeId, DateTime? fromDate, DateTime? toDate);

    /// <summary>The hub's tab-badge counts.</summary>
    Task<RequestCounts> GetCountsForUserAsync(int userId);

    /// <summary>
    /// What the caller may do at the current step. An EMPTY list means "not yours to decide" and is
    /// returned as such — the client renders the chain read-only rather than showing dead buttons.
    /// Behind the same visibility rule as the request itself.
    /// </summary>
    Task<IEnumerable<DecisionOption>> GetAvailableDecisionsAsync(int requestInstanceId, RequestCaller caller);

    /// <summary>
    /// Whether the caller must password-sign their decision here, and the database's own wording for
    /// why. Read with the page so a signature never surprises anyone at the moment they commit.
    /// </summary>
    Task<SignatureRequirement?> GetSignatureRequirementAsync(int requestInstanceId, RequestCaller caller);

    /// <summary>The caller's OWN unsigned draft, or null. Never anyone else's.</summary>
    Task<DraftDecision?> GetDraftAsync(int requestInstanceId, RequestCaller caller);

    /// <summary>Saves a decision without signing it. Deliberately unvalidated — a draft may be half-formed.</summary>
    Task SaveDraftAsync(int requestInstanceId, int actedByUserId, SaveDraftRequest request);

    /// <summary>Throws the caller's own draft away.</summary>
    Task DiscardDraftAsync(int requestInstanceId, int actedByUserId);

    /// <summary>Hands the current step to a named person. The database decides whether the caller may.</summary>
    Task DelegateAsync(int requestInstanceId, int actedByUserId, int toUserId, string reason);

    /// <summary>Takes a delegated step back — for whoever handed it over. Nothing was signed, so no password.</summary>
    Task ReclaimAsync(int requestInstanceId, int actedByUserId, string? reason);

    /// <summary>
    /// Approve. When the step or the caller's role demands a signature, <paramref name="password"/>
    /// must be their real password: it is verified here and a wrong one is a 401 that changes nothing.
    ///
    /// ONLY for types with no typed decide procedure. A request whose final approval has side effects
    /// (leave, advances, adjustments, overtime, swaps, hires, separations, exit permissions…) is
    /// refused with a <see cref="WorkflowException"/> 409 telling the caller to use its typed endpoint
    /// — the generic engine call would close the request without ever applying them.
    /// </summary>
    Task<ApproveResult?> ApproveAsync(int requestInstanceId, int actedByUserId, string? comment, string? changeSummary = null, string? password = null);
    Task<RequestClosedResult?> RejectAsync(int requestInstanceId, int actedByUserId, string reason, string? password = null);
    /// <summary>
    /// Cancels an open request. Refused with a <see cref="WorkflowException"/> 403 unless the caller
    /// raised it, is the employee it concerns, or holds HR/Admin — the same rule usp_Request_Cancel
    /// enforces, checked here only to answer cleanly before the round-trip.
    /// </summary>
    Task<RequestClosedResult?> CancelAsync(int requestInstanceId, RequestCaller caller, string reason);

    /// <summary>Parks a live request on hold. The database enforces the reason and who may act; a breach comes back as a WorkflowException.</summary>
    Task PutOnHoldAsync(int requestInstanceId, int actedByUserId, string reason, bool waitingOnRequester, string? password = null);

    /// <summary>
    /// Lifts a hold, returning the step to Pending with the same approver. The database allows the
    /// approver who set it OR the requester — a hold waiting on the requester is answered by them, and
    /// answering IS the resume. Its refusals come back as a WorkflowException, message intact.
    /// </summary>
    Task<ApproveResult?> ResumeAsync(int requestInstanceId, int actedByUserId, string? note);

    /// <summary>
    /// Sweeps approved requests whose type effect never landed and applies it. Reports what actually
    /// landed rather than what was attempted — anything left in StillUnapplied needs a person.
    /// </summary>
    Task<EffectReconcileResult> ReconcileApprovalEffectsAsync();

    /// <summary>The request's conversation, oldest first.</summary>
    Task<IEnumerable<RequestNote>> GetNotesAsync(int requestInstanceId);

    /// <summary>Adds a note and returns its id. The database refuses empty text; that comes back as a WorkflowException.</summary>
    Task<int> AddNoteAsync(int requestInstanceId, int authorUserId, string noteText, int? stepNo, bool isHoldResponse);

    /// <summary>Requests stuck on hold longer than the given number of days — HR's stuck-requests queue.</summary>
    Task<IEnumerable<LongHold>> GetLongHoldsAsync(int olderThanDays);

    /// <summary>
    /// Decisions somebody started and never signed. The quieter half of the oversight page — nobody
    /// is waiting on an answer they know is coming, because nothing visible has happened at all.
    /// </summary>
    Task<IEnumerable<StaleDraft>> GetStaleDraftsAsync(int olderThanDays);

    Task<IEnumerable<OldVersionRequest>> GetOnOldVersionsAsync(int? requestTypeId);
    Task<MoveVersionResult?> MoveToVersionAsync(int requestInstanceId, MoveVersionRequest request, int actedByUserId);

    /// <summary>The frozen signature image for a step, only if the caller may see the request it belongs to.</summary>
    Task<FrozenSignatureImage?> GetSignatureImageAsync(int requestInstanceId, int stepNo, RequestCaller caller);

    /// <summary>One frozen image by its signature-log id — named by a step's SignedSignatureId. Any signed-in user may read it.</summary>
    Task<FrozenSignatureImage?> GetFrozenImageByIdAsync(int signatureId);

    /// <summary>
    /// Takes back a decision on an exit-permission step. The database decides whether the caller may
    /// withdraw and whether anyone acted since; a breach there becomes a WorkflowException here, message
    /// intact.
    /// </summary>
    Task<WithdrawDecisionResult?> WithdrawExitPermissionDecisionAsync(int requestInstanceId, int stepNo, int actedByUserId, string reason, string? password = null);

    /// <summary>
    /// Takes back a decision through the ENGINE (usp_Request_WithdrawDecision) — for request types
    /// that stamp NO figure when they are decided, so there is nothing to restore. Asks the same
    /// signature question as the exit-permission path; the database remains the authority on whether
    /// this caller may withdraw at all.
    /// </summary>
    Task<ApproveResult?> WithdrawDecisionAsync(int requestInstanceId, int stepNo, int actedByUserId, string reason, string? password = null);

    /// <summary>Reopens a rejected/cancelled request. The database refuses an approved one and demands a reason; that comes back as a WorkflowException.</summary>
    Task<ApproveResult?> ReopenClosedAsync(int requestInstanceId, int actedByUserId, string reason);

    /// <summary>
    /// The last signer takes their own decision back, same UTC day. NO permission is checked here —
    /// the database decides, exactly as it does for approve and reject, and its refusal (wrong
    /// person, wrong day, already consumed) comes back as a WorkflowException with the message
    /// intact. That message is the entire value of the refusal, so nothing may replace it.
    /// </summary>
    /// <param name="password">
    /// Verified here and passed on as the signed fact. Required when the decision being struck was
    /// itself password-signed, or the caller's role demands a signature — undoing a signed act is a
    /// signed act, exactly as it is for a withdrawal.
    /// </param>
    Task<ApproveResult?> RetractLastDecisionAsync(int requestInstanceId, int actedByUserId, string reason, string? password = null);

    /// <summary>
    /// One half of a GM + Owner reopen. Answers 'AwaitingSecond' when this was the first signature —
    /// nothing has moved — or 'Reopened' with the request's new standing when the other role
    /// completed it. The database owns the role check and refuses anybody else.
    /// </summary>
    Task<ReopenResult?> ReopenAsync(int requestInstanceId, int actedByUserId, string reason);
}
