using System.Data;
using Dapper;
using Microsoft.Data.SqlClient;
using MokaCo.HRMS.Model.Booking;
using MokaCo.HRMS.Services.Booking;
using MokaCo.HRMS.Tests.Attendance;

namespace MokaCo.HRMS.Tests.Booking;

/// <summary>
/// SQL 89 (docs/89_booking_midnight_start.sql) against the database the API uses. A start after
/// midnight arrives in the contract shape — the NEXT date with startMin 0 — and is inside the opening
/// hours when the PREVIOUS date's window covers it: start + 1440 and end + 1440 up to that window's
/// CloseMin. Quote and create judge it the same way; the overlap test and availability compare across
/// midnight, so the fix cannot open a double booking.
///
/// Each test builds a throw-away room inside a transaction that is rolled back. Its week:
/// Monday 22:00–01:00, Tuesday 10:00–00:00 (closes AT midnight), every other day 10:00–22:00. The dates
/// are Monday 15 – Wednesday 17 June 2099; Source Manual keeps the lead-time rules out of the way, so
/// only the hours and the overlap speak. Skipped, with the reason, when the database is not reachable.
/// </summary>
public class MidnightStartDbTests
{
    private static readonly DateTime Mon = new(2099, 6, 15);
    private static readonly DateTime Tue = Mon.AddDays(1);
    private static readonly DateTime Wed = Mon.AddDays(2);

    private const string Closed = "The room is closed";
    private const string Taken = "That time was just taken";

    /// <summary>ISO weekday, Monday = 1 … Sunday = 7, the numbering of booking.ROOM_HOURS.DayOfWeek.</summary>
    private static int Dow(DateTime date) => ((int)date.DayOfWeek + 6) % 7 + 1;

    private static async Task<string> RoomAsync(SqlConnection db, SqlTransaction tx, IReadOnlyDictionary<int, (TimeSpan Open, TimeSpan Close)> hours)
    {
        Assert.True(await db.ExecuteScalarAsync<int>(
            "SELECT CASE WHEN OBJECT_DEFINITION(OBJECT_ID('booking.usp_Booking_Validate')) LIKE '%@PrevDow%' THEN 1 ELSE 0 END", transaction: tx) == 1,
            "apply docs/89_booking_midnight_start.sql");

        var roomId = await db.ExecuteScalarAsync<int>(
            "INSERT INTO booking.ROOM (Code, [Name], Seats, MinPersons, PricePerHour, MinHours, MaxHours, SortOrder, IsActive) " +
            "VALUES ('zz89', N'ZZ script 89 test', 8, 1, 10, 1, 6, 999, 1); SELECT CAST(SCOPE_IDENTITY() AS INT);",
            transaction: tx);

        for (var day = 1; day <= 7; day++)
        {
            var (open, close) = hours.TryGetValue(day, out var h) ? h : (new TimeSpan(10, 0, 0), new TimeSpan(22, 0, 0));
            await db.ExecuteAsync(
                "INSERT INTO booking.ROOM_HOURS (RoomId, DayOfWeek, OpenTime, CloseTime, IsClosed) VALUES (@roomId, @day, @open, @close, 0)",
                new { roomId, day, open, close }, tx);
        }

        return "zz89";
    }

    /// <summary>Monday 22:00–01:00, Tuesday 10:00–00:00, the rest 10:00–22:00.</summary>
    private static Task<string> TestRoomAsync(SqlConnection db, SqlTransaction tx) => RoomAsync(db, tx, new Dictionary<int, (TimeSpan, TimeSpan)>
    {
        [1] = (new TimeSpan(22, 0, 0), new TimeSpan(1, 0, 0)),
        [2] = (new TimeSpan(10, 0, 0), TimeSpan.Zero),
    });

    private static Task<dynamic> QuoteAsync(SqlConnection db, SqlTransaction tx, string room, DateTime date, int startMin, int endMin, string source = "Manual")
        => db.QuerySingleAsync("booking.usp_Booking_Quote",
            new { RoomCode = room, BookDate = date, StartMin = startMin, EndMin = endMin, Source = source },
            tx, commandType: CommandType.StoredProcedure);

    private static Task<(int BookingId, string BookingRef)> CreateAsync(SqlConnection db, SqlTransaction tx, string room, DateTime date, int startMin, int endMin)
        => db.QuerySingleAsync<(int, string)>("booking.usp_Booking_Create",
            new { RoomCode = room, BookDate = date, StartTime = MinuteClock.StartTime(startMin), EndTime = MinuteClock.EndTime(endMin),
                  Persons = 2, GuestName = "ZZ script 89 test", GuestPhone = "+96170000089", Source = "Manual" },
            tx, commandType: CommandType.StoredProcedure);

    private static async Task RefusedAsync(string expected, Func<Task> call)
    {
        var refusal = await Assert.ThrowsAsync<SqlException>(call);
        Assert.Equal(50000, refusal.Number);
        Assert.StartsWith(expected, refusal.Message);
    }

    private static async Task InRolledBackTransactionAsync(Func<SqlConnection, SqlTransaction, Task> body)
    {
        await using var db = new SqlConnection(DbFactAttribute.ConnectionString);
        await db.OpenAsync();
        await using var tx = db.BeginTransaction();
        try
        {
            await body(db, tx);
        }
        finally
        {
            try { await tx.RollbackAsync(); } catch { /* already rolled back by the procedure (slot taken) */ }
        }
    }

    [DbFact]
    public Task Midnight_to_one_after_a_day_closing_at_one_is_quoted_and_created() => InRolledBackTransactionAsync(async (db, tx) =>
    {
        var room = await TestRoomAsync(db, tx);

        var quote = await QuoteAsync(db, tx, room, Tue, 0, 60);
        Assert.Equal(1m, (decimal)quote.Hours);

        var created = await CreateAsync(db, tx, room, Tue, 0, 60);
        var stored = await db.QuerySingleAsync<(DateTime BookDate, int StartMin, int EndMin)>(
            "SELECT BookDate, StartMin, EndMin FROM booking.BOOKING WHERE BookingId = @Id", new { Id = created.BookingId }, tx);
        Assert.Equal((Tue, 0, 60), stored);     // stored on the NEXT date, as the website sends it
    });

    [DbFact]
    public Task Half_past_midnight_to_half_past_one_runs_past_the_close_and_is_refused() => InRolledBackTransactionAsync(async (db, tx) =>
    {
        var room = await TestRoomAsync(db, tx);

        await RefusedAsync(Closed, () => QuoteAsync(db, tx, room, Tue, 30, 90));
        await RefusedAsync(Closed, () => CreateAsync(db, tx, room, Tue, 30, 90));
    });

    [DbFact]
    public Task Midnight_after_a_day_closing_at_midnight_is_refused() => InRolledBackTransactionAsync(async (db, tx) =>
    {
        var room = await TestRoomAsync(db, tx);

        // Tuesday's window ends at 00:00 (CloseMin 1440): Wednesday 00:00 is outside every window.
        await RefusedAsync(Closed, () => QuoteAsync(db, tx, room, Wed, 0, 60));
        await RefusedAsync(Closed, () => CreateAsync(db, tx, room, Wed, 0, 60));
    });

    [DbFact]
    public Task Slots_inside_a_dates_own_hours_are_judged_as_before() => InRolledBackTransactionAsync(async (db, tx) =>
    {
        var room = await TestRoomAsync(db, tx);

        await QuoteAsync(db, tx, room, Wed, 600, 720);                               // 10:00–12:00
        await RefusedAsync(Closed, () => QuoteAsync(db, tx, room, Wed, 540, 600));   // 09:00–10:00, before opening
        await RefusedAsync(Closed, () => QuoteAsync(db, tx, room, Wed, 1260, 1380)); // 21:00–23:00, past closing

        await QuoteAsync(db, tx, room, Mon, 1320, 1500);                             // 22:00–01:00 on its own date
        await RefusedAsync(Closed, () => QuoteAsync(db, tx, room, Mon, 1260, 1320)); // 21:00–22:00
        await QuoteAsync(db, tx, room, Tue, 1320, 1440);                             // 22:00–00:00
        await RefusedAsync(Closed, () => QuoteAsync(db, tx, room, Tue, 1380, 1500)); // 23:00–01:00, Tuesday closes at 00:00
        await RefusedAsync(Closed, () => QuoteAsync(db, tx, room, Tue, 60, 120));    // 01:00–02:00, after Monday's 01:00 close
    });

    [DbFact]
    public Task A_booking_running_past_midnight_takes_the_next_dates_midnight_start() => InRolledBackTransactionAsync(async (db, tx) =>
    {
        var room = await TestRoomAsync(db, tx);

        await CreateAsync(db, tx, room, Mon, 1380, 1500);                            // Monday 23:00–01:00
        await RefusedAsync(Taken, () => CreateAsync(db, tx, room, Tue, 0, 60));      // Tuesday 00:00–01:00: the same hour
    });

    [DbFact]
    public Task A_midnight_start_takes_the_previous_dates_booking_past_midnight() => InRolledBackTransactionAsync(async (db, tx) =>
    {
        var room = await TestRoomAsync(db, tx);

        await CreateAsync(db, tx, room, Tue, 0, 60);                                 // Tuesday 00:00–01:00
        await RefusedAsync(Taken, () => CreateAsync(db, tx, room, Mon, 1380, 1500)); // Monday 23:00–01:00 overlaps it
    });

    [DbFact]
    public Task Ranges_that_only_touch_at_midnight_both_stand() => InRolledBackTransactionAsync(async (db, tx) =>
    {
        var room = await TestRoomAsync(db, tx);

        await CreateAsync(db, tx, room, Tue, 0, 60);                                 // Tuesday 00:00–01:00
        await CreateAsync(db, tx, room, Mon, 1320, 1440);                            // Monday 22:00–00:00 ends as it starts

        var count = await db.ExecuteScalarAsync<int>(
            "SELECT COUNT(*) FROM booking.BOOKING b JOIN booking.ROOM r ON r.RoomId = b.RoomId WHERE r.Code = @room", new { room }, tx);
        Assert.Equal(2, count);
    });

    [DbFact]
    public Task A_staff_block_past_midnight_takes_the_midnight_start() => InRolledBackTransactionAsync(async (db, tx) =>
    {
        var room = await TestRoomAsync(db, tx);

        await db.ExecuteAsync(
            "INSERT INTO booking.BOOKING_BLOCK (RoomId, BlockDate, StartTime, EndTime, Reason) " +
            "SELECT RoomId, @Mon, '23:30', '00:30', N'ZZ script 89 test' FROM booking.ROOM WHERE Code = @room",
            new { Mon, room }, tx);

        await RefusedAsync(Taken, () => CreateAsync(db, tx, room, Tue, 0, 60));
    });

    [DbFact]
    public Task Availability_shows_the_midnight_booking_inside_the_previous_dates_window() => InRolledBackTransactionAsync(async (db, tx) =>
    {
        var room = await TestRoomAsync(db, tx);
        await CreateAsync(db, tx, room, Tue, 0, 60);                                 // Tuesday 00:00–01:00

        // Monday's day view: the booking is Monday's 1440–1500, so only 22:00–00:00 is left.
        var monday = await ReadDayAsync(db, tx, room, Mon);
        Assert.Equal((1320, 1500), (monday.Frame.OpenMin, monday.Frame.CloseMin));
        Assert.Contains((1440, 1500), monday.Taken);
        var free = AvailabilityMath.FreeRanges(1320, 1500,
            monday.Taken.Select(t => new TakenRange { StartMin = t.StartMin, EndMin = t.EndMin }), 1320, 60);
        Assert.Equal(new[] { (1320, 1440) }, free.Select(f => (f.StartMin, f.EndMin)));

        // Tuesday's own list still names it (it IS Tuesday's), before Tuesday's 10:00 opening.
        var tuesday = await ReadDayAsync(db, tx, room, Tue);
        Assert.Equal(new[] { (0, 60) }, tuesday.Taken);

        // The month counts it where it falls: in Monday's window, not in Tuesday's hours.
        var month = (await db.QueryAsync<(DateTime OnDate, bool IsClosed, int OpenMinutes, int TakenMinutes, int MaxFreeRun)>(
            "booking.usp_Availability_GetMonth", new { RoomCode = room, MonthDate = Mon }, tx, commandType: CommandType.StoredProcedure))
            .ToDictionary(d => d.OnDate);
        Assert.Equal((180, 60, 120), (month[Mon].OpenMinutes, month[Mon].TakenMinutes, month[Mon].MaxFreeRun));
        Assert.Equal((840, 0, 840), (month[Tue].OpenMinutes, month[Tue].TakenMinutes, month[Tue].MaxFreeRun));
    });

    [DbFact]
    public Task The_websites_midnight_start_is_quoted_on_a_real_date() => InRolledBackTransactionAsync(async (db, tx) =>
    {
        // The report's exact path: Source Website, the next date with startMin 0, a date inside the
        // booking window — so the step, length and lead-time rules run too.
        var today = await db.ExecuteScalarAsync<DateTime>("SELECT CAST(booking.fn_LocalNow() AS DATE)", transaction: tx);
        var leadMaxDays = await db.ExecuteScalarAsync<int?>("SELECT TRY_CAST(SettingValue AS INT) FROM core.SETTING WHERE SettingKey = 'BookingLeadMaxDays'", transaction: tx) ?? 30;
        var leadMinHours = await db.ExecuteScalarAsync<int?>("SELECT TRY_CAST(SettingValue AS INT) FROM core.SETTING WHERE SettingKey = 'BookingLeadMinHours'", transaction: tx) ?? 0;
        var date = today.AddDays(3);
        Assert.True(leadMaxDays >= 3 && leadMinHours < 48, $"the settings leave no room for a date 3 days out (BookingLeadMaxDays {leadMaxDays}, BookingLeadMinHours {leadMinHours})");

        var room = await RoomAsync(db, tx, new Dictionary<int, (TimeSpan, TimeSpan)>
        {
            [Dow(date.AddDays(-1))] = (new TimeSpan(22, 0, 0), new TimeSpan(1, 0, 0)),   // like Aden: 10:00 PM – 1:00 AM
        });

        var quote = await QuoteAsync(db, tx, room, date, 0, 60, source: "Website");
        Assert.Equal(1m, (decimal)quote.Hours);
        await RefusedAsync(Closed, () => QuoteAsync(db, tx, room, date, 60, 120, source: "Website"));
    });

    private static async Task<(DayFrame Frame, List<(int StartMin, int EndMin)> Taken)> ReadDayAsync(SqlConnection db, SqlTransaction tx, string room, DateTime date)
    {
        using var multi = await db.QueryMultipleAsync("booking.usp_Availability_GetDay",
            new { RoomCode = room, OnDate = date }, tx, commandType: CommandType.StoredProcedure);
        var frame = await multi.ReadSingleAsync<DayFrame>();
        var taken = (await multi.ReadAsync<(int, int)>()).ToList();
        return (frame, taken);
    }

    private sealed class DayFrame
    {
        public int? OpenMin { get; set; }
        public int? CloseMin { get; set; }
    }
}
