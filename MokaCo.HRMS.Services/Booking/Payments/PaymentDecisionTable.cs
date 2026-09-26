namespace MokaCo.HRMS.Services.Booking.Payments;

public enum PaymentOutcome
{
    /// <summary>The whole deposit was captured, in the booking's currency.</summary>
    Paid,

    /// <summary>The gateway says definitively that the payment did not happen.</summary>
    Failed,

    /// <summary>
    /// Anything else. The guest is NEVER told "nothing was charged" and never invited to pay again
    /// (a second payment could be a double charge); the hold is kept until it is settled.
    /// </summary>
    Unconfirmed,
}

/// <param name="Outcome">What to do.</param>
/// <param name="Reason">Why, in a few words, for the log and a staff alert. Never shown to a guest.</param>
public sealed record PaymentDecision(PaymentOutcome Outcome, string Reason);

/// <summary>
/// THE ONE PLACE that decides whether a deposit was paid, from what RETRIEVE_ORDER said. Pure: no
/// clock, no database, no gateway. The rules are mokanco-lb functions/api/booking/verify.js'
/// (audit findings 2 and 3), tightened to the booking's own deposit:
///
///   paid        result SUCCESS AND status CAPTURED AND totalCapturedAmount == amount
///               AND amount == the booking's deposit AND currency == the booking's currency.
///               This is a PURCHASE flow: AUTHORIZED alone is NOT paid.
///   failed      status FAILED, CANCELLED or EXPIRED, or result FAILURE.
///   unconfirmed everything else — a retrieval error, an order the gateway has not seen, PENDING,
///               AUTHORIZED, INITIATED, a partial capture, an amount or currency that does not match.
/// </summary>
public static class PaymentDecisionTable
{
    private static readonly string[] FailedStatuses = ["FAILED", "CANCELLED", "EXPIRED"];

    public static PaymentDecision Decide(MpgsOrderLookup order, decimal expectedAmount, string expectedCurrency)
    {
        if (order.Kind == MpgsLookupKind.Error)
            return new(PaymentOutcome.Unconfirmed, $"retrieval error ({order.Problem})");

        if (order.Kind == MpgsLookupKind.NotFound)
            return new(PaymentOutcome.Unconfirmed, "the gateway has no such order");

        var result = order.Result?.Trim().ToUpperInvariant();
        var status = order.Status?.Trim().ToUpperInvariant();

        if (result == "SUCCESS" && status == "CAPTURED")
        {
            if (order.Amount is not { } amount || order.TotalCapturedAmount is not { } captured || captured != amount)
                return new(PaymentOutcome.Unconfirmed, $"captured {order.TotalCapturedAmount?.ToString() ?? "?"} of {order.Amount?.ToString() ?? "?"}");

            if (amount != expectedAmount)
                return new(PaymentOutcome.Unconfirmed, $"amount mismatch: order {amount}, deposit {expectedAmount}");

            if (!string.Equals(order.Currency?.Trim(), expectedCurrency?.Trim(), StringComparison.OrdinalIgnoreCase))
                return new(PaymentOutcome.Unconfirmed, $"currency mismatch: order {order.Currency ?? "?"}, booking {expectedCurrency}");

            return new(PaymentOutcome.Paid, "captured in full");
        }

        if (status is not null && FailedStatuses.Contains(status))
            return new(PaymentOutcome.Failed, $"status {status}");

        if (result == "FAILURE")
            return new(PaymentOutcome.Failed, "result FAILURE");

        return new(PaymentOutcome.Unconfirmed, $"result {result ?? "-"}, status {status ?? "-"}");
    }
}
