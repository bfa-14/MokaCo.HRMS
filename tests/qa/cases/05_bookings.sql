/* ============================================================================
   cases/05_bookings.sql — database-side checks for B0..B7 (the HTTP traffic against the
   public booking contract and the staff refund/cancel-by endpoints is in api-tests.mjs
   phase2) plus the two rules exercised again at procedure level: guest cancel with the
   phone match (SQL 79) and refund recording through usp_Refund_Add (SQL 74).
   ============================================================================ */
SET NOCOUNT ON;
DECLARE @Room INT = (SELECT RoomId FROM booking.ROOM WHERE Code = 'qa-room');
DECLARE @b1 INT = TRY_CAST((SELECT [Value] FROM dbo.QA_STATE WHERE [Key] = 'booking.b1') AS INT);
DECLARE @b4a INT = TRY_CAST((SELECT [Value] FROM dbo.QA_STATE WHERE [Key] = 'booking.b4a') AS INT);
DECLARE @b4b INT = TRY_CAST((SELECT [Value] FROM dbo.QA_STATE WHERE [Key] = 'booking.b4b') AS INT);
DECLARE @b5 INT = TRY_CAST((SELECT [Value] FROM dbo.QA_STATE WHERE [Key] = 'booking.b5') AS INT);
DECLARE @exp NVARCHAR(600), @act NVARCHAR(600), @pass BIT, @t NVARCHAR(1000), @n INT;
DECLARE @Cash INT = (SELECT PaymentMethodId FROM booking.PAYMENT_METHOD WHERE Name = N'Cash');

/* B0: the four public routes the website calls (api.ts: catalog, availability, quote, GET {ref}) answered
   during api-tests phase2 — recorded there in QA_STATE, judged here so the SQL summary carries it. */
DECLARE @routes NVARCHAR(400) = (SELECT [Value] FROM dbo.QA_STATE WHERE [Key] = 'booking.routes');
SET @act = ISNULL(@routes, 'not recorded (api-tests phase2 did not run)');
SET @pass = CASE WHEN @routes LIKE '%catalog=200%' AND @routes LIKE '%availability=200%' AND @routes LIKE '%quote=200%' AND @routes LIKE '%byref=200%' THEN 1 ELSE 0 END;
EXEC dbo.QA_Check 'B0', 'the public booking routes the website calls (GET catalog, GET availability?room&date, POST quote, GET {ref}) all answer on /api/public/booking', 'catalog=200, availability=200, quote=200, byref=200', @act, @pass;

/* B1: one live booking on the slot */
SELECT @n = COUNT(*) FROM booking.BOOKING b WHERE b.RoomId = @Room AND b.BookDate = (SELECT BookDate FROM booking.BOOKING WHERE BookingId = @b1) AND b.StartMin = 600 AND b.[Status] IN ('Pending', 'Confirmed');
SET @act = ISNULL(CAST(@n AS NVARCHAR(10)), 'n/a'); SET @pass = CASE WHEN @n = 1 THEN 1 ELSE 0 END;
EXEC dbo.QA_Check 'B1c', 'after the duplicate create attempt the slot still holds exactly one live booking', '1', @act, @pass;

/* B2 at procedure level: usp_Booking_Create accepts an end time after midnight (EndMin 1500) */
DECLARE @d2 DATE = DATEADD(DAY, 16, CAST(GETDATE() AS DATE));
DECLARE @c TABLE (BookingId INT, BookingRef VARCHAR(12), TotalAmount DECIMAL(10,2), DepositDue DECIMAL(10,2), DepositPercent DECIMAL(5,2), CurrencyCode CHAR(3), [Status] VARCHAR(12), Hours DECIMAL(6,2), RoomName NVARCHAR(80), RoomId INT, DiscountPercent DECIMAL(5,2), DiscountAmount DECIMAL(10,2));
SET @act = NULL; SET @pass = 0;
BEGIN TRY
    INSERT INTO @c EXEC booking.usp_Booking_Create @RoomId = @Room, @BookDate = @d2, @StartTime = '22:00', @EndTime = '01:00', @Persons = 2, @GuestName = N'QA Guest B2 proc', @GuestPhone = '+96170000009', @Source = 'Manual';
    SELECT @act = CONCAT('status=', [Status], ' hours=', Hours, ' total=', TotalAmount) FROM @c;
    SELECT @act = CONCAT(@act, ' startMin=', StartMin, ' endMin=', EndMin), @pass = CASE WHEN EndMin = 1500 AND StartMin = 1320 THEN 1 ELSE 0 END FROM booking.BOOKING WHERE BookingId = (SELECT TOP 1 BookingId FROM @c);
    UPDATE core.EMAIL_OUTBOX SET [Status] = 'QaHeld' WHERE BookingId = (SELECT TOP 1 BookingId FROM @c) AND [Status] = 'Pending';
END TRY
BEGIN CATCH SET @act = ERROR_MESSAGE(); SET @pass = 0; END CATCH;
SET @act = ISNULL(@act, 'no result');
EXEC dbo.QA_Check 'B2c', 'usp_Booking_Create 22:00-01:00 (end after midnight) -> row with StartMin 1320 / EndMin 1500', 'startMin=1320 endMin=1500, hours 3', @act, @pass;
SELECT @n = COUNT(*) FROM booking.BOOKING WHERE RoomId = @Room AND BookDate = @d2 AND [Status] IN ('Pending','Confirmed') AND StartMin < 1500 AND EndMin > 1320;
SET @act = CAST(@n AS NVARCHAR(10)); SET @pass = CASE WHEN @n = 1 THEN 1 ELSE 0 END;
EXEC dbo.QA_Check 'B2d', 'the availability rule (usp_Availability_GetDay: StartMin < end AND EndMin > start) reports the 22:00-01:00 slot as taken', '1 overlapping live booking', @act, @pass;

/* B3: outbox kinds for B1 (rows were held by the test harness before the mail worker could send them) */
SET @act = (SELECT ISNULL(STRING_AGG(CONCAT(MailKind, '/', Channel, ':', [Status]), ', ') WITHIN GROUP (ORDER BY EmailId), 'no rows') FROM core.EMAIL_OUTBOX WHERE BookingId = @b1);
SELECT @n = COUNT(DISTINCT MailKind) FROM core.EMAIL_OUTBOX WHERE BookingId = @b1 AND Channel = 'Email' AND MailKind IN ('Request', 'StaffAlert', 'Confirmation');
SET @pass = CASE WHEN @n = 3 THEN 1 ELSE 0 END;
EXEC dbo.QA_Check 'B3c', 'B1 outbox after create + staff confirm: Request, StaffAlert (at creation) and Confirmation (at confirm) e-mail rows', 'Request/Email, StaffAlert/Email, Confirmation/Email', @act, @pass;
SELECT @n = COUNT(*) FROM core.EMAIL_OUTBOX o JOIN booking.BOOKING b ON b.BookingId = o.BookingId WHERE b.GuestName LIKE N'QA %' AND b.[Source] = 'Website' AND b.[Status] = 'Pending' AND o.MailKind = 'Confirmation';
SET @act = CAST(@n AS NVARCHAR(10)); SET @pass = CASE WHEN @n = 0 THEN 1 ELSE 0 END;
EXEC dbo.QA_Check 'B3d', 'website bookings that are still Pending have no Confirmation mail queued', '0', @act, @pass;

/* B4: guest cancel at procedure level (SQL 79: @Phone must match the booking's last 8 digits): paid 30, deposit 20 % -> refund 10 */
DECLARE @ref VARCHAR(12) = (SELECT BookingRef FROM booking.BOOKING WHERE BookingId = @b4b);
DECLARE @paid DECIMAL(10,2) = (SELECT ISNULL(SUM(Amount), 0) FROM booking.BOOKING_PAYMENT WHERE BookingId = @b4b);
DECLARE @dep DECIMAL(10,2) = (SELECT DepositDue FROM booking.BOOKING WHERE BookingId = @b4b);
DECLARE @refExp DECIMAL(10,2) = CASE WHEN @paid - @dep < 0 THEN 0 ELSE @paid - @dep END;
SET @act = NULL; SET @pass = 0;
BEGIN TRY
    EXEC booking.usp_Booking_CancelByGuest @Ref = @ref, @Phone = '70 999 999';
    SET @act = 'accepted a non-matching phone';
END TRY
BEGIN CATCH
    SELECT @act = CONCAT('refused: ', ERROR_MESSAGE(), '; status=', (SELECT [Status] FROM booking.BOOKING WHERE BookingId = @b4b)),
           @pass = CASE WHEN ERROR_MESSAGE() LIKE 'The phone number does not match%' AND (SELECT [Status] FROM booking.BOOKING WHERE BookingId = @b4b) = 'Confirmed' THEN 1 ELSE 0 END;
END CATCH;
EXEC dbo.QA_Check 'B4h', 'usp_Booking_CancelByGuest with a phone whose last 8 digits differ -> RAISERROR, booking untouched', 'refused: The phone number does not match this booking.; status=Confirmed', @act, @pass;
SET @exp = CONCAT('status=Cancelled cancelledBy=Guest refundAmount=', @refExp, ' (paid ', @paid, ' - deposit ', @dep, ') refundStatus=Due');
SET @act = NULL; SET @pass = 0;
BEGIN TRY
    EXEC booking.usp_Booking_CancelByGuest @Ref = @ref, @Phone = '0096170000005';   -- the booking holds +96170000005; the last 8 digits are what count
    SELECT @act = CONCAT('status=', [Status], ' cancelledBy=', CancelledBy, ' refundAmount=', RefundAmount, ' refundStatus=', RefundStatus), @pass = CASE WHEN [Status] = 'Cancelled' AND CancelledBy = 'Guest' AND RefundAmount = @refExp AND RefundStatus = 'Due' THEN 1 ELSE 0 END FROM booking.BOOKING WHERE BookingId = @b4b;
    UPDATE core.EMAIL_OUTBOX SET [Status] = 'QaHeld' WHERE BookingId = @b4b AND [Status] = 'Pending';
END TRY
BEGIN CATCH SET @act = ERROR_MESSAGE(); SET @pass = 0; END CATCH;
SET @act = ISNULL(@act, 'no result');
EXEC dbo.QA_Check 'B4d', 'guest cancel (usp_Booking_CancelByGuest @Ref, @Phone; deposit not refundable): refund = paid - deposit', @exp, @act, @pass;

/* B4: refund recording at procedure level (SQL 74: CK_PAY_Amount admits the negative line) on the guest-cancelled booking:
   10 first -> Partial, then the rest of what is due -> Refunded. (The staff-cancelled booking b4a was refunded through the API in B4c.) */
DECLARE @r TABLE (PaymentId INT, RefundedTotal DECIMAL(10,2), RefundDue DECIMAL(10,2), RefundStatus VARCHAR(10));
DECLARE @due DECIMAL(10,2) = (SELECT RefundAmount FROM booking.BOOKING WHERE BookingId = @b4b);
DECLARE @rest DECIMAL(10,2) = @due - 10;
SET @exp = CONCAT('after 10: Partial; after ', @rest, ' more (', @due, ' due): Refunded; CK_PAY_Amount holds a -10.00 line');
SET @act = NULL; SET @pass = 0;
BEGIN TRY
    INSERT INTO @r EXEC booking.usp_Refund_Add @BookingId = @b4b, @Amount = 10, @PaymentMethodId = @Cash, @Reference = N'QA partial refund';
    SELECT @act = CONCAT('after 10: ', RefundStatus, ' (refunded ', RefundedTotal, ' of ', RefundDue, ')') FROM @r;
    DELETE FROM @r;
    INSERT INTO @r EXEC booking.usp_Refund_Add @BookingId = @b4b, @Amount = @rest, @PaymentMethodId = @Cash, @Reference = N'QA rest';
    SELECT @act = CONCAT(@act, '; after ', @rest, ' more: ', RefundStatus, ' (refunded ', RefundedTotal, ')'), @pass = CASE WHEN RefundStatus = 'Refunded' THEN 1 ELSE 0 END FROM @r;
    SELECT @act = CONCAT(@act, '; lines=', STRING_AGG(CONCAT(Amount, CASE WHEN IsRefund = 1 THEN 'R' ELSE '' END), ',') WITHIN GROUP (ORDER BY PaymentId)) FROM booking.BOOKING_PAYMENT WHERE BookingId = @b4b;
    IF NOT EXISTS (SELECT 1 FROM booking.BOOKING_PAYMENT WHERE BookingId = @b4b AND IsRefund = 1 AND Amount = -10) SET @pass = 0;
    UPDATE core.EMAIL_OUTBOX SET [Status] = 'QaHeld' WHERE BookingId = @b4b AND [Status] = 'Pending';
END TRY
BEGIN CATCH SET @act = ERROR_MESSAGE(); SET @pass = 0; END CATCH;
SET @act = ISNULL(@act, 'no result');
EXEC dbo.QA_Check 'B4i', 'recording refunds with usp_Refund_Add on the guest-cancelled booking flips RefundStatus Due -> Partial (10) -> Refunded (the rest), the lines stored negative with IsRefund = 1 (SQL 74)', @exp, @act, @pass;
/* B4c at the API level (staff-cancelled booking, refunded through POST /api/bookings/{id}/refunds in api-tests): the row agrees */
SET @act = NULL; SET @pass = 0;
SELECT @act = CONCAT('cancelledBy=', CancelledBy, ' refundAmount=', RefundAmount, ' refundStatus=', RefundStatus, ' refundedUtc=', CASE WHEN RefundedUtc IS NULL THEN 'NULL' ELSE 'set' END,
                     ' refundLines=', (SELECT COUNT(*) FROM booking.BOOKING_PAYMENT WHERE BookingId = @b4a AND IsRefund = 1),
                     ' refunded=', (SELECT ISNULL(-SUM(Amount), 0) FROM booking.BOOKING_PAYMENT WHERE BookingId = @b4a AND IsRefund = 1)),
       @pass = CASE WHEN CancelledBy = 'Staff' AND RefundAmount = 30 AND RefundStatus = 'Refunded' AND RefundedUtc IS NOT NULL
                     AND (SELECT ISNULL(-SUM(Amount), 0) FROM booking.BOOKING_PAYMENT WHERE BookingId = @b4a AND IsRefund = 1) = 30 THEN 1 ELSE 0 END
FROM booking.BOOKING WHERE BookingId = @b4a;
SET @act = ISNULL(@act, 'no booking');
EXEC dbo.QA_Check 'B4j', 'the staff-cancelled booking refunded through the API (B4c) is stored Refunded with two negative IsRefund lines summing to 30 and RefundedUtc set', 'cancelledBy=Staff refundAmount=30.00 refundStatus=Refunded refundedUtc=set refundLines=2 refunded=30.00', @act, @pass;

/* B5: stored figures */
SET @act = NULL; SET @pass = 0;
SELECT @act = CONCAT('discountPct=', DiscountPercent, ' discount=', DiscountAmount, ' total=', TotalAmount, ' depositPct=', DepositPercent, ' deposit=', DepositDue, ' addons=', (SELECT ISNULL(SUM(Amount), 0) FROM booking.BOOKING_ADDON WHERE BookingId = @b5)),
       @pass = CASE WHEN DiscountAmount = 6 AND TotalAmount = 69 AND DepositDue = 13.80 THEN 1 ELSE 0 END
FROM booking.BOOKING WHERE BookingId = @b5;
SET @act = ISNULL(@act, 'no booking');
EXEC dbo.QA_Check 'B5c', 'B5 stored: 10 % discount on the room only (6.00), total 69.00 incl. the 15.00 add-on, deposit 20 % of the discounted total (13.80)', 'discount=6.00 total=69.00 deposit=13.80 addons=15.00', @act, @pass;

EXEC dbo.QA_Note 'Bookings: the HTTP checks (B0a, B1a/b/d, B2a/b/e/f, B3a/b, B4a/c/e/f/g/m, B5a/b/d, B6a/b/c, B7a/b/c/d) are in api-tests.mjs phase2 against /api/public/booking (Origin http://localhost:4321) and /api/bookings; this file holds the row-level checks and the procedure-level guest cancel (@Phone) and refund recording.';
GO
