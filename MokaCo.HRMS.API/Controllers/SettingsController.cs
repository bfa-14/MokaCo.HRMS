using System.Security.Claims;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Api.Jobs;
using MokaCo.HRMS.Model.Core;
using MokaCo.HRMS.Services.Core;
using MokaCo.HRMS.Services.Security.Gate;

namespace MokaCo.HRMS.Api.Controllers;

/// <summary>
/// core.SETTING — the SYSTEM's global key/value configuration, so policy can change without a
/// code deploy. It is not an attendance feature; attendance was simply the first thing to need
/// it, and payroll and workflow will add their own keys here.
///
/// WHO MAY CALL WHAT, and why the split is not uniform:
///   GET  /api/settings      SETTING_MANAGE — the full list, including the values that decide
///                           what a working day IS and therefore what people are paid.
///   PUT  /api/settings/{k}  SETTING_MANAGE — owner-level. Changing StandardWorkingDaysPerMonth
///                           silently re-prices every day rate at once.
///   GET  /api/settings/ui   ANY SIGNED-IN USER — see below.
/// </summary>
[ApiController]
[Route("api/settings")]
public class SettingsController : ControllerBase
{
    private readonly ISettingService _settings;
    private readonly ILiveNotifier _live;
    private readonly IMailProbe? _mail;
    private readonly IHostEnvironment? _environment;

    public SettingsController(ISettingService settings, ILiveNotifier live, IMailProbe? mail = null, IHostEnvironment? environment = null)
    {
        _settings = settings;
        _live = live;
        _mail = mail;
        _environment = environment;
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

    /// <summary>
    /// Changes one setting. The caller is recorded, because some of these change what people are paid.
    ///
    /// NOT the four Google* keys of the sign-in gate (docs/GOOGLE_SIGNIN_GATE.md G5): they change only
    /// through PUT api/access/settings, which refuses to turn the gate on for a caller who has not
    /// passed it — this path would let anyone with SETTING_MANAGE lock everybody out, themselves included.
    ///
    /// AND ONLY A PLAIN KEY: the procedure takes it as VARCHAR(60), where a look-alike letter becomes its
    /// plain one and the rest of a long key is cut off — "GoogleSİgnInRequired" would land on the gate's row.
    /// </summary>
    [HttpPut("{key}")]
    [HasPermission("SETTING_MANAGE")]
    public async Task<IActionResult> Upsert(string key, [FromBody] SettingUpsertRequest request)
    {
        if (!GateSettingKeys.IsPlainKey(key))
            return BadRequest(new { error = "That is not a setting key." });
        if (GateSettingKeys.IsGateKey(key))
            return BadRequest(new { error = "Change this on Settings → Google sign-in." });
        if (SettingValueRules.Problem(key, request.SettingValue) is { } problem)
            return BadRequest(new { error = problem });

        await _settings.UpsertAsync(key, request, CurrentUserId);
        // Settings are read by every module — the standard working day, the expense threshold, the
        // signature grace. Which one changed is not known here, so every topic is signalled.
        await _live.NotifyAsync("workflow", "payroll", "attendance", "hr", "dashboard");
        return NoContent();
    }

    /// <summary>
    /// Whether this system is the production one, and, where it is not, who it may write to (<see cref="MailGuard"/>):
    /// the Settings page shows the list of test recipients on a test system only.
    /// </summary>
    [HttpGet("mail-guard")]
    [HasPermission("SETTING_MANAGE")]
    public async Task<IActionResult> MailGuardState()
    {
        var production = _environment?.IsProduction() ?? true;
        var list = production ? null : (await _settings.GetAsync(MailGuard.SettingKey))?.SettingValue;
        var guard = MailGuard.Of(production, list);
        return Ok(new { production, recipients = guard.Allowed.Order(StringComparer.Ordinal).ToArray(), settingKey = MailGuard.SettingKey });
    }

    /// <summary>
    /// Sends ONE test message now, through the HR account ("hr") or the bookings mailbox ("booking"), with the
    /// settings as they are saved, and answers with what the mail server said. 200 either way: a refused login is
    /// the answer, not a fault of this call. The password is never in the answer.
    /// </summary>
    [HttpPost("mail-test")]
    [HasPermission("SETTING_MANAGE")]
    public async Task<IActionResult> MailTest([FromBody] MailTestRequest? request, CancellationToken cancellationToken)
    {
        var account = MailProbe.ParseAccount(request?.Account);
        if (account is null)
            return BadRequest(new { error = "Choose the account to test: hr or booking." });
        var to = (request?.To ?? string.Empty).Trim();
        if (to.Length is 0 or > 150 || !System.Net.Mail.MailAddress.TryCreate(to, out var parsed) || parsed.Address != to)
            return BadRequest(new { error = "Type the e-mail address the test message goes to." });
        if (_mail is null)
            return StatusCode(StatusCodes.Status503ServiceUnavailable, new { error = "The mail test is not available on this server." });

        return Ok(await _mail.SendTestAsync(account, to, cancellationToken));
    }
}

/// <summary>POST api/settings/mail-test.</summary>
public sealed record MailTestRequest(string? Account, string? To);
