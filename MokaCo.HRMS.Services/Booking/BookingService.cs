using System.Globalization;
using System.Text.Json;
using MokaCo.HRMS.Model.Booking;
using MokaCo.HRMS.Repository.Booking;
using MokaCo.HRMS.Repository.Core;

namespace MokaCo.HRMS.Services.Booking;

/// <summary>
/// Bookings. Almost every rule lives in the procedures; what lives here is the PROJECTION of a
/// booking for an anonymous reader, and the resolution of a refund's payment method.
///
/// NOTHING IS QUEUED HERE. The old "create, then queue the guest's copy" orchestration went with
/// SQL 66/69: booking.trg_Booking_Notify and trg_Payment_RefundNotify write the outbox rows inside
/// the transaction that changed the row, so an explicit usp_Booking_QueueEmail call from this layer
/// would send every message twice.
/// </summary>
public class BookingService : IBookingService
{
    private const string DepositRequiredSetting = "BookingDepositRequired";

    private readonly IBookingRepository _bookings;
    private readonly IRoomRepository _rooms;
    private readonly ISettingRepository _settings;

    public BookingService(IBookingRepository bookings, IRoomRepository rooms, ISettingRepository settings)
    {
        _bookings = bookings;
        _rooms = rooms;
        _settings = settings;
    }

    /* ---- public ---------------------------------------------------------------------------- */

    public Task<BookingCreated?> CreateFromWebsiteAsync(PublicBookingRequest request)
        => _bookings.CreateFromWebsiteAsync(request);

    public Task<BookingQuote?> QuoteAsync(PublicQuoteRequest request)
        => _bookings.QuoteAsync(request);

    public async Task<PublicBookingRecap?> GetPublicRecapAsync(string bookingRef)
    {
        var booking = await _bookings.GetByRefAsync(bookingRef);
        return booking is null ? null : ToRecap(booking);
    }

    public Task<BookingHoldReleased?> ReleaseHoldAsync(string bookingRef)
        => _bookings.ReleaseHoldAsync(bookingRef);

    public async Task<PublicBookingRecap?> CancelByGuestAsync(string bookingRef, string phone)
    {
        var booking = await _bookings.CancelByGuestAsync(bookingRef, phone);
        return booking is null ? null : ToRecap(booking);
    }

    public Task<IReadOnlyList<string>> ExpireHoldsAsync()
        => _bookings.ExpireHoldsAsync();

    public async Task<bool> IsDepositRequiredAsync()
    {
        var setting = await _settings.GetAsync(DepositRequiredSetting);
        return setting?.SettingValue?.Trim() == "1";
    }

    /// <summary>
    /// The projection for an anonymous holder of the reference, in ONE place so that a new endpoint
    /// cannot leak a phone number by forgetting to project. No phone, no email, no note, no gateway
    /// ids; the name is cut to "Rami H.".
    /// </summary>
    public static PublicBookingRecap ToRecap(BookingRefDetail booking) => new()
    {
        Ref = booking.BookingRef,
        Status = booking.Status,
        RoomCode = booking.RoomCode,
        RoomName = booking.RoomName,
        Date = booking.BookDate,
        StartMin = booking.StartMin,
        EndMin = booking.EndMin,
        VacateByMin = booking.VacateByMin,
        TurnaroundMinutes = booking.TurnaroundMinutes,
        Hours = booking.Hours,
        Persons = booking.Persons,
        GuestName = ShortenName(booking.GuestName),
        Total = booking.TotalAmount,
        DiscountPercent = booking.DiscountPercent,
        DiscountAmount = booking.DiscountAmount,
        Deposit = booking.DepositDue,
        Paid = booking.PaidAmount,
        Balance = booking.BalanceDue,
        RefundAmount = booking.RefundAmount,
        RefundStatus = booking.RefundStatus,
        CancelledBy = booking.CancelledBy,
        Currency = booking.CurrencyCode,
        PolicyText = booking.PolicyText,
        CanCancelOnline = booking.CanCancelOnline,
        CancelHours = booking.CancelHours,
        Addons = booking.Addons,
    };

    /// <summary>"Rami Haddad" → "Rami H."; a single name stays as it is. Enough to recognise, not enough to identify.</summary>
    public static string ShortenName(string guestName)
    {
        var parts = (guestName ?? string.Empty).Trim().Split(' ', StringSplitOptions.RemoveEmptyEntries);

        return parts.Length switch
        {
            0 => string.Empty,
            1 => parts[0],
            _ => $"{parts[0]} {char.ToUpper(parts[^1][0], CultureInfo.InvariantCulture)}.",
        };
    }

    /* ---- staff ----------------------------------------------------------------------------- */

    public Task<BookingCreated?> CreateManuallyAsync(BookingCreateRequest request, int createdByUserId)
        => _bookings.CreateAsync(request, source: "Manual", createdByUserId);

    public Task<BookingRange> GetForRangeAsync(DateTime fromDate, DateTime toDate, int? roomId, string? status)
        => _bookings.GetForRangeAsync(fromDate, toDate, roomId, status);

    /// <summary>
    /// The receipt is read for its payment lines and for the reference; the row itself comes from
    /// usp_Booking_GetByRef, which is the one read that carries RefundedUtc, CancelledBy and the
    /// cancel window together. Two procedure calls, one shape.
    /// </summary>
    public async Task<BookingStaffDetail?> GetStaffDetailAsync(int bookingId)
    {
        var receipt = await _bookings.GetReceiptAsync(bookingId);
        if (receipt.Header is not { } header || string.IsNullOrEmpty(header.BookingRef))
            return null;

        var booking = await _bookings.GetByRefAsync(header.BookingRef);
        if (booking is null)
            return null;

        return new BookingStaffDetail { Booking = booking, Payments = receipt.Payments };
    }

    public Task<BookingStatusChanged?> SetStatusAsync(int bookingId, BookingStatusRequest request, int actedByUserId)
        => _bookings.SetStatusAsync(
            bookingId, request.Status, actedByUserId, request.EffectiveNote,
            string.IsNullOrWhiteSpace(request.CancelledBy) ? "Staff" : request.CancelledBy.Trim());

    public Task<PaymentAdded?> AddPaymentAsync(int bookingId, BookingPaymentRequest request, int receivedByUserId)
        => _bookings.AddPaymentAsync(bookingId, request, receivedByUserId);

    public async Task<RefundOutcome> AddRefundAsync(int bookingId, BookingRefundRequest request, int receivedByUserId)
    {
        var (method, resolvedBy, error) = await ResolveMethodAsync(request);
        if (method is null)
            return new RefundOutcome { Error = error };

        var added = await _bookings.AddRefundAsync(bookingId, request.Amount, method.PaymentMethodId, request.Reference, receivedByUserId);
        return new RefundOutcome { Added = added, Method = method, ResolvedBy = resolvedBy };
    }

    /// <summary>
    /// `method` may be a PaymentMethodId (a JSON number, or a numeric string) or a method name
    /// ("Cash", "Card", "Whish", "OMT" — case-insensitive); `paymentMethodId` is accepted as well.
    /// Only ACTIVE methods resolve: a retired method is not a way to give money back.
    /// </summary>
    private async Task<(PaymentMethod? Method, string ResolvedBy, string? Error)> ResolveMethodAsync(BookingRefundRequest request)
    {
        var methods = (await _rooms.GetPaymentMethodsAsync()).Where(m => m.IsActive).ToList();

        int? id = request.PaymentMethodId;
        string? name = null;

        if (request.Method is { } element)
        {
            switch (element.ValueKind)
            {
                case JsonValueKind.Number when element.TryGetInt32(out var number):
                    id = number;
                    break;
                case JsonValueKind.String:
                    var text = element.GetString()?.Trim();
                    if (int.TryParse(text, NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsed))
                        id = parsed;
                    else
                        name = text;
                    break;
                case JsonValueKind.Null:
                case JsonValueKind.Undefined:
                    break;
                default:
                    return (null, string.Empty, "method must be a payment method id or name.");
            }
        }

        if (id is { } wanted)
        {
            var byId = methods.FirstOrDefault(m => m.PaymentMethodId == wanted);
            return byId is null
                ? (null, string.Empty, $"Unknown payment method id {wanted}.")
                : (byId, "id", null);
        }

        if (!string.IsNullOrWhiteSpace(name))
        {
            var byName = methods.FirstOrDefault(m => string.Equals(m.Name, name, StringComparison.OrdinalIgnoreCase));
            return byName is null
                ? (null, string.Empty, $"Unknown payment method '{name}'. Active methods: {string.Join(", ", methods.Select(m => m.Name))}.")
                : (byName, "name", null);
        }

        return (null, string.Empty, "Say how the money went back: method is a payment method id or name.");
    }

    public Task<BookingReceipt> GetReceiptAsync(int bookingId)
        => _bookings.GetReceiptAsync(bookingId);

    public Task<BlockCreated?> CreateBlockAsync(BlockCreateRequest request, int createdByUserId)
        => _bookings.CreateBlockAsync(request, createdByUserId);

    public Task DeleteBlockAsync(int blockId)
        => _bookings.DeleteBlockAsync(blockId);

    public Task<BookingReport> GetReportAsync(DateTime fromDate, DateTime toDate, string groupBy)
        => _bookings.GetReportAsync(fromDate, toDate, groupBy);
}
