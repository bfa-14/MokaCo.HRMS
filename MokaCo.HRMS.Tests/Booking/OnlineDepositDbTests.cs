using System.Data;
using Dapper;
using Microsoft.Data.SqlClient;
using MokaCo.HRMS.Api.PublicBooking;
using MokaCo.HRMS.Model.Booking;
using MokaCo.HRMS.Tests.Attendance;

namespace MokaCo.HRMS.Tests.Booking;

/// <summary>
/// SQL 88 (docs/88_booking_online_deposit.sql) against the database the API uses: what /pay may
/// start (and the code each refusal maps to), what it stamps, and that recording the same gateway
/// order twice — one after the other, or at the same moment from two connections — leaves ONE
/// payment line. Throw-away bookings on 2099-06-22 (a Monday; the QA case uses the 15th). Skipped,
/// with the reason, when the database is not reachable.
/// </summary>
public class OnlineDepositDbTests
{
    private static readonly DateTime Day = new(2099, 6, 22);

    private static async Task RequireScript88(SqlConnection db, SqlTransaction? tx = null)
    {
        var applied = await db.ExecuteScalarAsync<int>(
            "SELECT COUNT(*) FROM sys.indexes WHERE object_id = OBJECT_ID('booking.BOOKING_PAYMENT') AND name = 'UX_BOOKING_PAYMENT_GatewayOrder'",
            transaction: tx);
        Assert.True(applied == 1, "apply docs/88_booking_online_deposit.sql");
    }

    /// <summary>A website booking waiting for payment: made as a staff booking (no lead-time rules this far out), then turned Pending/Website.</summary>
    private static async Task<(int BookingId, string Ref, decimal Deposit)> WaitingForPaymentAsync(
        SqlConnection db, SqlTransaction? tx, TimeSpan start, string guest)
    {
        var room = await db.ExecuteScalarAsync<int?>(
            "SELECT TOP 1 r.RoomId FROM booking.ROOM r WHERE r.IsActive = 1 AND EXISTS (SELECT 1 FROM booking.ROOM_HOURS h WHERE h.RoomId = r.RoomId AND h.DayOfWeek = 1 AND h.IsClosed = 0 AND h.OpenMin <= 600 AND h.CloseMin >= 1020) ORDER BY r.SortOrder",
            transaction: tx);
        Assert.True(room is not null, "no active room open on a Monday 10:00-17:00");

        var created = await db.QuerySingleAsync<(int BookingId, string BookingRef, decimal TotalAmount, decimal DepositDue)>(
            "booking.usp_Booking_Create",
            new { RoomId = room, BookDate = Day, StartTime = start, EndTime = start.Add(TimeSpan.FromHours(1)),
                  Persons = 1, GuestName = guest, GuestPhone = "+96170000088", Source = "Manual" },
            tx, commandType: CommandType.StoredProcedure);

        await db.ExecuteAsync("UPDATE booking.BOOKING SET [Status] = 'Pending', [Source] = 'Website' WHERE BookingId = @Id",
            new { Id = created.BookingId }, tx);
        return (created.BookingId, created.BookingRef, created.DepositDue);
    }

    private static async Task<string> RefusalOf(SqlConnection db, SqlTransaction tx, string reference)
    {
        var refusal = await Assert.ThrowsAsync<SqlException>(() => db.ExecuteAsync(
            "booking.usp_Booking_StartPayment", new { Ref = reference }, tx, commandType: CommandType.StoredProcedure));
        Assert.Equal(50000, refusal.Number);
        return BookingRefusals.Classify(refusal.Message).Code;
    }

    [DbFact]
    public async Task Pay_starts_only_a_pending_unexpired_booking_and_each_refusal_has_its_code()
    {
        await using var db = new SqlConnection(DbFactAttribute.ConnectionString);
        await db.OpenAsync();
        await using var tx = db.BeginTransaction();
        try
        {
            await RequireScript88(db, tx);
            var (id, reference, deposit) = await WaitingForPaymentAsync(db, tx, new TimeSpan(10, 0, 0), "ZZ script 88 start");
            var holdMinutes = await db.ExecuteScalarAsync<int?>(
                "SELECT TRY_CAST(SettingValue AS INT) FROM core.SETTING WHERE SettingKey = 'BookingHoldMinutes'", transaction: tx) ?? 15;

            // happy path: stamped in one go, the deposit is the row's
            var started = await db.QuerySingleAsync<PaymentStarted>("booking.usp_Booking_StartPayment", new { Ref = reference }, tx, commandType: CommandType.StoredProcedure);
            Assert.Equal(deposit, started.DepositDue);
            Assert.Null(started.PreviousOpenedUtc);
            Assert.Equal(holdMinutes, (int)Math.Round((started.HoldExpiresUtc!.Value - started.PaymentOpenedUtc!.Value).TotalMinutes));
            Assert.Equal(reference, await db.ExecuteScalarAsync<string>("SELECT GatewayOrderId FROM booking.BOOKING WHERE BookingId = @Id", new { Id = id }, tx));

            // twice: allowed, says a session was opened before, same order id
            var again = await db.QuerySingleAsync<PaymentStarted>("booking.usp_Booking_StartPayment", new { Ref = reference }, tx, commandType: CommandType.StoredProcedure);
            Assert.NotNull(again.PreviousOpenedUtc);

            // the refusals
            Assert.Equal("not_found", await RefusalOf(db, tx, "MC-00000000"));

            await db.ExecuteAsync("UPDATE booking.BOOKING SET HoldExpiresUtc = DATEADD(MINUTE, -1, SYSUTCDATETIME()) WHERE BookingId = @Id", new { Id = id }, tx);
            Assert.Equal("hold_expired", await RefusalOf(db, tx, reference));

            await db.ExecuteAsync("UPDATE booking.BOOKING SET [Status] = 'Confirmed', HoldExpiresUtc = NULL WHERE BookingId = @Id", new { Id = id }, tx);
            Assert.Equal("not_pending", await RefusalOf(db, tx, reference));
        }
        finally
        {
            try { await tx.RollbackAsync(); } catch { /* already rolled back */ }
        }
    }

    [DbFact]
    public async Task Confirming_the_same_order_twice_records_one_line_and_confirms_once()
    {
        await using var db = new SqlConnection(DbFactAttribute.ConnectionString);
        await db.OpenAsync();
        await using var tx = db.BeginTransaction();
        try
        {
            await RequireScript88(db, tx);
            var (id, reference, deposit) = await WaitingForPaymentAsync(db, tx, new TimeSpan(11, 0, 0), "ZZ script 88 replay");
            await db.ExecuteAsync("booking.usp_Booking_StartPayment", new { Ref = reference }, tx, commandType: CommandType.StoredProcedure);

            async Task<OnlinePaymentRecorded> Confirm() => await db.QuerySingleAsync<OnlinePaymentRecorded>(
                "booking.usp_Booking_ConfirmOnlinePayment",
                new { Ref = reference, Amount = deposit, CurrencyCode = "USD", GatewayOrderId = reference, TransactionId = "db-test-1" },
                tx, commandType: CommandType.StoredProcedure);

            var first = await Confirm();
            var second = await Confirm();

            Assert.Equal(("Confirmed", "Confirmed"), (first.Outcome, first.Status));
            Assert.Equal(("Replay", "Confirmed"), (second.Outcome, second.Status));
            Assert.Equal(deposit, second.PaidAmount);

            var lines = (await db.QueryAsync<(decimal Amount, string GatewayOrderId, string GatewayTransactionId, string CurrencyCode, string Method)>(
                "SELECT p.Amount, p.GatewayOrderId, p.GatewayTransactionId, p.CurrencyCode, m.[Name] FROM booking.BOOKING_PAYMENT p JOIN booking.PAYMENT_METHOD m ON m.PaymentMethodId = p.PaymentMethodId WHERE p.BookingId = @Id",
                new { Id = id }, tx)).ToList();
            Assert.Equal((deposit, reference, "db-test-1", "USD", "Card (MPGS)"), Assert.Single(lines));

            var state = await db.QuerySingleAsync<(string Status, DateTime? HoldExpiresUtc, DateTime? PaidConfirmedUtc)>(
                "SELECT [Status], HoldExpiresUtc, PaidConfirmedUtc FROM booking.BOOKING WHERE BookingId = @Id", new { Id = id }, tx);
            Assert.Equal("Confirmed", state.Status);
            Assert.Null(state.HoldExpiresUtc);
            Assert.NotNull(state.PaidConfirmedUtc);

            Assert.True(await db.ExecuteScalarAsync<int>(
                "SELECT COUNT(*) FROM core.EMAIL_OUTBOX WHERE BookingId = @Id AND MailKind = 'PayReceived'", new { Id = id }, tx) <= 1);
        }
        finally
        {
            try { await tx.RollbackAsync(); } catch { /* already rolled back */ }
        }
    }

    [DbFact]
    public async Task Money_arriving_on_a_released_booking_is_recorded_and_marked_for_refund()
    {
        await using var db = new SqlConnection(DbFactAttribute.ConnectionString);
        await db.OpenAsync();
        await using var tx = db.BeginTransaction();
        try
        {
            await RequireScript88(db, tx);
            var (id, reference, deposit) = await WaitingForPaymentAsync(db, tx, new TimeSpan(12, 0, 0), "ZZ script 88 late");
            await db.ExecuteAsync("booking.usp_Booking_StartPayment", new { Ref = reference }, tx, commandType: CommandType.StoredProcedure);
            await db.ExecuteAsync("booking.usp_Booking_ReleaseHold", new { Ref = reference }, tx, commandType: CommandType.StoredProcedure);

            var recorded = await db.QuerySingleAsync<OnlinePaymentRecorded>(
                "booking.usp_Booking_ConfirmOnlinePayment",
                new { Ref = reference, Amount = deposit, CurrencyCode = "USD", GatewayOrderId = reference, TransactionId = "db-test-2" },
                tx, commandType: CommandType.StoredProcedure);

            Assert.Equal(("PaidButClosed", "Cancelled"), (recorded.Outcome, recorded.Status));
            var refund = await db.QuerySingleAsync<(decimal RefundAmount, string RefundStatus)>(
                "SELECT RefundAmount, RefundStatus FROM booking.BOOKING WHERE BookingId = @Id", new { Id = id }, tx);
            Assert.Equal((deposit, "Due"), refund);
        }
        finally
        {
            try { await tx.RollbackAsync(); } catch { /* already rolled back */ }
        }
    }

    /// <summary>
    /// THE RACE, FOR REAL: two connections confirm the same order at the same moment (the guest's
    /// return and the reconciliation job). The row lock queues the second behind the first, which
    /// then finds the line and answers Replay — no second line, and no unique-key error either.
    ///
    /// Two connections cannot share a transaction, so this booking is COMMITTED and deleted again in
    /// finally. It is made Confirmed before the race so no guest message is due, and its outbox rows
    /// are held (Status 'TestHeld', plus a held 'PayReceived' placeholder that makes the staff alert a
    /// no-op) so a running mail worker has nothing to send.
    /// </summary>
    [DbFact]
    public async Task Two_simultaneous_confirmations_of_one_order_leave_one_line()
    {
        int id = 0;
        await using (var setup = new SqlConnection(DbFactAttribute.ConnectionString))
        {
            await setup.OpenAsync();
            await RequireScript88(setup);
            await using var tx = setup.BeginTransaction();
            var made = await WaitingForPaymentAsync(setup, tx, new TimeSpan(13, 0, 0), "ZZ script 88 race test");
            id = made.BookingId;
            await setup.ExecuteAsync(
                """
                UPDATE booking.BOOKING SET [Status] = 'Confirmed', GatewayOrderId = BookingRef, PaymentOpenedUtc = SYSUTCDATETIME() WHERE BookingId = @Id;
                UPDATE core.EMAIL_OUTBOX SET [Status] = 'TestHeld' WHERE BookingId = @Id;
                INSERT INTO core.EMAIL_OUTBOX (ToAddress, [Subject], Body, Channel, Lang, BookingId, MailKind, [Status])
                VALUES (N'nobody@example.invalid', N'held', N'held', 'Email', 'en', @Id, 'PayReceived', 'TestHeld');
                """, new { Id = id }, tx);
            await tx.CommitAsync();
        }

        try
        {
            var reference = await ScalarAsync<string>("SELECT BookingRef FROM booking.BOOKING WHERE BookingId = @Id", id);
            var deposit = await ScalarAsync<decimal>("SELECT DepositDue FROM booking.BOOKING WHERE BookingId = @Id", id);

            async Task<string> ConfirmOnItsOwnConnection(string transactionId)
            {
                await using var db = new SqlConnection(DbFactAttribute.ConnectionString);
                await db.OpenAsync();
                var recorded = await db.QuerySingleAsync<OnlinePaymentRecorded>(
                    "booking.usp_Booking_ConfirmOnlinePayment",
                    new { Ref = reference, Amount = deposit, CurrencyCode = "USD", GatewayOrderId = reference, TransactionId = transactionId },
                    commandType: CommandType.StoredProcedure);
                return recorded.Outcome;
            }

            var outcomes = await Task.WhenAll(ConfirmOnItsOwnConnection("race-a"), ConfirmOnItsOwnConnection("race-b"));

            Assert.Equal(["Recorded", "Replay"], outcomes.Order());
            Assert.Equal(1, await ScalarAsync<int>("SELECT COUNT(*) FROM booking.BOOKING_PAYMENT WHERE BookingId = @Id", id));
            Assert.Equal(0, await ScalarAsync<int>("SELECT COUNT(*) FROM core.EMAIL_OUTBOX WHERE BookingId = @Id AND [Status] = 'Pending'", id));
        }
        finally
        {
            await using var cleanup = new SqlConnection(DbFactAttribute.ConnectionString);
            await cleanup.OpenAsync();
            await cleanup.ExecuteAsync(
                """
                DELETE FROM core.EMAIL_OUTBOX WHERE BookingId = @Id;
                DELETE FROM booking.BOOKING_PAYMENT WHERE BookingId = @Id;
                DELETE FROM booking.BOOKING_ADDON WHERE BookingId = @Id;
                DELETE FROM booking.BOOKING WHERE BookingId = @Id AND GuestName = N'ZZ script 88 race test';
                """, new { Id = id });
        }
    }

    private static async Task<T> ScalarAsync<T>(string sql, int bookingId)
    {
        await using var db = new SqlConnection(DbFactAttribute.ConnectionString);
        await db.OpenAsync();
        return await db.ExecuteScalarAsync<T>(sql, new { Id = bookingId }) ?? throw new InvalidOperationException("no value");
    }
}
