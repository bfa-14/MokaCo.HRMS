/* ============================================================================
   tests/qa3/booking/paid_clash_midnight.sql - QA3 BKG-3 (docs/104_qa3_booking.sql).

   usp_Booking_ConfirmOnlinePayment decided "another live booking now holds the slot" on the same
   DATE only. Guest A pays for Tuesday 00:00-01:00 (stored on Tuesday, minutes 0-60); A's hold lapses
   while the gateway page is open; guest B takes Monday 23:00-01:00 (Monday, 1380-1500) and staff
   confirm it; A's payment arrives. That must be a SlotClash (recorded, A stays Pending, staff
   alerted) - not a second Confirmed booking on the same hour.

     C1  across midnight (A on the next date): SlotClash, A still Pending, one payment line
     C2  across midnight the other way (A Monday 23:00-01:00 paid, B Tuesday 00:00-01:00 live): SlotClash
     C3  a staff block on the next date's 00:00-01:00 counts as well: SlotClash
     C4  nothing in the way: Confirmed (the ordinary path is unchanged)

   Each case in its own transaction, rolled back: the throw-away room 'QA3 booking room' and its
   bookings never persist. Online deposits are switched on inside the transaction (BKG-1 only lets a
   deposit booking be paid). RAISERROR on a wrong result; 'ok ...' otherwise.
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
DECLARE @fail NVARCHAR(1000) = NULL, @case INT = 1, @Outcome VARCHAR(20), @StatusA VARCHAR(12), @Lines INT;
DECLARE @Room INT, @Mon DATE, @Tue DATE, @RefA VARCHAR(12), @RefB VARCHAR(12), @Dep DECIMAL(10,2);
DECLARE @made TABLE (BookingId INT, BookingRef VARCHAR(12), TotalAmount DECIMAL(10,2), DepositDue DECIMAL(10,2), DepositPercent DECIMAL(5,2), CurrencyCode CHAR(3), [Status] VARCHAR(12), Hours DECIMAL(6,2), RoomName NVARCHAR(80), RoomId INT, DiscountPercent DECIMAL(5,2), DiscountAmount DECIMAL(10,2));
DECLARE @sp TABLE (BookingId INT, BookingRef VARCHAR(12), DepositDue DECIMAL(10,2), CurrencyCode CHAR(3), TotalAmount DECIMAL(10,2), BookDate DATE, StartMin INT, EndMin INT, Hours DECIMAL(6,2), RoomName NVARCHAR(80), HoldExpiresUtc DATETIME2, PaymentOpenedUtc DATETIME2, PreviousOpenedUtc DATETIME2);
DECLARE @cf TABLE (Outcome VARCHAR(20), BookingId INT, BookingRef VARCHAR(12), [Status] VARCHAR(12), PaidAmount DECIMAL(10,2), BalanceDue DECIMAL(10,2));
DECLARE @blk TABLE (BlockId INT);

WHILE @case <= 4
BEGIN
    DELETE FROM @made; DELETE FROM @sp; DELETE FROM @cf; DELETE FROM @blk;
    SELECT @RefA = NULL, @RefB = NULL, @Outcome = NULL, @StatusA = NULL;
    BEGIN TRAN;
    BEGIN TRY
        UPDATE core.SETTING SET SettingValue = '60' WHERE SettingKey IN ('BookingSlotMinutes', 'BookingLeadMaxDays');
        UPDATE core.SETTING SET SettingValue = '1'  WHERE SettingKey = 'BookingLeadMinHours';
        UPDATE core.SETTING SET SettingValue = '0'  WHERE SettingKey = 'BookingAutoConfirm';
        IF NOT EXISTS (SELECT 1 FROM core.SETTING WHERE SettingKey = 'BookingDepositRequired')
            INSERT INTO core.SETTING (SettingKey, SettingValue, DataType) VALUES ('BookingDepositRequired', '1', 'bool');
        UPDATE core.SETTING SET SettingValue = '1' WHERE SettingKey = 'BookingDepositRequired';

        INSERT INTO booking.ROOM (Code, [Name], Seats, MinPersons, PricePerHour, MinHours, MaxHours, SortOrder, IsActive)
        VALUES ('qa3-bk', N'QA3 booking room', 6, 1, 20, 1, 6, 999, 1);
        SET @Room = SCOPE_IDENTITY();
        INSERT INTO booking.ROOM_HOURS (RoomId, DayOfWeek, OpenTime, CloseTime, IsClosed)
        SELECT @Room, d, '07:00', '01:00', 0 FROM (VALUES (1),(2),(3),(4),(5),(6),(7)) v(d);
        SET @Mon = DATEADD(DAY, 10, CAST(booking.fn_LocalNow() AS DATE));
        SET @Tue = DATEADD(DAY, 1, @Mon);

        /* A: the one who pays (a website deposit booking), its hold then lapses */
        IF @case IN (1, 3, 4)
            INSERT INTO @made EXEC booking.usp_Booking_Create @RoomId = @Room, @BookDate = @Tue, @StartTime = '00:00', @EndTime = '01:00',
                 @Persons = 2, @GuestName = N'QA3 Payer A', @GuestPhone = '+96170000311', @Source = 'Website';
        ELSE
            INSERT INTO @made EXEC booking.usp_Booking_Create @RoomId = @Room, @BookDate = @Mon, @StartTime = '23:00', @EndTime = '01:00',
                 @Persons = 2, @GuestName = N'QA3 Payer A', @GuestPhone = '+96170000311', @Source = 'Website';
        SELECT @RefA = BookingRef FROM @made;
        INSERT INTO @sp EXEC booking.usp_Booking_StartPayment @Ref = @RefA;
        SELECT @Dep = DepositDue FROM @sp;
        UPDATE booking.BOOKING SET HoldExpiresUtc = DATEADD(MINUTE, -1, SYSUTCDATETIME()) WHERE BookingRef = @RefA;

        /* B: what took the time meanwhile */
        DELETE FROM @made;
        IF @case = 1
            INSERT INTO @made EXEC booking.usp_Booking_Create @RoomId = @Room, @BookDate = @Mon, @StartTime = '23:00', @EndTime = '01:00',
                 @Persons = 2, @GuestName = N'QA3 Other B', @GuestPhone = '+96170000312', @Source = 'Manual';
        IF @case = 2
            INSERT INTO @made EXEC booking.usp_Booking_Create @RoomId = @Room, @BookDate = @Tue, @StartTime = '00:00', @EndTime = '01:00',
                 @Persons = 2, @GuestName = N'QA3 Other B', @GuestPhone = '+96170000312', @Source = 'Manual';
        IF @case = 3      /* Monday 23:30 to Tuesday 00:30 (usp_Block_Add, 104); A's lapsed hold does not stop it */
            INSERT INTO @blk EXEC booking.usp_Block_Add @RoomId = @Room, @BlockDate = @Mon, @StartTime = '23:30', @EndTime = '00:30', @Reason = N'QA3 block';

        INSERT INTO @cf EXEC booking.usp_Booking_ConfirmOnlinePayment @Ref = @RefA, @Amount = @Dep, @CurrencyCode = 'USD',
             @GatewayOrderId = @RefA, @TransactionId = 'QA3-T1';
        SELECT @Outcome = Outcome FROM @cf;
        SELECT @StatusA = [Status] FROM booking.BOOKING WHERE BookingRef = @RefA;
        SELECT @Lines = COUNT(*) FROM booking.BOOKING_PAYMENT p JOIN booking.BOOKING b ON b.BookingId = p.BookingId WHERE b.BookingRef = @RefA;

        IF @case IN (1, 2, 3) AND NOT (@Outcome = 'SlotClash' AND @StatusA = 'Pending' AND @Lines = 1)
            SET @fail = CONCAT(@fail, ' C', @case, ': expected SlotClash/Pending/1 line, got ', ISNULL(@Outcome, 'NULL'), '/', ISNULL(@StatusA, 'NULL'), '/', @Lines, ';');
        IF @case = 4 AND NOT (@Outcome = 'Confirmed' AND @StatusA = 'Confirmed' AND @Lines = 1)
            SET @fail = CONCAT(@fail, ' C4: expected Confirmed/Confirmed/1 line, got ', ISNULL(@Outcome, 'NULL'), '/', ISNULL(@StatusA, 'NULL'), '/', @Lines, ';');
    END TRY
    BEGIN CATCH
        SET @fail = CONCAT(@fail, ' C', @case, ': unexpected error: ', ERROR_MESSAGE(), ';');
    END CATCH;
    IF @@TRANCOUNT > 0 ROLLBACK;
    SET @case += 1;
END

IF @fail IS NOT NULL RAISERROR('paid_clash_midnight FAILED:%s', 16, 1, @fail);
ELSE PRINT 'ok paid_clash_midnight';
GO
