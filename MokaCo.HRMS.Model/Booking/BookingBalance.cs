namespace MokaCo.HRMS.Model.Booking;

/// <summary>
/// What a guest still OWES on a booking (QA3 BKG-8).
///
/// The procedures compute BalanceDue as TotalAmount − PaidAmount, and PaidAmount is net of refunds
/// (a refund is a negative payment line). On a booking that did not happen that number is not a debt:
/// a cancelled booking whose deposit is refunded showed a "balance due" that GREW with every refund
/// recorded, and the receipt printed BALANCE DUE on it. A Cancelled or No-show booking owes nothing;
/// what may still be owed is the café's refund to the guest, which RefundAmount / RefundStatus say.
/// One rule, applied wherever a balance leaves the API (calendar rows, the staff detail, the receipt,
/// the guest's recap and the live message).
/// </summary>
public static class BookingBalance
{
    /// <summary>True for the two statuses on which nothing can be owed.</summary>
    public static bool OwesNothing(string? status)
        => string.Equals(status, "Cancelled", StringComparison.OrdinalIgnoreCase)
           || string.Equals(status, "NoShow", StringComparison.OrdinalIgnoreCase);

    /// <summary>The balance as the procedure computed it, or 0 for a Cancelled / No-show booking.</summary>
    public static decimal Owed(string? status, decimal balanceDue)
        => OwesNothing(status) ? 0m : balanceDue;
}
