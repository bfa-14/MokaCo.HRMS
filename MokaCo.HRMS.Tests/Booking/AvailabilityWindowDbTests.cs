using System.Data;
using Dapper;
using Microsoft.Data.SqlClient;
using MokaCo.HRMS.Model.Booking;
using MokaCo.HRMS.Services.Booking;
using MokaCo.HRMS.Tests.Attendance;

namespace MokaCo.HRMS.Tests.Booking;

/// <summary>
/// docs/104_qa3_booking.sql against the database the API uses, for what the scenario script
/// tests/qa3/booking/availability_window.sql cannot reach (usp_Availability_GetDay answers two result
/// sets): QA3 BKG-11 — a DEACTIVATED room offered free time on the website while create refused it.
/// A throw-away room inside a transaction that is rolled back. Skipped, with the reason, when the
/// database is not reachable.
/// </summary>
public class AvailabilityWindowDbTests
{
    private static async Task<DayAvailability> ReadDayAsync(SqlConnection db, SqlTransaction tx, string room, DateTime date)
    {
        using var multi = await db.QueryMultipleAsync("booking.usp_Availability_GetDay",
            new { RoomId = (int?)null, RoomCode = room, OnDate = date }, tx, commandType: CommandType.StoredProcedure);
        var day = await multi.ReadFirstAsync<DayAvailability>();
        day.Taken = (await multi.ReadAsync<TakenRange>()).ToList();
        return day;
    }

    [DbFact]
    public async Task A_deactivated_room_offers_no_free_time()
    {
        await using var db = new SqlConnection(DbFactAttribute.ConnectionString);
        await db.OpenAsync();
        await using var tx = db.BeginTransaction();
        try
        {
            Assert.True(await db.ExecuteScalarAsync<int>("SELECT CASE WHEN OBJECT_ID('booking.fn_SettingIsOn') IS NULL THEN 0 ELSE 1 END", transaction: tx) == 1,
                "apply docs/104_qa3_booking.sql");

            var roomId = await db.ExecuteScalarAsync<int>(
                "INSERT INTO booking.ROOM (Code, [Name], Seats, MinPersons, PricePerHour, MinHours, MaxHours, SortOrder, IsActive) " +
                "VALUES ('zzqa3', N'ZZ QA3 retired room', 6, 1, 20, 1, 6, 999, 1); SELECT CAST(SCOPE_IDENTITY() AS INT);", transaction: tx);
            await db.ExecuteAsync(
                "INSERT INTO booking.ROOM_HOURS (RoomId, DayOfWeek, OpenTime, CloseTime, IsClosed) " +
                "SELECT @roomId, d, '07:00', '01:00', 0 FROM (VALUES (1),(2),(3),(4),(5),(6),(7)) v(d)", new { roomId }, tx);

            var date = (await db.ExecuteScalarAsync<DateTime>("SELECT CAST(booking.fn_LocalNow() AS DATE)", transaction: tx)).AddDays(3);

            var open = await ReadDayAsync(db, tx, "zzqa3", date);
            AvailabilityMath.Derive(open);
            Assert.False(open.IsClosed);
            Assert.NotEmpty(open.Free);

            await db.ExecuteAsync("UPDATE booking.ROOM SET IsActive = 0 WHERE RoomId = @roomId", new { roomId }, tx);

            var retired = await ReadDayAsync(db, tx, "zzqa3", date);
            Assert.True(retired.IsClosed);           // the frame itself says closed
            AvailabilityMath.Derive(retired);
            Assert.Empty(retired.Free);              // so the site is offered nothing
        }
        finally
        {
            try { await tx.RollbackAsync(); } catch { /* already rolled back */ }
        }
    }
}
