using System.Text.RegularExpressions;
using MokaCo.HRMS.Model.Booking;

namespace MokaCo.HRMS.Api.PublicBooking;

/// <summary>
/// The handful of shape checks the database cannot make on the caller's behalf: the required text,
/// the lengths a procedure parameter would otherwise TRUNCATE silently, and numbers far enough out
/// of range to be nonsense. Everything else — the room, the hours, the person count against THIS
/// room, the lead time, the overlap — belongs to the procedure and is left there.
///
/// BUG-22: the end is compared with the start AS MINUTES. 22:00→01:00 is 1320→1500 and 1500 &gt; 1320;
/// the old check compared the wrapped clock times and refused every booking that crossed midnight.
/// </summary>
public static partial class PublicBookingRules
{
    public const int MaxName = 120;
    public const int MaxPhone = 30;
    public const int MaxEmail = 150;
    public const int MaxNotes = 500;
    public const int MaxPersons = 30;

    /// <summary>A refusal the caller could have avoided: the sentence, and which box it is about when it is about one.</summary>
    public sealed record Problem(string Error, string? Field = null);

    /// <summary>Starts with a digit or '+', then at least six of digits, spaces, dashes and brackets.</summary>
    [GeneratedRegex(@"^[\d+][\d\s\-()]{6,}$")]
    private static partial Regex PhoneShape();

    [GeneratedRegex(@"^[^@\s]+@[^@\s]+\.[^@\s]+$")]
    private static partial Regex EmailShape();

    public static Problem? SlotProblem(string? roomCode, int startMin, int endMin)
    {
        if (string.IsNullOrWhiteSpace(roomCode))
            return new Problem("Say which room.", "roomCode");

        if (startMin is < 0 or > 1439)
            return new Problem("The start time must be between 00:00 and 23:59.", "startMin");

        if (endMin > MinuteClock.MaxEndMin)
            return new Problem("The end time cannot be later than 06:00 the next morning.", "endMin");

        if (endMin <= startMin)
            return new Problem("The end time must be after the start time.", "endMin");

        return null;
    }

    public static Problem? Validate(PublicQuoteRequest request)
        => SlotProblem(request.RoomCode, request.StartMin, request.EndMin);

    public static Problem? Validate(PublicBookingRequest request)
    {
        if (SlotProblem(request.RoomCode, request.StartMin, request.EndMin) is { } slot)
            return slot;

        if (request.Persons is < 1 or > MaxPersons)
            return new Problem($"Choose between 1 and {MaxPersons} guests.", "persons");

        if (string.IsNullOrWhiteSpace(request.Name))
            return new Problem("Please give us a name for the booking.", "name");

        if (request.Name.Trim().Length > MaxName)
            return new Problem($"The name is too long (max {MaxName} characters).", "name");

        if (string.IsNullOrWhiteSpace(request.Phone))
            return new Problem("Please give us a phone number so we can reach you.", "phone");

        var phone = request.Phone.Trim();
        if (phone.Length > MaxPhone)
            return new Problem($"The phone number is too long (max {MaxPhone} characters).", "phone");

        if (!PhoneShape().IsMatch(phone))
            return new Problem("Enter a valid phone number.", "phone");

        var email = request.Email?.Trim();
        if (!string.IsNullOrEmpty(email))
        {
            if (email.Length > MaxEmail)
                return new Problem($"The email address is too long (max {MaxEmail} characters).", "email");

            if (!EmailShape().IsMatch(email))
                return new Problem("Enter a valid email address.", "email");
        }

        if (request.Notes?.Length > MaxNotes)
            return new Problem($"The note is too long (max {MaxNotes} characters).", "notes");

        return null;
    }

    /// <summary>Trimmed, and an empty email or note stored as null — the procedure treats "" and NULL alike, but null is what "none" means.</summary>
    public static void Normalize(PublicBookingRequest request)
    {
        request.RoomCode = request.RoomCode.Trim();
        request.Name = request.Name.Trim();
        request.Phone = request.Phone.Trim();
        request.Email = string.IsNullOrWhiteSpace(request.Email) ? null : request.Email.Trim();
        request.Notes = string.IsNullOrWhiteSpace(request.Notes) ? null : request.Notes.Trim();
    }
}
