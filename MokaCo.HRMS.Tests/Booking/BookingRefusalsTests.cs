using MokaCo.HRMS.Api.PublicBooking;

namespace MokaCo.HRMS.Tests.Booking;

/// <summary>
/// The error mapping of the public booking API: a procedure's RAISERROR text becomes a status and a
/// machine code BY ITS OPENING WORDS, and the sentence itself is what the guest reads. Held here so a
/// reworded procedure message that drops its prefix is caught before the website loses a code it
/// switches on (BUG-20: "That time was just taken" used to be a 400 with no code at all).
/// </summary>
public class BookingRefusalsTests
{
    [Theory]
    [InlineData("That time was just taken — pick another slot.", 409, "slot_taken")]
    [InlineData("That room is not available for booking.", 400, "room_unavailable")]
    [InlineData("The room is closed at that time — pick a time inside its opening hours.", 400, "closed")]
    [InlineData("Bookings open up to 30 days ahead.", 400, "lead_time")]
    [InlineData("Online booking closes 1 hour(s) before the start — call us instead.", 400, "lead_time")]
    [InlineData("This hold has expired.", 409, "hold_expired")]
    [InlineData("The hold was released.", 409, "hold_expired")]
    [InlineData("Online cancellation closes 24 hours before the start — please call us.", 409, "cancel_window")]
    [InlineData("This booking can no longer be cancelled online.", 409, "not_cancellable")]
    [InlineData("Booking not found.", 404, "not_found")]
    [InlineData("Mokha takes 2 to 8 persons.", 400, "invalid_input")]
    [InlineData("Times must be in 60-minute steps.", 400, "invalid_input")]
    [InlineData("The phone number does not match this booking.", 400, "invalid_input")]
    [InlineData("", 400, "invalid_input")]
    [InlineData(null, 400, "invalid_input")]
    public void Procedure_text_maps_to_status_and_code(string? message, int status, string code)
    {
        var (actualStatus, actualCode) = BookingRefusals.Classify(message);

        Assert.Equal(status, actualStatus);
        Assert.Equal(code, actualCode);
    }

    [Fact]
    public void Prefix_match_is_case_insensitive_and_tolerates_a_reworded_tail()
    {
        Assert.Equal((409, "slot_taken"), BookingRefusals.Classify("that time was just taken, sorry"));
        Assert.Equal((400, "lead_time"), BookingRefusals.Classify("Bookings open up to 45 days ahead, and no further."));
    }
}
