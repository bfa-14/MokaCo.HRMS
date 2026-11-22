using Microsoft.AspNetCore.Mvc;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Model.Booking;
using MokaCo.HRMS.Services.Booking;
using MokaCo.HRMS.Services.Booking.Payments;

namespace MokaCo.HRMS.Api.Controllers;

/// <summary>
/// THE PAYMENT GATEWAYS, FOR AN ADMIN (script 119) - Settings > Payment gateways and Settings > Gateway test.
/// EVERY ACTION NEEDS GATEWAY_ADMIN, which the script gives to the admin roles and the Owner only.
///
///   GET    /api/payment-gateways                          both gateways: the mode in use, each mode's keys (masked), history
///   PUT    /api/payment-gateways/{gateway}/{mode}/keys    save the keys of one mode (blank = keep what is saved)
///   DELETE /api/payment-gateways/{gateway}/{mode}/keys    remove them from HRMS
///   PUT    /api/payment-gateways/{gateway}/mode           { mode: "test" | "live" | null }   null = follow the server file
///   POST   /api/payment-gateways/{gateway}/{mode}/check   connection check: asks the gateway, moves no money
///   GET    /api/payment-gateways/tests                    the last test payments
///   POST   /api/payment-gateways/tests                    { gateway, mode, amount, currency } -> a payment page to open
///   GET    /api/payment-gateways/tests/{ref}              one test and its log
///   POST   /api/payment-gateways/tests/{ref}/check        ask the gateway what became of it
///   POST   /api/payment-gateways/tests/{ref}/refund       give a paid Whish test back
///   POST   /api/payment-gateways/lookup                   { gateway, mode, reference, currency } -> what the gateway holds
///
/// {gateway} is card (Bank of Beirut) or whish; {mode} is test or live. A KEY NEVER LEAVES THIS API: what is typed is
/// encrypted before it is stored, and what is answered shows the end of a secret at most. A refusal the admin could
/// have avoided is 400 { error }, in a sentence written for them.
/// </summary>
[ApiController]
[Route("api/payment-gateways")]
public class PaymentGatewaysController : ControllerBase
{
    private const string Permission = "GATEWAY_ADMIN";

    private readonly IGatewayAdminService _gateways;

    public PaymentGatewaysController(IGatewayAdminService gateways) => _gateways = gateways;

    [HttpGet]
    [HasPermission(Permission)]
    public async Task<IActionResult> Get()
    {
        var overview = await _gateways.GetAsync();
        return Ok(new
        {
            timeZone = BeirutTime.IanaId,
            card = Shape(overview.Card),
            whish = Shape(overview.Whish),
            whishOnWebsite = overview.WhishOnWebsite,
            depositsRequired = overview.DepositsRequired,
            siteUrl = overview.SiteUrl,
            apiPublicUrl = overview.ApiPublicUrl,
            maxTestAmount = new { usd = GatewayAdminService.MaxTestAmountUsd, lbp = GatewayAdminService.MaxTestAmountLbp },
            history = overview.History.Select(h => new
            {
                id = h.PaymentEventId,
                gateway = h.Gateway,
                mode = h.Mode,
                type = h.EventType,
                outcome = h.Outcome,
                detail = h.Detail,
                at = Utc(h.CreatedAtUtc),
                by = h.UserName,
            }),
        });
    }

    [HttpPut("{gateway}/{mode}/keys")]
    [HasPermission(Permission)]
    public async Task<IActionResult> SaveKeys(string gateway, string mode, [FromBody] GatewayKeysInput? input)
    {
        if (Names(gateway, mode) is not var (name, which)) return UnknownGateway();
        return Answer(await _gateways.SaveKeysAsync(name, which, input ?? new GatewayKeysInput(), User.UserId()));
    }

    [HttpDelete("{gateway}/{mode}/keys")]
    [HasPermission(Permission)]
    public async Task<IActionResult> DeleteKeys(string gateway, string mode)
    {
        if (Names(gateway, mode) is not var (name, which)) return UnknownGateway();
        return Answer(await _gateways.DeleteKeysAsync(name, which, User.UserId()));
    }

    public sealed class ModeRequest
    {
        public string? Mode { get; set; }
    }

    [HttpPut("{gateway}/mode")]
    [HasPermission(Permission)]
    public async Task<IActionResult> SetMode(string gateway, [FromBody] ModeRequest? request)
    {
        if (GatewayNames.Parse(gateway) is not { } name) return UnknownGateway();

        var wanted = request?.Mode?.Trim();
        var mode = string.IsNullOrEmpty(wanted) ? null : GatewayModes.Parse(wanted);
        if (!string.IsNullOrEmpty(wanted) && mode is null)
            return BadRequest(new { error = "The mode must be test or live." });

        return Answer(await _gateways.SetModeAsync(name, mode, User.UserId()));
    }

    [HttpPost("{gateway}/{mode}/check")]
    [HasPermission(Permission)]
    public async Task<IActionResult> Check(string gateway, string mode, CancellationToken cancellationToken)
    {
        if (Names(gateway, mode) is not var (name, which)) return UnknownGateway();

        // A check that fails is still an answer the page shows, with its sentence: 200 with ok = false.
        var result = await _gateways.CheckConnectionAsync(name, which, User.UserId(), cancellationToken);
        return Ok(new { ok = result.Ok, message = result.Message, ms = result.Milliseconds });
    }

    /* ---- test payments ---------------------------------------------------------------------- */

    [HttpGet("tests")]
    [HasPermission(Permission)]
    public async Task<IActionResult> ListTests()
        => Ok((await _gateways.ListTestsAsync()).Select(Shape));

    public sealed class TestRequest
    {
        public string? Gateway { get; set; }
        public string? Mode { get; set; }
        public decimal Amount { get; set; }
        public string? Currency { get; set; }
    }

    [HttpPost("tests")]
    [HasPermission(Permission)]
    public async Task<IActionResult> OpenTest([FromBody] TestRequest? request, CancellationToken cancellationToken)
    {
        if (request is null || Names(request.Gateway, request.Mode) is not var (name, which)) return UnknownGateway();

        // Where the tester's browser comes back to: the HRMS page this request was made from, by the browser's own
        // Origin header (a page cannot forge it) - never an address out of the request body.
        var origin = Request.Headers.Origin.ToString();
        var result = await _gateways.OpenTestAsync(name, which, request.Amount, request.Currency ?? "USD", origin, User.UserId(), cancellationToken, Request.Host.Host);
        return result.Test is null
            ? BadRequest(new { error = result.Message })
            : Ok(new { ok = result.Ok, message = result.Message, test = Shape(result.Test) });
    }

    [HttpGet("tests/{testRef}")]
    [HasPermission(Permission)]
    public async Task<IActionResult> GetTest(string testRef)
    {
        var reference = testRef.Trim().ToUpperInvariant();
        if (!GatewayTestRefs.IsTestRef(reference)) return NotFound();

        var found = await _gateways.GetTestAsync(reference);
        return found is null ? NotFound() : Ok(new { test = Shape(found.Test), events = found.Events.Select(BookingPaymentsController.Shape) });
    }

    [HttpPost("tests/{testRef}/check")]
    [HasPermission(Permission)]
    public async Task<IActionResult> CheckTest(string testRef, CancellationToken cancellationToken)
    {
        var reference = testRef.Trim().ToUpperInvariant();
        if (!GatewayTestRefs.IsTestRef(reference)) return NotFound();

        var result = await _gateways.CheckTestAsync(reference, User.UserId(), PaymentEvents.FromStaff, cancellationToken);
        return result.Test is null ? NotFound() : Ok(new { ok = result.Ok, message = result.Message, test = Shape(result.Test), facts = Facts(result.Facts) });
    }

    [HttpPost("tests/{testRef}/refund")]
    [HasPermission(Permission)]
    public async Task<IActionResult> RefundTest(string testRef, CancellationToken cancellationToken)
    {
        var reference = testRef.Trim().ToUpperInvariant();
        if (!GatewayTestRefs.IsTestRef(reference)) return NotFound();

        var result = await _gateways.RefundTestAsync(reference, User.UserId(), cancellationToken);
        return result.Test is null ? NotFound() : Ok(new { ok = result.Ok, message = result.Message, test = Shape(result.Test) });
    }

    public sealed class LookupRequest
    {
        public string? Gateway { get; set; }
        public string? Mode { get; set; }
        public string? Reference { get; set; }
        public string? Currency { get; set; }
    }

    [HttpPost("lookup")]
    [HasPermission(Permission)]
    public async Task<IActionResult> Lookup([FromBody] LookupRequest? request, CancellationToken cancellationToken)
    {
        if (request is null || Names(request.Gateway, request.Mode) is not var (name, which)) return UnknownGateway();

        var result = await _gateways.LookupAsync(name, which, request.Reference ?? string.Empty, request.Currency ?? "USD", cancellationToken);
        return result.Facts is null
            ? BadRequest(new { error = result.Message })
            : Ok(new { ok = result.Ok, message = result.Message, ms = result.Milliseconds, facts = Facts(result.Facts) });
    }

    /* ---- shapes ----------------------------------------------------------------------------- */

    private static (string Gateway, string Mode)? Names(string? gateway, string? mode)
        => GatewayNames.Parse(gateway) is { } name && GatewayModes.Parse(mode) is { } which ? (name, which) : null;

    private IActionResult UnknownGateway()
        => BadRequest(new { error = "Say which gateway (card or whish) and which mode (test or live)." });

    private IActionResult Answer(GatewayActionResult result)
        => result.Ok ? Ok(new { ok = true, message = result.Message }) : BadRequest(new { error = result.Message });

    private static object Shape(GatewayView view) => new
    {
        gateway = view.Gateway,
        activeMode = view.ActiveMode,
        chosenMode = view.ChosenMode,
        serverMode = view.ServerMode,
        ready = view.Ready,
        problem = view.Problem,
        modeChangedAt = view.ModeChangedAtUtc,
        modeChangedBy = view.ModeChangedBy,
        modes = view.Modes.Select(m => new
        {
            mode = m.Mode,
            source = m.Source,
            hasKeys = m.HasKeys,
            unreadable = m.Unreadable,
            ready = m.Ready,
            problem = m.Problem,
            shown = m.Shown,
            savedAt = m.SavedAtUtc,
            savedBy = m.SavedBy,
        }),
    };

    internal static object Shape(GatewayTestRow test) => new
    {
        id = test.TestId,
        @ref = test.TestRef,
        gateway = test.Gateway,
        mode = test.Mode,
        amount = test.Amount,
        currency = test.CurrencyCode,
        status = test.Status,
        gatewayStatus = test.GatewayStatus,
        detail = test.Detail,
        payUrl = test.Status == "Opened" ? test.PayUrl : null,
        payerPhone = test.PayerPhone,
        transactionId = test.TransactionId,
        callbackAt = Utc(test.CallbackAtUtc),
        returnedAt = Utc(test.ReturnedAtUtc),
        checkedAt = Utc(test.CheckedAtUtc),
        refundedAt = Utc(test.RefundedAtUtc),
        createdAt = Utc(test.CreatedAtUtc),
        createdBy = test.CreatedBy,
    };

    internal static IEnumerable<object>? Facts(IReadOnlyList<GatewayFact>? facts)
        => facts?.Select(f => (object)new { label = f.Label, value = f.Value });

    internal static DateTime? Utc(DateTime? value) => value is { } at ? DateTime.SpecifyKind(at, DateTimeKind.Utc) : null;
}
