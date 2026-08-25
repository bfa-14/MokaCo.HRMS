using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Model.Workflow;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Api.Controllers;

/// <summary>
/// Roster approvals — a branch's whole month of roster, put up for signature in one request.
///
/// CREATE ONLY, and deliberately so. This type has no typed decision: approving it changes no
/// figure an approver chose, so it goes through the generic /api/requests/{id}/approve, where
/// workflow.usp_Request_Approve's ApplyApprovalEffects activates the month. Adding a decide here
/// would mean adding ROSTER_APPROVAL to RequestService.TypedDecideOnly, which would make the
/// generic path — the one that actually applies the roster — refuse with a 409.
///
/// Reading and acting on the request itself (chain, notes, reject, hold, cancel) is the generic
/// /api/requests surface, which knows nothing about rosters.
/// </summary>
[ApiController]
[Route("api/workflow/roster-approvals")]
[Authorize]
public class RosterApprovalsController : ControllerBase
{
    private readonly IRosterApprovalService _rosterApprovals;
    private readonly ILiveNotifier _live;

    public RosterApprovalsController(IRosterApprovalService rosterApprovals, ILiveNotifier live)
    {
        _rosterApprovals = rosterApprovals;
        _live = live;
    }

    /// <summary>
    /// Raises one for a branch-month.
    ///
    /// ATTENDANCE_MANAGE, not REQUEST_RAISE_SELF: this is not somebody asking for something of their
    /// own, it is the person who owns the roster declaring a month finished. The employee the
    /// request is filed against, and the user who raised it, both come from the token — the body
    /// carries only WHICH branch-month, never WHO.
    ///
    /// The refusals worth reading are all here rather than at approval: no roster rows for that
    /// branch and month, already approved, already pending. Each is a 400 with the procedure's own
    /// sentence, which names which of the three it is.
    /// </summary>
    [HttpPost]
    [HasPermission("ATTENDANCE_MANAGE")]
    public async Task<IActionResult> Create([FromBody] RosterApprovalCreateRequest request)
    {
        try
        {
            var created = await _rosterApprovals.CreateAsync(request, User.UserId());
            if (created is null)
                return BadRequest(new { error = "The request could not be created." });

            // The roster month moves to Pending, so the roster screens and the request hub are both
            // showing something that has changed.
            await _live.NotifyAsync("workflow", "attendance", "dashboard");
            return Ok(created);
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }
}
