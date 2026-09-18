namespace MokaCo.HRMS.Services.Booking;

/// <summary>
/// The café's clock, and the only one any booking code is allowed to consult. NEVER DateTime.Now:
/// the API may be hosted anywhere and a developer's laptop certainly is somewhere else, so "is this
/// booking at least an hour from now" would quietly become a different rule per server.
///
/// THE DATABASE IS STILL THE AUTHORITY on what time it is — booking.fn_LocalNow() is what
/// usp_Booking_Validate compares against, and every LocalNow on the wire comes from there. What this
/// class adds is the OFFSET: a wall-clock reading with no offset is ambiguous to a browser, which
/// will happily parse "2026-09-08T19:00:00" as the visitor's own 7pm in Berlin. Attaching +03:00
/// makes every moment on the wire mean exactly one instant.
///
/// TWO IDS FOR ONE ZONE. The IANA name resolves on Linux and, through ICU, on Windows; the Windows
/// registry id is the fallback for a host running without ICU. The last resort is UTC rather than a
/// crash: an API that will not start because a time zone is missing is worse than one whose
/// offsets are wrong until somebody notices the log line.
/// </summary>
public static class BeirutTime
{
    /// <summary>What goes on the wire. Browsers read IANA names, not Windows registry keys.</summary>
    public const string IanaId = "Asia/Beirut";

    /// <summary>core.SETTING BookingTimeZone's value — the id Windows knows the zone by.</summary>
    public const string WindowsId = "Middle East Standard Time";

    /// <summary>Resolved once; consulted on every public request.</summary>
    public static TimeZoneInfo Zone { get; } = Resolve();

    private static TimeZoneInfo Resolve()
    {
        foreach (var id in new[] { IanaId, WindowsId })
        {
            try
            {
                return TimeZoneInfo.FindSystemTimeZoneById(id);
            }
            catch (Exception ex) when (ex is TimeZoneNotFoundException or InvalidTimeZoneException)
            {
                // Try the other spelling before giving up — see the class remark.
            }
        }

        return TimeZoneInfo.Utc;
    }

    /// <summary>The café's wall clock right now (server "now"). Used for logs and for the hold-expiry job; the guest is judged by the database's clock.</summary>
    public static DateTime Now => TimeZoneInfo.ConvertTime(DateTimeOffset.UtcNow, Zone).DateTime;

    /// <summary>
    /// Stamps a Beirut wall-clock reading with Beirut's offset for that date. The Kind is forced to
    /// Unspecified first: a DateTime that picked up Kind=Utc/Local on the way makes the
    /// DateTimeOffset constructor throw, and a 500 on a confirmation page is a poor way to learn that.
    /// </summary>
    public static DateTimeOffset At(DateTime localWallClock)
    {
        var unspecified = DateTime.SpecifyKind(localWallClock, DateTimeKind.Unspecified);
        return new DateTimeOffset(unspecified, Zone.GetUtcOffset(unspecified));
    }

    /// <summary>A date plus minutes from ITS midnight. MINUTES MAY EXCEED 1440: 1500 on the 8th is 01:00 on the 9th, and AddMinutes rolls the date over.</summary>
    public static DateTimeOffset At(DateTime date, int minutesFromMidnight)
        => At(date.Date.AddMinutes(minutesFromMidnight));

    /// <summary>A UTC instant read from the database, moved to Beirut.</summary>
    public static DateTimeOffset FromUtc(DateTime utc)
        => TimeZoneInfo.ConvertTime(new DateTimeOffset(DateTime.SpecifyKind(utc, DateTimeKind.Utc)), Zone);
}
