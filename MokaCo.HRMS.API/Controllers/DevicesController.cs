using System.Net;
using Microsoft.AspNetCore.Mvc;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Services.Attendance;

namespace MokaCo.HRMS.Api.Controllers;

/// <summary>
/// Fingerprint terminals, the PIN→employee map, and the keys terminals push punches with.
///
/// Reading is ATTENDANCE_VIEW. Everything that changes the set of trusted punch sources is
/// DEVICE_MANAGE, because a device is a source of truth about PAY: whoever can add one, or hand out
/// its key, can inject attendance.
/// </summary>
[ApiController]
[Route("api/devices")]
// Class-level floor (see AttendanceController): devices are attendance configuration.
[HasPermission("ATTENDANCE_VIEW")]
public class DevicesController : ControllerBase
{
    private readonly IDeviceService _devices;
    private readonly IMachinePullService _pull;
    private readonly ILiveNotifier _live;
    private readonly ILogger<DevicesController> _logger;

    public DevicesController(
        IDeviceService devices,
        IMachinePullService pull,
        ILiveNotifier live,
        ILogger<DevicesController> logger)
    {
        _devices = devices;
        _pull = pull;
        _live = live;
        _logger = logger;
    }

    [HttpGet]
    [HasPermission("ATTENDANCE_VIEW")]
    public async Task<IActionResult> GetAll() => Ok(await _devices.GetAllAsync());

    [HttpPost]
    [HasPermission("DEVICE_MANAGE")]
    public async Task<IActionResult> Create([FromBody] DeviceCreateRequest request)
    {
        if (ValidatePull(request.PullEnabled, request.PullIp, request.PullPort) is { } error)
            return BadRequest(new { error });

        var id = await _devices.CreateAsync(request);
        await _live.NotifyAsync("attendance");
        return CreatedAtAction(nameof(GetAll), new { id }, new { deviceId = id });
    }

    [HttpPut("{id:int}")]
    [HasPermission("DEVICE_MANAGE")]
    public async Task<IActionResult> Update(int id, [FromBody] DeviceUpdateRequest request)
    {
        if (ValidatePull(request.PullEnabled, request.PullIp, request.PullPort) is { } error)
            return BadRequest(new { error });

        await _devices.UpdateAsync(id, request);
        await _live.NotifyAsync("attendance");
        return NoContent();
    }

    /* ── Pull: the server calling the terminal ────────────────────────────────────────────────────
       DEVICE_MANAGE on both, matching the rest of this controller's write side. Neither endpoint
       changes anything on the machine, but both open a socket to a device that controls a door, and
       "who may make the server connect to hardware" is the same question as "who may add a device".
       ─────────────────────────────────────────────────────────────────────────────────────────── */

    /// <summary>
    /// Reads one machine NOW, through the same lock the timer uses — so pressing this during a cycle
    /// waits for it rather than breaking it. The machine's buffer is not cleared, so this is safe to
    /// press repeatedly: the second press lands nothing and reports the punches as duplicates.
    /// </summary>
    [HttpPost("{id:int}/pull")]
    [HasPermission("DEVICE_MANAGE")]
    public async Task<IActionResult> PullNow(int id, CancellationToken ct)
    {
        var result = await _pull.PullAsync(id, ct);

        foreach (var warning in result.Warnings)
            _logger.LogWarning("Manual pull of device {DeviceId}: {Warning}", id, warning);

        if (result.Error is null && result.Inserted > 0)
            await _live.NotifyAsync("attendance");

        // 200 even when the machine could not be reached: the request was handled correctly and the
        // answer is "here is what happened". The caller shows result.error; a 5xx would make the
        // browser's own error handling talk about the SERVER when the fault is a terminal on a shelf.
        return Ok(new
        {
            received = result.Received,
            inserted = result.Inserted,
            duplicates = result.Duplicates,
            unresolvedPins = result.UnresolvedPins,
            error = result.Error
        });
    }

    /// <summary>
    /// Connects, asks the machine what time it is, disconnects. Reads no punches and writes nothing —
    /// not even the pull heartbeat, because a button somebody pressed is not a scheduled attempt and
    /// should not rewrite the device's pull history.
    ///
    /// The clock in the response is the real payload. Punches are stored at the terminal's own time,
    /// so a machine running fast quietly inflates everybody's hours, and this is the moment somebody
    /// is most likely to notice.
    /// </summary>
    [HttpPost("{id:int}/test-connection")]
    [HasPermission("DEVICE_MANAGE")]
    public async Task<IActionResult> TestConnection(int id, CancellationToken ct)
    {
        var result = await _pull.TestConnectionAsync(id, ct);

        return Ok(new
        {
            ok = result.Ok,
            deviceTime = result.DeviceTime,
            error = result.Error
        });
    }

    /// <summary>
    /// Rescues anything still on the machine and then ERASES the machine's own attendance log.
    /// Enrolled users and fingerprint templates are not touched.
    ///
    /// THE SERIAL IN THE BODY MUST MATCH, and this check is not the UI's politeness repeated. The UI
    /// asks too, but a typed endpoint that erases hardware state on nothing more than an id in a URL
    /// is one mis-aimed request away from wiping the wrong terminal — a CSRF, a stale tab, a script
    /// with an off-by-one. The serial makes the caller name the machine it means.
    ///
    /// Returns 200 with `cleared: false` and a reason when the safety check refuses. That is not an
    /// error to the API's way of thinking: the request was handled exactly as designed, and the
    /// answer is "no, and here is why nothing was deleted".
    /// </summary>
    [HttpPost("{id:int}/clear-machine-log")]
    [HasPermission("DEVICE_MANAGE")]
    public async Task<IActionResult> ClearMachineLog(
        int id, [FromBody] ClearMachineLogRequest request, CancellationToken ct)
    {
        var device = (await _devices.GetAllAsync()).FirstOrDefault(d => d.DeviceId == id);

        if (device is null)
            return NotFound();

        if (string.IsNullOrWhiteSpace(device.PullIp))
            return BadRequest(new
            {
                error = "This machine has no address configured, so its log cannot be read or cleared."
            });

        // Ordinal, not culture-aware: a serial is an identifier printed on a case, and two strings
        // that a locale considers equivalent are still two different machines.
        if (!string.Equals(request?.ConfirmSerial?.Trim(), device.SerialNumber, StringComparison.Ordinal))
            return BadRequest(new
            {
                error = "The serial you typed does not match this machine. Nothing was deleted."
            });

        var result = await _pull.ClearMachineLogAsync(id, ct);

        foreach (var warning in result.PulledBeforeClear.Warnings)
            _logger.LogWarning("Clear-machine-log on device {DeviceId}: {Warning}", id, warning);

        if (result.Cleared)
        {
            // Loud on purpose. This is the one operation here that destroys state we cannot get
            // back, and the log line is the only record that it happened at all.
            _logger.LogInformation(
                "MACHINE LOG CLEARED for {Serial}: pulled {Received} first — {Inserted} new, {Duplicates} already stored.",
                device.SerialNumber,
                result.PulledBeforeClear.Received,
                result.PulledBeforeClear.Inserted,
                result.PulledBeforeClear.Duplicates);

            await _live.NotifyAsync("attendance");
        }
        else
        {
            _logger.LogWarning(
                "Clear-machine-log REFUSED for {Serial}; the machine was not touched: {Error}",
                device.SerialNumber, result.Error);
        }

        return Ok(new
        {
            pulledBeforeClear = new
            {
                received = result.PulledBeforeClear.Received,
                inserted = result.PulledBeforeClear.Inserted,
                duplicates = result.PulledBeforeClear.Duplicates,
                unresolvedPins = result.PulledBeforeClear.UnresolvedPins,
            },
            cleared = result.Cleared,
            error = result.Error,
        });
    }

    /// <summary>
    /// Connection validation, applied only when pulling is actually switched ON — a half-filled
    /// address on a machine nobody is polling is a note-to-self, not an error worth refusing a save
    /// over. Returns null when the request is fine.
    /// </summary>
    private static string? ValidatePull(bool pullEnabled, string? pullIp, int pullPort)
    {
        if (!pullEnabled)
            return null;

        if (string.IsNullOrWhiteSpace(pullIp))
            return "Switching pulling on needs the machine's IP address.";

        var host = pullIp.Trim();

        // An IP or a hostname: sites that give their terminals DHCP reservations name them, and
        // refusing a name would force those sites to chase an address that is allowed to change.
        if (!IPAddress.TryParse(host, out _) && Uri.CheckHostName(host) == UriHostNameType.Unknown)
            return "The machine's IP address is not a valid address or hostname.";

        if (pullPort is < 1 or > 65535)
            return "The machine's port must be between 1 and 65535 (4370 on a ZK terminal).";

        return null;
    }

    /// <summary>
    /// Issues (or rotates) the key a terminal uses to push punches. The plaintext key is in THIS
    /// RESPONSE AND NOWHERE ELSE — only its hash is stored, so it cannot be looked up later. Rotating
    /// invalidates the previous key immediately, which is also how a compromised device is cut off.
    /// </summary>
    [HttpPost("{id:int}/api-key")]
    [HasPermission("DEVICE_MANAGE")]
    public async Task<IActionResult> IssueApiKey(int id)
    {
        var all = await _devices.GetAllAsync();
        var device = all.FirstOrDefault(d => d.DeviceId == id);
        if (device is null)
            return NotFound();

        var result = await _devices.IssueApiKeyAsync(id, device.SerialNumber);
        await _live.NotifyAsync("attendance");
        return Ok(result);
    }

    [HttpGet("enrollments")]
    [HasPermission("ATTENDANCE_VIEW")]
    public async Task<IActionResult> GetEnrollments() => Ok(await _devices.GetEnrollmentsAsync());

    /// <summary>
    /// Maps a device PIN to a person. It is RETROACTIVE: punches that already arrived on that PIN
    /// with nobody attached are claimed immediately, which is why the response says how many were
    /// recovered rather than just "ok".
    /// </summary>
    [HttpPost("enrollments")]
    [HasPermission("DEVICE_MANAGE")]
    public async Task<IActionResult> MapEnrollment([FromBody] EnrollmentMapRequest request)
    {
        var result = await _devices.MapAsync(request);
        // Mapping a PIN to a person moves punches out of the unresolved queue and onto their days.
        await _live.NotifyAsync("attendance", "dashboard");
        return Ok(result);
    }

    [HttpDelete("enrollments/{id:int}")]
    [HasPermission("DEVICE_MANAGE")]
    public async Task<IActionResult> Unmap(int id)
    {
        await _devices.UnmapAsync(id);
        await _live.NotifyAsync("attendance", "dashboard");
        return NoContent();
    }
}
