/* ============================================================================
   tests/qa3/booking/whish_attempts.sql - script 118 (docs/118_booking_whish.sql).

   Whish is a second way to pay the deposit behind the card's own pipeline. What the database adds is the ATTEMPT:
   a Whish payment link allows one attempt, so every try has an id of its own - the reference plus a number - kept
   as the booking's gateway order id.

     P1  no attempt before the payment was started: usp_Booking_StartWhishAttempt refuses, nothing written
     P2  after usp_Booking_StartPayment: attempt 1 is <ref>-A1 and becomes the gateway order id; pressing pay again
         (StartPayment + a new attempt) gives <ref>-A2
     P3  a paid attempt goes through the card flow's own procedure (usp_Booking_ConfirmOnlinePayment, method
         'Whish'): the booking is Confirmed, the payment line carries the attempt id; usp_Booking_SetWhishPayer
         words the line as Whish's and keeps the payer's phone; the same attempt again is a Replay
     P4  the switch BookingWhishEnabled exists, and a booking that is no longer Pending gets no new attempt

   Two transactions, both rolled back: the throw-away room, its booking and the setting changes never persist. A
   refusal of these procedures dooms the caller's transaction, so each transaction holds one, last, followed by
   reads only. RAISERROR on a wrong result; 'ok whish_attempts' otherwise.
   sqlcmd -I -b -i tests/qa3/booking/whish_attempts.sql
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
DECLARE @fail NVARCHAR(2000) = NULL, @Room INT, @D DATE, @Ref VARCHAR(12), @Msg NVARCHAR(400), @Bid INT;
DECLARE @made TABLE (BookingId INT, BookingRef VARCHAR(12), TotalAmount DECIMAL(10,2), DepositDue DECIMAL(10,2), DepositPercent DECIMAL(5,2), CurrencyCode CHAR(3), [Status] VARCHAR(12), Hours DECIMAL(6,2), RoomName NVARCHAR(80), RoomId INT, DiscountPercent DECIMAL(5,2), DiscountAmount DECIMAL(10,2));
DECLARE @sp TABLE (BookingId INT, BookingRef VARCHAR(12), DepositDue DECIMAL(10,2), CurrencyCode CHAR(3), TotalAmount DECIMAL(10,2), BookDate DATE, StartMin INT, EndMin INT, Hours DECIMAL(6,2), RoomName NVARCHAR(80), HoldExpiresUtc DATETIME2, PaymentOpenedUtc DATETIME2, PreviousOpenedUtc DATETIME2);
DECLARE @at TABLE (BookingId INT, BookingRef VARCHAR(12), ExternalId VARCHAR(40), Attempt INT, DepositDue DECIMAL(10,2), CurrencyCode CHAR(3), HoldExpiresUtc DATETIME2, PaymentOpenedUtc DATETIME2);
DECLARE @paid TABLE (Outcome VARCHAR(20), BookingId INT, BookingRef VARCHAR(12), [Status] VARCHAR(12), PaidAmount DECIMAL(10,2), BalanceDue DECIMAL(10,2));

BEGIN TRAN;
BEGIN TRY
    UPDATE core.SETTING SET SettingValue = '60' WHERE SettingKey IN ('BookingSlotMinutes', 'BookingLeadMaxDays');
    UPDATE core.SETTING SET SettingValue = '1'  WHERE SettingKey = 'BookingLeadMinHours';
    UPDATE core.SETTING SET SettingValue = '0'  WHERE SettingKey = 'BookingAutoConfirm';
    UPDATE core.SETTING SET SettingValue = '1'  WHERE SettingKey = 'BookingDepositRequired';

    INSERT INTO booking.ROOM (Code, [Name], Seats, MinPersons, PricePerHour, MinHours, MaxHours, SortOrder, IsActive)
    VALUES ('qa3-wh', N'QA3 whish room', 6, 1, 20, 1, 6, 999, 1);
    SET @Room = SCOPE_IDENTITY();
    INSERT INTO booking.ROOM_HOURS (RoomId, DayOfWeek, OpenTime, CloseTime, IsClosed)
    SELECT @Room, d, '07:00', '01:00', 0 FROM (VALUES (1),(2),(3),(4),(5),(6),(7)) v(d);
    SET @D = DATEADD(DAY, 10, CAST(booking.fn_LocalNow() AS DATE));

    INSERT INTO @made EXEC booking.usp_Booking_Create @RoomId = @Room, @BookDate = @D, @StartTime = '10:00', @EndTime = '12:00',
         @Persons = 2, @GuestName = N'QA3 Whish', @GuestPhone = '+96170000318', @Source = 'Website';
    SELECT @Ref = BookingRef, @Bid = BookingId FROM @made;
    IF (SELECT OnlineDeposit FROM booking.BOOKING WHERE BookingId = @Bid) <> 1
        SET @fail = CONCAT(@fail, ' setup: the booking was not taken in deposit mode;');

    /* P4a: the switch is there (off unless somebody turned it on) */
    IF NOT EXISTS (SELECT 1 FROM core.SETTING WHERE SettingKey = 'BookingWhishEnabled' AND DataType = 'bool' AND Section = 'Booking')
        SET @fail = CONCAT(@fail, ' P4: the setting BookingWhishEnabled is missing;');

    /* P2: started, then attempt 1, then pay again -> attempt 2 */
    INSERT INTO @sp EXEC booking.usp_Booking_StartPayment @Ref = @Ref;
    INSERT INTO @at EXEC booking.usp_Booking_StartWhishAttempt @Ref = @Ref;
    IF NOT EXISTS (SELECT 1 FROM @at WHERE Attempt = 1 AND ExternalId = CONCAT(@Ref, '-A1') AND DepositDue > 0)
       OR (SELECT GatewayOrderId FROM booking.BOOKING WHERE BookingId = @Bid) <> CONCAT(@Ref, '-A1')
        SET @fail = CONCAT(@fail, ' P2: the first attempt is not <ref>-A1 on the booking;');
    DELETE FROM @sp; DELETE FROM @at;
    INSERT INTO @sp EXEC booking.usp_Booking_StartPayment @Ref = @Ref;
    IF (SELECT GatewayOrderId FROM booking.BOOKING WHERE BookingId = @Bid) <> @Ref
        SET @fail = CONCAT(@fail, ' P2: starting the payment again did not put the bare reference back (a card order);');
    INSERT INTO @at EXEC booking.usp_Booking_StartWhishAttempt @Ref = @Ref;
    IF NOT EXISTS (SELECT 1 FROM @at WHERE Attempt = 2 AND ExternalId = CONCAT(@Ref, '-A2'))
       OR (SELECT CONCAT(GatewayOrderId, '|', WhishAttempt) FROM booking.BOOKING WHERE BookingId = @Bid) <> CONCAT(@Ref, '-A2|2')
        SET @fail = CONCAT(@fail, ' P2: the second attempt is not <ref>-A2;');
    IF (SELECT HoldExpiresUtc FROM booking.BOOKING WHERE BookingId = @Bid) IS NULL
        SET @fail = CONCAT(@fail, ' P2: the attempt lost the hold;');

    /* P3: attempt 2 is paid - the card flow's own procedure, named Whish */
    DECLARE @Deposit DECIMAL(10,2) = (SELECT DepositDue FROM booking.BOOKING WHERE BookingId = @Bid);
    DECLARE @Ext VARCHAR(40) = CONCAT(@Ref, '-A2');
    INSERT INTO @paid EXEC booking.usp_Booking_ConfirmOnlinePayment @Ref = @Ref, @Amount = @Deposit, @CurrencyCode = 'USD',
         @GatewayOrderId = @Ext, @TransactionId = '96170000318', @MethodName = N'Whish';
    IF NOT EXISTS (SELECT 1 FROM @paid WHERE Outcome = 'Confirmed' AND [Status] = 'Confirmed' AND PaidAmount = @Deposit)
        SET @fail = CONCAT(@fail, ' P3: a paid Whish attempt did not confirm the booking (', (SELECT TOP 1 Outcome FROM @paid), ');');
    EXEC booking.usp_Booking_SetWhishPayer @Ref = @Ref, @ExternalId = @Ext, @Phone = ' 96170000318 ';
    IF NOT EXISTS (SELECT 1 FROM booking.BOOKING_PAYMENT p JOIN booking.PAYMENT_METHOD m ON m.PaymentMethodId = p.PaymentMethodId
                   WHERE p.BookingId = @Bid AND p.GatewayOrderId = @Ext AND p.IsRefund = 0 AND m.[Name] = N'Whish'
                     AND p.Reference = CONCAT(N'Whish ', @Ext, N' / paid from 96170000318'))
        SET @fail = CONCAT(@fail, ' P3: the payment line is not worded as Whish''s (',
                           (SELECT TOP 1 p.Reference FROM booking.BOOKING_PAYMENT p WHERE p.BookingId = @Bid), ');');
    IF ISNULL((SELECT WhishPayerPhone FROM booking.BOOKING WHERE BookingId = @Bid), '') <> '96170000318'
        SET @fail = CONCAT(@fail, ' P3: the payer''s phone is not on the booking;');
    DELETE FROM @paid;
    INSERT INTO @paid EXEC booking.usp_Booking_ConfirmOnlinePayment @Ref = @Ref, @Amount = @Deposit, @CurrencyCode = 'USD',
         @GatewayOrderId = @Ext, @TransactionId = NULL, @MethodName = N'Whish';
    IF NOT EXISTS (SELECT 1 FROM @paid WHERE Outcome = 'Replay') OR (SELECT COUNT(*) FROM booking.BOOKING_PAYMENT WHERE BookingId = @Bid) <> 1
        SET @fail = CONCAT(@fail, ' P3: the same attempt recorded twice;');
    /* an attempt with no payment line: nothing is re-worded and no phone is written */
    EXEC booking.usp_Booking_SetWhishPayer @Ref = @Ref, @ExternalId = 'MC-NOSUCHID-A9', @Phone = '96179999999';
    IF (SELECT WhishPayerPhone FROM booking.BOOKING WHERE BookingId = @Bid) <> '96170000318'
        SET @fail = CONCAT(@fail, ' P3: a payer was noted for an attempt that was never paid;');

    /* P4b (a refusal: last writes): the booking is Confirmed now - no new attempt */
    BEGIN TRY
        EXEC booking.usp_Booking_StartWhishAttempt @Ref = @Ref;
    END TRY
    BEGIN CATCH
        SET @Msg = ERROR_MESSAGE();
    END CATCH;
    IF @Msg IS NULL OR @Msg NOT LIKE N'This booking is not waiting for a payment%'
        SET @fail = CONCAT(@fail, ' P4: a confirmed booking got a new Whish attempt (', ISNULL(@Msg, N'no refusal'), N');');
    IF (SELECT WhishAttempt FROM booking.BOOKING WHERE BookingId = @Bid) <> 2
        SET @fail = CONCAT(@fail, ' P4: the refused attempt was counted;');
END TRY
BEGIN CATCH
    SET @fail = CONCAT(@fail, ' error: ', ERROR_MESSAGE(), ' (line ', ERROR_LINE(), ');');
END CATCH;
IF @@TRANCOUNT > 0 ROLLBACK TRAN;

/* P1, in a transaction of its own (one refusal a transaction): an unknown reference gets no attempt */
SET @Msg = NULL;
BEGIN TRAN;
BEGIN TRY EXEC booking.usp_Booking_StartWhishAttempt @Ref = 'MC-ZZZZZZZZ'; END TRY BEGIN CATCH SET @Msg = ERROR_MESSAGE(); END CATCH;
IF @@TRANCOUNT > 0 ROLLBACK TRAN;
IF @Msg IS NULL OR @Msg NOT LIKE N'Booking not found%'
    SET @fail = CONCAT(@fail, ' P1: an unknown reference got an attempt (', ISNULL(@Msg, N'no refusal'), N');');

IF @fail IS NOT NULL RAISERROR('whish_attempts:%s', 16, 1, @fail);
ELSE PRINT 'ok whish_attempts';
