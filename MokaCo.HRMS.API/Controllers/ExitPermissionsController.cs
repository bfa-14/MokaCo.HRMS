using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Model.Workflow;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Api.Controllers;

/// <summary>
/// Exit permissions — the first concrete request type. Raising one submits it into the workflow
/// engine; approving it (through the generic request endpoints) eventually pushes the approved
/// minutes into the attendance day.
/// </summary>
[ApiController]
[Route("api/exit-permissions")]
[Authorize]
public class ExitPermissionsController : ControllerBase
{
    private readonly IExitPermissionService _exitPermissions;
    private readonly IWorkflowSupportService _support;

    public ExitPermissionsController(IExitPermissionService exitPermissions, IWorkflowSupportService support)
    {
        _exitPermissions = exitPermissions;
        _support = support;
    }

    /// <summary>
    /// Raises an exit permission. REQUEST_RAISE_SELF is the floor — everyone who may raise anything
    /// holds it. The service enforces WHO it may be raised FOR: without REQUEST_RAISE_OTHERS, only the
    /// caller's own employee id (resolved from the token, never trusted from the body) is allowed, and
    /// a mismatch is a 403 rather than a silent redirect to the caller.
    /// </summary>
    [HttpPost]
    [HasPermission("REQUEST_RAISE_SELF")]
    public async Task<IActionResult> Create([FromBody] ExitPermissionCreateRequest request)
    {
        var me = await _support.GetEmployeeByUserIdAsync(User.UserId());
        var caller = new ExitPermissionCaller(
            User.UserId(),
            me?.EmployeeId,
            User.HasPermission("REQUEST_RAISE_OTHERS"));

        try
        {
            var created = await _exitPermissions.CreateAsync(request, caller);
            return created is null ? BadRequest(new { error = "The request could not be created." }) : Ok(created);
        }
        catch (WorkflowException ex)
        {
            return StatusCode(ex.StatusCode, new { error = ex.Message });
        }
    }

    /// <summary>The caller's own exit permissions. Empty for an account not linked to an employee.</summary>
    [HttpGet("mine")]
    public async Task<IActionResult> Mine([FromQuery] DateTime? from, [FromQuery] DateTime? to)
    {
        var me = await _support.GetEmployeeByUserIdAsync(User.UserId());
        if (me is null)
            return Ok(Array.Empty<MyExitPermission>());

        return Ok(await _exitPermissions.GetForEmployeeAsync(me.EmployeeId, from, to));
    }

    /// <summary>The payload behind a request, plus what attendance recorded once the day exists.</summary>
    [HttpGet("by-request/{id:int}")]
    public async Task<IActionResult> GetByRequest(int id)
    {
        var detail = await _exitPermissions.GetByRequestAsync(id);
        return detail is null ? NotFound() : Ok(detail);
    }

    /// <summary>
    /// Sweeps approved permissions into attendance. Also run nightly; exposed here so HR can push a
    /// day through by hand. Idempotent — a permission already applied is left alone.
    /// </summary>
    [HttpPost("apply")]
    [HasPermission("ATTENDANCE_MANAGE")]
    public async Task<IActionResult> Apply([FromQuery] int? exitPermissionId, [FromQuery] DateTime? workDate)
        => Ok(await _exitPermissions.ApplyToAttendanceAsync(exitPermissionId, workDate));

    /// <summary>Approved permissions not yet reflected in attendance — the day may not have happened yet.</summary>
    [HttpGet("pending-application")]
    [HasPermission("ATTENDANCE_VIEW")]
    public async Task<IActionResult> PendingApplication()
        => Ok(await _exitPermissions.GetPendingApplicationAsync());

    /// <summary>Posts the leave usage for converted exit permissions at period close. ATTENDANCE_MANAGE.</summary>
    [HttpPost("post-leave")]
    [HasPermission("ATTENDANCE_MANAGE")]
    public async Task<IActionResult> PostLeave([FromBody] PostLeaveRequest request)
        => Ok(await _exitPermissions.PostLeaveUsageAsync(request, User.UserId()));
}
