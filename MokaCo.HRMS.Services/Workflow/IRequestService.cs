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
    /// </summary>
    Task<ApproveResult?> ApproveAsync(int requestInstanceId, int actedByUserId, string? comment, string? changeSummary = null, string? password = null);
    Task<RequestClosedResult?> RejectAsync(int requestInstanceId, int actedByUserId, string reason, string? password = null);
    Task<RequestClosedResult?> CancelAsync(int requestInstanceId, int actedByUserId, string reason);

    /// <summary>Parks a live request on hold. The database enforces the reason and who may act; a breach comes back as a WorkflowException.</summary>
    Task PutOnHoldAsync(int requestInstanceId, int actedByUserId, string reason, bool waitingOnRequester, string? password = null);

    /// <summary>The request's conversation, oldest first.</summary>
    Task<IEnumerable<RequestNote>> GetNotesAsync(int requestInstanceId);

    /// <summary>Adds a note and returns its id. The database refuses empty text; that comes back as a WorkflowException.</summary>
    Task<int> AddNoteAsync(int requestInstanceId, int authorUserId, string noteText, int? stepNo, bool isHoldResponse);

    /// <summary>Requests stuck on hold longer than the given number of days — HR's stuck-requests queue.</summary>
    Task<IEnumerable<LongHold>> GetLongHoldsAsync(int olderThanDays);

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

    /// <summary>Reopens a rejected/cancelled request. The database refuses an approved one and demands a reason; that comes back as a WorkflowException.</summary>
    Task<ApproveResult?> ReopenClosedAsync(int requestInstanceId, int actedByUserId, string reason);
}
