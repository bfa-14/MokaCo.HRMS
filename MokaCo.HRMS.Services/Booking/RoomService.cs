using MokaCo.HRMS.Model.Booking;
using MokaCo.HRMS.Repository.Booking;

namespace MokaCo.HRMS.Services.Booking;

/// <summary>
/// The room catalogue. Thin over the repository except for one thing that is genuinely the service's
/// to decide: WHAT AN ANONYMOUS VISITOR IS SHOWN.
/// </summary>
public class RoomService : IRoomService
{
    private readonly IRoomRepository _rooms;
    public RoomService(IRoomRepository rooms) => _rooms = rooms;

    /// <summary>
    /// The public feed. Active rooms, and then hours and add-ons FILTERED TO THOSE ROOMS —
    /// usp_Room_GetAll returns the hours and add-ons of every room in the table regardless of the
    /// @IncludeInactive flag, so without this the site would receive the opening hours and price
    /// list of rooms it was never told about. Retired add-ons go too: an add-on switched off is one
    /// the procedure will refuse to price, and offering it would produce a total the guest was
    /// quoted and then not charged.
    /// </summary>
    public async Task<RoomCatalog> GetPublicCatalogAsync()
    {
        var catalog = await _rooms.GetCatalogAsync(includeInactive: false);

        var visible = catalog.Rooms.Select(room => room.RoomId).ToHashSet();

        return new RoomCatalog
        {
            Rooms = catalog.Rooms,
            Hours = catalog.Hours.Where(h => visible.Contains(h.RoomId)).ToList(),
            Addons = catalog.Addons.Where(a => visible.Contains(a.RoomId) && a.IsActive).ToList(),
        };
    }

    public Task<RoomCatalog> GetCatalogAsync(bool includeInactive)
        => _rooms.GetCatalogAsync(includeInactive);

    public Task<Room?> UpsertRoomAsync(int? roomId, RoomUpsertRequest request)
        => _rooms.UpsertRoomAsync(roomId, request);

    /// <summary>
    /// One procedure call per day. See <see cref="IRoomService.SetHoursAsync"/> for why this is not
    /// atomic and why the order matters.
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

    public Task<DayAvailability> GetDayAsync(int roomId, DateTime onDate)
        => _rooms.GetDayAsync(roomId, onDate);

    public Task<IEnumerable<MonthDayAvailability>> GetMonthAsync(int roomId, DateTime monthDate)
        => _rooms.GetMonthAsync(roomId, monthDate);
}
