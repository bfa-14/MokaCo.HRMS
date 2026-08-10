using System.Security.Cryptography;
using System.Text;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.RateLimiting;
using MokaCo.HRMS.Api.Hubs;
using MokaCo.HRMS.Model.Attendance;
using MokaCo.HRMS.Services.Attendance;
using MokaCo.HRMS.Services.Core;

namespace MokaCo.HRMS.Api.Controllers;

/// <summary>
/// The ZKTeco iclock/ADMS push receiver — how a fingerprint terminal delivers punches to us
/// directly, with no middleware, no export and nobody remembering to upload anything.
///
/// THIS CONTROLLER IS NOT SPEAKING OUR PROTOCOL. It is speaking the terminal's, and every odd
/// thing about it is the firmware's requirement rather than a choice:
///   • THE PATHS ARE HARDCODED IN THE DEVICE. /iclock/cdata and /iclock/getrequest are compiled
///     into the firmware. They cannot be prefixed with /api, versioned, or renamed.
///   • IT IS RAW TEXT IN AND OUT, not JSON. The body is tab-separated lines; the reply to a batch
///     of punches is the two bytes "OK".
///   • "OK" IS LOAD-BEARING. A terminal that receives anything else considers the batch undelivered
///     and re-sends it, forever, on a timer. So a body it does not recognise is not a cosmetic
///     problem — it is a device that never stops shouting and never clears its buffer.
///   • THERE IS NO JWT AND THERE CANNOT BE ONE. There is no human at a punch clock, no browser, no
///     token refresh. The device identifies itself with ?SN= in a query string and nothing else.
///
/// SO WHAT ACTUALLY PROTECTS THIS, stated plainly rather than implied:
///   1. AN ALLOWLIST. The serial must already exist in attendance.DEVICE and be active. An unknown
///      or retired serial is refused 403 and logged.
///   2. AN OPTIONAL SHARED KEY in the URL (core.SETTING 'IclockSharedKey'), for firmware whose
///      Server Address field tolerates a query suffix. Off by default; the log line for every
///      accepted request says which check admitted it, so you can tell whether it is really on.
///   3. A RATE LIMIT PER SERIAL and a request size cap, so a serial that leaks cannot be used to
///      flood the punch table faster than a real terminal ever would.
///   4. TLS. The serial is printed on the back of the machine and travels in a query string; on
///      plain HTTP it is readable by anyone on the path, and so is every punch.
///
/// This is DELIBERATELY WEAKER than POST /api/attendance/punch, which proves possession of a
/// per-device secret (see DeviceApiKeyAttribute). That endpoint still exists and is still the
/// better one. This is what the hardware will actually do. Anyone who knows a registered serial
/// can post punches for any PIN on it — forged attendance is forged pay — and the mitigations are
/// the four above, not authentication. Clearing IsActive is the kill switch.
/// </summary>
[ApiController]
[Route("iclock")]
[EnableRateLimiting(RateLimitPolicy)]
public class IclockController : ControllerBase
{
    /// <summary>Matches the policy registered in Program.cs, partitioned per serial.</summary>
    public const string RateLimitPolicy = "iclock";

    /// <summary>core.SETTING key. Empty or missing = the shared key is off and the allowlist stands alone.</summary>
    private const string SharedKeySetting = "IclockSharedKey";

    /// <summary>
    /// The only thing a terminal will accept as "delivered". Two bytes, no punctuation, no JSON —
    /// anything else and it re-sends the batch on its retry timer forever.
    /// </summary>
    private const string OkBody = "OK";

    /// <summary>
    /// What a caller is told when something broke on our side. No message, no type, no stack trace:
    /// this endpoint is reachable by anyone who can guess a serial, and an exception's text is a
    /// free map of our schema. The detail goes to OUR log, where it belongs.
    /// </summary>
    private const string Error = "ERROR";

    private const string PlainText = "text/plain";

    private readonly IDeviceService _devices;
    private readonly IImportService _import;
    private readonly ISettingService _settings;
    private readonly ILiveNotifier _live;
    private readonly ILogger<IclockController> _log;

    public IclockController(
        IDeviceService devices,
        IImportService import,
        ISettingService settings,
        ILiveNotifier live,
        ILogger<IclockController> log)
    {
        _devices = devices;
        _import = import;
        _settings = settings;
        _live = live;
        _log = log;
    }

    /// <summary>
    /// THE HANDSHAKE. The terminal asks "what are my orders", and this block is the answer; it is
    /// the first thing that happens after somebody types our address into the machine, and if it
    /// does not come back correctly the device never sends a single punch.
    ///
    /// Every line is a device-side setting, and the ones that matter here:
    ///   ATTLOGStamp=None   — send everything you have, do not resume from a bookmark. This is what
    ///                        makes a freshly-pointed terminal flush its whole buffer at us; dedup
    ///                        is what makes that safe.
    ///   TRANSFLAG          — which log types to transmit. The leading 1s enable attendance.
    ///   Realtime=1         — push each punch as it happens instead of only on the timer. This is
    ///                        the difference between "appears within seconds" and "appears at 14:05".
    ///   TRANSINTERVAL=1    — and if it does batch, batch for a minute, not an hour.
    ///   Encrypt=None       — the payload is plain text. TLS is the only thing encrypting it.
    /// </summary>
    [HttpGet("cdata")]
    public async Task<IActionResult> Handshake([FromQuery] string? sn, [FromQuery] string? key)
    {
        var (device, refusal) = await AuthoriseAsync(sn, key, "handshake");
        if (refusal is not null)
            return refusal;

        // A handshake is contact, not a punch: it proves the network, not the sensor.
        await _devices.TouchSyncAsync(device!.DeviceId);

        _log.LogInformation(
            "iclock handshake from {Serial} ({DeviceName}); replying with the option block.",
            device.SerialNumber, device.Name ?? "unnamed");

        // \n, and a trailing one. The firmware parses this line by line and a missing final
        // newline is the kind of thing that makes the last option silently not apply.
        var options = string.Join('\n', new[]
        {
            $"GET OPTION FROM: {device.SerialNumber}",
            "ATTLOGStamp=None",
            "OPERLOGStamp=9999",
            "ERRORDELAY=30",
            "DELAY=15",
            "TRANSTIMES=00:00;14:05",
            "TRANSINTERVAL=1",
            "TRANSFLAG=1111000000",
            "Realtime=1",
            "Encrypt=None",
        }) + "\n";

        return Text(options);
    }

    /// <summary>
    /// THE PUNCHES. Everything else in this controller exists so that this can happen.
    ///
    /// The body is tab-separated lines, one punch each, parsed by ImportService.PushAttlogAsync into
    /// the SAME landing table, via the SAME dedup hash, as the spreadsheet importer. There is no
    /// second pipeline, because a second pipeline is a second set of rules and eventually a second
    /// answer to "how many hours did this person work".
    ///
    /// IT ANSWERS "OK" EVEN WHEN IT STORED NOTHING, and that is correct rather than lazy. "OK" does
    /// not mean "these were new" — it means "we have them, stop re-sending". A batch of pure
    /// duplicates is the normal result of a link that dropped before the last acknowledgement, and
    /// answering anything else would put the terminal into a permanent retry loop over punches we
    /// already have.
    ///
    /// The only thing that does NOT get an OK is a genuine failure on our side (see the catch): a
    /// 500 makes the device keep the batch and try again, which is exactly what we want, because
    /// the alternative is acknowledging punches we failed to store.
    /// </summary>
    [HttpPost("cdata")]
    [RequestSizeLimit(MaxBodyBytes)]
    public async Task<IActionResult> Cdata(
        [FromQuery] string? sn,
        [FromQuery] string? table,
        [FromQuery] string? key)
    {
        var (device, refusal) = await AuthoriseAsync(sn, key, $"cdata table={table ?? "(none)"}");
        if (refusal is not null)
            return refusal;

        // Contact, recorded before anything can go wrong with the body — the terminal DID reach us,
        // and that fact should survive a batch we could not read.
        await _devices.TouchSyncAsync(device!.DeviceId);

        // The same endpoint carries operation logs (door opened, admin menu entered), device options
        // on first contact, and on some firmware biometric templates. They are not attendance, we
        // store none of them, and they still must be acknowledged or the device re-sends forever.
        if (!string.Equals(table, "ATTLOG", StringComparison.OrdinalIgnoreCase))
        {
            _log.LogInformation(
                "iclock non-attendance upload from {Serial}: table={Table}. Acknowledged and discarded.",
                device.SerialNumber, table ?? "(none)");

            return Text(OkBody);
        }

        string body;
        try
        {
            body = await ReadBodyAsync();
        }
        catch (BadHttpRequestException ex)
        {
            // The size cap tripped. A real terminal's batch is kilobytes; this is either a firmware
            // fault or somebody using a leaked serial as a hose. Refuse it — do NOT say OK, because
            // we did not store it.
            _log.LogWarning(ex, "iclock body from {Serial} exceeded the {Cap}-byte cap and was refused.",
                device.SerialNumber, MaxBodyBytes);

            return Text(Error, StatusCodes.Status413PayloadTooLarge);
        }

        try
        {
            var result = await _import.PushAttlogAsync(device.DeviceId, body);

            // "Punches arrived" is a stronger statement than "the device called" — it is the one
            // that tells you the sensor still works. Stamped only when a batch actually parsed.
            if (result.Received > 0)
                await _devices.TouchPushAsync(device.DeviceId);

            LogPushOutcome(device, result);

            // Only when something actually landed. Signalling on a batch of duplicates would make
            // every open attendance page refetch on a device's retry timer, all day, for nothing.
            if (result.ChangedAnything)
                await _live.NotifyAsync("attendance");

            return Text(OkBody);
        }
        catch (Exception ex)
        {
            // Deliberately NOT "OK". The device keeps the batch and retries, which is the only
            // behaviour here that does not quietly lose somebody's day.
            _log.LogError(ex, "iclock ATTLOG from {Serial} failed to land; the device will retry.",
                device.SerialNumber);

            return Text(Error, StatusCodes.Status500InternalServerError);
        }
    }

    /// <summary>
    /// The command channel. The terminal polls this every few seconds asking "anything for me?" —
    /// remote door open, re-upload a fingerprint, reboot. We issue no commands, so the answer is a
    /// bare OK, meaning "nothing queued".
    ///
    /// It is still worth having rather than 404ing: this poll is the heartbeat, and it is what keeps
    /// LastSyncUtc moving between punches. A terminal in an empty shop at 3am is silent on cdata and
    /// chatty here, and that is precisely how you tell "closed" from "unplugged".
    /// </summary>
    [HttpGet("getrequest")]
    public async Task<IActionResult> GetRequest([FromQuery] string? sn, [FromQuery] string? key)
    {
        var (device, refusal) = await AuthoriseAsync(sn, key, "getrequest");
        if (refusal is not null)
            return refusal;

        await _devices.TouchSyncAsync(device!.DeviceId);

        // Deliberately Debug, not Information: this fires every few seconds per device, and at
        // Information it would be the entire log.
        _log.LogDebug("iclock command poll from {Serial}; nothing queued.", device.SerialNumber);

        return Text(OkBody);
    }

    /// <summary>
    /// EVERYTHING ELSE UNDER /iclock — devicecmd, fdata, ping, and whatever the next firmware
    /// revision invents.
    ///
    /// It answers OK and logs what was asked for. That ordering is on purpose: firmware families
    /// differ in which auxiliary paths they call, the vendor documents them inconsistently, and a
    /// 404 to a path the device considers mandatory can stop it pushing punches at all. So the
    /// default is "acknowledge, and write down what it wanted" — then the log tells us which of
    /// these actually need implementing, instead of us guessing in advance.
    ///
    /// It is inside the allowlist, so an unknown serial still gets nothing.
    /// </summary>
    [AcceptVerbs("GET", "POST", "PUT", "DELETE")]
    [Route("{**path}")]
    [RequestSizeLimit(MaxBodyBytes)]
    public async Task<IActionResult> Unknown(string path, [FromQuery] string? sn, [FromQuery] string? key)
    {
        var (device, refusal) = await AuthoriseAsync(sn, key, $"unhandled path /{path}");
        if (refusal is not null)
            return refusal;

        await _devices.TouchSyncAsync(device!.DeviceId);

        _log.LogInformation(
            "iclock UNHANDLED path from {Serial}: {Method} /iclock/{Path}?{Query} — acknowledged, nothing stored. "
            + "If this recurs, it is a path worth implementing.",
            device.SerialNumber, Request.Method, path, Request.QueryString.Value?.TrimStart('?') ?? string.Empty);

        return Text(OkBody);
    }

    /* ------------------------------------------------------------------ *
     * The gate. Every action above goes through this and none of them     *
     * touch the database until it has passed.                             *
     * ------------------------------------------------------------------ */

    /// <summary>
    /// Decides whether this caller may talk to us at all, and returns the device it claims to be.
    ///
    /// TWO CHECKS, IN THIS ORDER:
    ///   1. The shared key, if one is configured. Checked FIRST because it is the cheaper gate and
    ///      because a caller that fails it should learn nothing about which serials we know.
    ///   2. The allowlist: the serial must exist in attendance.DEVICE and still be active.
    ///
    /// EVERY REFUSAL IS THE SAME 403 WITH THE SAME BODY. Unknown serial, retired terminal and wrong
    /// key are indistinguishable from outside — otherwise this endpoint becomes a way to enumerate
    /// our terminals one guess at a time. The log is where the three are told apart.
    /// </summary>
    private async Task<(Device? Device, IActionResult? Refusal)> AuthoriseAsync(
        string? serial, string? key, string what)
    {
        var sharedKey = await GetSharedKeyAsync();

        if (sharedKey is not null && !FixedTimeEquals(key, sharedKey))
        {
            _log.LogWarning(
                "iclock REFUSED ({What}) from {Remote}: shared key missing or wrong for serial {Serial}.",
                what, RemoteAddress(), Describe(serial));

            return (null, Forbid403());
        }

        if (string.IsNullOrWhiteSpace(serial))
        {
            _log.LogWarning("iclock REFUSED ({What}) from {Remote}: no SN in the query string.",
                what, RemoteAddress());

            return (null, Forbid403());
        }

        var device = await _devices.AuthoriseBySerialAsync(serial);

        if (device is null)
        {
            // The single most useful line in this file when a terminal "does not work": it is
            // almost always a serial typed into the Devices page that does not match the hardware.
            _log.LogWarning(
                "iclock REFUSED ({What}) from {Remote}: serial {Serial} is not a registered, active device. "
                + "Register it on Attendance > Devices, or re-activate it, if this is our terminal.",
                what, RemoteAddress(), Describe(serial));

            return (null, Forbid403());
        }

        _log.LogDebug("iclock admitted {Serial} for {What} ({Gate}).",
            device.SerialNumber, what,
            sharedKey is null ? "allowlist only — shared key is off" : "allowlist + shared key");

        return (device, null);
    }

    /// <summary>
    /// The configured shared key, or null when the feature is off. Blank counts as off — a setting
    /// row that exists with an empty value is the documented "disabled" state, not a key of length
    /// zero that every caller would satisfy.
    /// </summary>
    private async Task<string?> GetSharedKeyAsync()
    {
        var setting = await _settings.GetAsync(SharedKeySetting);
        var value = setting?.SettingValue?.Trim();

        return string.IsNullOrEmpty(value) ? null : value;
    }

    /// <summary>
    /// Reads the raw body. NOT model binding: the payload is tab-separated text, and there is no
    /// [FromBody] anywhere in this controller precisely so that nothing tries to parse it as JSON
    /// and reject the batch before we have seen it.
    /// </summary>
    private async Task<string> ReadBodyAsync()
    {
        using var reader = new StreamReader(Request.Body, Encoding.UTF8, leaveOpen: true);
        return await reader.ReadToEndAsync();
    }

    private void LogPushOutcome(Device device, AttlogPushResult result)
    {
        _log.LogInformation(
            "iclock ATTLOG from {Serial}: {Received} line(s) — {Inserted} stored, {Duplicates} already had, "
            + "{Unresolved} on unmapped PIN(s), {UnknownDirection} with an unmodelled direction, {Unparsed} unreadable.",
            device.SerialNumber, result.Received, result.Inserted, result.Duplicates,
            result.UnresolvedPins, result.UnknownDirection, result.Unparsed);

        // Loud, and separate, because these punches are GONE — the batch was acknowledged, so the
        // terminal has already cleared them from its buffer and will never send them again.
        if (result.Unparsed > 0)
        {
            _log.LogWarning(
                "iclock {Count} unreadable line(s) from {Serial} were DROPPED (the batch had to be acknowledged "
                + "or the device would retry forever). Sample: {Lines}",
                result.Unparsed, device.SerialNumber, string.Join(" | ", result.UnparsedLines));
        }

        if (result.UnresolvedPins > 0)
        {
            _log.LogInformation(
                "iclock {Count} punch(es) from {Serial} are on a PIN nobody is enrolled on. They are KEPT and "
                + "waiting on Attendance > Unresolved PINs; mapping the PIN claims them retroactively.",
                result.UnresolvedPins, device.SerialNumber);
        }
    }

    /* ---- responses ---- */

    /// <summary>
    /// Plain text, and nothing but. ASP.NET's default error shapes (ProblemDetails JSON, the
    /// developer exception page) are meaningless to a fingerprint reader — it would treat any of
    /// them as a failed delivery and retry the batch forever.
    /// </summary>
    private ContentResult Text(string body, int statusCode = StatusCodes.Status200OK)
        => new() { Content = body, ContentType = PlainText, StatusCode = statusCode };

    /// <summary>
    /// One answer for every refusal. Named Forbid403 rather than Forbid() because ControllerBase's
    /// Forbid() runs the authentication stack — which this controller does not participate in — and
    /// would return an empty 404-ish result instead of the plain 403 the log claims we sent.
    /// </summary>
    private ContentResult Forbid403()
        => Text("Unknown or inactive device.", StatusCodes.Status403Forbidden);

    private string RemoteAddress()
        => HttpContext.Connection.RemoteIpAddress?.ToString() ?? "unknown";

    /// <summary>
    /// A caller-supplied serial on its way into a log line. Trimmed and capped: it is unvalidated
    /// remote input, and a megabyte of it in the log file is its own small denial of service.
    /// </summary>
    private static string Describe(string? serial)
    {
        if (string.IsNullOrWhiteSpace(serial))
            return "(none)";

        var trimmed = serial.Trim();
        return trimmed.Length <= 60 ? trimmed : trimmed[..60] + "…";
    }

    /// <summary>
    /// Fixed-time comparison of the shared key. A plain == on a secret leaks its prefix to anyone
    /// patient enough to measure the response, and this endpoint is reachable by anyone.
    /// </summary>
    private static bool FixedTimeEquals(string? supplied, string expected)
    {
        if (string.IsNullOrEmpty(supplied))
            return false;

        return CryptographicOperations.FixedTimeEquals(
            Encoding.UTF8.GetBytes(supplied),
            Encoding.UTF8.GetBytes(expected));
    }

    /// <summary>
    /// A real terminal's batch is a few kilobytes. This is generous enough for a device flushing a
    /// long backlog on first connection and small enough that a leaked serial cannot be used to
    /// push megabytes into the punch table in one request.
    /// </summary>
    private const int MaxBodyBytes = 1_048_576;
}
