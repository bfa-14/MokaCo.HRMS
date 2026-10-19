/* ============================================================================
   tests/qa3/booking/deposit_mode_pay.sql - QA3 BKG-1 (docs/104_qa3_booking.sql).

   Anyone holding an MC- reference could put a PAYMENT HOLD on a step-1 website request
   (usp_Booking_StartPayment) and then have it released or expired. A payment may now be opened only
   on a booking taken in DEPOSIT MODE (a website booking made while BookingDepositRequired is on),
   and only while deposits are still on.

     P1  deposits off: the website booking is a request (OnlineDeposit = 0); StartPayment refuses
         ('This booking is not waiting for a payment ...') and stamps no hold
     P2  deposits on ('true', the Settings page's other dialect): the website booking is a deposit
         booking; StartPayment stamps the hold and PaymentOpenedUtc
     P3  deposits switched off again: the same deposit booking is refused, nothing re-stamped
     P4  a staff (Manual) booking is never a deposit booking

   Three transactions, all rolled back: the throw-away room 'QA3 booking room', its bookings and the
   setting changes never persist. usp_Booking_StartPayment runs with XACT_ABORT ON, so its refusal
   dooms the caller's transaction: each refusal comes LAST in its transaction and is followed by
   reads only. RAISERROR on a wrong result; 'ok ...' otherwise.
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
DECLARE @fail NVARCHAR(1000) = NULL, @step INT = 1, @Room INT, @D DATE, @Ref VARCHAR(12), @Msg NVARCHAR(400);
DECLARE @made TABLE (BookingId INT, BookingRef VARCHAR(12), TotalAmount DECIMAL(10,2), DepositDue DECIMAL(10,2), DepositPercent DECIMAL(5,2), CurrencyCode CHAR(3), [Status] VARCHAR(12), Hours DECIMAL(6,2), RoomName NVARCHAR(80), RoomId INT, DiscountPercent DECIMAL(5,2), DiscountAmount DECIMAL(10,2));
DECLARE @sp TABLE (BookingId INT, BookingRef VARCHAR(12), DepositDue DECIMAL(10,2), CurrencyCode CHAR(3), TotalAmount DECIMAL(10,2), BookDate DATE, StartMin INT, EndMin INT, Hours DECIMAL(6,2), RoomName NVARCHAR(80), HoldExpiresUtc DATETIME2, PaymentOpenedUtc DATETIME2, PreviousOpenedUtc DATETIME2);

WHILE @step <= 3
BEGIN
    DELETE FROM @made; DELETE FROM @sp; SELECT @Ref = NULL, @Msg = NULL;
    BEGIN TRAN;
    BEGIN TRY
        /* known rules for the website path, a room of our own (no real booking can be in the way) */
        UPDATE core.SETTING SET SettingValue = '60' WHERE SettingKey IN ('BookingSlotMinutes', 'BookingLeadMaxDays');
        UPDATE core.SETTING SET SettingValue = '1'  WHERE SettingKey = 'BookingLeadMinHours';
        UPDATE core.SETTING SET SettingValue = '0'  WHERE SettingKey = 'BookingAutoConfirm';
        IF NOT EXISTS (SELECT 1 FROM core.SETTING WHERE SettingKey = 'BookingDepositRequired')
            INSERT INTO core.SETTING (SettingKey, SettingValue, DataType) VALUES ('BookingDepositRequired', '0', 'bool');
        UPDATE core.SETTING SET SettingValue = CASE @step WHEN 1 THEN '0' WHEN 2 THEN 'true' ELSE '1' END
        WHERE SettingKey = 'BookingDepositRequired';

        INSERT INTO booking.ROOM (Code, [Name], Seats, MinPersons, PricePerHour, MinHours, MaxHours, SortOrder, IsActive)
        VALUES ('qa3-bk', N'QA3 booking room', 6, 1, 20, 1, 6, 999, 1);
        SET @Room = SCOPE_IDENTITY();
        INSERT INTO booking.ROOM_HOURS (RoomId, DayOfWeek, OpenTime, CloseTime, IsClosed)
        SELECT @Room, d, '07:00', '01:00', 0 FROM (VALUES (1),(2),(3),(4),(5),(6),(7)) v(d);
        SET @D = DATEADD(DAY, 10, CAST(booking.fn_LocalNow() AS DATE));

        IF @step = 1        /* P1 */
        BEGIN
            INSERT INTO @made EXEC booking.usp_Booking_Create @RoomId = @Room, @BookDate = @D, @StartTime = '10:00', @EndTime = '12:00',
                 @Persons = 2, @GuestName = N'QA3 Request', @GuestPhone = '+96170000301', @Source = 'Website';
            SELECT @Ref = BookingRef FROM @made;
            IF (SELECT OnlineDeposit FROM booking.BOOKING WHERE BookingRef = @Ref) <> 0
                SET @fail = CONCAT(@fail, ' P1: a request was taken in deposit mode;');
            BEGIN TRY
                EXEC booking.usp_Booking_StartPayment @Ref = @Ref;     -- last write of the transaction
            END TRY
            BEGIN CATCH
                SET @Msg = ERROR_MESSAGE();
            END CATCH;
            IF @Msg IS NULL OR @Msg NOT LIKE 'This booking is not waiting for a payment%'
                SET @fail = CONCAT(@fail, ' P1: StartPayment on a request answered ', ISNULL(@Msg, 'success'), ';');
            IF EXISTS (SELECT 1 FROM booking.BOOKING WHERE BookingRef = @Ref AND (HoldExpiresUtc IS NOT NULL OR PaymentOpenedUtc IS NOT NULL))
                SET @fail = CONCAT(@fail, ' P1: a hold was stamped on a request;');
        END

        IF @step = 2        /* P2, then P3 */
        BEGIN
            INSERT INTO @made EXEC booking.usp_Booking_Create @RoomId = @Room, @BookDate = @D, @StartTime = '14:00', @EndTime = '16:00',
                 @Persons = 2, @GuestName = N'QA3 Deposit', @GuestPhone = '+96170000302', @Source = 'Website';
            SELECT @Ref = BookingRef FROM @made;
            IF (SELECT OnlineDeposit FROM booking.BOOKING WHERE BookingRef = @Ref) <> 1
                SET @fail = CONCAT(@fail, ' P2: not taken in deposit mode with BookingDepositRequired = true;');
            INSERT INTO @sp EXEC booking.usp_Booking_StartPayment @Ref = @Ref;
            IF NOT EXISTS (SELECT 1 FROM booking.BOOKING WHERE BookingRef = @Ref AND HoldExpiresUtc IS NOT NULL AND PaymentOpenedUtc IS NOT NULL)
                SET @fail = CONCAT(@fail, ' P2: StartPayment did not stamp the hold;');

            UPDATE core.SETTING SET SettingValue = 'false' WHERE SettingKey = 'BookingDepositRequired';
            UPDATE booking.BOOKING SET PaymentOpenedUtc = DATEADD(MINUTE, -30, PaymentOpenedUtc) WHERE BookingRef = @Ref;
            BEGIN TRY
                EXEC booking.usp_Booking_StartPayment @Ref = @Ref;     -- last write of the transaction
            END TRY
            BEGIN CATCH
                SET @Msg = ERROR_MESSAGE();
            END CATCH;
            IF @Msg IS NULL OR @Msg NOT LIKE 'This booking is not waiting for a payment%'
                SET @fail = CONCAT(@fail, ' P3: StartPayment with deposits off answered ', ISNULL(@Msg, 'success'), ';');
            IF NOT EXISTS (SELECT 1 FROM booking.BOOKING WHERE BookingRef = @Ref AND PaymentOpenedUtc < DATEADD(MINUTE, -20, SYSUTCDATETIME()))
                SET @fail = CONCAT(@fail, ' P3: the refused call re-stamped the payment;');
        END

        IF @step = 3        /* P4 */
        BEGIN
            INSERT INTO @made EXEC booking.usp_Booking_Create @RoomId = @Room, @BookDate = @D, @StartTime = '18:00', @EndTime = '19:00',
                 @Persons = 2, @GuestName = N'QA3 Manual', @GuestPhone = '+96170000303', @Source = 'Manual';
            SELECT @Ref = BookingRef FROM @made;
            IF (SELECT OnlineDeposit FROM booking.BOOKING WHERE BookingRef = @Ref) <> 0
                SET @fail = CONCAT(@fail, ' P4: a staff booking was taken in deposit mode;');
        END
    END TRY
    BEGIN CATCH
        SET @fail = CONCAT(@fail, ' step ', @step, ': unexpected error: ', ERROR_MESSAGE(), ';');
    END CATCH;
    IF @@TRANCOUNT > 0 ROLLBACK;
    SET @step += 1;
END

IF @fail IS NOT NULL RAISERROR('deposit_mode_pay FAILED:%s', 16, 1, @fail);
ELSE PRINT 'ok deposit_mode_pay';
GO
