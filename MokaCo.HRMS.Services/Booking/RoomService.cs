using System.Globalization;
using MokaCo.HRMS.Model.Booking;
using MokaCo.HRMS.Repository.Booking;
using MokaCo.HRMS.Repository.Core;

namespace MokaCo.HRMS.Services.Booking;

/// <summary>
/// The room catalogue. Thin over the repository except for the two things that are genuinely this
/// layer's to decide: WHAT AN ANONYMOUS VISITOR IS SHOWN, and WHAT IS LEFT once the taken time is
/// subtracted from a day (<see cref="AvailabilityMath"/>).
/// </summary>
public class RoomService : IRoomService
{
    private const string TurnaroundSetting = "BookingTurnaroundMinutes";

    private readonly IRoomRepository _rooms;
    private readonly ISettingRepository _settings;

    public RoomService(IRoomRepository rooms, ISettingRepository settings)
    {
        _rooms = rooms;
        _settings = settings;
    }

    /// <summary>
    /// The public feed, assembled. The procedure has already filtered to active rooms and their
    /// active add-ons; this hangs the hours, the add-ons and the discount ladder off the room they
    /// belong to, so the site reads one object per room instead of indexing six parallel lists.
    /// </summary>
    public async Task<PublicCatalog> GetPublicCatalogAsync()
    {
        var sets = await _rooms.GetPublicCatalogSetsAsync();

        var hoursByRoom = sets.Hours.ToLookup(h => h.RoomId);
        var addonsByRoom = sets.Addons.ToLookup(a => a.RoomId);

        /* THE LADDER IS RESOLVED BY THE PROCEDURE'S OWN RULE: a room with rungs of its own uses them
           and nothing else; a room with none uses the café's defaults (RoomId NULL). All-or-nothing
           per room, because that is what fn_PriceQuote does — a merged list would print a discount
           the server would then refuse to give. */
        var discountsByRoom = sets.Discounts.Where(d => d.RoomId is not null).ToLookup(d => d.RoomId!.Value);
        var defaultDiscounts = sets.Discounts.Where(d => d.RoomId is null).ToList();

        foreach (var room in sets.Rooms)
        {
            room.Hours = hoursByRoom[room.RoomId].OrderBy(h => h.DayOfWeek).ToList();
            room.Addons = addonsByRoom[room.RoomId].ToList();

            var own = discountsByRoom[room.RoomId].ToList();
            room.Discounts = (own.Count > 0 ? own : defaultDiscounts)
                .OrderBy(d => d.MinHours)
                .Select(d => new PublicRoomDiscount { MinHours = d.MinHours, DiscountPercent = d.DiscountPercent })
                .ToList();
        }

        return new PublicCatalog
        {
            Rooms = sets.Rooms,
            DepositTiers = sets.Tiers,
            Rules = sets.Rules,
        };
    }

    public Task<RoomCatalog> GetCatalogAsync(bool includeInactive)
        => _rooms.GetCatalogAsync(includeInactive);

    public Task<Room?> UpsertRoomAsync(int? roomId, RoomUpsertRequest request)
        => _rooms.UpsertRoomAsync(roomId, request);

    /// <summary>
    /// One procedure call per day, in DayOfWeek order. usp_Room_SetHours is a per-day MERGE and
    /// there is no procedure that takes a week, so a refused day stops the run with the days before
    /// it stored — and the caller is told which day failed.
    /// </summary>
    public async Task SetHoursAsync(int roomId, IEnumerable<RoomHoursRequest> hours)
    {
        foreach (var day in hours.OrderBy(h => h.DayOfWeek))
            await _rooms.SetHoursAsync(roomId, day);
    }

    public Task UpsertAddonAsync(int? addonId, int roomId, RoomAddonUpsertRequest request)
        => _rooms.UpsertAddonAsync(addonId, roomId, request);

    public async Task<IEnumerable<PaymentMethod>> GetActivePaymentMethodsAsync()
    {
        var methods = await _rooms.GetPaymentMethodsAsync();
        return methods.Where(method => method.IsActive).ToList();
    }

    public async Task<DayAvailability?> GetPublicDayAsync(string roomCode, DateTime onDate)
    {
        var day = await _rooms.GetDayAsync(roomCode, onDate);
        if (day is null)
            return null;

        // Not in the procedure's frame: read once here, so the free ranges and the "wrap up by" line
        // the site draws come from the same number.
        day.TurnaroundMinutes = await GetTurnaroundMinutesAsync();
        AvailabilityMath.Derive(day);
        return day;
    }

    /// <summary>
    /// The frame for the first of the month is read first — it is what says whether the room
    /// exists at all (usp_Availability_GetMonth answers "all closed" for an unknown code), and it
    /// carries the clock, the window and the room's minimum length that decide each day's word.
    /// </summary>
    public async Task<MonthAvailability?> GetPublicMonthAsync(string roomCode, DateTime monthDate)
    {
        var first = new DateTime(monthDate.Year, monthDate.Month, 1);
        var frame = await _rooms.GetDayAsync(roomCode, first);
        if (frame is null)
            return null;

        var days = await _rooms.GetMonthAsync(roomCode, first);

        var today = frame.LocalNow.Date;
        var lastBookable = today.AddDays(frame.LeadMaxDays);
        var minMinutes = frame.MinHours * 60;

        return new MonthAvailability
        {
            RoomCode = frame.RoomCode,
            Month = first.ToString("yyyy-MM", CultureInfo.InvariantCulture),
            Days = days
                .Select(day => new MonthDayStatus
                {
                    Date = day.OnDate,
                    Status = AvailabilityMath.StatusOf(day, today, lastBookable, minMinutes),
                })
                .ToList(),
        };
    }

    private async Task<int> GetTurnaroundMinutesAsync()
    {
        var setting = await _settings.GetAsync(TurnaroundSetting);
        return int.TryParse(setting?.SettingValue?.Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var minutes) && minutes > 0
            ? minutes
            : 0;
    }
}
