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

    public WorkflowController(IDefinitionService definitions, IRequestService requests)
    {
        _definitions = definitions;
        _requests = requests;
    }

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
        => Ok(new { requestTypeId = await _definitions.UpsertRequestTypeAsync(request) });

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
            return result is null ? NotFound() : Ok(result);
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
        => Ok(await _definitions.CreateDraftAsync(request, User.UserId()));

    /// <summary>Adds a step to a DRAFT. The engine refuses this on a published version — that refusal becomes a 400.</summary>
    [HttpPost("definitions/{id:int}/steps")]
    [HasPermission("WORKFLOW_CONFIGURE")]
    public async Task<IActionResult> AddStep(int id, [FromBody] DefinitionAddStepRequest step)
    {
        try
        {
            await _definitions.AddStepAsync(id, step);
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
            return result is null ? NotFound() : Ok(result);
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
            return result is null ? NotFound() : Ok(result);
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
}
