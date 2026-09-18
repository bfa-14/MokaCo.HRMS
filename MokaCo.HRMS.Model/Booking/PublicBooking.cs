namespace MokaCo.HRMS.Model.Booking;

/// <summary>
/// One bookable room as the website receives it (booking.usp_Public_GetCatalog, first result set),
/// with its week, its add-ons and its hour-discount ladder hung off it.
///
/// NESTED HERE AND FLAT IN THE PROCEDURE, on purpose. The procedure returns six parallel sets keyed
/// by RoomId; the website reads one room at a time and would immediately have to index the others
/// by hand, so RoomService does that join once, here.
///
/// MinHours/MaxHours ARE ALREADY RESOLVED: the room's own value if it has one, the core.SETTING
/// default if it does not. The procedure applies that fallback, so a null never reaches the site.
/// </summary>
public class PublicRoom
{
    public int RoomId { get; set; }

    /// <summary>The website's id for the room — r1, r2, r3, pod. Matches the ids in the site's rooms.json.</summary>
    public string Code { get; set; } = string.Empty;

    public string Name { get; set; } = string.Empty;
    public string? NameAr { get; set; }

    public int Seats { get; set; }
    public int MinPersons { get; set; }

    public decimal PricePerHour { get; set; }
    public string CurrencyCode { get; set; } = string.Empty;

    public string? Description { get; set; }
    public string? Features { get; set; }
    public string? PolicyText { get; set; }
    public string? PhotoKey { get; set; }
    public int SortOrder { get; set; }

    public int MinHours { get; set; }
    public int MaxHours { get; set; }

    public List<PublicRoomHours> Hours { get; set; } = [];
    public List<PublicRoomAddon> Addons { get; set; } = [];

    /// <summary>
    /// This room's ladder, RESOLVED: its own rungs where it has any, the café's defaults where it
    /// has none — the same all-or-nothing rule booking.fn_PriceQuote applies, so the sentence the
    /// site prints and the price the server charges cannot disagree.
    /// </summary>
    public List<PublicRoomDiscount> Discounts { get; set; } = [];
}

/// <summary>"From N hours, X% off the room." No id and no room: the site prints a sentence, it prices nothing.</summary>
public class PublicRoomDiscount
{
    public decimal MinHours { get; set; }
    public decimal DiscountPercent { get; set; }
}

/// <summary>
/// One weekday's opening hours IN MINUTES FROM MIDNIGHT (booking.ROOM_HOURS.OpenMin/CloseMin).
///
/// DayOfWeek IS 1=MONDAY..7=SUNDAY, computed in SQL so it does not move with DATEFIRST. CloseMin
/// MAY EXCEED 1440: the café closes at 01:00, which is 1500 — the whole reason these are minutes
/// rather than times.
/// </summary>
public class PublicRoomHours
{
    public int RoomId { get; set; }
    public string RoomCode { get; set; } = string.Empty;
    public byte DayOfWeek { get; set; }
    public int OpenMin { get; set; }
    public int CloseMin { get; set; }
    public bool IsClosed { get; set; }
}

/// <summary>A paid extra offered with one room. ACTIVE ONES ONLY reach the website — the procedure filters.</summary>
public class PublicRoomAddon
{
    public int AddonId { get; set; }
    public int RoomId { get; set; }
    public string RoomCode { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;

    /// <summary>'PerHour' or 'Fixed'.</summary>
    public string PriceType { get; set; } = string.Empty;

    public decimal Price { get; set; }
}

/// <summary>One rung of the deposit ladder (booking.DEPOSIT_TIER): book at least this many hours ahead and this is the percentage due.</summary>
public class DepositTier
{
    public int MinLeadHours { get; set; }
    public decimal DepositPercent { get; set; }
}

/// <summary>
/// The booking rules as one object — every core.SETTING the wizard needs to draw itself
/// (booking.usp_Public_GetCatalog, fifth result set).
/// </summary>
public class BookingRules
{
    public int SlotMinutes { get; set; }
    public int MinHours { get; set; }
    public int MaxHours { get; set; }
    public int LeadMinHours { get; set; }
    public int LeadMaxDays { get; set; }
    public int HoldMinutes { get; set; }
    public decimal DepositFloor { get; set; }
    public bool DepositRequired { get; set; }
    public string Currency { get; set; } = string.Empty;
    public int CancelHours { get; set; }

    /// <summary>Information, not a rule: the minutes at the end of a booking the guest is asked to be leaving in. Nothing is shortened by it.</summary>
    public int TurnaroundMinutes { get; set; }

    /// <summary>Café-local wall clock from booking.fn_LocalNow(). The site computes "today" from THIS, never from the visitor's device.</summary>
    public DateTime LocalNow { get; set; }

    /// <summary>core.SETTING BookingWebsiteEnabled. False = the site shows its WhatsApp fallback.</summary>
    public bool WebsiteEnabled { get; set; } = true;
}

/// <summary>The six result sets of booking.usp_Public_GetCatalog, exactly as they arrive. RoomService hangs the flat lists off their rooms.</summary>
public class PublicCatalogSets
{
    public List<PublicRoom> Rooms { get; set; } = [];
    public List<PublicRoomHours> Hours { get; set; } = [];
    public List<PublicRoomAddon> Addons { get; set; } = [];
    public List<DepositTier> Tiers { get; set; } = [];
    public BookingRules Rules { get; set; } = new();
    public List<CatalogRoomDiscount> Discounts { get; set; } = [];
}

/// <summary>One row of the catalogue's discount set. RoomId NULL = the default ladder.</summary>
public class CatalogRoomDiscount
{
    public int? RoomId { get; set; }
    public string? RoomCode { get; set; }
    public decimal MinHours { get; set; }
    public decimal DiscountPercent { get; set; }
}

/// <summary>Everything the website needs to render the booking wizard, in ONE call.</summary>
public class PublicCatalog
{
    public List<PublicRoom> Rooms { get; set; } = [];
    public List<DepositTier> DepositTiers { get; set; } = [];
    public BookingRules Rules { get; set; } = new();
}

/// <summary>
/// What booking.usp_Booking_Quote returns: the price of a slot and the deposit due on it, WITHOUT
/// taking it. THE SERVER PRICES, THE SITE DISPLAYS — every number on the summary rail comes from here.
/// </summary>
public class BookingQuote
{
    public int RoomId { get; set; }
    public string RoomCode { get; set; } = string.Empty;
    public string RoomName { get; set; } = string.Empty;
    public decimal Hours { get; set; }
    public decimal PricePerHour { get; set; }

    /// <summary>The room before any discount: price per hour times hours.</summary>
    public decimal RoomGross { get; set; }

    public decimal DiscountPercent { get; set; }
    public decimal DiscountFromHours { get; set; }
    public decimal DiscountAmount { get; set; }

    /// <summary>RoomGross less DiscountAmount. Add-ons are not in it and are never discounted.</summary>
    public decimal RoomTotal { get; set; }

    public decimal AddonTotal { get; set; }
    public decimal TotalAmount { get; set; }
    public decimal DepositPercent { get; set; }
    public decimal DepositDue { get; set; }
    public string CurrencyCode { get; set; } = string.Empty;
    public DateTime LocalNow { get; set; }
    public bool DepositRequired { get; set; }
}

/// <summary>
/// booking.usp_Booking_GetByRef's header row, IN FULL — guest contact details and gateway ids
/// included.
///
/// THIS TYPE IS NOT A PUBLIC HTTP RESPONSE and must never be returned as one. What a guest may see
/// is <see cref="PublicBookingRecap"/>, which BookingService projects; the projection lives in the
/// service so that a new endpoint cannot leak a phone number by forgetting to project.
/// </summary>
public class BookingRefDetail
{
    public int BookingId { get; set; }
    public string BookingRef { get; set; } = string.Empty;

    public DateTime BookDate { get; set; }
    public TimeSpan StartTime { get; set; }
    public TimeSpan EndTime { get; set; }
    public int StartMin { get; set; }
    public int EndMin { get; set; }
    public decimal Hours { get; set; }

    /// <summary>EndMin less core.SETTING BookingTurnaroundMinutes, as the procedure computes it.</summary>
    public int VacateByMin { get; set; }

    public int TurnaroundMinutes { get; set; }

    public int Persons { get; set; }
    public string GuestName { get; set; } = string.Empty;
    public string GuestPhone { get; set; } = string.Empty;
    public string? GuestEmail { get; set; }
    public string? Note { get; set; }

    public decimal TotalAmount { get; set; }
    public decimal DepositDue { get; set; }
    public decimal DepositPercent { get; set; }
    public decimal DiscountPercent { get; set; }
    public decimal DiscountAmount { get; set; }
    public string CurrencyCode { get; set; } = string.Empty;

    public string Status { get; set; } = string.Empty;
    public string Source { get; set; } = string.Empty;

    public string? CancelReason { get; set; }
    public string? CancelledBy { get; set; }
    public decimal RefundAmount { get; set; }
    public string? RefundStatus { get; set; }
    public DateTime? RefundedUtc { get; set; }

    public DateTime? HoldExpiresUtc { get; set; }
    public string? GatewayOrderId { get; set; }
    public string? GatewaySessionId { get; set; }
    public DateTime? PaidConfirmedUtc { get; set; }
    public DateTime CreatedUtc { get; set; }

    public string RoomCode { get; set; } = string.Empty;
    public string RoomName { get; set; } = string.Empty;
    public string? PolicyText { get; set; }
    public decimal PricePerHour { get; set; }

    /// <summary>Net of refunds — refund lines are negative rows in the same table.</summary>
    public decimal PaidAmount { get; set; }

    /// <summary>What has gone back so far, positive.</summary>
    public decimal RefundedAmount { get; set; }

    public decimal BalanceDue { get; set; }

    public bool CanCancelOnline { get; set; }
    public int CancelHours { get; set; }

    public List<BookingRefAddon> Addons { get; set; } = [];
}

/// <summary>One add-on line AS CHARGED (booking.BOOKING_ADDON).</summary>
public class BookingRefAddon
{
    public string Name { get; set; } = string.Empty;
    public decimal Amount { get; set; }
}

/// <summary>
/// The confirmation page's recap — the whole of what an anonymous holder of a booking reference is
/// told. No phone, no email, no note, no gateway id; the guest's name is cut to "Rami H.".
/// </summary>
public class PublicBookingRecap
{
    public string Ref { get; set; } = string.Empty;
    public string Status { get; set; } = string.Empty;
    public string RoomCode { get; set; } = string.Empty;
    public string RoomName { get; set; } = string.Empty;

    public DateTime Date { get; set; }
    public int StartMin { get; set; }
    public int EndMin { get; set; }
    public int VacateByMin { get; set; }
    public int TurnaroundMinutes { get; set; }
    public decimal Hours { get; set; }
    public int Persons { get; set; }

    /// <summary>"Rami H." — enough to recognise, not enough to identify.</summary>
    public string GuestName { get; set; } = string.Empty;

    public decimal Total { get; set; }
    public decimal DiscountPercent { get; set; }
    public decimal DiscountAmount { get; set; }
    public decimal Deposit { get; set; }
    public decimal Paid { get; set; }
    public decimal Balance { get; set; }
    public decimal RefundAmount { get; set; }
    public string? RefundStatus { get; set; }
    public string? CancelledBy { get; set; }
    public string Currency { get; set; } = string.Empty;
    public string? PolicyText { get; set; }

    public bool CanCancelOnline { get; set; }
    public int CancelHours { get; set; }

    public List<BookingRefAddon> Addons { get; set; } = [];
}

/// <summary>The echo from booking.usp_Booking_ReleaseHold — the reference and where it ended up. Unchanged when there was no hold to release.</summary>
public class BookingHoldReleased
{
    public string BookingRef { get; set; } = string.Empty;
    public string Status { get; set; } = string.Empty;
}

/// <summary>
/// A staff-side booking with its money lines: GET /api/bookings/{id}, and what PUT status answers
/// with. Built from usp_Booking_GetByRef (the row) and usp_Booking_GetReceipt (the payments).
/// </summary>
public class BookingStaffDetail
{
    public BookingRefDetail Booking { get; set; } = new();
    public List<ReceiptPayment> Payments { get; set; } = [];
}
