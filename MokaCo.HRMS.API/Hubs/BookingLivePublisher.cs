using Microsoft.AspNetCore.SignalR;
using MokaCo.HRMS.Model.Booking;
using MokaCo.HRMS.Repository.Booking;

namespace MokaCo.HRMS.Api.Hubs;

/// <summary>
/// Announces a booking's state on <see cref="BookingHub"/> after a change has been committed.
///
/// IT RE-READS THE BOOKING rather than trusting what the caller holds. The seven places that change a
/// booking each return a different shape (a created row, a status row, a refund outcome, a count…),
/// and the two messages must be the same whoever caused them; one read of usp_Booking_GetByRef gives
/// status, refund status, paid and balance as the database now has them.
///
/// IT NEVER FAILS THE REQUEST. The change is already committed when this runs; a hub that cannot be
/// reached costs the listeners their instant update — the website falls back to its 30-second poll,
/// the staff calendar to its next refetch — and nothing else. Failures are logged and swallowed.
/// </summary>
public interface IBookingLivePublisher
{
    /// <summary>Publish the current state of the booking with this reference. Unknown reference: nothing is sent.</summary>
    Task PublishAsync(string? bookingRef);
}

public sealed class BookingLivePublisher : IBookingLivePublisher
{
    private readonly IHubContext<BookingHub> _hub;
    private readonly IBookingRepository _bookings;
    private readonly ILogger<BookingLivePublisher> _log;

    public BookingLivePublisher(IHubContext<BookingHub> hub, IBookingRepository bookings, ILogger<BookingLivePublisher> log)
    {
        _hub = hub;
        _bookings = bookings;
        _log = log;
    }

    public async Task PublishAsync(string? bookingRef)
    {
        if (string.IsNullOrWhiteSpace(bookingRef))
            return;

        try
        {
            var booking = await _bookings.GetByRefAsync(bookingRef.Trim().ToUpperInvariant());
            if (booking is null)
                return;

            await _hub.Clients.Group(BookingHub.StaffGroup).SendAsync(BookingHub.BookingChanged, StaffMessage(booking));
            await _hub.Clients.Group(BookingHub.GuestGroup(booking.BookingRef)).SendAsync(BookingHub.BookingStatus, GuestMessage(booking));
        }
        catch (Exception ex)
        {
            _log.LogWarning(ex, "Live booking publish failed for {Ref}; the change itself stands.", bookingRef);
        }
    }

    /// <summary>One calendar row: enough to refetch, toast and open the right drawer.</summary>
    public static object StaffMessage(BookingRefDetail b) => new
    {
        bookingId = b.BookingId,
        @ref = b.BookingRef,
        status = b.Status,
        roomCode = b.RoomCode,
        date = b.BookDate.ToString("yyyy-MM-dd"),
        startMin = b.StartMin,
        endMin = b.EndMin,
        guestName = b.GuestName,
        source = b.Source,
    };

    /// <summary>What the guest's page repaints from. changedAt is the website's fifth field (confirmed.ts).</summary>
    public static object GuestMessage(BookingRefDetail b) => new
    {
        @ref = b.BookingRef,
        status = b.Status,
        refundStatus = b.RefundStatus,
        paid = b.PaidAmount,
        balance = b.BalanceDue,
        changedAt = DateTimeOffset.UtcNow,
    };
}
