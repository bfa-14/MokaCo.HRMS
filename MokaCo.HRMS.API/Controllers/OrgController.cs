using Microsoft.AspNetCore.Mvc;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Services.HR;

namespace MokaCo.HRMS.Api.Controllers;

/// <summary>
/// Org-shape reads the chain builder needs. Gated on WORKFLOW_CONFIGURE — the same permission that
/// guards building a chain — because this is consumed while configuring one, not while browsing HR.
/// </summary>
[ApiController]
[Route("api/org")]
public class OrgController : ControllerBase
{
    private readonly IEmployeeService _employees;
    public OrgController(IEmployeeService employees) => _employees = employees;

    /// <summary>
    /// The deepest reporting line among current employees. The builder compares a Line-manager step's
    /// level against this: a level beyond it resolves nobody and the step skips for everyone today — a
    /// legal but worth-warning state, so this is advisory, never a block.
    /// </summary>
    [HttpGet("max-depth")]
    [HasPermission("WORKFLOW_CONFIGURE")]
    public async Task<IActionResult> GetMaxDepth()
        => Ok(new { maxDepth = await _employees.GetOrgMaxDepthAsync() });
}
