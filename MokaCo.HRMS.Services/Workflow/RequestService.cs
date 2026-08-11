using MokaCo.HRMS.Model.Workflow;
using MokaCo.HRMS.Repository.Security;
using MokaCo.HRMS.Repository.Workflow;
using MokaCo.HRMS.Services.Auth;

namespace MokaCo.HRMS.Services.Workflow;

/// <summary>
/// Request instances: reading them (under the visibility rule) and acting on them.
///
/// Two things this layer does and the repository does not:
///   1. It enforces WHO MAY SEE a request — a C# rule, because the read procedure does not gate
///      itself and an employee's request can be private.
///   2. It maps the SQL errors from approve/reject/cancel to clean statuses. It does NOT re-check
///      who may approve — that stays in the database (see WorkflowSqlErrors).
/// </summary>
public class RequestService : IRequestService
{
    private readonly IRequestRepository _repo;
    private readonly IUserRepository _users;
    private readonly IPasswordHasher _hasher;

    public RequestService(IRequestRepository repo, IUserRepository users, IPasswordHasher hasher)
    {
        _repo = repo;
        _users = users;
        _hasher = hasher;
    }

    /// <summary>
    /// THE SIGNATURE. Proves the person committing the decision is the account holder, for a step or
    /// role whose policy demands it.
    ///
    /// The requirement is re-read from the database HERE rather than trusted from the client — a
    /// caller that simply omits the password must not be able to skip a signature the policy demands.
    /// Returns whether the act was signed, which is the only thing recorded: the password itself is
    /// never stored, logged or echoed back.
    /// </summary>
    private async Task<bool> VerifySignatureAsync(int requestInstanceId, int userId, string? password)
    {
        var requirement = await _repo.GetSignatureRequirementAsync(requestInstanceId, userId);
        return await VerifyPasswordAsync(
            userId,
            password,
            requirement?.SignatureRequired ?? false,
            requirement?.Explanation ?? "This decision must be signed with your password.");
    }

    /// <summary>
    /// The password check itself, given an already-decided requirement. Split out because a WITHDRAWAL
    /// asks a different question from a decision — see WithdrawExitPermissionDecisionAsync.
    /// </summary>
    private async Task<bool> VerifyPasswordAsync(int userId, string? password, bool required, string demand)
    {
        if (!required)
        {
            // Not demanded. Someone may still choose to send one; an unrequested password is simply
            // not a signature, and is dropped rather than half-checked.
            return false;
        }

        if (string.IsNullOrEmpty(password))
            throw new WorkflowException(401, demand);

        var user = await _users.GetByIdAsync(userId);
        if (user is null || !_hasher.Verify(password, user.PasswordHash))
            throw new WorkflowException(401, "That password is not correct.");

        return true;
    }

    public async Task<RequestDetail?> GetByIdAsync(int requestInstanceId, RequestCaller caller)
    {
        var detail = await _repo.GetByIdAsync(requestInstanceId);
        if (detail is null)
            return null;

        if (!await CanSeeAsync(detail, caller))
            throw new WorkflowException(403, "You do not have access to this request.");

        return detail;
    }

    /// <summary>
    /// SEEING OTHER PEOPLE'S REQUESTS. Allowed when the caller holds REQUEST_VIEW_ALL, or the request
    /// is theirs, or they raised it, or they are — or were — an approver on one of its steps.
    /// Approvers must be able to see what they are being asked to sign, and what they already signed.
    /// The cheap checks run first; the inbox lookup (which also catches role-based current steps) runs
    /// only if nothing simpler already granted access.
    /// </summary>
    private async Task<bool> CanSeeAsync(RequestDetail detail, RequestCaller caller)
    {
        if (caller.HasViewAll)
            return true;

        if (caller.EmployeeId is int me && detail.Header.EmployeeId == me)
            return true;

        if (detail.Header.RaisedByUserId == caller.UserId)
            return true;

        // A named approver on any step — pending, signed or skipped-past.
        if (detail.Steps.Any(s => s.ResolvedUserId == caller.UserId || s.ActedByUserId == caller.UserId))
            return true;

        // The current step may be a ROLE step with no resolved user; the inbox resolves role
        // membership, so a request sitting in the caller's inbox is one they may act on and see.
        var inbox = await _repo.GetPendingForUserAsync(caller.UserId);
        return inbox.Any(i => i.RequestInstanceId == detail.Header.RequestInstanceId);
    }

    /// <summary>
    /// The chain, behind the SAME visibility rule as the detail. The request is loaded to gate the
    /// read; the steps themselves are then read FOR the caller so CanWithdraw is answered from their
    /// point of view.
    /// </summary>
    public async Task<IEnumerable<RequestStep>> GetStepsAsync(int requestInstanceId, RequestCaller caller)
    {
        var detail = await _repo.GetByIdAsync(requestInstanceId);
        if (detail is null)
            return Array.Empty<RequestStep>();

        if (!await CanSeeAsync(detail, caller))
            throw new WorkflowException(403, "You do not have access to this request.");

        return await _repo.GetStepsAsync(requestInstanceId, caller.UserId);
    }

    public Task<IEnumerable<MyRequest>> GetForEmployeeAsync(int employeeId, string? status)
        => _repo.GetForEmployeeAsync(employeeId, status);

    public Task<IEnumerable<InboxItem>> GetInboxAsync(int userId)
        => _repo.GetPendingForUserAsync(userId);

    /// <summary>Scoped to the user by the procedure itself — no extra visibility check needed, every row is already theirs.</summary>
    public Task<IEnumerable<ForUserRequest>> GetForUserAsync(int userId, string? status, bool includeClosed, int? requestTypeId, DateTime? fromDate, DateTime? toDate)
        => _repo.GetForUserAsync(userId, status, includeClosed, requestTypeId, fromDate, toDate);

    public Task<RequestCounts> GetCountsForUserAsync(int userId)
        => _repo.GetCountsForUserAsync(userId);

    /// <summary>
    /// The decisions available to the caller. Gated by the same visibility rule as the request, then
    /// answered entirely by the procedure — which returns NOTHING when the step is not the caller's.
    /// That empty list is passed through untouched: it is the answer, not a failure to find one.
    /// </summary>
    public async Task<IEnumerable<DecisionOption>> GetAvailableDecisionsAsync(int requestInstanceId, RequestCaller caller)
    {
        var detail = await _repo.GetByIdAsync(requestInstanceId);
        if (detail is null)
            return Array.Empty<DecisionOption>();

        if (!await CanSeeAsync(detail, caller))
            throw new WorkflowException(403, "You do not have access to this request.");

        return await _repo.GetAvailableDecisionsAsync(requestInstanceId, caller.UserId);
    }

    public async Task<SignatureRequirement?> GetSignatureRequirementAsync(int requestInstanceId, RequestCaller caller)
    {
        var detail = await _repo.GetByIdAsync(requestInstanceId);
        if (detail is null)
            return null;

        if (!await CanSeeAsync(detail, caller))
            throw new WorkflowException(403, "You do not have access to this request.");

        return await _repo.GetSignatureRequirementAsync(requestInstanceId, caller.UserId);
    }

    /// <summary>Scoped to the caller by the procedure — a colleague's draft on a shared step never surfaces.</summary>
    public async Task<DraftDecision?> GetDraftAsync(int requestInstanceId, RequestCaller caller)
    {
        var detail = await _repo.GetByIdAsync(requestInstanceId);
        if (detail is null)
            return null;

        if (!await CanSeeAsync(detail, caller))
            throw new WorkflowException(403, "You do not have access to this request.");

        return await _repo.GetDraftDecisionAsync(requestInstanceId, caller.UserId);
    }

    /// <summary>NOTHING is validated — the requirement flags apply when a decision is signed, not saved.</summary>
    public Task SaveDraftAsync(int requestInstanceId, int actedByUserId, SaveDraftRequest request)
        => WorkflowSqlErrors.MapAsync<object?>(async () =>
        {
            await _repo.SaveDraftDecisionAsync(
                requestInstanceId, actedByUserId, request.DecisionCode, request.Comment,
                request.Value, request.TargetUserId, request.WaitingOnRequester);
            return null;
        });

    public Task DiscardDraftAsync(int requestInstanceId, int actedByUserId)
        => WorkflowSqlErrors.MapAsync<object?>(async () =>
        {
            await _repo.DiscardDraftDecisionAsync(requestInstanceId, actedByUserId);
            return null;
        });

    /// <summary>The database decides whether the caller may hand this step over, and to whom.</summary>
    public Task DelegateAsync(int requestInstanceId, int actedByUserId, int toUserId, string reason)
        => WorkflowSqlErrors.MapAsync<object?>(async () =>
        {
            await _repo.DelegateAsync(requestInstanceId, actedByUserId, toUserId, reason);
            return null;
        });

    public Task ReclaimAsync(int requestInstanceId, int actedByUserId, string? reason)
        => WorkflowSqlErrors.MapAsync<object?>(async () =>
        {
            await _repo.ReclaimDelegationAsync(requestInstanceId, actedByUserId, reason);
            return null;
        });

    /// <summary>
    /// THE TYPES THAT MUST NOT COME THROUGH THE GENERIC APPROVE.
    ///
    /// Every one of these has a typed _Decide procedure that applies the request's SIDE EFFECTS at
    /// final approval — the leave-ledger post, the payroll advance and adjustment rows, the overtime
    /// figure and its attendance link, the roster exchange, the employee a hire creates, the
    /// termination date a separation stamps. workflow.usp_Request_Approve moves the chain and knows
    /// nothing about any of it, so approving one of these here closed the request while the money,
    /// the leave or the roster silently never happened.
    ///
    /// EXIT_PERMISSION is in the list for the same reason, even though its effects are also picked up
    /// later by the nightly job and the period close: the approver may REDUCE the minutes, and only
    /// the typed route carries that figure.
    /// </summary>
    private static readonly HashSet<string> TypedDecideOnly = new(StringComparer.OrdinalIgnoreCase)
    {
        "LEAVE_REQUEST", "SALARY_ADVANCE", "PAYROLL_ADJUSTMENT", "OVERTIME", "SHIFT_SWAP",
        "EXPENSE_REIMBURSEMENT", "TIP_DISTRIBUTION", "SEPARATION", "ONBOARDING",
        "AVAILABILITY_CHANGE", "EXIT_PERMISSION",
    };

    /// <summary>
    /// The database decides whether this user may approve; a rejection there becomes a 403 here. The
    /// signature is verified FIRST, so a wrong password changes nothing at all.
    ///
    /// Before any of that, a typed request is REFUSED outright (409). The refusal comes before the
    /// password check on purpose: there is no point putting the caller through a signature for a call
    /// that was never going to be honoured. Untyped/simple types keep the plain engine behaviour.
    /// </summary>
    public async Task<ApproveResult?> ApproveAsync(int requestInstanceId, int actedByUserId, string? comment, string? changeSummary = null, string? password = null)
    {
        var detail = await _repo.GetByIdAsync(requestInstanceId);
        if (detail is null)
            return null;

        if (TypedDecideOnly.Contains(detail.Header.RequestTypeCode))
            throw new WorkflowException(409, "Use the typed decide endpoint for this request type.");

        var signed = await VerifySignatureAsync(requestInstanceId, actedByUserId, password);
        return await WorkflowSqlErrors.MapAsync(() => _repo.ApproveAsync(requestInstanceId, actedByUserId, comment, changeSummary, signed));
    }

    public async Task<RequestClosedResult?> RejectAsync(int requestInstanceId, int actedByUserId, string reason, string? password = null)
    {
        var signed = await VerifySignatureAsync(requestInstanceId, actedByUserId, password);
        return await WorkflowSqlErrors.MapAsync(() => _repo.RejectAsync(requestInstanceId, actedByUserId, reason, signed));
    }

    /// <summary>
    /// Cancelling is for the people the request BELONGS to — whoever raised it, whoever it is about —
    /// or HR/Admin acting for them.
    ///
    /// The procedure enforces exactly this and stays the authority; the same check runs here only so
    /// the answer is a clean 403 with the reason, instead of a SQL round-trip that has to be
    /// pattern-matched back out of an error message. The two must agree — if the rule ever changes,
    /// change it in usp_Request_Cancel first and mirror it here.
    /// </summary>
    public async Task<RequestClosedResult?> CancelAsync(int requestInstanceId, RequestCaller caller, string reason)
    {
        var detail = await _repo.GetByIdAsync(requestInstanceId);
        if (detail is null)
            return null;

        if (!await MayCancelAsync(detail.Header, caller))
            throw new WorkflowException(403,
                "Only the person who raised this request, the employee it concerns, or HR may cancel it.");

        return await WorkflowSqlErrors.MapAsync(() => _repo.CancelAsync(requestInstanceId, caller.UserId, reason));
    }

    /// <summary>
    /// The subject is matched on EMPLOYEE id rather than user id — the header carries the employee the
    /// request is about, and the caller's own employee record is what the controller already resolved.
    /// The role names are read from the database, not the token: only permissions are in the claims.
    /// </summary>
    private async Task<bool> MayCancelAsync(RequestHeader header, RequestCaller caller)
    {
        if (header.RaisedByUserId == caller.UserId)
            return true;

        if (caller.EmployeeId is int me && header.EmployeeId == me)
            return true;

        var roles = await _users.GetRoleNamesAsync(caller.UserId);
        return roles.Any(r => r.Equals("HR", StringComparison.OrdinalIgnoreCase)
                           || r.Equals("Admin", StringComparison.OrdinalIgnoreCase));
    }

    /// <summary>
    /// The database enforces the reason and who may act; a rule broken there becomes a WorkflowException.
    /// The signature is verified where policy demands it, even though usp_Request_PutOnHold has no
    /// SignedWithPassword to record it in — proving identity is the point, and the hold is refused
    /// without it. The fact of the signature simply cannot be stored on a hold.
    /// </summary>
    public async Task PutOnHoldAsync(int requestInstanceId, int actedByUserId, string reason, bool waitingOnRequester, string? password = null)
    {
        await VerifySignatureAsync(requestInstanceId, actedByUserId, password);
        await WorkflowSqlErrors.MapAsync<object?>(async () =>
        {
            await _repo.PutOnHoldAsync(requestInstanceId, actedByUserId, reason, waitingOnRequester);
            return null;
        });
    }

    /// <summary>
    /// Lifts a hold. NO permission and no C# identity rule — the database decides, exactly as it does
    /// for approve and hold, and it allows the approver OR the requester on purpose: a hold marked
    /// "waiting on the requester" is answered BY the requester, and making them then chase the
    /// approver to press a button would leave the request parked for no reason.
    ///
    /// No signature. Resuming asserts nothing and decides nothing — it hands the step back to the
    /// approver exactly as it was before the hold.
    /// </summary>
    public Task<ApproveResult?> ResumeAsync(int requestInstanceId, int actedByUserId, string? note)
        => WorkflowSqlErrors.MapAsync(() => _repo.ResumeAsync(requestInstanceId, actedByUserId, note));

    public Task<IEnumerable<RequestNote>> GetNotesAsync(int requestInstanceId)
        => _repo.GetNotesAsync(requestInstanceId);

    /// <summary>The database refuses empty text; that becomes a WorkflowException here.</summary>
    public Task<int> AddNoteAsync(int requestInstanceId, int authorUserId, string noteText, int? stepNo, bool isHoldResponse)
        => WorkflowSqlErrors.MapAsync(() => _repo.AddNoteAsync(requestInstanceId, authorUserId, noteText, stepNo, isHoldResponse));

    public Task<IEnumerable<LongHold>> GetLongHoldsAsync(int olderThanDays)
        => _repo.GetLongHoldsAsync(olderThanDays);

    public Task<IEnumerable<OldVersionRequest>> GetOnOldVersionsAsync(int? requestTypeId)
        => _repo.GetOnOldVersionsAsync(requestTypeId);

    public Task<MoveVersionResult?> MoveToVersionAsync(int requestInstanceId, MoveVersionRequest request, int actedByUserId)
        => WorkflowSqlErrors.MapAsync(() =>
            _repo.MoveToVersionAsync(requestInstanceId, request.TargetWorkflowDefinitionId, actedByUserId, request.Reason));

    /// <summary>
    /// The frozen signature image for a step — behind the SAME visibility rule as the request itself,
    /// because a signature is part of a request and no more public than the request is.
    /// </summary>
    public async Task<FrozenSignatureImage?> GetSignatureImageAsync(int requestInstanceId, int stepNo, RequestCaller caller)
    {
        var detail = await _repo.GetByIdAsync(requestInstanceId);
        if (detail is null)
            return null;

        if (!await CanSeeAsync(detail, caller))
            throw new WorkflowException(403, "You do not have access to this request.");

        return await _repo.GetSignatureImageAsync(requestInstanceId, stepNo);
    }

    /// <summary>
    /// One frozen image by its signature-log id — the row the step list already named via
    /// SignedSignatureId. No per-request visibility check beyond being signed in: a signature is a
    /// mark shown on approval documents any authenticated user may see, the same footing as a user's
    /// own signature image, and the id is opaque rather than guessable request context.
    /// </summary>
    public Task<FrozenSignatureImage?> GetFrozenImageByIdAsync(int signatureId)
        => _repo.GetFrozenImageByIdAsync(signatureId);

    /// <summary>
    /// The database is the authority on who may withdraw and whether it is still possible; its
    /// human-readable refusal must reach the client verbatim, so the SQL error is mapped, not swallowed.
    /// </summary>
    /// <summary>
    /// Undoing a signed act is itself a signed act, so the signature is verified here too — and it can
    /// be demanded even where a fresh decision would not need one.
    /// </summary>
    public async Task<WithdrawDecisionResult?> WithdrawExitPermissionDecisionAsync(int requestInstanceId, int stepNo, int actedByUserId, string reason, string? password = null)
    {
        // THE WITHDRAWAL'S OWN SIGNATURE QUESTION, read from the STEP — not the request's
        // SignatureRequired. They differ: a decision signed with a password must be signed to undo,
        // even where the caller's role would no longer demand one for a fresh decision. Reading the
        // wrong flag here would let a signed act be undone unsigned.
        var steps = await _repo.GetStepsAsync(requestInstanceId, actedByUserId);
        var target = steps.FirstOrDefault(s => s.StepNo == stepNo);

        var signed = await VerifyPasswordAsync(
            actedByUserId,
            password,
            target?.WithdrawNeedsSignature ?? false,
            "Undoing a signed decision must itself be signed with your password.");

        return await WorkflowSqlErrors.MapAsync(() => _repo.WithdrawExitPermissionDecisionAsync(requestInstanceId, stepNo, actedByUserId, reason, signed));
    }

    public Task<ApproveResult?> ReopenClosedAsync(int requestInstanceId, int actedByUserId, string reason)
        => WorkflowSqlErrors.MapAsync(() => _repo.ReopenClosedAsync(requestInstanceId, actedByUserId, reason));

    /*
     * THE TWO REVERSALS. Neither checks a permission and neither re-checks a rule.
     *
     * Who may retract (the last signer, same UTC day, their own signature) and who may reopen (the
     * General Manager and the Owner, together) are decided by the procedures, in the same way and
     * for the same reason as approve and reject: the database is the single authority on who may act
     * on a request, and a second copy of the rule in C# would drift from it.
     *
     * What reaches the user is the procedure's own sentence. Every one of them says which rule was
     * broken AND what to do instead — a next-day retract names the GM + Owner path, a consumed
     * adjustment names the counter-adjustment — so replacing them with a friendlier message would
     * throw away the only part worth reading.
     */

    public Task<ApproveResult?> RetractLastDecisionAsync(int requestInstanceId, int actedByUserId, string reason)
        => WorkflowSqlErrors.MapAsync(() => _repo.RetractLastDecisionAsync(requestInstanceId, actedByUserId, reason));

    public Task<ReopenResult?> ReopenAsync(int requestInstanceId, int actedByUserId, string reason)
        => WorkflowSqlErrors.MapAsync(() => _repo.ReopenAsync(requestInstanceId, actedByUserId, reason));
}
