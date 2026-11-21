namespace MokaCo.HRMS.Model.Booking;

/* Script 119: the gateways' keys and mode, the payment log, the payments page, the gateway tests. */

/// <summary>booking.usp_Gateway_Get, first set: which mode a gateway works in. ActiveMode null = as the server file says.</summary>
public class GatewayModeRow
{
    public string Gateway { get; set; } = string.Empty;
    public string? ActiveMode { get; set; }
    public DateTime? ModifiedAtUtc { get; set; }
    public string? ModifiedBy { get; set; }
}

/// <summary>booking.usp_Gateway_Get, second set: the keys of one gateway in one mode, as the API encrypted them.</summary>
public class GatewayKeysRow
{
    public string Gateway { get; set; } = string.Empty;
    public string Mode { get; set; } = string.Empty;
    public byte[] KeysCipher { get; set; } = [];
    public DateTime ModifiedAtUtc { get; set; }
    public string? ModifiedBy { get; set; }
}

public sealed record GatewayStore(IReadOnlyList<GatewayModeRow> Modes, IReadOnlyList<GatewayKeysRow> Keys)
{
    public static GatewayStore Empty { get; } = new([], []);
}

/// <summary>booking.usp_Gateway_History: a change to the gateways' settings, or a connection check.</summary>
public class GatewayHistoryRow
{
    public long PaymentEventId { get; set; }
    public string Gateway { get; set; } = string.Empty;
    public string? Mode { get; set; }
    public string EventType { get; set; } = string.Empty;
    public string? Outcome { get; set; }
    public string? Detail { get; set; }
    public DateTime CreatedAtUtc { get; set; }
    public string? UserName { get; set; }
}

/// <summary>One step of an online payment, as it is written to booking.PAYMENT_EVENT. Never carries a key.</summary>
public sealed record PaymentEventEntry(
    string Gateway,
    string EventType,
    string Source,
    string? BookingRef = null,
    string? TestRef = null,
    string? Mode = null,
    string? GatewayOrderId = null,
    string? Outcome = null,
    string? GatewayStatus = null,
    string? Detail = null,
    decimal? Amount = null,
    string? CurrencyCode = null,
    int? UserId = null);

/// <summary>booking.fn_PaymentRows: a booking an online payment was opened or recorded for.</summary>
public class PaymentRow
{
    public int BookingId { get; set; }
    public string BookingRef { get; set; } = string.Empty;
    public string GuestName { get; set; } = string.Empty;
    public string? GuestPhone { get; set; }
    public string RoomName { get; set; } = string.Empty;
    public DateTime BookDate { get; set; }
    public int StartMin { get; set; }
    public int EndMin { get; set; }
    public string BookingStatus { get; set; } = string.Empty;
    public decimal DepositDue { get; set; }
    public decimal TotalAmount { get; set; }
    public string CurrencyCode { get; set; } = string.Empty;
    public DateTime? PaymentOpenedUtc { get; set; }
    public DateTime? PaymentCheckedUtc { get; set; }
    public DateTime? HoldExpiresUtc { get; set; }
    public int Attempts { get; set; }
    public string? PayerPhone { get; set; }
    public decimal RefundAmount { get; set; }
    public string? RefundStatus { get; set; }
    public DateTime? RefundedUtc { get; set; }
    public int? PaymentId { get; set; }
    public decimal? PaidAmount { get; set; }
    public DateTime? PaidUtc { get; set; }
    public string? TransactionId { get; set; }
    public string? GatewayOrderId { get; set; }
    public DateTime? ActivityUtc { get; set; }

    /// <summary>card | whish.</summary>
    public string Gateway { get; set; } = string.Empty;

    /// <summary>Paid, RefundDue, Refunded, NeedsStaff, Open, Unconfirmed, NotPaid.</summary>
    public string PayState { get; set; } = string.Empty;

    public decimal RefundedAmount { get; set; }

    /// <summary>test | live, from the payment's log; null for a payment older than the log.</summary>
    public string? Mode { get; set; }

    /// <summary>The gateway itself gave the money back (a refund made from HRMS).</summary>
    public bool GatewayRefunded { get; set; }

    public string? LastEventType { get; set; }
    public string? LastOutcome { get; set; }
    public string? LastDetail { get; set; }
    public DateTime? LastEventUtc { get; set; }
}

public class PaymentEventRow
{
    public long PaymentEventId { get; set; }
    public string Gateway { get; set; } = string.Empty;
    public string? Mode { get; set; }
    public string? GatewayOrderId { get; set; }
    public string EventType { get; set; } = string.Empty;
    public string Source { get; set; } = string.Empty;
    public string? Outcome { get; set; }
    public string? GatewayStatus { get; set; }
    public string? Detail { get; set; }
    public decimal? Amount { get; set; }
    public string? CurrencyCode { get; set; }
    public int Repeats { get; set; }
    public DateTime CreatedAtUtc { get; set; }
    public DateTime LastAtUtc { get; set; }
    public string? UserName { get; set; }
}

/// <summary>A money line of the booking (a payment, or a refund as a negative amount).</summary>
public class PaymentLineRow
{
    public int PaymentId { get; set; }
    public decimal Amount { get; set; }
    public bool IsRefund { get; set; }
    public string MethodName { get; set; } = string.Empty;
    public string? Reference { get; set; }
    public DateTime PaidUtc { get; set; }
    public string? ReceivedBy { get; set; }
    public string? GatewayOrderId { get; set; }
    public string? TransactionId { get; set; }
}

public sealed record PaymentDetail(PaymentRow Payment, IReadOnlyList<PaymentEventRow> Events, IReadOnlyList<PaymentLineRow> Lines);

/// <summary>booking.GATEWAY_TEST: a test payment opened from HRMS. Never a booking.</summary>
public class GatewayTestRow
{
    public int TestId { get; set; }
    public string TestRef { get; set; } = string.Empty;
    public string Gateway { get; set; } = string.Empty;
    public string Mode { get; set; } = string.Empty;
    public decimal Amount { get; set; }
    public string CurrencyCode { get; set; } = string.Empty;

    /// <summary>Opened, Paid, NotPaid, Unknown, Refunded, Error.</summary>
    public string Status { get; set; } = string.Empty;

    public string? GatewayStatus { get; set; }
    public string? Detail { get; set; }
    public string? PayUrl { get; set; }
    public string? ReturnUrl { get; set; }
    public string? PayerPhone { get; set; }
    public string? TransactionId { get; set; }
    public DateTime? CallbackAtUtc { get; set; }
    public DateTime? ReturnedAtUtc { get; set; }
    public DateTime? CheckedAtUtc { get; set; }
    public DateTime? RefundedAtUtc { get; set; }
    public int? CreatedByUserId { get; set; }
    public DateTime CreatedAtUtc { get; set; }
    public string? CreatedBy { get; set; }
}

public sealed record GatewayTestDetail(GatewayTestRow Test, IReadOnlyList<PaymentEventRow> Events);
