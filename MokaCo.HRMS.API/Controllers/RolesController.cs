using Microsoft.AspNetCore.Mvc;
using Microsoft.Data.SqlClient;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Model.Security;
using MokaCo.HRMS.Repository.Security;
using System.Security.Claims;

namespace MokaCo.HRMS.Api.Controllers;

[ApiController]
[Route("api/roles")]
public class RolesController : ControllerBase
{
    private readonly IRoleRepository _roles;
    private readonly IPermissionRepository _permissions;
    private readonly ILiveNotifier _live;

    public RolesController(
        IRoleRepository roles, IPermissionRepository permissions, ILiveNotifier live)
    { _roles = roles; _permissions = permissions; _live = live; }

    /// <summary>
    /// Roles are how the chains decide who may sign a step, whether a rejection ends the request,
    /// and whether a password is demanded — so a role edit reaches every request in flight.
    /// </summary>
    private Task NotifyRolesAsync() => _live.NotifyAsync("workflow", "dashboard");

    [HttpGet]
    [HasPermission("ROLE_MANAGE")]
    public async Task<IActionResult> GetRoles() => Ok(await _roles.GetAllAsync());

    [HttpGet("permissions")]
    [HasPermission("ROLE_MANAGE")]
    public async Task<IActionResult> GetPermissions() => Ok(await _permissions.GetAllAsync());

    /// <summary>Roles the chain builder may offer as an approver or deputy. Gated with WORKFLOW_CONFIGURE — it feeds the chain builder's deputy picker, not role administration.</summary>
    [HttpGet("approvers")]
    [HasPermission("WORKFLOW_CONFIGURE")]
    public async Task<IActionResult> GetApprovers() => Ok(await _roles.GetApproversAsync());

    [HttpGet("{id:int}/permissions")]
    [HasPermission("ROLE_MANAGE")]
    public async Task<IActionResult> GetRolePermissions(int id)
        => Ok(await _roles.GetPermissionIdsAsync(id));
    private int CurrentUserId =>
    int.Parse(User.FindFirstValue(ClaimTypes.NameIdentifier) ?? User.FindFirstValue("sub")!);

    [HttpPut("{id:int}/permissions")]
    [HasPermission("ROLE_MANAGE")]
    public async Task<IActionResult> SetRolePermissions(int id, [FromBody] int[] permissionIds)
    {
        await _roles.SetPermissionsAsync(id, permissionIds ?? Array.Empty<int>(), CurrentUserId);
        await NotifyRolesAsync();
        return NoContent();
    }

    [HttpPost]
    [HasPermission("ROLE_MANAGE")]
    public async Task<IActionResult> Create([FromBody] RoleRequest request)
    {
        var id = await _roles.CreateAsync(request.Name, CurrentUserId);
        await NotifyRolesAsync();
        return CreatedAtAction(nameof(GetRoles), new { id }, new { roleId = id });
    }

    [HttpPut("{id:int}")]
    [HasPermission("ROLE_MANAGE")]
    public async Task<IActionResult> Update(int id, [FromBody] RoleRequest request)
    {
        await _roles.UpdateAsync(id, request.Name, CurrentUserId);
        await NotifyRolesAsync();
        return NoContent();
    }

    /// <summary>
    /// Every approver role with its rejection behaviour — whether a "no" from that role stops a
    /// request or travels on as advice. Feeds the Settings section that lets an administrator decide
    /// which roles have a final say.
    /// </summary>
    [HttpGet("rejection-behaviour")]
    [HasPermission("ROLE_MANAGE")]
    public async Task<IActionResult> GetRejectionBehaviour()
        => Ok(await _roles.GetRejectionBehaviourAsync());

    /// <summary>
    /// Sets whether a rejection by this role ends the request. The FINAL step still ends the request
    /// regardless — this only governs whether an EARLIER rejection is a verdict or a recommendation.
    /// </summary>
    [HttpPut("{id:int}/rejection-behaviour")]
    [HasPermission("ROLE_MANAGE")]
    public async Task<IActionResult> SetRejectionBehaviour(int id, [FromBody] RejectionBehaviourRequest request)
    {
        var updated = await _roles.SetRejectionBehaviourAsync(id, request.RejectionEndsRequest);
        if (updated is null) return NotFound();

        await NotifyRolesAsync();
        return Ok(updated);
    }

    /// <summary>Every role with its approver-usage and signature flags — the other two "workflow behaviour" settings.</summary>
    [HttpGet("signature-requirements")]
    [HasPermission("ROLE_MANAGE")]
    public async Task<IActionResult> GetSignatureRequirements()
        => Ok(await _roles.GetSignatureRequirementsAsync());

    /// <summary>
    /// Sets whether a role may be chosen as an approver in chains. The procedure REFUSES to switch it
    /// off while a PUBLISHED chain still uses the role, and that refusal is the whole value — it tells
    /// the admin to publish a new version without the role first — so it is surfaced verbatim as a 409,
    /// never swallowed into a generic error.
    /// </summary>
    [HttpPut("{id:int}/approver-usage")]
    [HasPermission("ROLE_MANAGE")]
    public async Task<IActionResult> SetApproverUsage(int id, [FromBody] ApproverUsageRequest request)
    {
        try
        {
            var updated = await _roles.SetApproverUsageAsync(id, request.UsableAsApprover);
            if (updated is null) return NotFound();

            await NotifyRolesAsync();
            return Ok(updated);
        }
        catch (SqlException ex) when (ex.Number == 50000)
        {
            // A RAISERROR from the procedure (severity 16) — its message is written for the admin.
            return Conflict(new { error = ex.Message });
        }
    }

    /// <summary>Sets whether decisions by this role must be password-signed. Confirms identity; never changes who may approve.</summary>
    [HttpPut("{id:int}/signature-requirement")]
    [HasPermission("ROLE_MANAGE")]
    public async Task<IActionResult> SetSignatureRequirement(int id, [FromBody] SignatureRequirementRequest request)
    {
        var updated = await _roles.SetSignatureRequirementAsync(id, request.RequiresSignaturePassword);
        if (updated is null) return NotFound();

        await NotifyRolesAsync();
        return Ok(updated);
    }
}
