using Microsoft.AspNetCore.Mvc;
using Microsoft.Data.SqlClient;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Model.HR;
using MokaCo.HRMS.Services.HR;

namespace MokaCo.HRMS.Api.Controllers;

[ApiController]
[Route("api/leave-types")]
public class LeaveTypesController : ControllerBase
{
    private readonly ILeaveTypeService _leaveTypes;
    private readonly ILiveNotifier _live;

    public LeaveTypesController(ILeaveTypeService leaveTypes, ILiveNotifier live)
    {
        _leaveTypes = leaveTypes;
        _live = live;
    }

    /// <summary>
    /// A leave type's tiers decide the entitlement every balance is measured against, so editing one
    /// changes figures already on screen elsewhere.
    /// </summary>
    private Task NotifyLeavePolicyAsync() => _live.NotifyAsync("hr", "dashboard");

    [HttpGet]
    [HasPermission("EMP_VIEW")]
    public async Task<IActionResult> GetAll() => Ok(await _leaveTypes.GetAllAsync());

    /// <summary>
    /// Which leave types ask for a relation, which relations they cover, and the days each entitles.
    /// The leave form reads this to decide whether to show the relation dropdown at all — the same
    /// question usp_LeaveRequest_Create answers by looking for rows here, so the two cannot disagree.
    ///
    /// EMP_VIEW like the type list itself: this is policy an employee raising a request must be able
    /// to see, not something they configure.
    /// </summary>
    [HttpGet("relation-entitlements")]
    [HasPermission("EMP_VIEW")]
    public async Task<IActionResult> GetRelationEntitlements()
        => Ok(await _leaveTypes.GetRelationEntitlementsAsync());

    /// <summary>
    /// Creates a leave type, policy and all (hr.usp_LeaveType_Upsert). Returns the row AS STORED so
    /// the caller binds from the save. A duplicate name is refused by the procedure, verbatim.
    /// </summary>
    [HttpPost]
    [HasPermission("LEAVE_POLICY_MANAGE")]
    public async Task<IActionResult> Create([FromBody] LeaveTypeUpsertRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.Name))
            return BadRequest(new { error = "Give the leave type a name." });

        try
        {
            var saved = await _leaveTypes.UpsertAsync(null, request);
            if (saved is null)
                return BadRequest(new { error = "The leave type could not be saved." });

            await NotifyLeavePolicyAsync();
            return Ok(saved);
        }
        catch (SqlException ex) when (ex.Number == 50000)
        {
            // "A leave type with that name already exists." — the procedure's own wording.
            return BadRequest(new { error = ex.Message });
        }
    }

    /// <summary>
    /// Updates a leave type. A POLICY FIELD LEFT NULL KEEPS ITS STORED VALUE, so an older screen
    /// that knows only name/paid/accrual/carry-over cannot silently clear the rest.
    /// </summary>
    [HttpPut("{id:int}")]
    [HasPermission("LEAVE_POLICY_MANAGE")]
    public async Task<IActionResult> Update(int id, [FromBody] LeaveTypeUpsertRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.Name))
            return BadRequest(new { error = "Give the leave type a name." });

        try
        {
            var saved = await _leaveTypes.UpsertAsync(id, request);
            if (saved is null) return NotFound();

            await NotifyLeavePolicyAsync();
            return Ok(saved);
        }
        catch (SqlException ex) when (ex.Number == 50000)
        {
            return BadRequest(new { error = ex.Message });
        }
    }

    /* ---- tiers and relations. The leave type is always the ROUTE, never the body: a mismatch
       between the two is a class of bug there is no reason to make possible. ---- */

    /// <summary>Adds or replaces one accrual tier — keyed on (type, MinServiceYears), so re-setting a year edits it.</summary>
    [HttpPut("{id:int}/accrual-tier")]
    [HasPermission("LEAVE_POLICY_MANAGE")]
    public async Task<IActionResult> SetAccrualTier(int id, [FromBody] LeaveAccrualTierRequest request)
    {
        await _leaveTypes.SetAccrualTierAsync(id, request);
        await NotifyLeavePolicyAsync();
        return NoContent();
    }

    [HttpDelete("{id:int}/accrual-tier/{minYears:int}")]
    [HasPermission("LEAVE_POLICY_MANAGE")]
    public async Task<IActionResult> DeleteAccrualTier(int id, int minYears)
    {
        await _leaveTypes.DeleteAccrualTierAsync(id, minYears);
        await NotifyLeavePolicyAsync();
        return NoContent();
    }

    /// <summary>Adds or replaces one sick-pay tier — keyed on (type, MinServiceYears).</summary>
    [HttpPut("{id:int}/pay-tier")]
    [HasPermission("LEAVE_POLICY_MANAGE")]
    public async Task<IActionResult> SetPayTier(int id, [FromBody] LeavePayTierRequest request)
    {
        await _leaveTypes.SetPayTierAsync(id, request);
        await NotifyLeavePolicyAsync();
        return NoContent();
    }

    [HttpDelete("{id:int}/pay-tier/{minYears:int}")]
    [HasPermission("LEAVE_POLICY_MANAGE")]
    public async Task<IActionResult> DeletePayTier(int id, int minYears)
    {
        await _leaveTypes.DeletePayTierAsync(id, minYears);
        await NotifyLeavePolicyAsync();
        return NoContent();
    }

    /// <summary>
    /// Adds or replaces one relation entitlement — keyed on (type, Relation). Adding a row here is
    /// what makes usp_LeaveRequest_Create accept that relation; deleting it makes it refuse again.
    /// </summary>
    [HttpPut("{id:int}/relation")]
    [HasPermission("LEAVE_POLICY_MANAGE")]
    public async Task<IActionResult> SetRelation(int id, [FromBody] LeaveRelationRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.Relation))
            return BadRequest(new { error = "Name the relation." });

        await _leaveTypes.SetRelationAsync(id, request);
        await NotifyLeavePolicyAsync();
        return NoContent();
    }

    [HttpDelete("{id:int}/relation/{relation}")]
    [HasPermission("LEAVE_POLICY_MANAGE")]
    public async Task<IActionResult> DeleteRelation(int id, string relation)
    {
        await _leaveTypes.DeleteRelationAsync(id, relation);
        await NotifyLeavePolicyAsync();
        return NoContent();
    }
}

/// <summary>
/// The whole leave policy in one read. Separate controller because it is not addressed under a
/// single leave type — it is types, tiers and relations together, which is what the policy screen
/// needs to decide which grids a type even has.
/// </summary>
[ApiController]
[Route("api/leave-policy")]
public class LeavePolicyController : ControllerBase
{
    private readonly ILeaveTypeService _leaveTypes;
    public LeavePolicyController(ILeaveTypeService leaveTypes) => _leaveTypes = leaveTypes;

    [HttpGet]
    [HasPermission("EMP_VIEW")]
    public async Task<IActionResult> Get() => Ok(await _leaveTypes.GetPolicyAsync());
}
