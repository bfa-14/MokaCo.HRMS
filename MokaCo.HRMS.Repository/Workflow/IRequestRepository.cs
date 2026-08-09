using MokaCo.HRMS.Model.Workflow;

namespace MokaCo.HRMS.Repository.Workflow;

public interface IRequestRepository
{
    /// <summary>Header, chain and history together — the three result sets of usp_Request_GetById. Null when no such request.</summary>
    Task<RequestDetail?> GetByIdAsync(int requestInstanceId);

    /// <summary>
    /// The materialised chain on its own (usp_Request_GetSteps), read FOR a specific user so each step's
    /// CanWithdraw is answered from that user's point of view.
    /// </summary>
    Task<IEnumerable<RequestStep>> GetStepsAsync(int requestInstanceId, int forUserId);

    Task<IEnumerable<MyRequest>> GetForEmployeeAsync(int employeeId, string? status);
    Task<IEnumerable<InboxItem>> GetPendingForUserAsync(int userId);

    /// <summary>Everything the user is connected to, in any capacity, with the "how" flags. Feeds the whole hub.</summary>
    Task<IEnumerable<ForUserRequest>> GetForUserAsync(int userId, string? status, bool includeClosed, int? requestTypeId, DateTime? fromDate, DateTime? toDate);

    /// <summary>The hub's tab-badge counts.</summary>
    Task<RequestCounts> GetCountsForUserAsync(int userId);

    /// <summary>
    /// What THIS user may do at the current step (usp_Step_GetAvailableDecisions), already filtered by
    /// the step's configured set and whether they may act at all. An EMPTY result means "not yours to
    /// decide" — a real answer, not a failure.
    /// </summary>
    Task<IEnumerable<DecisionOption>> GetAvailableDecisionsAsync(int requestInstanceId, int userId);

    /// <summary>
    /// Whether this user's decision at the current step must be password-signed, and the verbatim
    /// sentence explaining why (usp_Step_GetSignatureRequirement).
    /// </summary>
    Task<SignatureRequirement?> GetSignatureRequirementAsync(int requestInstanceId, int userId);

    /// <summary>The caller's OWN unsigned draft here, or null. A colleague's draft on a shared step is invisible.</summary>
    Task<DraftDecision?> GetDraftDecisionAsync(int requestInstanceId, int forUserId);

    /// <summary>Saves a decision without signing it. Nothing is validated — a draft is allowed to be half-formed.</summary>
    Task SaveDraftDecisionAsync(int requestInstanceId, int actedByUserId, string decisionCode, string? comment, int? value, int? targetUserId, bool waitingOnRequester);

    /// <summary>Throws the caller's draft away.</summary>
    Task DiscardDraftDecisionAsync(int requestInstanceId, int actedByUserId);

    /// <summary>Hands the current step to a named person (usp_Request_Delegate); the request does not advance.</summary>
    Task DelegateAsync(int requestInstanceId, int actedByUserId, int toUserId, string reason);

    /// <summary>Takes a delegated step back (usp_Request_ReclaimDelegation) — only for whoever handed it over.</summary>
    Task ReclaimDelegationAsync(int requestInstanceId, int actedByUserId, string? reason);

    /// <summary><paramref name="signedWithPassword"/> records that the caller proved their identity — the procedure stores the fact, never the password.</summary>
    Task<ApproveResult?> ApproveAsync(int requestInstanceId, int actedByUserId, string? comment, string? changeSummary = null, bool signedWithPassword = false);
    Task<RequestClosedResult?> RejectAsync(int requestInstanceId, int actedByUserId, string reason, bool signedWithPassword = false);
    Task<RequestClosedResult?> CancelAsync(int requestInstanceId, int actedByUserId, string reason);

    /// <summary>Parks a live request on hold. The procedure raises if the reason is blank or the caller is not the approver.</summary>
    Task PutOnHoldAsync(int requestInstanceId, int actedByUserId, string reason, bool waitingOnRequester);

    /// <summary>The request's conversation, oldest first.</summary>
    Task<IEnumerable<RequestNote>> GetNotesAsync(int requestInstanceId);

    /// <summary>Adds a note and returns the new note's id. The procedure raises on empty text.</summary>
    Task<int> AddNoteAsync(int requestInstanceId, int authorUserId, string noteText, int? stepNo, bool isHoldResponse);

    /// <summary>Requests stuck on hold longer than the given number of days — HR's stuck-requests queue.</summary>
    Task<IEnumerable<LongHold>> GetLongHoldsAsync(int olderThanDays);

    Task<IEnumerable<OldVersionRequest>> GetOnOldVersionsAsync(int? requestTypeId);
    Task<MoveVersionResult?> MoveToVersionAsync(int requestInstanceId, int? targetWorkflowDefinitionId, int actedByUserId, string reason);

    /// <summary>The FROZEN signature image for one signed step. Null when there is no signed image for it.</summary>
    Task<FrozenSignatureImage?> GetSignatureImageAsync(int requestInstanceId, int stepNo);

    /// <summary>One frozen image by its signature-log id — the row named by a step's SignedSignatureId. Null when it has no image.</summary>
    Task<FrozenSignatureImage?> GetFrozenImageByIdAsync(int signatureId);

    /// <summary>
    /// Takes back a decision on an EXIT PERMISSION step (usp_ExitPermission_WithdrawDecision) — the
    /// typed proc that also restores the figure. The proc is the authority on who may withdraw and
    /// whether anyone has acted since, and raises otherwise.
    /// </summary>
    Task<WithdrawDecisionResult?> WithdrawExitPermissionDecisionAsync(int requestInstanceId, int stepNo, int actedByUserId, string reason, bool signedWithPassword = false);

    /// <summary>
    /// Reopens a REJECTED or CANCELLED request (usp_Request_ReopenClosed), returning it to the step
    /// that closed it. The proc refuses an approved request and demands a reason, raising otherwise.
    /// </summary>
    Task<ApproveResult?> ReopenClosedAsync(int requestInstanceId, int actedByUserId, string reason);
}
