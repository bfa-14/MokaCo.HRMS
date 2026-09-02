namespace MokaCo.HRMS.Model.Booking;

/// <summary>
/// One time bucket of the bookings report — result set 1 of booking.usp_Report_Bookings.
///
/// REVENUE COUNTS CONFIRMED AND COMPLETED ONLY; COLLECTED COUNTS EVERYTHING RECEIVED. They are
/// deliberately not the same population, and the gap between them is the report's whole point:
/// Revenue is what was sold, Collected is what is in the till, and money taken against a booking
/// that was later cancelled still sits in the till. Netting them into one figure would hide both.
/// </summary>
public class BookingReportBucket
{
    /// <summary>'2026-09-02' for day, '2026-W36' for week, '2026-09' for month — the grouping the caller asked for.</summary>
    public string Bucket { get; set; } = string.Empty;

    /// <summary>Every booking in the bucket, whatever its status — the denominator for the two below.</summary>
    public int Bookings { get; set; }

    public int Cancelled { get; set; }
    public int NoShows { get; set; }

    /// <summary>Hours on Confirmed and Completed bookings. What the room actually sold.</summary>
    public decimal HoursSold { get; set; }

    /// <summary>Value of Confirmed and Completed bookings.</summary>
    public decimal Revenue { get; set; }

    /// <summary>Payments received against bookings in the bucket, regardless of how they ended.</summary>
    public decimal Collected { get; set; }
}

/// <summary>
/// One room's share of the WHOLE range — result set 2, not bucketed.
///
/// It answers "which rooms earn their keep", which is a question about the period as a whole; broken
/// down per bucket as well it would be a cross-tab nobody reads. Ordered by Revenue descending, so
/// the answer is the first row.
/// </summary>
public class BookingReportRoom
{
    public string RoomName { get; set; } = string.Empty;
    public int Bookings { get; set; }
    public decimal HoursSold { get; set; }
    public decimal Revenue { get; set; }
    public decimal Collected { get; set; }
}

/// <summary>Both result sets of booking.usp_Report_Bookings: the timeline, and the per-room totals behind it.</summary>
public class BookingReport
{
    public List<BookingReportBucket> Buckets { get; set; } = [];
    public List<BookingReportRoom> Rooms { get; set; } = [];
}
