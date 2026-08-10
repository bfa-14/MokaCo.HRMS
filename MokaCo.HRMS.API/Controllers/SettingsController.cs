using System.Security.Claims;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Model.Core;
using MokaCo.HRMS.Services.Core;

namespace MokaCo.HRMS.Api.Controllers;

/// <summary>
/// core.SETTING — the SYSTEM's global key/value configuration, so policy can change without a
/// code deploy. It is not an attendance feature; attendance was simply the first thing to need
/// it, and payroll and workflow will add their own keys here.
///
/// WHO MAY CALL WHAT, and why the split is not uniform:
///   GET  /api/settings      SETTING_MANAGE — the full list, including the values that decide
///                           what a working day IS and therefore what people are paid.
///   PUT  /api/settings/{k}  SETTING_MANAGE — owner-level. Changing StandardWorkDayHours
///                           silently re-prices every part-day and every exit permission at once.
///   GET  /api/settings/ui   ANY SIGNED-IN USER — see below.
/// </summary>
[ApiController]
[Route("api/settings")]
public class SettingsController : ControllerBase
{
    private readonly ISettingService _settings;
    private readonly ILiveNotifier _live;

    public SettingsController(ISettingService settings, ILiveNotifier live)
    {
        _settings = settings;
        _live = live;
    }

    private int CurrentUserId =>
        int.Parse(User.FindFirstValue(ClaimTypes.NameIdentifier) ?? User.FindFirstValue("sub")!);

    [HttpGet]
    [HasPermission("SETTING_MANAGE")]
    public async Task<IActionResult> GetAll() => Ok(await _settings.GetAllAsync());

    /// <summary>
    /// The handful of settings that change how the UI BEHAVES, readable by anyone who is signed in.
    ///
    /// This exists because the full list is gated on SETTING_MANAGE — which HR deliberately does
    /// not have — and yet every user's screen needs to know whether the help panels are switched
    /// on. Without this endpoint an HR user could not even READ the flag that governs their own
    /// page, and the feature would only work for owners.
    ///
    /// Only non-sensitive, presentation-affecting keys belong here. It must never become a way to
    /// read the payroll policy values around the SETTING_MANAGE gate.
    /// </summary>
    [HttpGet("ui")]
    [Authorize]
    public async Task<IActionResult> GetUiSettings()
    {
        var showPageHelp = await _settings.GetAsync("ShowPageHelp");

        return Ok(new UiSettings
        {
            // Absent or unparseable means SHOW the help. Failing open is right here: the cost of
            // showing help nobody needed is a collapsed panel, and the cost of hiding it from
            // somebody who has never seen these screens is that they get somebody's pay wrong.
            ShowPageHelp = !string.Equals(showPageHelp?.SettingValue, "false", StringComparison.OrdinalIgnoreCase),
        });
    }

    /// <summary>Changes one setting. The caller is recorded, because some of these change what people are paid.</summary>
    [HttpPut("{key}")]
    [HasPermission("SETTING_MANAGE")]
    public async Task<IActionResult> Upsert(string key, [FromBody] SettingUpsertRequest request)
    {
        await _settings.UpsertAsync(key, request, CurrentUserId);
        // Settings are read by every module — the standard working day, the expense threshold, the
        // signature grace. Which one changed is not known here, so every topic is signalled.
        await _live.NotifyAsync("workflow", "payroll", "attendance", "hr", "dashboard");
        return NoContent();
    }
}
