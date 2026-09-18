using System.Data;
using Dapper;
using Microsoft.Data.SqlClient;
using MokaCo.HRMS.Tests.Attendance;

namespace MokaCo.HRMS.Tests.Booking;

/// <summary>
/// SQL 79 (docs/79_booking_guest_cancel_phone.sql) against the database the API uses:
/// booking.usp_Booking_CancelByGuest refuses a missing or non-matching phone and accepts any
/// spelling whose LAST 8 DIGITS match. Runs inside a transaction that is rolled back — the
/// throw-away booking (and the outbox rows its trigger writes) never persist. Skipped, with the
/// reason, when the database is not reachable.
/// </summary>
public class GuestCancelPhoneDbTests
{
    [DbFact]
    public async Task Guest_cancel_needs_the_bookings_phone_last_8_digits()
    {
        await using var db = new SqlConnection(DbFactAttribute.ConnectionString);
        await db.OpenAsync();
        await using var tx = db.BeginTransaction();

        try
        {
            var hasPhoneParam = await db.ExecuteScalarAsync<int>(
                "SELECT COUNT(*) FROM sys.parameters WHERE object_id = OBJECT_ID('booking.usp_Booking_CancelByGuest') AND name = '@Phone'",
                transaction: tx);
            Assert.True(hasPhoneParam == 1, "apply docs/79_booking_guest_cancel_phone.sql");

            var room = await db.ExecuteScalarAsync<string?>(
                "SELECT TOP 1 r.Code FROM booking.ROOM r WHERE r.IsActive = 1 AND EXISTS (SELECT 1 FROM booking.ROOM_HOURS h WHERE h.RoomId = r.RoomId AND h.DayOfWeek = 1 AND h.IsClosed = 0 AND h.OpenMin <= 600 AND h.CloseMin >= 720) ORDER BY r.SortOrder",
                transaction: tx);
            Assert.False(string.IsNullOrEmpty(room), "no active room open on a Monday 10:00–12:00");

            // 2099-06-15 is a Monday, far outside anything real. Source Manual skips the lead-time rules.
            var created = await db.QuerySingleAsync<(int BookingId, string BookingRef)>(
                "booking.usp_Booking_Create",
                new { RoomCode = room, BookDate = new DateTime(2099, 6, 15), StartTime = new TimeSpan(10, 0, 0), EndTime = new TimeSpan(12, 0, 0),
                      Persons = 2, GuestName = "ZZ script 79 test", GuestPhone = "+96170000005", Source = "Manual" },
                tx, commandType: CommandType.StoredProcedure);

            var wrong = await Assert.ThrowsAsync<SqlException>(() => db.ExecuteAsync(
                "booking.usp_Booking_CancelByGuest", new { Ref = created.BookingRef, Phone = "70 999 999" }, tx, commandType: CommandType.StoredProcedure));
            Assert.Equal(50000, wrong.Number);
            Assert.StartsWith("The phone number does not match", wrong.Message);

            var missing = await Assert.ThrowsAsync<SqlException>(() => db.ExecuteAsync(
                "booking.usp_Booking_CancelByGuest", new { Ref = created.BookingRef, Phone = (string?)null }, tx, commandType: CommandType.StoredProcedure));
            Assert.StartsWith("The phone number does not match", missing.Message);

            var still = await db.ExecuteScalarAsync<string>("SELECT [Status] FROM booking.BOOKING WHERE BookingId = @Id", new { Id = created.BookingId }, tx);
            Assert.Equal("Confirmed", still);

            // Same number, different spelling: the local part is what is compared.
            await db.ExecuteAsync("booking.usp_Booking_CancelByGuest", new { Ref = created.BookingRef, Phone = "0096170000005" }, tx, commandType: CommandType.StoredProcedure);

            var after = await db.QuerySingleAsync<(string Status, string CancelledBy, decimal RefundAmount, string RefundStatus)>(
                "SELECT [Status], CancelledBy, RefundAmount, RefundStatus FROM booking.BOOKING WHERE BookingId = @Id", new { Id = created.BookingId }, tx);
            Assert.Equal(("Cancelled", "Guest", 0m, "None"), after);
        }
        finally
        {
            try { await tx.RollbackAsync(); } catch { /* already rolled back by an aborted batch */ }
        }
    }

    [DbFact]
    public async Task Refund_lines_pass_the_check_constraint_as_negative_amounts()
    {
        await using var db = new SqlConnection(DbFactAttribute.ConnectionString);
        await db.OpenAsync();

        var definition = await db.ExecuteScalarAsync<string?>(
            "SELECT cc.[definition] FROM sys.check_constraints cc WHERE cc.parent_object_id = OBJECT_ID('booking.BOOKING_PAYMENT') AND cc.[name] = 'CK_PAY_Amount'");

        Assert.NotNull(definition);
        Assert.Contains("IsRefund", definition);
        Assert.Contains("<(0)", definition);   // a refund line may be negative — SQL 74
    }
}
