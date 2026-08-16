using Microsoft.AspNetCore.Mvc;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Model.HR;
using MokaCo.HRMS.Model.Workflow;
using MokaCo.HRMS.Services.HR;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Api.Controllers;

[ApiController]
[Route("api/branches")]
public class BranchesController : ControllerBase
{
    private readonly IBranchService _branches;
    private readonly IWorkflowSupportService _workflowSupport;

    private readonly ILiveNotifier _live;

    public BranchesController(
        IBranchService branches, IWorkflowSupportService workflowSupport, ILiveNotifier live)
    {
        _live = live;
        _branches = branches;
        _workflowSupport = workflowSupport;
    }

    [HttpGet]
    [HasPermission("EMP_VIEW")]
    public async Task<IActionResult> GetAll() => Ok(await _branches.GetAllAsync());

    [HttpPost]
    [HasPermission("ORG_MANAGE")]
    public async Task<IActionResult> Create([FromBody] BranchCreateRequest request)
    {
        var id = await _branches.CreateAsync(request.Name);
        await _live.NotifyAsync("hr", "dashboard");
        return CreatedAtAction(nameof(GetAll), new { id }, new { branchId = id });
    }

    [HttpPut("{id:int}")]
    [HasPermission("ORG_MANAGE")]
    public async Task<IActionResult> Update(int id, [FromBody] BranchUpdateRequest request)
    {
        await _branches.UpdateAsync(id, request.Name, request.IsActive);
        await _live.NotifyAsync("hr", "dashboard");
        return NoContent();
    }

    /* ---- branch managers (workflow: the post a 'BranchManager' approval step resolves through) ---- */

    /// <summary>
    /// Branches with their manager and a warning flag when a manager has no login. A vacant post, or a
    /// manager who cannot log in, means every BranchManager approval step for that branch is skipped —
    /// the single most likely reason a chain appears not to work, which is why it is surfaced loudly.
    /// </summary>
    [HttpGet("with-manager")]
    [HasPermission("WORKFLOW_CONFIGURE")]
    public async Task<IActionResult> GetAllWithManager()
        => Ok(await _workflowSupport.GetBranchesWithManagerAsync());

    /// <summary>Assigns (or clears) a branch's manager. Returns a warning sentence when the new manager has no user account.</summary>
    [HttpPut("{id:int}/manager")]
    [HasPermission("WORKFLOW_CONFIGURE")]
    public async Task<IActionResult> SetManager(int id, [FromBody] SetBranchManagerRequest request)
    {
        var result = await _workflowSupport.SetBranchManagerAsync(id, request, User.UserId());
        if (result is null) return NotFound();

        // Branch-manager steps resolve to THIS person. Changing them changes who owes a signature on
        // every request in flight through such a step — and a vacant post makes those steps skip.
        await _live.NotifyAsync("hr", "workflow", "dashboard");
        return Ok(result);
    }
}
