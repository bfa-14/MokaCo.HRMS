namespace MokaCo.HRMS.Model.Booking;

/// <summary>
/// One booking as the management calendar reads it: the booking.BOOKING row plus the room it is in
/// and the money that has actually arrived against it.
///
/// TOTALAMOUNT IS A SNAPSHOT, NOT A CALCULATION. It was worked out from the room's price and the
/// add-ons chosen at the moment of booking and then STORED. Re-pricing the room afterwards moves
/// nothing here, which is the only honest behaviour: the guest was quoted a number.
/// </summary>
public class BookingRow
{
    public int BookingId { get; set; }
    public int RoomId { get; set; }

    public DateTime BookDate { get; set; }
    public TimeSpan StartTime { get; set; }
    public TimeSpan EndTime { get; set; }

    public int Persons { get; set; }

    public string GuestName { get; set; } = string.Empty;
    public string GuestPhone { get; set; } = string.Empty;

    /// <summary>Optional — a phone number is the only contact the public form insists on.</summary>
    public string? GuestEmail { get; set; }

    public string? Note { get; set; }

    /// <summary>Computed in the database from the two times. Read-only; nothing sets it.</summary>
    public decimal? Hours { get; set; }

    public decimal TotalAmount { get; set; }

    /// <summary>What was due up front, from the room's DepositPercent at booking time.</summary>
    public decimal DepositDue { get; set; }

    public string CurrencyCode { get; set; } = string.Empty;

    /// <summary>Pending | Confirmed | Completed | Cancelled | NoShow.</summary>
    public string Status { get; set; } = string.Empty;

    /// <summary>Website | Manual — where it came from, which is also what decided whether it opened Pending.</summary>
    public string Source { get; set; } = string.Empty;

    public DateTime CreatedUtc { get; set; }
    public int? CreatedByUserId { get; set; }

    public int? DecidedByUserId { get; set; }
    public DateTime? DecidedUtc { get; set; }

    /// <summary>Required by the procedure when cancelling, and kept afterwards — a cancellation with no stated reason is an argument later.</summary>
    public string? CancelReason { get; set; }

    /* ---- joined, not stored ---- */

    public string RoomName { get; set; } = string.Empty;
    public string RoomCode { get; set; } = string.Empty;

    /// <summary>Sum of booking.BOOKING_PAYMENT. Zero, never null — a booking nobody has paid on has paid nothing.</summary>
    public decimal PaidAmount { get; set; }

    /// <summary>TotalAmount − PaidAmount. Computed in SQL so the grid, the drawer and the receipt cannot disagree.</summary>
    public decimal BalanceDue { get; set; }

    public string? DecidedByUsername { get; set; }
}

/// <summary>
/// A stretch of a room held back by staff (booking.BOOKING_BLOCK) — maintenance, a private event,
/// a deep clean.
///
/// A BLOCK IS NOT A BOOKING and has no guest, no money and no status. It exists to make the room
/// unbookable, and usp_Block_Create refuses to lay one over live bookings rather than quietly
/// double-holding the room.
/// </summary>
public class BookingBlock
{
    public int BlockId { get; set; }
    public int RoomId { get; set; }

    public DateTime BlockDate { get; set; }
    public TimeSpan StartTime { get; set; }
    public TimeSpan EndTime { get; set; }

    /// <summary>Internal — the public availability feed never carries it.</summary>
    public string? Reason { get; set; }

    public int? CreatedByUserId { get; set; }
    public DateTime CreatedUtc { get; set; }

    public string RoomName { get; set; } = string.Empty;
    public string? CreatedByUsername { get; set; }
}

/// <summary>
/// Both result sets of booking.usp_Booking_GetForRange.
///
/// THE CALENDAR NEEDS BOTH OR IT LIES. Drawing the bookings without the blocks paints free time over
/// a room that is shut, and one round trip that returns them together is the difference between a
/// consistent picture and two fetches that can disagree by a second.
/// </summary>
public class BookingRange
{
    public List<BookingRow> Bookings { get; set; } = [];
    public List<BookingBlock> Blocks { get; set; } = [];
}

/// <summary>
/// What booking.usp_Booking_Create returns — and, for a website guest, the whole of what they are
/// told.
///
/// STATUS IS HERE BECAUSE IT IS NOT PREDICTABLE FROM THE REQUEST. The same POST produces 'Pending'
/// or 'Confirmed' depending on core.SETTING BookingAutoConfirm and on whether staff or the site
/// made it, and a confirmation page that guessed would eventually tell somebody their slot was
/// confirmed when it was not.
/// </summary>
public class BookingCreated
{
    public int BookingId { get; set; }
    public decimal TotalAmount { get; set; }
    public decimal DepositDue { get; set; }
    public string CurrencyCode { get; set; } = string.Empty;
    public string Status { get; set; } = string.Empty;
}

/// <summary>The echo from booking.usp_Booking_SetStatus — the id and where it landed.</summary>
public class BookingStatusChanged
{
    public int BookingId { get; set; }
    public string Status { get; set; } = string.Empty;
}

/// <summary>
/// The result of booking.usp_Payment_Add: the new payment, and the money position after it.
///
/// THE BALANCE COMES BACK FROM THE PROCEDURE rather than being subtracted on the client, because the
/// procedure is also the thing that refused to let the total be exceeded. Two places computing the
/// same balance is how a screen ends up offering to collect money that is already paid.
/// </summary>
public class PaymentAdded
{
    public int PaymentId { get; set; }
    public decimal PaidTotal { get; set; }
    public decimal BalanceDue { get; set; }
}

/// <summary>The id booking.usp_Block_Create hands back, so the calendar can drop the block in without refetching.</summary>
public class BlockCreated
{
    public int BlockId { get; set; }
}
