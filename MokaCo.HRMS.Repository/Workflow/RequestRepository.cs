using System.Data;
using Dapper;
using MokaCo.HRMS.Model.Workflow;
using MokaCo.HRMS.Repository.Common;

namespace MokaCo.HRMS.Repository.Workflow;

/// <summary>
/// Dapper access for request instances via workflow.usp_Request_*.
///
/// The approve/reject/cancel procedures decide FOR THEMSELVES whether the caller may act, and raise
/// a SQL error otherwise — this repository does not re-check that, and must not. It passes the
/// caller's id through and lets the database be the authority; the service turns any resulting SQL
/// error into a clean HTTP response.
/// </summary>
public class RequestRepository : IRequestRepository
{
    private readonly IDbConnectionFactory _factory;
    public RequestRepository(IDbConnectionFactory factory) => _factory = factory;

    /// <summary>
    /// Reads all FOUR result sets: the header, the materialised chain, the append-only history, and
    /// any reversals. Reading only the first would give a request with no chain; stopping at the
    /// third would drop the record of what struck a signature in that history. All four are the
    /// record.
    /// </summary>
    public async Task<RequestDetail?> GetByIdAsync(int requestInstanceId)
    {
        using var db = _factory.Create();
        using var multi = await db.QueryMultipleAsync(
            "workflow.usp_Request_GetById",
            new { RequestInstanceId = requestInstanceId },
            commandType: CommandType.StoredProcedure);

        var header = await multi.ReadSingleOrDefaultAsync<RequestHeader>();
        if (header is null)
            return null;

        var steps = (await multi.ReadAsync<RequestStep>()).ToList();
        var history = (await multi.ReadAsync<SignatureLogEntry>()).ToList();
        var reversals = (await multi.ReadAsync<RequestReversal>()).ToList();

        return new RequestDetail
        {
            Header = header,
            Steps = steps,
            History = history,
            Reversals = reversals,
        };
    }

    /// <summary>The chain on its own, read FOR a user so each step's CanWithdraw reflects what that user may take back.</summary>
    public async Task<IEnumerable<RequestStep>> GetStepsAsync(int requestInstanceId, int forUserId)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<RequestStep>(
            "workflow.usp_Request_GetSteps",
            new { RequestInstanceId = requestInstanceId, ForUserId = forUserId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<MyRequest>> GetForEmployeeAsync(int employeeId, string? status)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<MyRequest>(
            "workflow.usp_Request_GetForEmployee",
            new { EmployeeId = employeeId, Status = status },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>Everything waiting on this user — whether as the named approver or as a holder of the step's role.</summary>
    public async Task<IEnumerable<InboxItem>> GetPendingForUserAsync(int userId)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<InboxItem>(
            "workflow.usp_Request_GetPendingForUser",
            new { UserId = userId },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>
    /// Everything the user is connected to, with the involvement flags. The procedure already scopes
    /// to the user, so there is no separate visibility check — a row comes back only because the
    /// caller is party to it.
    /// </summary>
    public async Task<IEnumerable<ForUserRequest>> GetForUserAsync(int userId, string? status, bool includeClosed, int? requestTypeId, DateTime? fromDate, DateTime? toDate)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<ForUserRequest>(
            "workflow.usp_Request_GetForUser",
            new
            {
                UserId = userId,
                Status = status,
                IncludeClosed = includeClosed,
                RequestTypeId = requestTypeId,
                FromDate = fromDate,
                ToDate = toDate,
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<RequestCounts> GetCountsForUserAsync(int userId)
    {
        using var db = _factory.Create();
        return await db.QuerySingleAsync<RequestCounts>(
            "workflow.usp_Request_GetCountsForUser",
            new { UserId = userId },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>
    /// What this user may do at the current step. Returning NOTHING is the procedure's way of saying
    /// "not yours to decide" — it is passed straight through as an empty list, never turned into an
    /// error, because the caller renders a read-only chain from it.
    /// </summary>
    public async Task<IEnumerable<DecisionOption>> GetAvailableDecisionsAsync(int requestInstanceId, int userId)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<DecisionOption>(
            "workflow.usp_Step_GetAvailableDecisions",
            new { RequestInstanceId = requestInstanceId, UserId = userId },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>Whether this user must sign the current step, and the wording to show. Null when the request has no live step.</summary>
    public async Task<SignatureRequirement?> GetSignatureRequirementAsync(int requestInstanceId, int userId)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<SignatureRequirement>(
            "workflow.usp_Step_GetSignatureRequirement",
            new { RequestInstanceId = requestInstanceId, UserId = userId },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>The caller's OWN draft, or null. The procedure scopes it to them — a colleague's draft never surfaces.</summary>
    public async Task<DraftDecision?> GetDraftDecisionAsync(int requestInstanceId, int forUserId)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<DraftDecision>(
            "workflow.usp_Step_GetDraftDecision",
            new { RequestInstanceId = requestInstanceId, ForUserId = forUserId },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>
    /// Saves an unsigned decision. Nothing is validated here or in the procedure — the requirement
    /// flags apply when it is SIGNED, and a draft exists precisely so a half-formed one can be kept.
    /// Value is NVARCHAR(200) in the procedure: the figure is stored as text and typed on the way out.
    /// </summary>
    public async Task SaveDraftDecisionAsync(int requestInstanceId, int actedByUserId, string decisionCode, string? comment, int? value, int? targetUserId, bool waitingOnRequester)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "workflow.usp_Step_SaveDraftDecision",
            new
            {
                RequestInstanceId = requestInstanceId,
                ActedByUserId = actedByUserId,
                DecisionCode = decisionCode,
                Comment = comment,
                Value = value?.ToString(),
                TargetUserId = targetUserId,
                WaitingOnRequester = waitingOnRequester,
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task DiscardDraftDecisionAsync(int requestInstanceId, int actedByUserId)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "workflow.usp_Step_DiscardDraftDecision",
            new { RequestInstanceId = requestInstanceId, ActedByUserId = actedByUserId },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>Hands the step to someone else. The procedure decides whether the caller may, and raises otherwise.</summary>
    public async Task DelegateAsync(int requestInstanceId, int actedByUserId, int toUserId, string reason)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "workflow.usp_Request_Delegate",
            new { RequestInstanceId = requestInstanceId, ActedByUserId = actedByUserId, ToUserId = toUserId, Reason = reason },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>Takes a delegated step back. Nothing was signed, so this asks for no password.</summary>
    public async Task ReclaimDelegationAsync(int requestInstanceId, int actedByUserId, string? reason)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "workflow.usp_Request_ReclaimDelegation",
            new { RequestInstanceId = requestInstanceId, ActedByUserId = actedByUserId, Reason = reason },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<ApproveResult?> ApproveAsync(int requestInstanceId, int actedByUserId, string? comment, string? changeSummary = null, bool signedWithPassword = false)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<ApproveResult>(
            "workflow.usp_Request_Approve",
            new
            {
                RequestInstanceId = requestInstanceId,
                ActedByUserId = actedByUserId,
                Comment = comment,
                ChangeSummary = changeSummary,
                SignedWithPassword = signedWithPassword,
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<RequestClosedResult?> RejectAsync(int requestInstanceId, int actedByUserId, string reason, bool signedWithPassword = false)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<RequestClosedResult>(
            "workflow.usp_Request_Reject",
            new
            {
                RequestInstanceId = requestInstanceId,
                ActedByUserId = actedByUserId,
                Reason = reason,
                SignedWithPassword = signedWithPassword,
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<RequestClosedResult?> CancelAsync(int requestInstanceId, int actedByUserId, string reason)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<RequestClosedResult>(
            "workflow.usp_Request_Cancel",
            new { RequestInstanceId = requestInstanceId, ActedByUserId = actedByUserId, Reason = reason },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>Parks the request on hold. The procedure is the authority — it raises if the reason is blank or the caller is not the approver.</summary>
    public async Task PutOnHoldAsync(int requestInstanceId, int actedByUserId, string reason, bool waitingOnRequester)
    {
        using var db = _factory.Create();
        await db.ExecuteAsync(
            "workflow.usp_Request_PutOnHold",
            new
            {
                RequestInstanceId = requestInstanceId,
                ActedByUserId = actedByUserId,
                Reason = reason,
                WaitingOnRequester = waitingOnRequester,
            },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>
    /// Lifts the hold — the step returns to Pending with the same approver. The procedure decides who
    /// may: the approver who set it OR the requester, because when a hold is waiting on the employee,
    /// answering it IS the resume and should not also require chasing the approver.
    /// </summary>
    public async Task<ApproveResult?> ResumeAsync(int requestInstanceId, int actedByUserId, string? note)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<ApproveResult>(
            "workflow.usp_Request_Resume",
            new { RequestInstanceId = requestInstanceId, ActedByUserId = actedByUserId, Note = note },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>The request's conversation, oldest first.</summary>
    public async Task<IEnumerable<RequestNote>> GetNotesAsync(int requestInstanceId)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<RequestNote>(
            "workflow.usp_RequestNote_GetForRequest",
            new { RequestInstanceId = requestInstanceId },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>Adds a note; the procedure SELECTs the new NoteId back as a scalar.</summary>
    public async Task<int> AddNoteAsync(int requestInstanceId, int authorUserId, string noteText, int? stepNo, bool isHoldResponse)
    {
        using var db = _factory.Create();
        return await db.ExecuteScalarAsync<int>(
            "workflow.usp_RequestNote_Add",
            new
            {
                RequestInstanceId = requestInstanceId,
                AuthorUserId = authorUserId,
                NoteText = noteText,
                StepNo = stepNo,
                IsHoldResponse = isHoldResponse,
            },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>Requests stuck on hold longer than the given number of days — HR's stuck-requests queue.</summary>
    public async Task<IEnumerable<LongHold>> GetLongHoldsAsync(int olderThanDays)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<LongHold>(
            "workflow.usp_Request_GetLongHolds",
            new { OlderThanDays = olderThanDays },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<OldVersionRequest>> GetOnOldVersionsAsync(int? requestTypeId)
    {
        using var db = _factory.Create();
        return await db.QueryAsync<OldVersionRequest>(
            "workflow.usp_Request_GetOnOldVersions",
            new { RequestTypeId = requestTypeId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<MoveVersionResult?> MoveToVersionAsync(int requestInstanceId, int? targetWorkflowDefinitionId, int actedByUserId, string reason)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<MoveVersionResult>(
            "workflow.usp_Request_MoveToVersion",
            new
            {
                RequestInstanceId = requestInstanceId,
                TargetWorkflowDefinitionId = targetWorkflowDefinitionId,
                ActedByUserId = actedByUserId,
                Reason = reason,
            },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>Reads the FROZEN image from the signature log — the copy taken at signing, not the signer's current image.</summary>
    public async Task<FrozenSignatureImage?> GetSignatureImageAsync(int requestInstanceId, int stepNo)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<FrozenSignatureImage>(
            "workflow.usp_Request_GetSignatureImage",
            new { RequestInstanceId = requestInstanceId, StepNo = stepNo },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>
    /// One frozen image by its signature-log id (usp_Signature_GetFrozenImage) — the row the step
    /// list already named via SignedSignatureId. Fetched ONE AT A TIME so the bytes never travel in
    /// the step list. Null when the id has no image.
    /// </summary>
    public async Task<FrozenSignatureImage?> GetFrozenImageByIdAsync(int signatureId)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<FrozenSignatureImage>(
            "workflow.usp_Signature_GetFrozenImage",
            new { SignatureId = signatureId },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>
    /// The TYPED withdraw for an exit permission — restores the figure and unsigns the step in one
    /// transaction. The proc raises if the caller may not withdraw or someone acted after them; it
    /// SELECTs the restored figure and the request's new standing back.
    /// </summary>
    public async Task<WithdrawDecisionResult?> WithdrawExitPermissionDecisionAsync(int requestInstanceId, int stepNo, int actedByUserId, string reason, bool signedWithPassword = false)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<WithdrawDecisionResult>(
            "workflow.usp_ExitPermission_WithdrawDecision",
            new
            {
                RequestInstanceId = requestInstanceId,
                StepNo = stepNo,
                ActedByUserId = actedByUserId,
                Reason = reason,
                SignedWithPassword = signedWithPassword,
            },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>Reopens a rejected/cancelled request; the proc SELECTs the request's new status and current step back.</summary>
    public async Task<ApproveResult?> ReopenClosedAsync(int requestInstanceId, int actedByUserId, string reason)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<ApproveResult>(
            "workflow.usp_Request_ReopenClosed",
            new { RequestInstanceId = requestInstanceId, ActedByUserId = actedByUserId, Reason = reason },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>
    /// The last signer takes their OWN decision back, same UTC day. Every rule about who and when is
    /// the procedure's — its own signature, the last one standing, the same day, and the request's
    /// effects not yet consumed — and each refusal names which of those failed. It SELECTs the
    /// request's new standing back.
    /// </summary>
    public async Task<ApproveResult?> RetractLastDecisionAsync(int requestInstanceId, int actedByUserId, string reason)
    {
        using var db = _factory.Create();
        return await db.QuerySingleOrDefaultAsync<ApproveResult>(
            "workflow.usp_Request_RetractLastDecision",
            new { RequestInstanceId = requestInstanceId, ActedByUserId = actedByUserId, Reason = reason },
            commandType: CommandType.StoredProcedure);
    }

    /// <summary>
    /// One half of a GM + Owner reopen.
    ///
    /// THE PROCEDURE RETURNS TWO DIFFERENT SHAPES and the caller must not assume either: the first
    /// role to sign gets back { State, FirstSignRole } and nothing has moved; the second gets back
    /// { RequestInstanceId, Status, CurrentStepNo } because the request is now open again. They are
    /// read into one row here and told apart by which columns arrived — Dapper leaves the absent
    /// ones at their defaults, so State is the discriminator and it is set explicitly for the
    /// completing call, which the procedure does not name.
    /// </summary>
    public async Task<ReopenResult?> ReopenAsync(int requestInstanceId, int actedByUserId, string reason)
    {
        using var db = _factory.Create();
        var row = await db.QuerySingleOrDefaultAsync<ReopenResult>(
            "workflow.usp_Request_Reopen",
            new { RequestInstanceId = requestInstanceId, ActedByUserId = actedByUserId, Reason = reason },
            commandType: CommandType.StoredProcedure);

        if (row is null)
            return null;

        // The completing call's result set has no State column, so Dapper leaves it empty. Naming it
        // here keeps the discriminator meaningful for every caller above this line.
        if (string.IsNullOrEmpty(row.State))
            row.State = "Reopened";

        return row;
    }
}
