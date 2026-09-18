namespace MokaCo.HRMS.Model.Booking;

/// <summary>
/// The body of both POST /api/public/booking/bookings and POST /api/bookings/manual.
///
/// ONE SHAPE FOR BOTH ON PURPOSE. They are the same act — booking.usp_Booking_Create is one
/// procedure — and the differences between a guest booking and a staff booking are not fields the
/// caller supplies: Source is decided by WHICH ENDPOINT was reached, and CreatedByUserId by who was
/// signed in. Neither appears here, because a public form that could post Source='Manual' would skip
/// the lead-time rules that only apply to the website, and one that could post CreatedByUserId would
/// be attributing bookings to staff who never touched them.
/// </summary>
public class BookingCreateRequest
{
    public int RoomId { get; set; }

    public DateTime BookDate { get; set; }

    /// <summary>Wire format 'HH:mm:ss' (or 'HH:mm') — the same TimeSpan convention the shift endpoints use.</summary>
    public TimeSpan StartTime { get; set; }

    public TimeSpan EndTime { get; set; }

    public int Persons { get; set; }

    public string GuestName { get; set; } = string.Empty;
    public string GuestPhone { get; set; } = string.Empty;

    /// <summary>Optional. No address simply means the confirmation cannot be emailed — it is not a refusal.</summary>
    public string? GuestEmail { get; set; }

    public string? Note { get; set; }

    /// <summary>
    /// Chosen add-ons, as ids. A LIST HERE, A COMMA-SEPARATED STRING AT THE PROCEDURE — the
    /// repository does that join, because the string is an artefact of STRING_SPLIT and has no
    /// business in an HTTP contract. Ids that are inactive, or belong to another room, are ignored
    /// by the procedure rather than refused.
    /// </summary>
    public List<int>? AddonIds { get; set; }
}

/// <summary>
/// PUT /api/bookings/{id}/status.
///
/// REASON IS OPTIONAL HERE AND MANDATORY FOR A CANCELLATION — the procedure enforces that, and the
/// enforcement is left there rather than duplicated as a null check in C#. One rule, one place: a
/// second copy in the controller is a second thing to forget when the rule changes.
/// </summary>
public class BookingStatusRequest
{
    /// <summary>Confirmed | Completed | Cancelled | NoShow. Anything else is refused by the procedure, by name.</summary>
    public string Status { get; set; } = string.Empty;

    /// <summary>The cancellation note. <see cref="Reason"/> is the older spelling the current web app sends; either is accepted.</summary>
    public string? Note { get; set; }

    public string? Reason { get; set; }

    /// <summary>
    /// 'Staff' (default) or 'Guest'. Who ASKED for the cancellation, which decides the refund:
    /// Guest = the guest rang and asked → refund minus the deposit; Staff = the café cancelled →
    /// everything paid goes back (booking.fn_RefundDue).
    /// </summary>
    public string CancelledBy { get; set; } = "Staff";

    /// <summary>Note first, then Reason — one string reaches the procedure whichever the client sent.</summary>
    public string? EffectiveNote => string.IsNullOrWhiteSpace(Note) ? Reason : Note;
}

/// <summary>
/// POST /api/bookings/{id}/refunds — one refund line against a cancelled booking (booking.usp_Refund_Add).
///
/// <see cref="Method"/> IS EITHER A PaymentMethodId OR A METHOD NAME ("Cash", "Card", "Whish",
/// "OMT"). The JSON may carry a number or a string; the service resolves a name through
/// usp_PaymentMethod_GetAll and says which it used. <see cref="PaymentMethodId"/> is accepted too,
/// for a client that already has the id.
/// </summary>
public class BookingRefundRequest
{
    /// <summary>Positive. The procedure refuses more than what was paid, naming what remains.</summary>
    public decimal Amount { get; set; }

    /// <summary>A PaymentMethodId (number) or a method name (string).</summary>
    public System.Text.Json.JsonElement? Method { get; set; }

    public int? PaymentMethodId { get; set; }

    /// <summary>The transfer or card slip number, when there is one. Optional.</summary>
    public string? Reference { get; set; }
}

/// <summary>POST /api/bookings/{id}/payments — one movement of money against one booking.</summary>
public class BookingPaymentRequest
{
    public int PaymentMethodId { get; set; }

    /// <summary>The procedure refuses an amount that would take the booking past its total, and says what remains.</summary>
    public decimal Amount { get; set; }

    /// <summary>Card slip, transfer number, whatever there is to write down. Optional.</summary>
    public string? Reference { get; set; }
}

/// <summary>POST /api/bookings/blocks — hold a room back for maintenance or a private event.</summary>
public class BlockCreateRequest
{
    public int RoomId { get; set; }
    public DateTime BlockDate { get; set; }
    public TimeSpan StartTime { get; set; }
    public TimeSpan EndTime { get; set; }

    /// <summary>Internal only. It never reaches the public availability feed.</summary>
    public string? Reason { get; set; }
}

/// <summary>
/// POST and PUT /api/bookings/rooms — booking.usp_Room_Upsert either way.
///
/// EVERY FIELD IS SENT ON AN EDIT, including the ones a screen did not change: the procedure UPDATEs
/// the whole row, so an omitted field is stored as its C# default, not left alone. That is the
/// procedure's contract and the reason this DTO carries the same defaults it does — a client that
/// posts a partial room gets a room with a 0% deposit, which is a bug worth being explicit about.
/// </summary>
public class RoomUpsertRequest
{
    public string Code { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    public string? NameAr { get; set; }

    public int Seats { get; set; }
    public int MinPersons { get; set; } = 1;

    public decimal PricePerHour { get; set; }
    public string CurrencyCode { get; set; } = "USD";
    public decimal DepositPercent { get; set; } = 50;

    /// <summary>Null = fall back to core.SETTING BookingMinHours.</summary>
    public int? MinHours { get; set; }

    /// <summary>Null = fall back to core.SETTING BookingMaxHours.</summary>
    public int? MaxHours { get; set; }

    public string? Description { get; set; }
    public string? Features { get; set; }
    public string? PolicyText { get; set; }
    public string? PhotoKey { get; set; }

    public int SortOrder { get; set; }
    public bool IsActive { get; set; } = true;
}

/// <summary>
/// One weekday's hours. PUT /api/bookings/rooms/{id}/hours takes a LIST of these.
///
/// booking.usp_Room_SetHours is a MERGE on one day, so the list is applied a row at a time. It takes
/// a list anyway because the screen that edits this is a seven-row week and saves as a week: seven
/// requests to store one edit would make a half-saved week a routine outcome of closing a laptop.
/// </summary>
public class RoomHoursRequest
{
    /// <summary>1 = Monday … 7 = Sunday. NOT System.DayOfWeek.</summary>
    public byte DayOfWeek { get; set; }

    public TimeSpan OpenTime { get; set; }
    public TimeSpan CloseTime { get; set; }

    /// <summary>Closed all day. The procedure skips the close-after-open check when this is set.</summary>
    public bool IsClosed { get; set; }
}

/// <summary>POST and PUT /api/bookings/rooms/{id}/addons — booking.usp_RoomAddon_Upsert.</summary>
public class RoomAddonUpsertRequest
{
    public string Name { get; set; } = string.Empty;

    /// <summary>'PerHour' or 'Fixed'. The procedure refuses anything else.</summary>
    public string PriceType { get; set; } = "PerHour";

    public decimal Price { get; set; }
    public bool IsActive { get; set; } = true;
}

/// <summary>
/// POST /api/public/booking/quote — price a slot without taking it. Times are MINUTES FROM MIDNIGHT
/// of <see cref="Date"/>; EndMin may exceed 1440 (01:00 next day = 1500).
/// </summary>
public class PublicQuoteRequest
{
    public string RoomCode { get; set; } = string.Empty;
    public DateTime Date { get; set; }
    public int StartMin { get; set; }
    public int EndMin { get; set; }
    public List<int>? AddonIds { get; set; }
}

/// <summary>
/// POST /api/public/booking — the website's booking. Source is NOT here: the repository nails it to
/// 'Website', so a caller cannot post 'Manual' and skip the lead-time rules.
/// </summary>
public class PublicBookingRequest
{
    public string RoomCode { get; set; } = string.Empty;
    public DateTime Date { get; set; }

    /// <summary>0..1439.</summary>
    public int StartMin { get; set; }

    /// <summary>Greater than StartMin, at most 1800. BUG-22: compared as minutes, never as a wrapped clock time.</summary>
    public int EndMin { get; set; }

    public int Persons { get; set; }
    public string Name { get; set; } = string.Empty;
    public string Phone { get; set; } = string.Empty;
    public string? Email { get; set; }
    public string? Notes { get; set; }
    public List<int>? AddonIds { get; set; }
}

/// <summary>POST /api/public/booking/{ref}/cancel — the phone number the booking was made with (last 8 digits must match).</summary>
public class PublicCancelRequest
{
    public string? Phone { get; set; }
}
