namespace MokaCo.HRMS.Model.Booking;

/// <summary>
/// The head of a printed receipt — result set 1 of booking.usp_Booking_GetReceipt.
///
/// PRICEPERHOUR AND POLICYTEXT ARE READ FROM THE ROOM AS IT IS NOW, not as it was when the booking
/// was taken; only the amounts are historical. That is a deliberate asymmetry and worth knowing when
/// reprinting an old receipt: the figures are what the guest agreed to, the terms are the current
/// ones. Storing a copy of the policy on every booking would be the alternative, and nobody has
/// needed to reprint terms that have since changed.
/// </summary>
public class ReceiptHeader
{
    public int BookingId { get; set; }

    public DateTime BookDate { get; set; }
    public TimeSpan StartTime { get; set; }
    public TimeSpan EndTime { get; set; }

    public int Persons { get; set; }

    /// <summary>Database-computed duration. Printed rather than recomputed so the receipt matches the report.</summary>
    public decimal? Hours { get; set; }

    public string GuestName { get; set; } = string.Empty;
    public string GuestPhone { get; set; } = string.Empty;
    public string? GuestEmail { get; set; }

    public string Status { get; set; } = string.Empty;
    public string Source { get; set; } = string.Empty;

    public decimal TotalAmount { get; set; }
    public decimal DepositDue { get; set; }
    public string CurrencyCode { get; set; } = string.Empty;

    public string? Note { get; set; }

    public string RoomName { get; set; } = string.Empty;

    /// <summary>The room's CURRENT hourly rate — see the class remark.</summary>
    public decimal PricePerHour { get; set; }

    /// <summary>The room's CURRENT terms, printed as the receipt's small print.</summary>
    public string? PolicyText { get; set; }

    public decimal PaidAmount { get; set; }

    /// <summary>Zero means PAID; anything above means BALANCE DUE. The footer is this number.</summary>
    public decimal BalanceDue { get; set; }
}

/// <summary>
/// One add-on line as it was CHARGED — result set 2, read from booking.BOOKING_ADDON.
///
/// Name and Amount were copied onto the booking when it was taken, so a receipt reprinted after the
/// add-on was renamed or re-priced still prints the line the guest actually paid for. It carries no
/// AddonId for that reason: it is a line on a receipt, not a pointer at a price list.
/// </summary>
public class ReceiptAddon
{
    public string Name { get; set; } = string.Empty;
    public decimal Amount { get; set; }
}

/// <summary>One money movement against the booking — result set 3, oldest first.</summary>
public class ReceiptPayment
{
    public int PaymentId { get; set; }
    public decimal Amount { get; set; }

    /// <summary>The card slip or transfer number, when whoever took it wrote one down.</summary>
    public string? Reference { get; set; }

    public DateTime PaidUtc { get; set; }

    public string MethodName { get; set; } = string.Empty;

    /// <summary>The staff username, null for a payment whose taker is no longer a user.</summary>
    public string? ReceivedBy { get; set; }
}

/// <summary>
/// All three result sets of booking.usp_Booking_GetReceipt — everything a printed receipt needs, in
/// one call, because a receipt assembled from three separate fetches can print a total that does not
/// match the lines beneath it.
/// </summary>
public class BookingReceipt
{
    public ReceiptHeader? Header { get; set; }
    public List<ReceiptAddon> Addons { get; set; } = [];
    public List<ReceiptPayment> Payments { get; set; } = [];
}
