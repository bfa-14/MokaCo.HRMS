using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Services.Core;

namespace MokaCo.HRMS.Api.Controllers;

/// <summary>
/// The home page — what the signed-in user has to act on today.
/// </summary>
[ApiController]
[Route("api/dashboard")]
[Authorize]
public class DashboardController : ControllerBase
{
    private readonly IDashboardService _dashboard;
    public DashboardController(IDashboardService dashboard) => _dashboard = dashboard;

    /// <summary>
    /// The whole page in one call: what waits on the caller, what they raised, what needs attention.
    ///
    /// AUTHENTICATION ONLY — deliberately NO [HasPermission]. Everybody has a dashboard, including a
    /// new employee holding nothing but REQUEST_RAISE_SELF, and a permission gate here would answer
    /// the app's landing page with a 403. What differs between callers is the CONTENT, and that is
    /// settled inside the procedure from the caller's own id: an ordinary employee's response simply
    /// carries no company-wide figures. The UserId comes from the token and is never accepted from the
    /// query string — otherwise anybody could read anybody's inbox by changing a number in the URL.
    /// </summary>
    [HttpGet]
    public async Task<IActionResult> Get() => Ok(await _dashboard.GetAsync(User.UserId()));
}
