/* ============================================================================
   cases/05_bookings.sql — database-side checks for B1..B5 (the HTTP traffic is in
   api-tests.mjs phase2) plus the two rules the HRMS API does not expose
   (guest cancel, refund recording), exercised at procedure level.
   ============================================================================ */
SET NOCOUNT ON;
DECLARE @Room INT = (SELECT RoomId FROM booking.ROOM WHERE Code = 'qa-room');
DECLARE @b1 INT = TRY_CAST((SELECT [Value] FROM dbo.QA_STATE WHERE [Key] = 'booking.b1') AS INT);
DECLARE @b4a INT = TRY_CAST((SELECT [Value] FROM dbo.QA_STATE WHERE [Key] = 'booking.b4a') AS INT);
DECLARE @b4b INT = TRY_CAST((SELECT [Value] FROM dbo.QA_STATE WHERE [Key] = 'booking.b4b') AS INT);
DECLARE @b5 INT = TRY_CAST((SELECT [Value] FROM dbo.QA_STATE WHERE [Key] = 'booking.b5') AS INT);
DECLARE @exp NVARCHAR(600), @act NVARCHAR(600), @pass BIT, @t NVARCHAR(1000), @n INT;
DECLARE @Cash INT = (SELECT PaymentMethodId FROM booking.PAYMENT_METHOD WHERE Name = N'Cash');

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

/* B4: refund recording (staff cancel, refund due 30) */
DECLARE @r TABLE (PaymentId INT, RefundedTotal DECIMAL(10,2), RefundDue DECIMAL(10,2), RefundStatus VARCHAR(10));
SET @act = NULL; SET @pass = 0;
BEGIN TRY
    INSERT INTO @r EXEC booking.usp_Refund_Add @BookingId = @b4a, @Amount = 10, @PaymentMethodId = @Cash, @Reference = N'QA partial refund';
    SELECT @act = CONCAT('after 10: ', RefundStatus, ' (refunded ', RefundedTotal, ' of ', RefundDue, ')') FROM @r;
    DELETE FROM @r;
    INSERT INTO @r EXEC booking.usp_Refund_Add @BookingId = @b4a, @Amount = 20, @PaymentMethodId = @Cash, @Reference = N'QA rest';
    SELECT @act = CONCAT(@act, '; after 30: ', RefundStatus, ' (refunded ', RefundedTotal, ')'), @pass = CASE WHEN RefundStatus = 'Refunded' THEN 1 ELSE 0 END FROM @r;
    UPDATE core.EMAIL_OUTBOX SET [Status] = 'QaHeld' WHERE BookingId = @b4a AND [Status] = 'Pending';
END TRY
BEGIN CATCH SET @act = ERROR_MESSAGE(); SET @pass = 0; END CATCH;
SET @act = ISNULL(@act, 'no result');
EXEC dbo.QA_Check 'B4c', 'recording refunds on the staff-cancelled booking flips RefundStatus Due -> Partial (10) -> Refunded (30)', 'after 10: Partial; after 30: Refunded', @act, @pass;
/* B4: guest cancel (proc; not exposed by the HRMS API): paid 30, deposit 20 -> refund 10 */
DECLARE @ref VARCHAR(12) = (SELECT BookingRef FROM booking.BOOKING WHERE BookingId = @b4b);
DECLARE @paid DECIMAL(10,2) = (SELECT ISNULL(SUM(Amount), 0) FROM booking.BOOKING_PAYMENT WHERE BookingId = @b4b);
DECLARE @dep DECIMAL(10,2) = (SELECT DepositDue FROM booking.BOOKING WHERE BookingId = @b4b);
DECLARE @refExp DECIMAL(10,2) = CASE WHEN @paid - @dep < 0 THEN 0 ELSE @paid - @dep END;
SET @exp = CONCAT('status=Cancelled cancelledBy=Guest refundAmount=', @refExp, ' (paid ', @paid, ' - deposit ', @dep, ') refundStatus=Due');
SET @act = NULL; SET @pass = 0;
BEGIN TRY
    EXEC booking.usp_Booking_CancelByGuest @Ref = @ref;
    SELECT @act = CONCAT('status=', [Status], ' cancelledBy=', CancelledBy, ' refundAmount=', RefundAmount, ' refundStatus=', RefundStatus), @pass = CASE WHEN [Status] = 'Cancelled' AND CancelledBy = 'Guest' AND RefundAmount = @refExp THEN 1 ELSE 0 END FROM booking.BOOKING WHERE BookingId = @b4b;
    UPDATE core.EMAIL_OUTBOX SET [Status] = 'QaHeld' WHERE BookingId = @b4b AND [Status] = 'Pending';
END TRY
BEGIN CATCH SET @act = ERROR_MESSAGE(); SET @pass = 0; END CATCH;
SET @act = ISNULL(@act, 'no result');
EXEC dbo.QA_Check 'B4d', 'guest cancel (usp_Booking_CancelByGuest, deposit not refundable): refund = paid - deposit', @exp, @act, @pass;

/* B5: stored figures */
SET @act = NULL; SET @pass = 0;
SELECT @act = CONCAT('discountPct=', DiscountPercent, ' discount=', DiscountAmount, ' total=', TotalAmount, ' depositPct=', DepositPercent, ' deposit=', DepositDue, ' addons=', (SELECT ISNULL(SUM(Amount), 0) FROM booking.BOOKING_ADDON WHERE BookingId = @b5)),
       @pass = CASE WHEN DiscountAmount = 6 AND TotalAmount = 69 AND DepositDue = 13.80 THEN 1 ELSE 0 END
FROM booking.BOOKING WHERE BookingId = @b5;
SET @act = ISNULL(@act, 'no booking');
EXEC dbo.QA_Check 'B5c', 'B5 stored: 10 % discount on the room only (6.00), total 69.00 incl. the 15.00 add-on, deposit 20 % of the discounted total (13.80)', 'discount=6.00 total=69.00 deposit=13.80 addons=15.00', @act, @pass;

EXEC dbo.QA_Note 'Booking observations: the HRMS controller exposes GET rooms, rooms/{id}/month, rooms/{id}/day and POST bookings; the website (mokanco-lb/src/scripts/api.ts) calls /catalog, /quote, POST /, /{ref} and /{ref}/cancel with startMin/endMin bodies - none of which exist on the API (curl: 401/404). The DB procs for those calls exist (usp_Public_GetCatalog, usp_Booking_Quote, usp_Booking_GetByRef, usp_Booking_CancelByGuest, usp_Booking_ReleaseHold, usp_Booking_ExpireHolds) but are not wired.';
GO
