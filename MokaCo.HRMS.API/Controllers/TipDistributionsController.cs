using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Model.Workflow;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Api.Controllers;

/// <summary>
/// Tip distributions — a shift's tips split between the people who worked it.
///
/// Reading and acting on the request itself (chain, notes, reject, hold, cancel, delegate) stays on
/// /api/requests: the engine knows nothing about tips. Only the typed payload and the typed
/// approval are here, and the typed approval exists because approving is what FINALIZES the lines.
/// </summary>
[ApiController]
[Route("api/tip-distributions")]
[Authorize]
public class TipDistributionsController : ControllerBase
{
    private readonly ITipDistributionService _tips;
    private readonly ILiveNotifier _live;

    public TipDistributionsController(ITipDistributionService tips, ILiveNotifier live)
    {
        _tips = tips;
        _live = live;
    }

    /// <summary>
    /// Raises one. REQUEST_RAISE_SELF is the floor — anyone who may raise anything holds it. There
    /// is no raise-for-others rule to enforce: the procedure takes the requester from the token, and
    /// the participants are a list it validates against the branch itself.
    /// </summary>
    [HttpPost]
    [HasPermission("REQUEST_RAISE_SELF")]
    public async Task<IActionResult> Create([FromBody] TipDistributionCreateRequest request)
    {
        try
        {
            var created = await _tips.CreateAsync(request, User.UserId());
            if (created is null) return BadRequest(new { error = "The request could not be created." });

            await _live.NotifyAsync("workflow", "dashboard");
            return Ok(created);
        }
        catch (WorkflowException ex)
        {
            // Verbatim: "Not active employees of this branch: 12, 15." names the ids to remove.
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>
    /// THE TYPED APPROVAL. Goes through here rather than the generic /approve because closing this
    /// request Approved stamps FinalizedAt on the distribution, which is what makes the lines
    /// payroll's to consume. Approving through the engine alone would approve a request that never
    /// finalized.
    ///
    /// The approver may also RESTATE THE SPLIT: `linesJson` is a full replacement set, or null to
    /// approve the split as calculated. The procedure refuses one that does not account for every
    /// pooled unit — naming the currency, the shortfall and the pool — and rewrites the lines only
    /// after the engine has accepted the decision, so a refusal never half-applies.
    ///
    /// Needs no permission: the database decides whether this caller is the approver at the current
    /// step and whether that step may adjust anything, and its refusal is surfaced with the message
    /// intact.
    /// </summary>
    [HttpPost("{id:int}/decide")]
    public async Task<IActionResult> Decide(int id, [FromBody] TipDecideRequest request)
    {
        try
        {
            var result = await _tips.DecideAsync(id, User.UserId(), request);
            if (result is null) return NotFound();

            // FINALIZE is what makes the lines payroll's to consume, so "payroll" belongs here as
            // much as "workflow" — the run that will pay these tips is now out of date.
            await _live.NotifyAsync("workflow", "payroll", "dashboard");
            return Ok(result);
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>The header and the per-person lines, as two halves of one payload. 404 when the request is not a tip one.</summary>
    [HttpGet("{id:int}/payload")]
    public async Task<IActionResult> GetPayload(int id)
    {
        var payload = await _tips.GetPayloadAsync(id);
        return payload.Header is null ? NotFound() : Ok(payload);
    }
}

/// <summary>
/// Shift swaps — two people in the same role exchange a rostered day.
/// </summary>
/// [LiveTopics] IS EASY TO LOSE ON A SECOND CLASS IN A SHARED FILE, and this one was: the attribute
/// on TipDistributionsController above sits at the top of the file and reads, at a glance, as
/// though it covers everything in it. It does not — the attribute is per class — so every swap
/// raised or decided here was silent, and a swap waiting on somebody never appeared on their hub
/// until they reloaded. A swap also moves the ROSTER once it is approved, which is why attendance
/// is signalled alongside workflow.
[ApiController]
[Route("api/shift-swaps")]
[Authorize]
public class ShiftSwapsController : ControllerBase
{
    private readonly IShiftSwapService _swaps;
    private readonly ILiveNotifier _live;

    public ShiftSwapsController(IShiftSwapService swaps, ILiveNotifier live)
    {
        _swaps = swaps;
        _live = live;
    }

    /// <summary>
    /// Raises one. Every rule is the procedure's — the consent tick, the same-role requirement,
    /// future dates, both people actually being rostered, and no open swap already touching either
    /// shift. Each refusal comes back with its own sentence, which is the one worth reading.
    /// </summary>
    [HttpPost]
    [HasPermission("REQUEST_RAISE_SELF")]
    public async Task<IActionResult> Create([FromBody] ShiftSwapCreateRequest request)
    {
        try
        {
            var created = await _swaps.CreateAsync(request, User.UserId());
            if (created is null) return BadRequest(new { error = "The request could not be created." });

            await _live.NotifyAsync("workflow", "dashboard");
            return Ok(created);
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>
    /// THE TYPED APPROVAL. At final approval the procedure REWRITES THE ROSTER — each person takes
    /// the other's slot and their own becomes a rest day — and stamps AppliedAt. That is why this
    /// cannot go through the generic /approve: an approved swap that never moved the roster would
    /// leave two people believing they had swapped.
    /// </summary>
    [HttpPost("{id:int}/decide")]
    public async Task<IActionResult> Decide(int id, [FromBody] TypedDecideRequest request)
    {
        try
        {
            var result = await _swaps.DecideAsync(id, User.UserId(), request);
            if (result is null) return NotFound();

            // A final approval REWRITES THE ROSTER, so attendance is stale too — the swap is not
            // only a request that closed, it is two people's rostered days changing hands.
            await _live.NotifyAsync("workflow", "attendance", "dashboard");
            return Ok(result);
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    [HttpGet("{id:int}/payload")]
    public async Task<IActionResult> GetPayload(int id)
    {
        var payload = await _swaps.GetPayloadAsync(id);
        return payload is null ? NotFound() : Ok(payload);
    }
}
