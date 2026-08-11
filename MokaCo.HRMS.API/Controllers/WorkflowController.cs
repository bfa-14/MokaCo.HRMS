using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Model.Workflow;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Api.Controllers;

/// <summary>
/// Approval-chain configuration — the SETUP side of workflow, visited rarely and by one or two
/// people. A chain is DATA: these endpoints read and write WORKFLOW_DEFINITION / WORKFLOW_STEP rows.
/// Publishing a change never touches requests already in flight; those keep the version they locked.
///
/// Everything here needs WORKFLOW_CONFIGURE, except the old-versions/move queue, which is HR's job
/// and needs WORKFLOW_VERSION_MOVE. Approving is NOT here and needs no permission — the database
/// decides who may sign, per step.
/// </summary>
[ApiController]
[Route("api/workflow")]
public class WorkflowController : ControllerBase
{
    private readonly IDefinitionService _definitions;
    private readonly IRequestService _requests;
    private readonly ILiveNotifier _live;

    public WorkflowController(
        IDefinitionService definitions, IRequestService requests, ILiveNotifier live)
    {
        _definitions = definitions;
        _requests = requests;
        _live = live;
    }

    /// <summary>
    /// A reversal moves a request between somebody's inbox and their history, and moves the counts
    /// with it — the same pair of topics every decision on a request signals. Named once so the pair
    /// cannot drift action by action.
    /// </summary>
    private Task NotifyWorkflowAsync() => _live.NotifyAsync("workflow", "dashboard");

    /* ---- request types ---- */

    [HttpGet("request-types")]
    [HasPermission("WORKFLOW_CONFIGURE")]
    public async Task<IActionResult> GetRequestTypes() => Ok(await _definitions.GetRequestTypesAsync());

    /// <summary>
    /// What the signed-in user may actually raise — active types WITH a published chain.
    ///
    /// Deliberately NOT gated on WORKFLOW_CONFIGURE, for the same reason as active/{code}: every
    /// employee raising a request needs to know what kinds exist, and they configure nothing. The
    /// full list, including the types nobody can raise and why, stays behind request-types.
    /// </summary>
    [HttpGet("request-types/raisable")]
    [Authorize]
    public async Task<IActionResult> GetRaisableRequestTypes()
        => Ok(await _definitions.GetRaisableRequestTypesAsync());

    [HttpPost("request-types")]
    [HasPermission("WORKFLOW_CONFIGURE")]
    public async Task<IActionResult> UpsertRequestType([FromBody] RequestTypeUpsertRequest request)
    {
        var requestTypeId = await _definitions.UpsertRequestTypeAsync(request);
        // Deactivating a type removes it from what anybody may raise.
        await NotifyWorkflowAsync();
        return Ok(new { requestTypeId });
    }

    /* ---- starting a draft from an existing chain ---- */

    /// <summary>
    /// Chains a draft can be started from — every version, of every type, that has steps. Retired and
    /// draft versions are included on purpose: the useful precedent is often the one just superseded.
    /// </summary>
    [HttpGet("copy-sources")]
    [HasPermission("WORKFLOW_CONFIGURE")]
    public async Task<IActionResult> GetCopySources()
        => Ok(await _definitions.GetCopySourcesAsync());

    /// <summary>
    /// Copies one chain's steps into a DRAFT — a SNAPSHOT, not a link, so later edits to either
    /// chain leave the other alone.
    ///
    /// The procedure refuses a draft that already has steps and says how many; the builder shows
    /// that verbatim and offers to retry with replaceExisting. Applies-to (tier) is NOT copied — it
    /// belongs to the draft, not to the steps.
    /// </summary>
    [HttpPost("definitions/{id:int}/copy-from")]
    [HasPermission("WORKFLOW_CONFIGURE")]
    public async Task<IActionResult> CopyFrom(int id, [FromBody] DefinitionCopyFromRequest request)
    {
        try
        {
            var result = await _definitions.CopyStepsFromAsync(id, request);
            if (result is null) return NotFound();

            await NotifyWorkflowAsync();
            return Ok(result);
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /* ---- definitions ---- */

    [HttpGet("definitions")]
    [HasPermission("WORKFLOW_CONFIGURE")]
    public async Task<IActionResult> GetDefinitions([FromQuery] int? requestTypeId)
        => Ok(await _definitions.GetDefinitionsAsync(requestTypeId));

    /// <summary>Starts a new DRAFT version. Changing a live chain is always a new draft, never an edit.</summary>
    [HttpPost("definitions")]
    [HasPermission("WORKFLOW_CONFIGURE")]
    public async Task<IActionResult> CreateDraft([FromBody] DefinitionCreateRequest request)
    {
        var created = await _definitions.CreateDraftAsync(request, User.UserId());
        await NotifyWorkflowAsync();
        return Ok(created);
    }

    /// <summary>Adds a step to a DRAFT. The engine refuses this on a published version — that refusal becomes a 400.</summary>
    [HttpPost("definitions/{id:int}/steps")]
    [HasPermission("WORKFLOW_CONFIGURE")]
    public async Task<IActionResult> AddStep(int id, [FromBody] DefinitionAddStepRequest step)
    {
        try
        {
            await _definitions.AddStepAsync(id, step);
            await NotifyWorkflowAsync();
            return NoContent();
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>Publishes a draft: it becomes the Active chain for NEW requests, and the previous Active retires.</summary>
    [HttpPost("definitions/{id:int}/publish")]
    [HasPermission("WORKFLOW_CONFIGURE")]
    public async Task<IActionResult> Publish(int id)
    {
        try
        {
            var result = await _definitions.PublishAsync(id, User.UserId());
            if (result is null) return NotFound();

            // Publishing RETIRES the previous active chain and decides who will sign every request
            // raised from now on — the one chain-config write that changes the running system.
            await NotifyWorkflowAsync();
            return Ok(result);
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    [HttpGet("definitions/{id:int}/steps")]
    [HasPermission("WORKFLOW_CONFIGURE")]
    public async Task<IActionResult> GetSteps(int id) => Ok(await _definitions.GetStepsAsync(id));

    /// <summary>
    /// Deletes a DRAFT definition and its steps — a discard, not history. The procedure REFUSES a
    /// published/retired version (those are the audit trail) and that message is shown verbatim.
    /// </summary>
    [HttpDelete("definitions/{id:int}")]
    [HasPermission("WORKFLOW_CONFIGURE")]
    public async Task<IActionResult> DeleteDraft(int id)
    {
        try
        {
            await _definitions.DeleteDraftAsync(id);
            await NotifyWorkflowAsync();
            return NoContent();
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>
    /// Sets which population a DRAFT chain serves — 2 (management+), 3 (executive only), or null for
    /// the default everyone chain. Draft-only: the procedure refuses a published version, and that
    /// message is shown verbatim because it tells the admin to draft a new version instead.
    /// </summary>
    [HttpPut("definitions/{id:int}/min-tier")]
    [HasPermission("WORKFLOW_CONFIGURE")]
    public async Task<IActionResult> SetMinTier(int id, [FromBody] MinTierRequest request)
    {
        try
        {
            var result = await _definitions.SetMinTierAsync(id, request.MinRequesterTier);
            if (result is null) return NotFound();

            await NotifyWorkflowAsync();
            return Ok(result);
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>
    /// The currently-published chain for a type — what a requester is shown before submitting.
    /// Deliberately NOT gated on WORKFLOW_CONFIGURE: every employee raising a request must be able to
    /// see who will have to sign it, and they do not configure chains. Authenticated is enough.
    /// </summary>
    [HttpGet("active/{requestTypeCode}")]
    [Authorize]
    public async Task<IActionResult> GetActive(string requestTypeCode, [FromQuery] int? employeeId = null)
        => Ok(await _definitions.GetActiveAsync(requestTypeCode, employeeId));

    /* ---- version moves (HR) ---- */

    /// <summary>Pending requests still on a superseded chain — HR's move-version queue.</summary>
    [HttpGet("requests/old-versions")]
    [HasPermission("WORKFLOW_VERSION_MOVE")]
    public async Task<IActionResult> GetOnOldVersions([FromQuery] int? requestTypeId)
        => Ok(await _requests.GetOnOldVersionsAsync(requestTypeId));

    /// <summary>Requests stuck on hold too long — the setup side's stuck-requests queue, gated like the rest of chain config.</summary>
    [HttpGet("long-holds")]
    [HasPermission("WORKFLOW_CONFIGURE")]
    public async Task<IActionResult> GetLongHolds([FromQuery] int olderThanDays = 7)
        => Ok(await _requests.GetLongHoldsAsync(olderThanDays));

    /* ---- reversals: taking a decision back ----
       Both need NO permission, exactly like approve and reject. The database decides who may act —
       the last signer on the same UTC day for a retract, the General Manager and the Owner together
       for a reopen — and refuses everybody else with a sentence that names the path that would
       work. Those sentences reach the client untouched. */

    /// <summary>
    /// The last signer takes their own decision back, on the same UTC day.
    ///
    /// The rules are the procedure's and are NOT duplicated here: it must be your own signature, it
    /// must be the last one standing, it must be from today, and the request's effects must not have
    /// been consumed yet. A next-day attempt is refused with the GM + Owner route named; an
    /// adjustment already swallowed by a locked payslip is refused with the counter-adjustment named.
    ///
    /// Whether the effects are consumed is deliberately NOT pre-checked to hide the button either —
    /// the refusal explains what to do instead, and no disabled control could say that much.
    ///
    /// The password is OPTIONAL on the wire: whether this particular retract must be signed depends on
    /// what is being struck, which the service works out. Sending none where one is demanded is a 401
    /// that changes nothing.
    /// </summary>
    [HttpPost("requests/{id:int}/retract")]
    [Authorize]
    public async Task<IActionResult> Retract(int id, [FromBody] ReasonRequest request)
    {
        if (string.IsNullOrWhiteSpace(request?.Reason))
            return BadRequest(new { error = "A reason is required to retract a decision." });

        try
        {
            var result = await _requests.RetractLastDecisionAsync(id, User.UserId(), request.Reason.Trim(), request.Password);
            if (result is null) return NotFound();

            // The struck signature puts the request back in somebody's inbox and moves the counts
            // with it — the same pair of topics every other decision on a request signals.
            await NotifyWorkflowAsync();
            return Ok(result);
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>
    /// Reopens a closed request — the General Manager AND the Owner, in either order.
    ///
    /// TWO OUTCOMES, and the caller must handle both. The first of the two to sign gets
    /// State 'AwaitingSecond' and NOTHING HAS MOVED: the request is still closed, waiting on the
    /// other role. The second gets State 'Reopened' with the request's new standing. Reporting the
    /// first as though it were the second is the mistake this shape exists to prevent.
    ///
    /// The reason is required on the first signature; the second inherits it, which is why an empty
    /// reason is not rejected here — the procedure knows which half this is and asks only when it
    /// needs to.
    /// </summary>
    [HttpPost("requests/{id:int}/reopen")]
    [Authorize]
    public async Task<IActionResult> Reopen(int id, [FromBody] ReasonRequest? request)
    {
        try
        {
            var result = await _requests.ReopenAsync(id, User.UserId(), request?.Reason?.Trim() ?? string.Empty);
            if (result is null) return NotFound();

            // Signalled on BOTH outcomes. A half-signed reopen changes nothing about the request,
            // but it does change what the other of GM/Owner sees when they open it — the banner
            // saying it is waiting on them is the whole point of telling them.
            await NotifyWorkflowAsync();
            return Ok(result);
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }
}
