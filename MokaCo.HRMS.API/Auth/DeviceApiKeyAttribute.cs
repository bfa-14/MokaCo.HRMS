using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Filters;
using MokaCo.HRMS.Services.Attendance;

namespace MokaCo.HRMS.Api.Auth;

/// <summary>
/// Authenticates a FINGERPRINT TERMINAL, not a person.
///
/// WHY THIS EXISTS AT ALL: there is no human standing at a punch clock. It cannot log in, it has no
/// JWT, and it cannot refresh a token. But leaving POST /api/attendance/punch open would mean anyone
/// who can reach the network can post punches for any PIN — and forged attendance is forged PAY. So
/// the device authenticates as ITSELF, with a per-device key sent as the X-Device-Key header
/// alongside its serial.
///
/// The key is compared against a stored SHA-256 hash (see DeviceService.AuthenticateAsync); the
/// plaintext exists only at the moment it is issued.
///
/// Usage: [DeviceApiKey] on the punch action. The authenticated device is left in
/// HttpContext.Items["Device"] for the action to read, so the action never has to trust a DeviceId
/// that came from the request body.
/// </summary>
public class DeviceApiKeyAttribute : ActionFilterAttribute
{
    public const string HeaderName = "X-Device-Key";
    public const string SerialHeaderName = "X-Device-Serial";

    /// <summary>Key under which the action finds the device that actually authenticated.</summary>
    public const string DeviceItemKey = "Device";

    public override async Task OnActionExecutionAsync(ActionExecutingContext context, ActionExecutionDelegate next)
    {
        var serial = context.HttpContext.Request.Headers[SerialHeaderName].ToString();
        var apiKey = context.HttpContext.Request.Headers[HeaderName].ToString();

        var devices = context.HttpContext.RequestServices.GetRequiredService<IDeviceService>();
        var device = await devices.AuthenticateAsync(serial, apiKey);

        // One answer for every failure — unknown serial, no key issued, retired device, wrong key.
        // Distinguishing them would turn this endpoint into an oracle for enumerating our terminals.
        if (device is null)
        {
            context.Result = new UnauthorizedObjectResult(new { error = "Unknown device or invalid device key." });
            return;
        }

        context.HttpContext.Items[DeviceItemKey] = device;

        await next();
    }
}
