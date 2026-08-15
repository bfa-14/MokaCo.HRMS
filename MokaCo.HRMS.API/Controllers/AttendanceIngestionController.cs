using System.Security.Claims;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Services.Attendance;

namespace MokaCo.HRMS.Api.Controllers;

/// <summary>
/// How punches GET IN: a terminal pushing them, or HR uploading the spreadsheet the terminal
/// exported. Both land in the same table and are consumed by the same processor — there is
/// deliberately no second pipeline.
///
/// The punch endpoint is the one place in the whole API that is not authenticated by a user's JWT.
/// A fingerprint reader has no user. It authenticates as itself with a per-device key
/// ([DeviceApiKey]); see DeviceApiKeyAttribute for what that does and does not protect against.
/// </summary>
[ApiController]
[Route("api/attendance")]
public class AttendanceIngestionController : ControllerBase
{
    private readonly IImportService _import;
    private readonly ILiveNotifier _live;

    public AttendanceIngestionController(IImportService import, ILiveNotifier live)
    {
        _import = import;
        _live = live;
    }

    private int CurrentUserId =>
        int.Parse(User.FindFirstValue(ClaimTypes.NameIdentifier) ?? User.FindFirstValue("sub")!);

    /// <summary>
    /// A terminal pushing one punch. NOT bearer-authenticated: there is no human at a punch clock.
    /// The device proves who it is with X-Device-Serial + X-Device-Key, and the DeviceId is taken
    /// from that authenticated device — never from the request body, which the caller controls.
    ///
    /// Idempotent: re-sending the same punch is reported as a duplicate, not stored twice. A punch on
    /// a PIN nobody is enrolled on is STORED anyway and parked for HR — losing it would mean quietly
    /// not paying somebody.
    /// </summary>
    [HttpPost("punch")]
    // [DeviceApiKey] is an action FILTER, not an authentication scheme — it leaves no authenticated
    // principal behind — so the authorization fallback in Program.cs would reject the device before
    // the filter ever ran. The device's credential check is unchanged; this only says the endpoint
    // does not want a JWT.
    [AllowAnonymous]
    [DeviceApiKey]
    public async Task<IActionResult> Punch([FromBody] PunchRequest request)
    {
        var device = (Device)HttpContext.Items[DeviceApiKeyAttribute.DeviceItemKey]!;

        var result = await _import.PunchAsync(device.DeviceId, request);
        // A punch is raw attendance arriving; the unresolved-PIN queue may have grown too.
        await _live.NotifyAsync("attendance", "dashboard");
        return Ok(result);
    }

    /// <summary>
    /// Says what an upload WOULD do, writing NOTHING. Same parse and same dedup hash as the real
    /// import, so the preview cannot disagree with the thing it is previewing.
    /// </summary>
    /* DELIBERATELY SILENT: a preview WRITES NOTHING, so there is nothing for anyone to be stale
       about. It is a POST only because it carries a file. Recorded so the "which mutating actions do
       not notify?" sweep stops flagging it. */
    [HttpPost("import/preview")]
    [HasPermission("ATTENDANCE_IMPORT")]
    public async Task<IActionResult> Preview(IFormFile file)
    {
        if (file is null || file.Length == 0)
            return BadRequest(new { error = "No file was uploaded." });

        await using var stream = file.OpenReadStream();
        return Ok(await _import.PreviewAsync(stream));
    }

    /// <summary>
    /// Imports the spreadsheet a fingerprint machine exported.
    ///
    /// Nothing here overwrites anything. A punch already in the system is ignored, and a punch on an
    /// unknown PIN is kept rather than thrown away — so uploading the same file twice is safe, and
    /// the second attempt imports nothing.
    /// </summary>
    [HttpPost("import")]
    [HasPermission("ATTENDANCE_IMPORT")]
    public async Task<IActionResult> Import(IFormFile file)
    {
        if (file is null || file.Length == 0)
            return BadRequest(new { error = "No file was uploaded." });

        await using var stream = file.OpenReadStream();
        var result = await _import.ImportAsync(stream, file.FileName, CurrentUserId);

        // The batch list and the unresolved-PIN queue are both open on the import screen.
        // (Preview above deliberately does NOT signal — it writes nothing.)
        await _live.NotifyAsync("attendance", "dashboard");
        return Ok(result);
    }

    [HttpGet("imports")]
    [HasPermission("ATTENDANCE_VIEW")]
    public async Task<IActionResult> GetImports() => Ok(await _import.GetBatchesAsync());

    /// <summary>One batch INCLUDING the audit copy of the file — what the spreadsheet actually said, kept for the day somebody disputes a payslip.</summary>
    [HttpGet("imports/{id:int}")]
    [HasPermission("ATTENDANCE_VIEW")]
    public async Task<IActionResult> GetImport(int id)
    {
        var batch = await _import.GetBatchAsync(id);
        return batch is null ? NotFound() : Ok(batch);
    }

    /// <summary>
    /// Punches whose PIN belongs to nobody. They are WAITING, not lost. Map the PIN on the enrollment
    /// endpoint and they are claimed retroactively and counted.
    /// </summary>
    [HttpGet("unresolved")]
    [HasPermission("ATTENDANCE_IMPORT")]
    public async Task<IActionResult> GetUnresolved([FromQuery] DateTime? from, [FromQuery] DateTime? to)
        => Ok(await _import.GetUnresolvedAsync(from, to));

    /// <summary>
    /// Every punch recorded on one day, exactly as the machines reported it — before the processor
    /// turns it into anybody's worked hours.
    ///
    /// THIS IS THE "DID MY PUNCH ARRIVE" ENDPOINT, and it exists because the answer was previously
    /// only available by querying the database by hand. It reads the RAW log rather than attendance
    /// records on purpose: a punch appears here the second it lands, hours before the nightly
    /// processor gives it meaning, and a punch on an unmapped PIN appears here too — with no name
    /// against it, which is precisely the diagnosis somebody needs.
    ///
    /// ATTENDANCE_VIEW, not ATTENDANCE_IMPORT like the unresolved list above: this is a read of what
    /// happened, for anybody already trusted to see attendance, not an ingestion tool.
    ///
    /// The date is REQUIRED. The raw log grows by every punch of every employee forever, and an
    /// endpoint that would happily be called without one is a page that works now and times out in
    /// two years.
    /// </summary>
    [HttpGet("punches")]
    [HasPermission("ATTENDANCE_VIEW")]
    public async Task<IActionResult> GetPunches(
        [FromQuery] DateTime? date,
        [FromQuery] int? deviceId,
        [FromQuery] bool unresolvedOnly = false)
    {
        if (date is null)
            return BadRequest(new { error = "A date is required." });

        return Ok(await _import.GetPunchesByDateAsync(date.Value, deviceId, unresolvedOnly));
    }
}
