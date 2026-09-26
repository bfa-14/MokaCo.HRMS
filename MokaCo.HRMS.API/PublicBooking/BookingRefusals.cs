namespace MokaCo.HRMS.Api.PublicBooking;

/// <summary>
/// Turns a procedure's refusal (RAISERROR text, SqlException 50000) into an HTTP status and a
/// machine code, KEEPING ITS SENTENCE as the user message.
///
/// MATCHED ON THE MESSAGE'S OPENING WORDS, which is the honest option available: SQL Server gives
/// every RAISERROR the same error number, so the text is the only thing distinguishing "that slot is
/// gone" from "that room takes eight people". The prefixes are the parts of each sentence that carry
/// the meaning; the tails are free to be reworded. Anything unrecognised is 400 invalid_input with
/// its own text intact, so a new refusal still reaches the guest and only loses its code.
///
/// BUG-20: "That time was just taken" used to be a 400 with no code; the website must react to it
/// by re-fetching availability, which it can only do from a code.
/// </summary>
public static class BookingRefusals
{
    public const string InvalidInput = "invalid_input";
    public const string NotFound = "not_found";

    public static (int Status, string Code) Classify(string? message)
    {
        var text = message ?? string.Empty;

        if (Starts(text, "That time was just taken"))
            return (StatusCodes.Status409Conflict, "slot_taken");

        if (Starts(text, "That room is not available"))
            return (StatusCodes.Status400BadRequest, "room_unavailable");

        if (Starts(text, "The room is closed"))
            return (StatusCodes.Status400BadRequest, "closed");

        if (Starts(text, "Bookings open up to") || Starts(text, "Online booking closes"))
            return (StatusCodes.Status400BadRequest, "lead_time");

        if (Contains(text, "hold has expired") || Contains(text, "hold was released") || Contains(text, "has been released"))
            return (StatusCodes.Status409Conflict, "hold_expired");

        if (Starts(text, "This booking is not waiting for a payment"))
            return (StatusCodes.Status409Conflict, "not_pending");

        if (Starts(text, "This booking has already been paid"))
            return (StatusCodes.Status409Conflict, "already_paid");

        if (Starts(text, "There is no deposit to pay"))
            return (StatusCodes.Status409Conflict, "nothing_due");

        if (Starts(text, "Online cancellation closes"))
            return (StatusCodes.Status409Conflict, "cancel_window");

        if (Contains(text, "can no longer be cancelled"))
            return (StatusCodes.Status409Conflict, "not_cancellable");

        if (Starts(text, "Booking not found") || Starts(text, "No such room") || Starts(text, "Room not found"))
            return (StatusCodes.Status404NotFound, NotFound);

        return (StatusCodes.Status400BadRequest, InvalidInput);
    }

    private static bool Starts(string text, string prefix)
        => text.StartsWith(prefix, StringComparison.OrdinalIgnoreCase);

    private static bool Contains(string text, string part)
        => text.Contains(part, StringComparison.OrdinalIgnoreCase);
}
