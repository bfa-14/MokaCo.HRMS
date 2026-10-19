/* ============================================================================
   tests/qa3/booking/reconcile_any_status.sql - QA3 BKG-4 (docs/104_qa3_booking.sql).

   usp_Booking_ListPaymentsToReconcile listed Pending bookings only, so a deposit captured on the
   gateway while staff confirmed or cancelled the booking (the guest's return trip lost) was never
   recorded. The list now holds, besides every opened Pending payment:

     R1  a Confirmed booking whose payment was opened 20 minutes ago, never checked    -> listed
     R2  a Cancelled one, opened 2 hours ago, last checked 90 minutes ago                -> listed
     R3  a Cancelled one checked 10 minutes ago (re-checked at most hourly)              -> not listed
     R4  a NoShow one opened 4 days ago (past the 72-hour window)                        -> not listed
     R5  a Confirmed one that already carries its gateway payment line                   -> not listed
     R6  a Pending one opened 20 minutes ago (as before)                                 -> listed
     R7  a booking opened 3 minutes ago (younger than @OpenedMinutesAgo = 10)            -> not listed
   and the result keeps script 88's eight columns (an INSERT ... EXEC into them works).

   One transaction, rolled back; bookings on 2099-06-15 in the throw-away room 'QA3 booking room'.
   RAISERROR on a wrong result; 'ok ...' otherwise.
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
DECLARE @fail NVARCHAR(1000) = NULL, @Room INT, @Day DATE = '2099-06-15', @i INT = 1;
DECLARE @made TABLE (BookingId INT, BookingRef VARCHAR(12), TotalAmount DECIMAL(10,2), DepositDue DECIMAL(10,2), DepositPercent DECIMAL(5,2), CurrencyCode CHAR(3), [Status] VARCHAR(12), Hours DECIMAL(6,2), RoomName NVARCHAR(80), RoomId INT, DiscountPercent DECIMAL(5,2), DiscountAmount DECIMAL(10,2));
DECLARE @rc TABLE (BookingId INT, BookingRef VARCHAR(12), DepositDue DECIMAL(10,2), CurrencyCode CHAR(3), PaymentOpenedUtc DATETIME2, PaymentCheckedUtc DATETIME2, HoldExpiresUtc DATETIME2, UnconfirmedAlerted BIT);
DECLARE @case TABLE (N INT PRIMARY KEY, BookingId INT, Expected BIT);
DECLARE @Start TIME(0), @End TIME(0), @Bid INT;

BEGIN TRAN;
BEGIN TRY
    INSERT INTO booking.ROOM (Code, [Name], Seats, MinPersons, PricePerHour, MinHours, MaxHours, SortOrder, IsActive)
    VALUES ('qa3-bk', N'QA3 booking room', 6, 1, 20, 1, 6, 999, 1);
    SET @Room = SCOPE_IDENTITY();
    INSERT INTO booking.ROOM_HOURS (RoomId, DayOfWeek, OpenTime, CloseTime, IsClosed)
    SELECT @Room, d, '07:00', '01:00', 0 FROM (VALUES (1),(2),(3),(4),(5),(6),(7)) v(d);

    /* seven one-hour bookings, 08:00, 09:00 ... (staff bookings: no lead-time rules this far out) */
    WHILE @i <= 7
    BEGIN
        SET @Start = DATEADD(HOUR, 7 + @i, CAST('00:00' AS TIME(0)));
        SET @End = DATEADD(HOUR, 1, @Start);
        DELETE FROM @made;
        INSERT INTO @made EXEC booking.usp_Booking_Create @RoomId = @Room, @BookDate = @Day, @StartTime = @Start,
             @EndTime = @End, @Persons = 1, @GuestName = N'QA3 Reconcile', @GuestPhone = '+96170000321', @Source = 'Manual';
        SELECT @Bid = BookingId FROM @made;
        INSERT INTO @case (N, BookingId, Expected) VALUES (@i, @Bid, CASE WHEN @i IN (1, 2, 6) THEN 1 ELSE 0 END);
        SET @i += 1;
    END
    UPDATE b SET [Source] = 'Website', OnlineDeposit = 1, GatewayOrderId = b.BookingRef
    FROM booking.BOOKING b JOIN @case c ON c.BookingId = b.BookingId;

    UPDATE b SET [Status] = 'Confirmed', PaymentOpenedUtc = DATEADD(MINUTE, -20, SYSUTCDATETIME()), PaymentCheckedUtc = NULL
    FROM booking.BOOKING b JOIN @case c ON c.BookingId = b.BookingId WHERE c.N = 1;
    UPDATE b SET [Status] = 'Cancelled', PaymentOpenedUtc = DATEADD(MINUTE, -120, SYSUTCDATETIME()), PaymentCheckedUtc = DATEADD(MINUTE, -90, SYSUTCDATETIME())
    FROM booking.BOOKING b JOIN @case c ON c.BookingId = b.BookingId WHERE c.N = 2;
    UPDATE b SET [Status] = 'Cancelled', PaymentOpenedUtc = DATEADD(MINUTE, -120, SYSUTCDATETIME()), PaymentCheckedUtc = DATEADD(MINUTE, -10, SYSUTCDATETIME())
    FROM booking.BOOKING b JOIN @case c ON c.BookingId = b.BookingId WHERE c.N = 3;
    UPDATE b SET [Status] = 'NoShow', PaymentOpenedUtc = DATEADD(DAY, -4, SYSUTCDATETIME()), PaymentCheckedUtc = NULL
    FROM booking.BOOKING b JOIN @case c ON c.BookingId = b.BookingId WHERE c.N = 4;
    UPDATE b SET [Status] = 'Confirmed', PaymentOpenedUtc = DATEADD(MINUTE, -20, SYSUTCDATETIME())
    FROM booking.BOOKING b JOIN @case c ON c.BookingId = b.BookingId WHERE c.N = 5;
    INSERT INTO booking.BOOKING_PAYMENT (BookingId, PaymentMethodId, Amount, Reference, IsRefund, GatewayOrderId, GatewayTransactionId, CurrencyCode)
    SELECT b.BookingId, (SELECT TOP 1 PaymentMethodId FROM booking.PAYMENT_METHOD ORDER BY IsOnline DESC, PaymentMethodId), 5, N'QA3 gateway line', 0, b.BookingRef, 'QA3-T5', 'USD'
    FROM booking.BOOKING b JOIN @case c ON c.BookingId = b.BookingId WHERE c.N = 5;
    UPDATE b SET [Status] = 'Pending', PaymentOpenedUtc = DATEADD(MINUTE, -20, SYSUTCDATETIME()), HoldExpiresUtc = DATEADD(MINUTE, -5, SYSUTCDATETIME())
    FROM booking.BOOKING b JOIN @case c ON c.BookingId = b.BookingId WHERE c.N = 6;
    UPDATE b SET [Status] = 'Pending', PaymentOpenedUtc = DATEADD(MINUTE, -3, SYSUTCDATETIME()), HoldExpiresUtc = DATEADD(MINUTE, 12, SYSUTCDATETIME())
    FROM booking.BOOKING b JOIN @case c ON c.BookingId = b.BookingId WHERE c.N = 7;

    INSERT INTO @rc EXEC booking.usp_Booking_ListPaymentsToReconcile @OpenedMinutesAgo = 10;

    SELECT @fail = CONCAT(@fail, (SELECT STRING_AGG(CONCAT(' R', c.N, ': expected ', CASE WHEN c.Expected = 1 THEN 'listed' ELSE 'not listed' END, ';'), '')
                                  FROM @case c
                                  WHERE c.Expected <> CASE WHEN EXISTS (SELECT 1 FROM @rc r WHERE r.BookingId = c.BookingId) THEN 1 ELSE 0 END));
    IF @fail = N'' SET @fail = NULL;
END TRY
BEGIN CATCH
    SET @fail = CONCAT(@fail, ' unexpected error: ', ERROR_MESSAGE());
END CATCH;
IF @@TRANCOUNT > 0 ROLLBACK;

IF @fail IS NOT NULL RAISERROR('reconcile_any_status FAILED:%s', 16, 1, @fail);
ELSE PRINT 'ok reconcile_any_status';
GO
