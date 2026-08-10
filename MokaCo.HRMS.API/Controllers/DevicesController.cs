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
public class DevicesController : ControllerBase
{
    private readonly IDeviceService _devices;
    private readonly ILiveNotifier _live;

    public DevicesController(IDeviceService devices, ILiveNotifier live)
    {
        _devices = devices;
        _live = live;
    }

    [HttpGet]
    [HasPermission("ATTENDANCE_VIEW")]
    public async Task<IActionResult> GetAll() => Ok(await _devices.GetAllAsync());

    [HttpPost]
    [HasPermission("DEVICE_MANAGE")]
    public async Task<IActionResult> Create([FromBody] DeviceCreateRequest request)
    {
        var id = await _devices.CreateAsync(request);
        await _live.NotifyAsync("attendance");
        return CreatedAtAction(nameof(GetAll), new { id }, new { deviceId = id });
    }

    [HttpPut("{id:int}")]
    [HasPermission("DEVICE_MANAGE")]
    public async Task<IActionResult> Update(int id, [FromBody] DeviceUpdateRequest request)
    {
        await _devices.UpdateAsync(id, request);
        await _live.NotifyAsync("attendance");
        return NoContent();
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
