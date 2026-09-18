using MokaCo.HRMS.Services.Booking;
using Quartz;

namespace MokaCo.HRMS.Api.Jobs;

/// <summary>
/// Every five minutes: cancels website payment holds whose clock ran out with no money against them
/// (booking.usp_Booking_ExpireHolds).
///
/// IT IS TIDYING, NOT ENFORCEMENT. Every query that decides whether a slot is taken — the create's
/// overlap check, both availability procedures — already excludes a Pending booking whose
/// HoldExpiresUtc has passed, so THE SLOT IS FREE THE SECOND THE CLOCK RUNS OUT whether or not this
/// has ever run. What this does is move the row to Cancelled so the staff calendar does not
/// accumulate bookings that will never happen. In step 1 (no payment gateway) no hold has an expiry
/// and this does nothing at all, correctly; it is registered now so it is not forgotten on the day
/// the gateway goes live. The scheduler is in-memory: a run missed while the API was down is skipped,
/// which is harmless here because the next run takes everything that is due.
/// </summary>
[DisallowConcurrentExecution]
public class BookingHoldExpiryJob : IJob
{
    private readonly IBookingService _bookings;
    private readonly ILogger<BookingHoldExpiryJob> _logger;

    public BookingHoldExpiryJob(IBookingService bookings, ILogger<BookingHoldExpiryJob> logger)
    {
        _bookings = bookings;
        _logger = logger;
    }

    public async Task Execute(IJobExecutionContext context)
    {
        var expired = await _bookings.ExpireHoldsAsync();

        // Silent on the ordinary outcome: this runs 288 times a day and almost every run has nothing to do.
        if (expired > 0)
            _logger.LogInformation("Booking holds: cancelled {Count} unpaid hold(s) whose time had run out (Beirut {Now:HH:mm}).",
                expired, BeirutTime.Now);
    }
}
