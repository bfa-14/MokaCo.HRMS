using System.Globalization;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Cors;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.ModelBinding;
using Microsoft.AspNetCore.RateLimiting;
using MokaCo.HRMS.Api.PublicBooking;
using MokaCo.HRMS.Model.Booking;
using MokaCo.HRMS.Services.Booking;

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
/// </summary>
[ApiController]
[Route("api/public/booking")]
[AllowAnonymous]
[EnableCors(BookingCorsPolicy)]
[PublicBookingAccess]
[PublicBookingErrorFilter]
public class PublicBookingController : ControllerBase
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

    public PublicBookingController(IBookingService bookings, IRoomService rooms, IBookingLivePublisher? live = null)
    {
        _bookings = bookings;
        _rooms = rooms;
        _live = live;
    }

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
    /// </summary>
    [HttpPost("{bookingRef:" + RefPattern + "}/release")]
    [EnableRateLimiting(WriteRateLimitPolicy)]
    public async Task<IActionResult> Release(string bookingRef)
    {
        var released = await _bookings.ReleaseHoldAsync(bookingRef.ToUpperInvariant());
        if (released is null)
            return Unknown("No booking with that reference.");

        if (_live is not null) await _live.PublishAsync(released.BookingRef);
        return Ok(new { timeZone = TimeZoneName, @ref = released.BookingRef, status = released.Status });
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

    /// <summary>STEP 2: the gateway's return trip. The route exists now and answers 501 so the site can be written against the real URL.</summary>
    [HttpGet("verify")]
    [EnableRateLimiting(ReadRateLimitPolicy)]
    public IActionResult Verify([FromQuery] string? @ref)
        => StatusCode(StatusCodes.Status501NotImplemented, new
        {
            error = "Online payment is not switched on yet.",
            code = "not_implemented",
            timeZone = TimeZoneName,
        });

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
