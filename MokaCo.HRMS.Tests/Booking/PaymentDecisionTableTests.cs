using MokaCo.HRMS.Services.Booking.Payments;

namespace MokaCo.HRMS.Tests.Booking;

/// <summary>
/// THE DECISION TABLE, EVERY BRANCH. The booking's deposit is USD 12.50 throughout. Paid needs all of
/// SUCCESS + CAPTURED + captured == amount + amount == deposit + currency; failed is FAILED /
/// CANCELLED / EXPIRED or FAILURE; everything else — including AUTHORIZED — is unconfirmed.
/// </summary>
public class PaymentDecisionTableTests
{
    private const decimal Deposit = 12.50m;

    private static MpgsOrderLookup Order(string? result, string? status, decimal? amount = Deposit, decimal? captured = Deposit, string? currency = "USD")
        => new(MpgsLookupKind.Found, result, status, amount, currency, captured, "1");

    private static PaymentOutcome Decide(MpgsOrderLookup order) => PaymentDecisionTable.Decide(order, Deposit, "USD").Outcome;

    [Fact]
    public void Captured_in_full_in_the_bookings_currency_is_paid()
    {
        Assert.Equal(PaymentOutcome.Paid, Decide(Order("SUCCESS", "CAPTURED")));
        Assert.Equal(PaymentOutcome.Paid, Decide(Order("success", "captured", currency: "usd")));   // case does not matter
    }

    [Fact]
    public void Authorized_alone_is_not_paid()
        => Assert.Equal(PaymentOutcome.Unconfirmed, Decide(Order("SUCCESS", "AUTHORIZED", captured: 0)));

    [Theory]
    [InlineData("PENDING")]
    [InlineData("INITIATED")]
    [InlineData("PARTIALLY_CAPTURED")]
    [InlineData("AUTHENTICATION_INITIATED")]
    [InlineData(null)]
    public void Other_statuses_are_unconfirmed(string? status)
        => Assert.Equal(PaymentOutcome.Unconfirmed, Decide(Order("SUCCESS", status)));

    [Fact]
    public void A_partial_capture_is_unconfirmed()
        => Assert.Equal(PaymentOutcome.Unconfirmed, Decide(Order("SUCCESS", "CAPTURED", captured: 5m)));

    [Fact]
    public void A_missing_amount_or_captured_amount_is_unconfirmed()
    {
        Assert.Equal(PaymentOutcome.Unconfirmed, Decide(Order("SUCCESS", "CAPTURED", amount: null)));
        Assert.Equal(PaymentOutcome.Unconfirmed, Decide(Order("SUCCESS", "CAPTURED", captured: null)));
    }

    [Fact]
    public void An_amount_that_is_not_the_deposit_is_unconfirmed()
    {
        var decision = PaymentDecisionTable.Decide(Order("SUCCESS", "CAPTURED", amount: 10m, captured: 10m), Deposit, "USD");
        Assert.Equal(PaymentOutcome.Unconfirmed, decision.Outcome);
        Assert.Contains("amount mismatch", decision.Reason);
    }

    [Fact]
    public void A_currency_that_is_not_the_bookings_is_unconfirmed()
    {
        var decision = PaymentDecisionTable.Decide(Order("SUCCESS", "CAPTURED", currency: "LBP"), Deposit, "USD");
        Assert.Equal(PaymentOutcome.Unconfirmed, decision.Outcome);
        Assert.Contains("currency mismatch", decision.Reason);
    }

    [Theory]
    [InlineData("SUCCESS", "FAILED")]
    [InlineData("SUCCESS", "CANCELLED")]
    [InlineData("SUCCESS", "EXPIRED")]
    [InlineData("FAILURE", "AUTHORIZED")]
    [InlineData("FAILURE", null)]
    [InlineData("FAILURE", "CAPTURED")]
    public void Failed_statuses_or_a_failure_result_are_failed(string result, string? status)
        => Assert.Equal(PaymentOutcome.Failed, Decide(Order(result, status)));

    [Fact]
    public void A_retrieval_error_is_unconfirmed_never_failed()
    {
        var decision = PaymentDecisionTable.Decide(MpgsOrderLookup.Error("HTTP 503"), Deposit, "USD");
        Assert.Equal(PaymentOutcome.Unconfirmed, decision.Outcome);
        Assert.Contains("retrieval error", decision.Reason);
    }

    [Fact]
    public void An_order_the_gateway_has_not_seen_is_unconfirmed()
        => Assert.Equal(PaymentOutcome.Unconfirmed, Decide(MpgsOrderLookup.NotFound()));

    [Fact]
    public void Nothing_attempted_is_flagged_only_when_the_gateway_answered_that_nothing_was_tried()
    {
        static PaymentDecision D(MpgsOrderLookup o) => PaymentDecisionTable.Decide(o, Deposit, "USD");

        // abandoned: the gateway does not know the order, or the order carries no transaction and no money
        Assert.True(D(MpgsOrderLookup.NotFound()).NothingAttempted);
        var empty = new MpgsOrderLookup(MpgsLookupKind.Found, "SUCCESS", "INITIATED", Deposit, "USD", 0m, null, TransactionCount: 0, TotalAuthorizedAmount: 0m);
        Assert.Equal((PaymentOutcome.Unconfirmed, true), (D(empty).Outcome, D(empty).NothingAttempted));

        // NOT abandoned: no answer at all, a transaction on the order, money authorised, or a count not reported
        Assert.False(D(MpgsOrderLookup.Error("timeout")).NothingAttempted);
        Assert.False(D(MpgsOrderLookup.Error("network error")).NothingAttempted);
        Assert.False(D(empty with { TransactionCount = 1 }).NothingAttempted);
        Assert.False(D(empty with { TotalAuthorizedAmount = Deposit }).NothingAttempted);
        Assert.False(D(empty with { TotalCapturedAmount = Deposit }).NothingAttempted);
        Assert.False(D(empty with { TransactionCount = null }).NothingAttempted);

        // and never on paid or failed
        Assert.False(D(Order("SUCCESS", "CAPTURED")).NothingAttempted);
        Assert.False(D(empty with { Status = "FAILED" }).NothingAttempted);
    }

    [Fact]
    public void A_result_the_table_does_not_know_is_unconfirmed()
        => Assert.Equal(PaymentOutcome.Unconfirmed, Decide(Order("PENDING", "CAPTURED")));
}
