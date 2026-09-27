namespace MokaCo.HRMS.Model.Booking;

/// <summary>
/// booking.usp_Booking_StartPayment (SQL 88): the booking as stamped for a checkout session. The
/// deposit is the row's DepositDue, priced when the booking was taken — never the caller's.
/// </summary>
public class PaymentStarted
{
    public int BookingId { get; set; }
    public string BookingRef { get; set; } = string.Empty;
    public decimal DepositDue { get; set; }
    public string CurrencyCode { get; set; } = string.Empty;
    public decimal TotalAmount { get; set; }
    public DateTime BookDate { get; set; }
    public int StartMin { get; set; }
    public int EndMin { get; set; }
    public decimal Hours { get; set; }
    public string RoomName { get; set; } = string.Empty;
    public DateTime? HoldExpiresUtc { get; set; }
    public DateTime? PaymentOpenedUtc { get; set; }

    /// <summary>Set when a checkout session had already been opened for this booking before this call.</summary>
    public DateTime? PreviousOpenedUtc { get; set; }
}

/// <summary>booking.usp_Booking_GetPaymentState: what the settlement code decides from.</summary>
public class PaymentState
{
    public int BookingId { get; set; }
    public string BookingRef { get; set; } = string.Empty;
    public string Status { get; set; } = string.Empty;
    public string Source { get; set; } = string.Empty;
    public decimal DepositDue { get; set; }
    public string CurrencyCode { get; set; } = string.Empty;
    public DateTime? HoldExpiresUtc { get; set; }
    public DateTime? PaymentOpenedUtc { get; set; }
    public DateTime? PaymentCheckedUtc { get; set; }
    public string? GatewayOrderId { get; set; }

    /// <summary>A gateway payment line is already recorded against this booking.</summary>
    public bool GatewayPaid { get; set; }
}

/// <summary>
/// booking.usp_Booking_ConfirmOnlinePayment. Outcome is one of Confirmed, Recorded, Replay,
/// PaidButClosed, SlotClash (see the procedure).
/// </summary>
public class OnlinePaymentRecorded
{
    public const string Confirmed = "Confirmed";
    public const string Recorded = "Recorded";
    public const string Replay = "Replay";
    public const string PaidButClosed = "PaidButClosed";
    public const string SlotClash = "SlotClash";

    public string Outcome { get; set; } = string.Empty;
    public int BookingId { get; set; }
    public string BookingRef { get; set; } = string.Empty;
    public string Status { get; set; } = string.Empty;
    public decimal PaidAmount { get; set; }
    public decimal BalanceDue { get; set; }
}

/// <summary>One row of booking.usp_Booking_ListPaymentsToReconcile.</summary>
public class PaymentToReconcile
{
    public int BookingId { get; set; }
    public string BookingRef { get; set; } = string.Empty;
    public decimal DepositDue { get; set; }
    public string CurrencyCode { get; set; } = string.Empty;
    public DateTime PaymentOpenedUtc { get; set; }
    public DateTime? PaymentCheckedUtc { get; set; }
    public DateTime? HoldExpiresUtc { get; set; }
    public bool UnconfirmedAlerted { get; set; }
}
