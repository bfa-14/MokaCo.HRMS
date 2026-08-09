using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Model.Workflow;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Api.Controllers;

/// <summary>
/// Requests — the OPERATIONS side everyone lives in: my requests, my inbox, and acting on a request.
///
/// Approving and rejecting need NO permission. Any authenticated user may attempt them; the database
/// decides — per step — whether the caller is the resolved approver or holds the step's role, and
/// refuses otherwise. That refusal is surfaced as a clean 403, message intact. It is never
/// re-checked in C#.
/// </summary>
[ApiController]
[Route("api/requests")]
[Authorize]
public class RequestsController : ControllerBase
{
    private readonly IRequestService _requests;
    private readonly IWorkflowSupportService _support;

    public RequestsController(IRequestService requests, IWorkflowSupportService support)
    {
        _requests = requests;
        _support = support;
    }

    /// <summary>
    /// One request in full. Visible only to someone who holds REQUEST_VIEW_ALL, or whose request it
    /// is, or who raised it, or who is an approver on one of its steps — the service enforces that and
    /// a breach comes back here as a 403.
    /// </summary>
    [HttpGet("{id:int}")]
    public async Task<IActionResult> GetById(int id)
    {
        var caller = new RequestCaller(
            User.UserId(),
            await ResolveEmployeeIdAsync(),
            User.HasPermission("REQUEST_VIEW_ALL"));

        try
        {
            var detail = await _requests.GetByIdAsync(id, caller);
            return detail is null ? NotFound() : Ok(detail);
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>
    /// One request's chain, read FOR the caller so each step says whether THEY may still withdraw it.
    /// Behind the same visibility rule as the request detail — a breach comes back as a 403.
    /// </summary>
    [HttpGet("{id:int}/steps")]
    public async Task<IActionResult> GetSteps(int id)
    {
        var caller = new RequestCaller(
            User.UserId(),
            await ResolveEmployeeIdAsync(),
            User.HasPermission("REQUEST_VIEW_ALL"));

        try
        {
            return Ok(await _requests.GetStepsAsync(id, caller));
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>Everything I have raised. Empty for an account with no employee record — that is not an error.</summary>
    [HttpGet("mine")]
    public async Task<IActionResult> Mine([FromQuery] string? status)
    {
        var employeeId = await ResolveEmployeeIdAsync();
        if (employeeId is null)
            return Ok(Array.Empty<MyRequest>());

        return Ok(await _requests.GetForEmployeeAsync(employeeId.Value, status));
    }

    /// <summary>Everything waiting on ME — as the named approver or a holder of the step's role.</summary>
    [HttpGet("inbox")]
    public async Task<IActionResult> Inbox() => Ok(await _requests.GetInboxAsync(User.UserId()));

    /// <summary>
    /// Everything the signed-in user is connected to, in ANY capacity — waiting on them, raised for
    /// them, raised by them, or signed by them at some point. One call feeds the whole hub; the
    /// client slices it into tabs. Closed requests are excluded unless includeClosed is true.
    /// </summary>
    [HttpGet("for-me")]
    public async Task<IActionResult> ForMe(
        [FromQuery] string? status = null,
        [FromQuery] bool includeClosed = false,
        [FromQuery] int? requestTypeId = null,
        [FromQuery] DateTime? from = null,
        [FromQuery] DateTime? to = null)
        => Ok(await _requests.GetForUserAsync(User.UserId(), status, includeClosed, requestTypeId, from, to));

    /// <summary>The hub's tab-badge counts, in one round trip.</summary>
    [HttpGet("counts")]
    public async Task<IActionResult> Counts() => Ok(await _requests.GetCountsForUserAsync(User.UserId()));

    /// <summary>
    /// THE DECISION CONTROL. What this caller may do at the current step, straight from
    /// usp_Step_GetAvailableDecisions — the catalogue, narrowed by the step's configuration and by
    /// whether the caller may act at all.
    ///
    /// AN EMPTY ARRAY IS THE NORMAL "NOT YOUR STEP" ANSWER, returned as 200 with []. It is not a 403
    /// and not a 404: the caller may well be entitled to SEE the request (their own, or a step they
    /// signed earlier) while having nothing to decide on it right now. The client renders the chain
    /// read-only and shows no button.
    /// </summary>
    [HttpGet("{id:int}/decisions")]
    public async Task<IActionResult> Decisions(int id)
    {
        var caller = new RequestCaller(
            User.UserId(),
            await ResolveEmployeeIdAsync(),
            User.HasPermission("REQUEST_VIEW_ALL"));

        try
        {
            return Ok(await _requests.GetAvailableDecisionsAsync(id, caller));
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>
    /// Whether this caller must password-sign their decision here, with the database's own wording for
    /// why. Read WITH the page rather than when the dialog opens, so the password field is visible from
    /// the start and nobody is ambushed by it at the moment they commit.
    /// </summary>
    [HttpGet("{id:int}/signature-requirement")]
    public async Task<IActionResult> SignatureRequirement(int id)
    {
        var caller = new RequestCaller(
            User.UserId(),
            await ResolveEmployeeIdAsync(),
            User.HasPermission("REQUEST_VIEW_ALL"));

        try
        {
            var requirement = await _requests.GetSignatureRequirementAsync(id, caller);
            return requirement is null ? NoContent() : Ok(requirement);
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>The caller's OWN unsigned draft here. 204 means "no draft of mine" — never an error.</summary>
    [HttpGet("{id:int}/draft")]
    public async Task<IActionResult> GetDraft(int id)
    {
        var caller = new RequestCaller(
            User.UserId(),
            await ResolveEmployeeIdAsync(),
            User.HasPermission("REQUEST_VIEW_ALL"));

        try
        {
            var draft = await _requests.GetDraftAsync(id, caller);
            return draft is null ? NoContent() : Ok(draft);
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>
    /// Saves a decision WITHOUT signing it. Deliberately validates nothing beyond the decision code —
    /// a draft exists so a half-formed judgement survives leaving the page, and requiring it to be
    /// complete would defeat the point.
    /// </summary>
    [HttpPost("{id:int}/draft")]
    public async Task<IActionResult> SaveDraft(int id, [FromBody] SaveDraftRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.DecisionCode))
            return BadRequest(new { error = "Choose a decision before saving." });

        try
        {
            await _requests.SaveDraftAsync(id, User.UserId(), request);
            return NoContent();
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    [HttpDelete("{id:int}/draft")]
    public async Task<IActionResult> DiscardDraft(int id)
    {
        try
        {
            await _requests.DiscardDraftAsync(id, User.UserId());
            return NoContent();
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>Hands the current step to a named person. They decide instead; the request does not advance.</summary>
    [HttpPost("{id:int}/delegate")]
    public async Task<IActionResult> Delegate(int id, [FromBody] DelegateRequest request)
    {
        if (request.ToUserId <= 0)
            return BadRequest(new { error = "Choose who to hand this step to." });
        if (string.IsNullOrWhiteSpace(request.Reason))
            return BadRequest(new { error = "Say why you are handing this over." });

        try
        {
            await _requests.DelegateAsync(id, User.UserId(), request.ToUserId, request.Reason.Trim());
            return NoContent();
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>
    /// Takes a delegated step back — for whoever handed it over, while the delegate has not decided.
    /// NOT a withdrawal: nothing was signed, so this asks for no password. The reason is optional.
    /// </summary>
    [HttpPost("{id:int}/reclaim")]
    public async Task<IActionResult> Reclaim(int id, [FromBody] ReasonRequest? request)
    {
        try
        {
            await _requests.ReclaimAsync(id, User.UserId(), string.IsNullOrWhiteSpace(request?.Reason) ? null : request!.Reason.Trim());
            return NoContent();
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>
    /// Approve. Where the step or the caller's role demands a signature, the password is verified
    /// BEFORE anything is written — a wrong one is a 401 that changes nothing, so the client can keep
    /// the dialog open with every other field intact.
    /// </summary>
    [HttpPost("{id:int}/approve")]
    public async Task<IActionResult> Approve(int id, [FromBody] ApproveRequest? request)
    {
        try
        {
            var result = await _requests.ApproveAsync(id, User.UserId(), request?.Comment, request?.ChangeSummary, request?.Password);
            return result is null ? NotFound() : Ok(result);
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>
    /// Parks a live request on hold while the approver waits for something. Needs no permission — any
    /// authenticated approver may hold, the same as approve/reject; the database decides whether the
    /// caller is the resolved approver and refuses otherwise. The reason is required.
    /// </summary>
    [HttpPost("{id:int}/hold")]
    public async Task<IActionResult> Hold(int id, [FromBody] PutOnHoldRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.Reason))
            return BadRequest(new { error = "Say what you are waiting for." });

        try
        {
            await _requests.PutOnHoldAsync(id, User.UserId(), request.Reason.Trim(), request.WaitingOnRequester, request.Password);
            return NoContent();
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>The request's conversation, oldest first. Visible to anyone who may see the request.</summary>
    [HttpGet("{id:int}/notes")]
    public async Task<IActionResult> GetNotes(int id) => Ok(await _requests.GetNotesAsync(id));

    /// <summary>Adds a note to the conversation. The text is required — the database refuses an empty one.</summary>
    [HttpPost("{id:int}/notes")]
    public async Task<IActionResult> AddNote(int id, [FromBody] AddNoteRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.NoteText))
            return BadRequest(new { error = "A note cannot be empty." });

        try
        {
            var noteId = await _requests.AddNoteAsync(id, User.UserId(), request.NoteText.Trim(), request.StepNo, request.IsHoldResponse);
            return Ok(new { noteId });
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>Rejecting ends the whole chain, so the reason is required — the DB enforces it, and so does this.</summary>
    [HttpPost("{id:int}/reject")]
    public async Task<IActionResult> Reject(int id, [FromBody] ReasonRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.Reason))
            return BadRequest(new { error = "A rejection reason is required." });

        try
        {
            var result = await _requests.RejectAsync(id, User.UserId(), request.Reason.Trim(), request.Password);
            return result is null ? NotFound() : Ok(result);
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    [HttpPost("{id:int}/cancel")]
    public async Task<IActionResult> Cancel(int id, [FromBody] ReasonRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.Reason))
            return BadRequest(new { error = "A cancellation reason is required." });

        try
        {
            var result = await _requests.CancelAsync(id, User.UserId(), request.Reason.Trim());
            return result is null ? NotFound() : Ok(result);
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>
    /// Takes back a decision the caller made on a step, while the request is still open and nobody has
    /// acted after them. Needs NO permission — the database decides whether this caller may withdraw,
    /// the same as approve/reject; its refusal comes back as a clean status, message intact. The reason
    /// is required. Only exit permissions support withdrawal today; the routing to the typed procedure
    /// lives here, never in the engine.
    /// </summary>
    [HttpPost("{id:int}/steps/{stepNo:int}/withdraw")]
    public async Task<IActionResult> Withdraw(int id, int stepNo, [FromBody] ReasonRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.Reason))
            return BadRequest(new { error = "A reason is required to withdraw a decision." });

        var caller = new RequestCaller(
            User.UserId(),
            await ResolveEmployeeIdAsync(),
            User.HasPermission("REQUEST_VIEW_ALL"));

        try
        {
            var detail = await _requests.GetByIdAsync(id, caller);
            if (detail is null)
                return NotFound();

            if (detail.Header.RequestTypeCode != "EXIT_PERMISSION")
                return BadRequest(new { error = "Withdrawing is not supported for this request type yet." });

            var result = await _requests.WithdrawExitPermissionDecisionAsync(id, stepNo, User.UserId(), request.Reason.Trim(), request.Password);
            return Ok(result);
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>
    /// Reopens a rejected or cancelled request, returning it to the step that closed it. HR only — it
    /// puts a closed request back in flight, so it needs WORKFLOW_VERSION_MOVE and a mandatory reason.
    /// The database refuses an approved request (its effect is already applied) and surfaces that
    /// verbatim.
    /// </summary>
    [HttpPost("{id:int}/reopen")]
    [HasPermission("WORKFLOW_VERSION_MOVE")]
    public async Task<IActionResult> Reopen(int id, [FromBody] ReasonRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.Reason))
            return BadRequest(new { error = "A reason is required to reopen a closed request." });

        try
        {
            await _requests.ReopenClosedAsync(id, User.UserId(), request.Reason.Trim());
            return NoContent();
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>
    /// Moves one live request onto the active chain version. HR only — this rewrites who must sign a
    /// request already in flight, so it needs WORKFLOW_VERSION_MOVE and a mandatory reason.
    /// </summary>
    [HttpPost("{id:int}/move-version")]
    [HasPermission("WORKFLOW_VERSION_MOVE")]
    public async Task<IActionResult> MoveVersion(int id, [FromBody] MoveVersionRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.Reason))
            return BadRequest(new { error = "A reason is required to move a request to another chain version." });

        try
        {
            var result = await _requests.MoveToVersionAsync(id, request, User.UserId());
            return result is null ? NotFound() : Ok(result);
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>
    /// Streams the FROZEN signature image for a signed step — the copy taken at signing, not the
    /// signer's current image, so a printed approval never restyles itself. Behind the same
    /// visibility rule as the request. The image is a convention; the name and timestamp beside it
    /// are the actual record, so the UI must never show it alone.
    /// </summary>
    [HttpGet("{id:int}/steps/{stepNo:int}/signature/image")]
    public async Task<IActionResult> StepSignatureImage(int id, int stepNo)
    {
        var caller = new RequestCaller(
            User.UserId(),
            await ResolveEmployeeIdAsync(),
            User.HasPermission("REQUEST_VIEW_ALL"));

        try
        {
            var image = await _requests.GetSignatureImageAsync(id, stepNo, caller);
            if (image?.SignatureImage is null || image.SignatureContentType is null)
                return NotFound();

            Response.Headers.CacheControl = "private, max-age=86400";
            return File(image.SignatureImage, image.SignatureContentType);
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>The caller's employee id, or null for an account not linked to an employee.</summary>
    private async Task<int?> ResolveEmployeeIdAsync()
    {
        var me = await _support.GetEmployeeByUserIdAsync(User.UserId());
        return me?.EmployeeId;
    }
}
