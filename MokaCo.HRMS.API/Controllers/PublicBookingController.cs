using System.Globalization;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Cors;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.ModelBinding;
using Microsoft.AspNetCore.RateLimiting;
using MokaCo.HRMS.Api.PublicBooking;
using MokaCo.HRMS.Model.Booking;
using MokaCo.HRMS.Services.Booking;
using MokaCo.HRMS.Services.Booking.Payments;

namespace MokaCo.HRMS.Api.Controllers;

/// <summary>
/// The public booking API — the calls the MokaCo website (mokanco-lb/src/scripts/api.ts) makes, and
/// the only part of this service reachable without a token.
///
/// EVERY TIME ON THE WIRE IS BEIRUT WALL CLOCK, said out loud in every response (timeZone). A slot is
/// a DATE plus MINUTES FROM ITS MIDNIGHT, because the café closes at 01:00 and clock times cannot
/// express that: 23:00–01:00 is 1380–1500. Wherever a single instant is returned — localNow, startAt,
/// endAt — it carries its offset (ISO-8601). Server "now" is <see cref="BeirutTime"/>, never
/// DateTime.Now; the guest is judged by booking.fn_LocalNow() in the database.
///
/// WHAT PROTECTS THIS: the access gate (<see cref="PublicBookingAccessAttribute"/> — the website's
/// origins, or a shared key), a per-IP rate limit, the fact that it is almost entirely read-only,
/// and that the one real write can only BOOK — Source is nailed to 'Website' in the repository,
/// price and status are computed by the procedure. There is no CAPTCHA; bookings arrive Pending for
/// a human to confirm.
///
/// EVERY REFUSAL LEAVES AS { error, code }. The procedures' sentences are written for guests and
/// travel untouched as `error`; `code` is what the site switches on (<see cref="BookingRefusals"/>).
/// <see cref="PublicBookingErrorFilter"/> does that mapping for the whole controller, and never lets
/// an exception's own text out.
///
/// NOTHING HERE QUEUES A NOTIFICATION. booking.trg_Booking_Notify queues the request, the staff
/// alert, the confirmation and the cancellation inside the transaction that changed the row.
///
/// ONLINE DEPOSITS (step 2): /{ref}/pay opens a gateway checkout session for the booking's deposit,
/// /verify is the gateway's return trip and the ONE action the access gate lets through without an
/// origin or key (<see cref="GatewayReturnAttribute"/>), and /{ref}/release asks the gateway before
/// giving back a slot whose payment was opened. All three settle through
/// <see cref="IOnlineDepositService"/>, the same path as the reconciliation job.
/// </summary>
[ApiController]
[Route("api/public/booking")]
[AllowAnonymous]
[EnableCors(BookingCorsPolicy)]
[PublicBookingAccess]
[PublicBookingErrorFilter]
public partial class PublicBookingController : ControllerBase
{
    /// <summary>The CORS policy built per request from core.SETTING BookingCorsOrigins (<see cref="PublicBookingCorsPolicyProvider"/>).</summary>
    public const string BookingCorsPolicy = "PublicBooking";

    /// <summary>30/minute per IP. Sized for a visitor clicking through a month of a calendar, not for a scraper.</summary>
    public const string ReadRateLimitPolicy = "public-booking-read";

    /// <summary>5/minute per IP. Nobody books five rooms in a minute by hand.</summary>
    public const string WriteRateLimitPolicy = "public-booking-write";

    /// <summary>Said in every response. The IANA name — browsers read IANA, not Windows registry keys.</summary>
    private const string TimeZoneName = BeirutTime.IanaId;

    private const string RefPattern = "regex(^MC-[[A-Z0-9]]{{8}}$)";

    private readonly IBookingService _bookings;
    private readonly IRoomService _rooms;

    /// <summary>
    /// Tells /hubs/booking after each committed change. Optional so the controller can still be built
    /// from its two services alone (the unit tests do); the container always supplies it.
    /// </summary>
    private readonly IBookingLivePublisher? _live;

    /// <summary>Online deposits. Optional for the same reason as <see cref="_live"/>; the container always supplies it.</summary>
    private readonly IOnlineDepositService? _deposits;

    private readonly ILogger<PublicBookingController>? _log;

    public PublicBookingController(IBookingService bookings, IRoomService rooms, IBookingLivePublisher? live = null,
        IOnlineDepositService? deposits = null, ILogger<PublicBookingController>? log = null)
    {
        _bookings = bookings;
        _rooms = rooms;
        _live = live;
        _deposits = deposits;
        _log = log;
    }

    private IOnlineDepositService Deposits
        => _deposits ?? throw new InvalidOperationException("Online deposits are not registered.");

    /* ---- 1. catalog ------------------------------------------------------------------------ */

    /// <summary>Everything the wizard needs to draw itself. Cached a minute at the browser: it says what CAN be booked, not what still IS free.</summary>
    [HttpGet("catalog")]
    [EnableRateLimiting(ReadRateLimitPolicy)]
    public async Task<IActionResult> GetCatalog()
    {
        var catalog = await _rooms.GetPublicCatalogAsync();

        Response.Headers.CacheControl = "public, max-age=60";

        return Ok(new
        {
            timeZone = TimeZoneName,
            rooms = catalog.Rooms.Select(room => new
            {
                code = room.Code,
                name = room.Name,
                nameAr = room.NameAr,
                seats = room.Seats,
                minPersons = room.MinPersons,
                pricePerHour = room.PricePerHour,
                currency = room.CurrencyCode,
                description = room.Description,
                features = room.Features,
                policyText = room.PolicyText,
                photoKey = room.PhotoKey,
                sortOrder = room.SortOrder,
                minHours = room.MinHours,
                maxHours = room.MaxHours,
                hours = room.Hours.Select(h => new { dayOfWeek = (int)h.DayOfWeek, openMin = h.OpenMin, closeMin = h.CloseMin, isClosed = h.IsClosed }),
                addons = room.Addons.Select(a => new { id = a.AddonId, name = a.Name, priceType = a.PriceType, price = a.Price }),
                discounts = room.Discounts.Select(d => new { minHours = d.MinHours, percent = d.DiscountPercent, discountPercent = d.DiscountPercent }),
            }),
            depositTiers = catalog.DepositTiers.Select(t => new { minLeadHours = t.MinLeadHours, depositPercent = t.DepositPercent }),
            rules = new
            {
                slotMinutes = catalog.Rules.SlotMinutes,
                minHours = catalog.Rules.MinHours,
                maxHours = catalog.Rules.MaxHours,
                leadMinHours = catalog.Rules.LeadMinHours,
                leadMaxDays = catalog.Rules.LeadMaxDays,
                holdMinutes = catalog.Rules.HoldMinutes,
                depositFloor = catalog.Rules.DepositFloor,
                depositRequired = catalog.Rules.DepositRequired,
                currency = catalog.Rules.Currency,
                cancelHours = catalog.Rules.CancelHours,
                turnaroundMinutes = catalog.Rules.TurnaroundMinutes,
                localNow = BeirutTime.At(catalog.Rules.LocalNow),
                websiteEnabled = catalog.Rules.WebsiteEnabled,
            },
        });
    }

    /* ---- 2. availability -------------------------------------------------------------------- */

    /// <summary>
    /// One room on one date: the frame, every stretch already taken, what is left, and the earliest
    /// start the lead time allows. NOT CACHED — this is the one answer that goes stale in seconds.
    /// Bookings and staff blocks are indistinguishable here, deliberately.
    /// </summary>
    [HttpGet("availability")]
    [EnableRateLimiting(ReadRateLimitPolicy)]
    public async Task<IActionResult> GetAvailability([FromQuery] string? room, [FromQuery] string? date)
    {
        if (string.IsNullOrWhiteSpace(room))
            return Invalid("Say which room.", "room");

        if (!TryParseDate(date, out var onDate))
            return Invalid("date must look like '2026-09-08'.", "date");

        var day = await _rooms.GetPublicDayAsync(room.Trim(), onDate);
        if (day is null)
            return Unknown("No such room.");

        Response.Headers.CacheControl = "no-store";

        return Ok(new
        {
            timeZone = TimeZoneName,
            room = day.RoomCode,
            date = day.OnDate.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
            isClosed = day.IsClosed,
            openMin = day.OpenMin,
            closeMin = day.CloseMin,
            slotMinutes = day.SlotMinutes,
            minHours = day.MinHours,
            maxHours = day.MaxHours,
            turnaroundMinutes = day.TurnaroundMinutes,
            localNow = BeirutTime.At(day.LocalNow),
            earliestStartMin = day.EarliestStartMin,
            taken = day.Taken.Select(t => new { startMin = t.StartMin, endMin = t.EndMin }),
            free = day.Free.Select(f => new { startMin = f.StartMin, endMin = f.EndMin }),
        });
    }

    /// <summary>A month of one room reduced to one word per day. Cached a minute: a calendar chooses a DAY; the slots are then fetched live.</summary>
    [HttpGet("availability/month")]
    [EnableRateLimiting(ReadRateLimitPolicy)]
    public async Task<IActionResult> GetAvailabilityMonth([FromQuery] string? room, [FromQuery] string? month)
    {
        if (string.IsNullOrWhiteSpace(room))
            return Invalid("Say which room.", "room");

        if (!TryParseMonth(month, out var monthDate))
            return Invalid("month must look like '2026-09'.", "month");

        var result = await _rooms.GetPublicMonthAsync(room.Trim(), monthDate);
        if (result is null)
            return Unknown("No such room.");

        Response.Headers.CacheControl = "public, max-age=60";

        return Ok(new
        {
            timeZone = TimeZoneName,
            room = result.RoomCode,
            month = result.Month,
            days = result.Days.Select(d => new { date = d.Date.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture), status = d.Status }),
        });
    }

    /* ---- 3. quote --------------------------------------------------------------------------- */

    /// <summary>
    /// Prices a slot without taking it. A POST because it has a body, not because it changes
    /// anything — so it sits on the READ rate limit: the wizard re-quotes on every change of mind.
    /// </summary>
    [HttpPost("quote")]
    [PausesWithWebsite]
    [EnableRateLimiting(ReadRateLimitPolicy)]
    public async Task<IActionResult> Quote([FromBody] PublicQuoteRequest request)
    {
        if (PublicBookingRules.Validate(request) is { } problem)
            return Invalid(problem);

        request.RoomCode = request.RoomCode.Trim();

        var quote = await _bookings.QuoteAsync(request);
        if (quote is null)
            return Invalid("That slot could not be priced.");

        return Ok(new
        {
            timeZone = TimeZoneName,
            roomCode = quote.RoomCode,
            roomName = quote.RoomName,
            hours = quote.Hours,
            pricePerHour = quote.PricePerHour,
            roomGross = quote.RoomGross,
            discountPercent = quote.DiscountPercent,
            discountFromHours = quote.DiscountFromHours,
            discountAmount = quote.DiscountAmount,
            roomTotal = quote.RoomTotal,
            addonTotal = quote.AddonTotal,
            total = quote.TotalAmount,
            depositPercent = quote.DepositPercent,
            deposit = quote.DepositDue,
            currency = quote.CurrencyCode,
            depositRequired = quote.DepositRequired,
        });
    }

    /* ---- 4. create -------------------------------------------------------------------------- */

    /// <summary>
    /// Takes a booking. The row is written Pending and its slot is taken from that moment. In step 1
    /// the hold has NO EXPIRY (holdExpiresUtc/expiresAt are null): a website booking is a request a
    /// human confirms. NOTHING IS PRE-CHECKED AGAINST AVAILABILITY — the overlap test lives inside
    /// the procedure's transaction, and the loser of a race gets 409 slot_taken.
    /// </summary>
    [HttpPost]
    [PausesWithWebsite]
    [EnableRateLimiting(WriteRateLimitPolicy)]
    public async Task<IActionResult> Create([FromBody] PublicBookingRequest request)
    {
        if (PublicBookingRules.Validate(request) is { } problem)
            return Invalid(problem);

        PublicBookingRules.Normalize(request);

        var created = await _bookings.CreateFromWebsiteAsync(request);
        if (created is null)
            return Invalid("The booking could not be taken. Please try again.");

        // the staff calendar hears about the request the moment it exists
        if (_live is not null) await _live.PublishAsync(created.BookingRef);

        var depositRequired = await _bookings.IsDepositRequiredAsync();

        return StatusCode(StatusCodes.Status201Created, new
        {
            timeZone = TimeZoneName,
            @ref = created.BookingRef,
            status = created.Status,
            date = request.Date.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
            startMin = request.StartMin,
            endMin = request.EndMin,
            startAt = BeirutTime.At(request.Date, request.StartMin),
            endAt = BeirutTime.At(request.Date, request.EndMin),
            total = created.TotalAmount,
            deposit = created.DepositDue,
            depositPercent = created.DepositPercent,
            discountPercent = created.DiscountPercent,
            discountAmount = created.DiscountAmount,
            currency = created.CurrencyCode,
            hours = created.Hours,
            roomName = created.RoomName,
            depositRequired,
            holdExpiresUtc = (DateTime?)null,
            expiresAt = (DateTimeOffset?)null,
        });
    }

    /* ---- 5. by reference -------------------------------------------------------------------- */

    /// <summary>
    /// The confirmation page's recap. THE REFERENCE IS THE ONLY CREDENTIAL, so the answer is written
    /// for the possibility that the wrong person holds it: no phone, no email, no gateway id, the
    /// name cut to "First L." (the service projects; see <see cref="BookingService.ToRecap"/>).
    /// </summary>
    [HttpGet("{bookingRef:" + RefPattern + "}")]
    [EnableRateLimiting(ReadRateLimitPolicy)]
    public async Task<IActionResult> GetByRef(string bookingRef)
    {
        var recap = await _bookings.GetPublicRecapAsync(bookingRef.ToUpperInvariant());
        return recap is null ? Unknown("No booking with that reference.") : Recap(recap);
    }

    /// <summary>
    /// Gives the slot back when a payment failed or was abandoned. Safe to expose to a caller holding
    /// only a reference: the procedure touches only a Pending WEBSITE booking that HAS an expiry and
    /// has taken no money, and echoes the status either way.
    ///
    /// WHEN A PAYMENT WAS OPENED FOR IT, THE GATEWAY IS ASKED FIRST (the same settlement as /verify):
    /// paid → the booking is confirmed instead; nothing attempted or failed → released; cannot tell →
    /// NOT released (the hold stays until the reconciliation job knows). The answer is the status
    /// either way, so the site reads the truth rather than assuming its request was obeyed.
    /// </summary>
    [HttpPost("{bookingRef:" + RefPattern + "}/release")]
    [EnableRateLimiting(WriteRateLimitPolicy)]
    public async Task<IActionResult> Release(string bookingRef)
    {
        var reference = bookingRef.ToUpperInvariant();

        if (_deposits is null)
        {
            var released = await _bookings.ReleaseHoldAsync(reference);
            if (released is null)
                return Unknown("No booking with that reference.");

            if (_live is not null) await _live.PublishAsync(released.BookingRef);
            return Ok(new { timeZone = TimeZoneName, @ref = released.BookingRef, status = released.Status });
        }

        var settled = await _deposits.SettleAsync(reference, SettleTrigger.GuestRelease);
        if (settled.Result == SettlementResult.UnknownBooking)
            return Unknown("No booking with that reference.");

        if (_live is not null) await _live.PublishAsync(settled.BookingRef);
        return Ok(new { timeZone = TimeZoneName, @ref = settled.BookingRef, status = settled.Status });
    }

    /// <summary>
    /// The guest cancels their own booking, proving the phone number it was made with (last 8 digits
    /// must match — SQL 79). Too late is 409 cancel_window and the booking stands; already closed is
    /// 409 not_cancellable and the page should re-read itself. Answers with the recap re-read after
    /// the cancellation (ref, status, refundAmount, refundStatus and the rest).
    /// </summary>
    [HttpPost("{bookingRef:" + RefPattern + "}/cancel")]
    [EnableRateLimiting(WriteRateLimitPolicy)]
    public async Task<IActionResult> Cancel(string bookingRef, [FromBody(EmptyBodyBehavior = EmptyBodyBehavior.Allow)] PublicCancelRequest? body)
    {
        var phone = body?.Phone?.Trim();
        if (string.IsNullOrEmpty(phone))
            return Invalid("Enter the phone number the booking was made with.", "phone");

        var recap = await _bookings.CancelByGuestAsync(bookingRef.ToUpperInvariant(), phone);
        if (recap is null)
            return Unknown("No booking with that reference.");

        if (_live is not null) await _live.PublishAsync(recap.Ref);
        return Recap(recap);
    }

    /* ---- 6. online deposit (step 2) --------------------------------------------------------- */

    /// <summary>
    /// Opens a gateway checkout session for the booking's DEPOSIT — the amount priced when the booking
    /// was taken (the same arithmetic as /quote), never anything from the request, which has no body.
    /// Valid only for a Pending website booking whose hold has not run out; stamps the hold
    /// (now + BookingHoldMinutes) and PaymentOpenedUtc in one transaction, then asks the gateway.
    /// The site then sends the guest to /pay/#session={sessionId}.
    ///
    /// CALLING IT TWICE IS SAFE: a new session on the same order (the order id is the reference). If
    /// an earlier session on it was already paid, the payment is recorded and the answer is 409
    /// already_paid; if the gateway cannot yet say, 409 payment_unconfirmed — a second payment could
    /// be a double charge.
    ///
    /// Refusals: 404 not_found, 409 not_pending, 409 hold_expired, 409 already_paid, 409 nothing_due,
    /// 409 payment_unconfirmed, 502 gateway_error, 503 paused, 401 unauthorized, 429.
    /// </summary>
    [HttpPost("{bookingRef:" + RefPattern + "}/pay")]
    [PausesWithWebsite]
    [EnableRateLimiting(WriteRateLimitPolicy)]
    public async Task<IActionResult> Pay(string bookingRef)
    {
        var opening = await Deposits.OpenAsync(bookingRef.ToUpperInvariant());

        if (opening.Changed && _live is not null) await _live.PublishAsync(opening.BookingRef);

        return opening.Result switch
        {
            PayOpenResult.Opened => Ok(new
            {
                timeZone = TimeZoneName,
                sessionId = opening.SessionId,
                @ref = opening.BookingRef,
                deposit = opening.Deposit,
                currency = opening.Currency,
                holdExpiresUtc = opening.HoldExpiresUtc is { } utc ? DateTime.SpecifyKind(utc, DateTimeKind.Utc) : (DateTime?)null,
                expiresAt = opening.HoldExpiresUtc is { } hold ? BeirutTime.FromUtc(hold) : (DateTimeOffset?)null,
            }),
            PayOpenResult.AlreadyPaid => Conflict(new
            {
                error = "This booking has already been paid.",
                code = "already_paid",
                @ref = opening.BookingRef,
                timeZone = TimeZoneName,
            }),
            PayOpenResult.PreviousUnconfirmed => Conflict(new
            {
                error = "We are still confirming an earlier payment for this booking. Please do not pay again; we will be in touch, or WhatsApp us.",
                code = "payment_unconfirmed",
                @ref = opening.BookingRef,
                timeZone = TimeZoneName,
            }),
            PayOpenResult.GatewayError => StatusCode(StatusCodes.Status502BadGateway, new
            {
                error = "We could not start the payment step. Try again, or book over WhatsApp.",
                code = "gateway_error",
                timeZone = TimeZoneName,
            }),
            _ => Unknown("No booking with that reference."),
        };
    }

    /// <summary>
    /// THE GATEWAY'S RETURN TRIP (its returnUrl, {API_PUBLIC_URL}/api/public/booking/verify?ref=). In
    /// production that is https://mokanco.com.lb/api/public/booking/verify?ref={ref}: the SAME origin as
    /// the site, whose nginx vhost proxies /api here — there is no api. host. A top-level browser
    /// redirect: no Origin, no key —
    /// hence <see cref="GatewayReturnAttribute"/>; the controller's [AllowAnonymous] keeps the
    /// authorization fallback away. The query string is not trusted for anything but the reference:
    /// the outcome comes from RETRIEVE_ORDER, asked server-side, through the decision table.
    ///
    ///   paid         → 302 {site}/reservations/confirmed/?ref=
    ///   failed       → the hold is released, 302 {site}/reservations/?payment=failed
    ///                  (also: an unknown reference, or one no payment was ever opened for — nothing written)
    ///   anything else (unconfirmed, paid-but-needs-staff, an error here)
    ///                → the hold is kept, 302 {site}/reservations/?payment=unconfirmed&amp;ref=
    ///
    /// IDEMPOTENT: a refresh, a double return or a return after the job has already settled it finds
    /// the payment line and redirects the same way without writing anything.
    /// </summary>
    [HttpGet("verify")]
    [GatewayReturn]
    [EnableRateLimiting(ReadRateLimitPolicy)]
    public async Task<IActionResult> Verify([FromQuery(Name = "ref")] string? reference)
    {
        var gateway = Deposits.Gateway;
        Response.Headers.CacheControl = "no-store";

        var bookingRef = (reference ?? string.Empty).Trim().ToUpperInvariant();
        if (!ReferenceShape().IsMatch(bookingRef))
            return Redirect(gateway.FailedUrl());

        Settlement settled;
        try
        {
            // Not the request's token: a guest closing the tab must not abandon a half-recorded payment.
            settled = await Deposits.SettleAsync(bookingRef, SettleTrigger.GatewayReturn);
        }
        catch (Exception ex)
        {
            _log?.LogError(ex, "Verify {Ref}: settlement failed; the guest is sent to the unconfirmed page.", bookingRef);
            return Redirect(gateway.UnconfirmedUrl(bookingRef));
        }

        if (settled.Changed && _live is not null) await _live.PublishAsync(bookingRef);

        return settled.Result switch
        {
            SettlementResult.Paid => Redirect(gateway.ConfirmedUrl(bookingRef)),
            // Nothing was charged: the gateway said so, or no payment was ever opened for this reference.
            SettlementResult.Released or SettlementResult.Failed or SettlementResult.UnknownBooking or SettlementResult.NotApplicable
                => Redirect(gateway.FailedUrl()),
            _ => Redirect(gateway.UnconfirmedUrl(bookingRef)),
        };
    }

    [System.Text.RegularExpressions.GeneratedRegex("^MC-[A-Z0-9]{8}$")]
    private static partial System.Text.RegularExpressions.Regex ReferenceShape();

    /* ---- shapes ----------------------------------------------------------------------------- */

    /// <summary>The recap, in ONE place, because two endpoints answer with it: reading a booking and cancelling one.</summary>
    private IActionResult Recap(PublicBookingRecap booking)
        => Ok(new
        {
            timeZone = TimeZoneName,
            @ref = booking.Ref,
            status = booking.Status,
            roomCode = booking.RoomCode,
            roomName = booking.RoomName,
            date = booking.Date.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
            startMin = booking.StartMin,
            endMin = booking.EndMin,
            vacateByMin = booking.VacateByMin,
            turnaroundMinutes = booking.TurnaroundMinutes,
            startAt = BeirutTime.At(booking.Date, booking.StartMin),
            endAt = BeirutTime.At(booking.Date, booking.EndMin),
            hours = booking.Hours,
            persons = booking.Persons,
            guestName = booking.GuestName,
            total = booking.Total,
            discountPercent = booking.DiscountPercent,
            discountAmount = booking.DiscountAmount,
            deposit = booking.Deposit,
            paid = booking.Paid,
            balance = booking.Balance,
            refundAmount = booking.RefundAmount,
            refundStatus = booking.RefundStatus,
            cancelledBy = booking.CancelledBy,
            currency = booking.Currency,
            policyText = booking.PolicyText,
            canCancelOnline = booking.CanCancelOnline,
            cancelHours = booking.CancelHours,
            addons = booking.Addons.Select(a => new { name = a.Name, amount = a.Amount }),
        });

    private IActionResult Invalid(PublicBookingRules.Problem problem)
        => Invalid(problem.Error, problem.Field);

    /// <summary>A refusal the caller could have avoided. `field` names the box when the message is about one, so the site can print it there.</summary>
    private IActionResult Invalid(string error, string? field = null)
        => BadRequest(new { error, code = BookingRefusals.InvalidInput, field, timeZone = TimeZoneName });

    private IActionResult Unknown(string error)
        => NotFound(new { error, code = BookingRefusals.NotFound, timeZone = TimeZoneName });

    /// <summary>'2026-09-08' only. A date is parsed by its own shape, never by the server's culture.</summary>
    private static bool TryParseDate(string? value, out DateTime date)
        => DateTime.TryParseExact(value, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out date);

    /// <summary>'2026-09' → the first of that month. A month is not a date and parsing it as one invites a silent off-by-one.</summary>
    private static bool TryParseMonth(string? value, out DateTime monthDate)
        => DateTime.TryParseExact(value, "yyyy-MM", CultureInfo.InvariantCulture, DateTimeStyles.None, out monthDate);
}
