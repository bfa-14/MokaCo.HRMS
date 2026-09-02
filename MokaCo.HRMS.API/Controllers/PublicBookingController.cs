using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Cors;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.RateLimiting;
using Microsoft.Data.SqlClient;
using MokaCo.HRMS.Model.Booking;
using MokaCo.HRMS.Services.Booking;

namespace MokaCo.HRMS.Api.Controllers;

/// <summary>
/// The public booking API — the four calls the MokaCo website makes, and the only part of this
/// service reachable without a token.
///
/// WHAT ACTUALLY PROTECTS THIS, stated plainly rather than implied:
///   1. IT IS ALMOST ENTIRELY READ-ONLY. Three GETs over the room catalogue and its availability —
///      information the website publishes anyway — and exactly one write.
///   2. THE ONE WRITE CANNOT DO ANYTHING BUT BOOK. Source is nailed to 'Website' HERE, not taken
///      from the body, so a caller cannot post 'Manual' and skip the lead-time rules that only apply
///      to the public; CreatedByUserId is null, so nothing can be attributed to staff who never
///      touched it. Price, deposit and status are computed by the procedure and never accepted.
///   3. A RATE LIMIT PER IP, tighter on the write than the reads (see the two policies below).
///   4. CORS IS AN ALLOWLIST AND IS EMPTY BY DEFAULT (BookingCorsOrigins). A browser on an origin
///      nobody named cannot read these responses.
///
/// AND WHAT DOES NOT: there is no CAPTCHA and no proof of identity. Somebody determined, from enough
/// addresses, can fill a calendar with bookings for guests who do not exist. That is a real residual
/// risk and the mitigation is operational, not technical — bookings open Pending by default
/// (core.SETTING BookingAutoConfirm = 0) and a human confirms them.
///
/// THE PROCEDURES' REFUSALS ARE WRITTEN FOR GUESTS and are passed through as the 400's text,
/// untouched: "That time was just taken — pick another slot", "Mokha takes 2 to 8 persons",
/// "Online booking closes 2 hours before the start — call us instead". Summarising them here would
/// replace advice a visitor can act on with a generic apology.
/// </summary>
[ApiController]
[Route("api/public/booking")]
// EXPLICITLY public. Program.cs sets an authorization fallback that demands an authenticated user
// for any endpoint that does not say otherwise, and a website visitor has no account.
[AllowAnonymous]
[EnableCors(BookingCorsPolicy)]
public class PublicBookingController : ControllerBase
{
    /// <summary>The CORS policy registered in Program.cs from the BookingCorsOrigins setting. Named here so only this controller can opt into it.</summary>
    public const string BookingCorsPolicy = "PublicBooking";

    /// <summary>30/minute per IP. Sized for a visitor clicking through a month of a calendar, not for a scraper.</summary>
    public const string ReadRateLimitPolicy = "public-booking-read";

    /// <summary>5/minute per IP. Nobody books five rooms in a minute by hand; a script trying to is the case this exists for.</summary>
    public const string WriteRateLimitPolicy = "public-booking-write";

    /* Guest-supplied text is bounded HERE because the database will not object. A stored procedure
       parameter TRUNCATES an over-long string silently rather than raising, so without these a guest
       would be told their booking succeeded and find their name cut in half on the receipt. The
       limits match the procedure's own parameter widths. */
    private const int MaxGuestName = 120;
    private const int MaxGuestPhone = 30;
    private const int MaxGuestEmail = 150;
    private const int MaxNote = 500;

    private readonly IBookingService _bookings;
    private readonly IRoomService _rooms;

    public PublicBookingController(IBookingService bookings, IRoomService rooms)
    {
        _bookings = bookings;
        _rooms = rooms;
    }

    /// <summary>
    /// The bookable rooms, with their opening hours and their live add-on list.
    ///
    /// Active rooms only, and their ACTIVE add-ons only — the service trims that, because the
    /// procedure returns the hours and price list of every room in the table whatever it was asked
    /// for.
    /// </summary>
    [HttpGet("rooms")]
    [EnableRateLimiting(ReadRateLimitPolicy)]
    public async Task<IActionResult> GetRooms()
        => Ok(await _rooms.GetPublicCatalogAsync());

    /// <summary>
    /// The month heat map for one room: per day, minutes open against minutes taken.
    ///
    /// Any date inside the month works; the site sends the first. A day comes back closed with zero
    /// open minutes when the room has no hours for that weekday, which is what colours it grey
    /// rather than free.
    /// </summary>
    [HttpGet("rooms/{id:int}/month")]
    [EnableRateLimiting(ReadRateLimitPolicy)]
    public async Task<IActionResult> GetMonth(int id, [FromQuery] string month)
    {
        if (!TryParseMonth(month, out var monthDate))
            return BadRequest(new { error = "month must look like '2026-09'." });

        return Ok(await _rooms.GetMonthAsync(id, monthDate));
    }

    /// <summary>
    /// One room on one date: when it is open, and every stretch already taken.
    ///
    /// BOOKINGS AND STAFF BLOCKS ARE INDISTINGUISHABLE in this answer, deliberately — an anonymous
    /// caller learns that a slot is unavailable, not who has it or why.
    /// </summary>
    [HttpGet("rooms/{id:int}/day")]
    [EnableRateLimiting(ReadRateLimitPolicy)]
    public async Task<IActionResult> GetDay(int id, [FromQuery] DateTime date)
        => Ok(await _rooms.GetDayAsync(id, date));

    /// <summary>
    /// Takes a booking from the website and queues the guest's confirmation.
    ///
    /// NOTHING IS PRE-CHECKED AGAINST AVAILABILITY HERE. The overlap test lives inside the
    /// procedure's transaction under UPDLOCK/HOLDLOCK, and a check out here would run outside that
    /// lock — answering a question that is already stale by the time the row is written. Two guests
    /// racing for the same slot is the ordinary case, and the loser gets a sentence telling them to
    /// pick another.
    ///
    /// Returns { bookingId, totalAmount, depositDue, currencyCode, status }. STATUS IS NOT
    /// PREDICTABLE from the request — BookingAutoConfirm decides between Pending and Confirmed — so
    /// the confirmation page must render what came back rather than assuming.
    /// </summary>
    [HttpPost("bookings")]
    [EnableRateLimiting(WriteRateLimitPolicy)]
    public async Task<IActionResult> Create([FromBody] BookingCreateRequest request)
    {
        if (Validate(request) is { } problem)
            return BadRequest(new { error = problem });

        try
        {
            var created = await _bookings.CreateFromWebsiteAsync(request);
            if (created is null)
                return BadRequest(new { error = "The booking could not be taken. Please try again." });

            return Ok(created);
        }
        catch (SqlException ex) when (ex.Number == 50000)
        {
            // The procedure's own wording, written to be read by a guest. Passed through verbatim.
            return BadRequest(new { error = ex.Message });
        }
    }

    /// <summary>
    /// The handful of checks the database cannot make on the caller's behalf: the required text, and
    /// the lengths it would otherwise truncate. Everything else — the room, the hours, the person
    /// count, the lead time, the overlap — belongs to the procedure and is left there.
    /// </summary>
    private static string? Validate(BookingCreateRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.GuestName))
            return "Please give us a name for the booking.";

        if (string.IsNullOrWhiteSpace(request.GuestPhone))
            return "Please give us a phone number so we can reach you.";

        if (request.GuestName.Trim().Length > MaxGuestName)
            return $"The name is too long (max {MaxGuestName} characters).";

        if (request.GuestPhone.Trim().Length > MaxGuestPhone)
            return $"The phone number is too long (max {MaxGuestPhone} characters).";

        if (request.GuestEmail?.Trim().Length > MaxGuestEmail)
            return $"The email address is too long (max {MaxGuestEmail} characters).";

        if (request.Note?.Length > MaxNote)
            return $"The note is too long (max {MaxNote} characters).";

        if (request.EndTime <= request.StartTime)
            return "The end time must be after the start time.";

        return null;
    }

    /// <summary>'2026-09' → the first of that month. The same shape ReportsController accepts, for the same reason: a month is not a date and parsing it as one invites a silent off-by-one.</summary>
    private static bool TryParseMonth(string? value, out DateTime monthDate)
    {
        monthDate = default;
        return !string.IsNullOrEmpty(value)
            && value.Length == 7
            && DateTime.TryParse($"{value}-01", out monthDate);
    }
}
