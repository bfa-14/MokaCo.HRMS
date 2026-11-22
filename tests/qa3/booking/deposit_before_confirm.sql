/* ============================================================================
   tests/qa3/booking/deposit_before_confirm.sql - script 120 (docs/120_booking_deposit_before_confirm.sql).

     N1  booking.fn_NewBookingStatus: staff = Confirmed; a deposit booking with something to pay = Pending whatever
         auto-confirm says; nothing to pay or no deposit mode = the auto-confirm rule
     N2  deposits ON + auto-confirm ON: a website booking starts Pending (it was Confirmed before any payment),
         it is a deposit booking, and usp_Booking_StartPayment opens its payment
     N3  the payment confirms it: usp_Booking_ConfirmOnlinePayment -> Confirmed, with the payment line
     N4  deposits OFF + auto-confirm ON: a website booking is Confirmed at once, as before
     N5  a staff booking is Confirmed at once, deposits on or not

   One transaction, rolled back. RAISERROR on a wrong result; 'ok ...' otherwise.
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
DECLARE @fail NVARCHAR(1000) = NULL, @Room INT, @D DATE, @Ref VARCHAR(12), @St VARCHAR(12), @Dep DECIMAL(10,2), @Ccy CHAR(3);
DECLARE @made TABLE (BookingId INT, BookingRef VARCHAR(12), TotalAmount DECIMAL(10,2), DepositDue DECIMAL(10,2), DepositPercent DECIMAL(5,2), CurrencyCode CHAR(3), [Status] VARCHAR(12), Hours DECIMAL(6,2), RoomName NVARCHAR(80), RoomId INT, DiscountPercent DECIMAL(5,2), DiscountAmount DECIMAL(10,2));
DECLARE @started TABLE (BookingId INT, BookingRef VARCHAR(12), DepositDue DECIMAL(10,2), CurrencyCode CHAR(3), TotalAmount DECIMAL(10,2), BookDate DATE, StartMin INT, EndMin INT, Hours DECIMAL(6,2), RoomName NVARCHAR(80), HoldExpiresUtc DATETIME2, PaymentOpenedUtc DATETIME2, PreviousOpenedUtc DATETIME2);
DECLARE @paid TABLE (Outcome VARCHAR(20), BookingId INT, BookingRef VARCHAR(12), [Status] VARCHAR(12), PaidAmount DECIMAL(10,2), BalanceDue DECIMAL(10,2));

BEGIN TRAN;
BEGIN TRY
    /* N1 */
    DECLARE @t TABLE (Src VARCHAR(10), Onl BIT, Dep DECIMAL(10,2), Auto BIT, Expect VARCHAR(12));
    INSERT INTO @t VALUES ('Manual', 0, 0, 0, 'Confirmed'), ('Manual', 1, 10, 0, 'Confirmed'),
                          ('Website', 1, 10, 1, 'Pending'), ('Website', 1, 10, 0, 'Pending'),
                          ('Website', 1, 0, 1, 'Confirmed'), ('Website', 1, 0, 0, 'Pending'),
                          ('Website', 0, 10, 1, 'Confirmed'), ('Website', 0, 10, 0, 'Pending'), ('Website', NULL, NULL, NULL, 'Pending');
    IF EXISTS (SELECT 1 FROM @t WHERE booking.fn_NewBookingStatus(Src, Onl, Dep, Auto) <> Expect)
        SET @fail = CONCAT(@fail, ' N1: wrong for ', (SELECT STRING_AGG(CONCAT(Src, '/', Onl, '/', Dep, '/', Auto), ', ') FROM @t
                                                     WHERE booking.fn_NewBookingStatus(Src, Onl, Dep, Auto) <> Expect), ';');

    UPDATE core.SETTING SET SettingValue = '60' WHERE SettingKey IN ('BookingSlotMinutes', 'BookingLeadMaxDays');
    UPDATE core.SETTING SET SettingValue = '1'  WHERE SettingKey = 'BookingLeadMinHours';
    IF NOT EXISTS (SELECT 1 FROM core.SETTING WHERE SettingKey = 'BookingAutoConfirm')
        INSERT INTO core.SETTING (SettingKey, SettingValue, DataType) VALUES ('BookingAutoConfirm', '0', 'bool');
    IF NOT EXISTS (SELECT 1 FROM core.SETTING WHERE SettingKey = 'BookingDepositRequired')
        INSERT INTO core.SETTING (SettingKey, SettingValue, DataType) VALUES ('BookingDepositRequired', '0', 'bool');
    INSERT INTO booking.ROOM (Code, [Name], Seats, MinPersons, PricePerHour, MinHours, MaxHours, SortOrder, IsActive, DepositPercent)
    VALUES ('qa3-dc', N'QA3 deposit room', 6, 1, 20, 1, 6, 999, 1, 20);
    SET @Room = SCOPE_IDENTITY();
    INSERT INTO booking.ROOM_HOURS (RoomId, DayOfWeek, OpenTime, CloseTime, IsClosed)
    SELECT @Room, d, '07:00', '01:00', 0 FROM (VALUES (1),(2),(3),(4),(5),(6),(7)) v(d);
    SET @D = DATEADD(DAY, 10, CAST(booking.fn_LocalNow() AS DATE));

    /* N2 */
    UPDATE core.SETTING SET SettingValue = '1' WHERE SettingKey IN ('BookingAutoConfirm', 'BookingDepositRequired');
    INSERT INTO @made EXEC booking.usp_Booking_Create @RoomId = @Room, @BookDate = @D, @StartTime = '10:00', @EndTime = '12:00',
         @Persons = 2, @GuestName = N'QA3 Deposit', @GuestPhone = '+96170000351', @Source = 'Website';
    SELECT @Ref = BookingRef, @St = [Status], @Dep = DepositDue, @Ccy = CurrencyCode FROM @made;
    IF @St <> 'Pending' OR ISNULL(@Dep, 0) <= 0
       OR NOT EXISTS (SELECT 1 FROM booking.BOOKING WHERE BookingRef = @Ref AND [Status] = 'Pending' AND OnlineDeposit = 1)
        SET @fail = CONCAT(@fail, ' N2: a deposit booking with auto-confirm on started ', @St, ' (deposit ', @Dep, ');');
    INSERT INTO @started EXEC booking.usp_Booking_StartPayment @Ref = @Ref;
    IF NOT EXISTS (SELECT 1 FROM @started WHERE BookingRef = @Ref AND HoldExpiresUtc IS NOT NULL)
        SET @fail = CONCAT(@fail, ' N2: its payment could not be opened;');

    /* N3 */
    INSERT INTO @paid EXEC booking.usp_Booking_ConfirmOnlinePayment @Ref = @Ref, @Amount = @Dep, @CurrencyCode = @Ccy,
         @GatewayOrderId = @Ref, @TransactionId = 'QA3-120';
    IF NOT EXISTS (SELECT 1 FROM @paid WHERE Outcome = 'Confirmed' AND [Status] = 'Confirmed' AND PaidAmount = @Dep)
        SET @fail = CONCAT(@fail, ' N3: the payment did not confirm it (', ISNULL((SELECT TOP 1 CONCAT(Outcome, '/', [Status], '/', PaidAmount) FROM @paid), 'no answer'), ');');

    /* N4 */
    UPDATE core.SETTING SET SettingValue = '0' WHERE SettingKey = 'BookingDepositRequired';
    DELETE FROM @made;
    INSERT INTO @made EXEC booking.usp_Booking_Create @RoomId = @Room, @BookDate = @D, @StartTime = '13:00', @EndTime = '14:00',
         @Persons = 2, @GuestName = N'QA3 Auto', @GuestPhone = '+96170000352', @Source = 'Website';
    IF NOT EXISTS (SELECT 1 FROM @made m JOIN booking.BOOKING b ON b.BookingId = m.BookingId WHERE b.[Status] = 'Confirmed' AND b.OnlineDeposit = 0)
        SET @fail = CONCAT(@fail, ' N4: without deposits, auto-confirm did not confirm;');

    /* N5 */
    UPDATE core.SETTING SET SettingValue = '1' WHERE SettingKey = 'BookingDepositRequired';
    UPDATE core.SETTING SET SettingValue = '0' WHERE SettingKey = 'BookingAutoConfirm';
    DELETE FROM @made;
    INSERT INTO @made EXEC booking.usp_Booking_Create @RoomId = @Room, @BookDate = @D, @StartTime = '15:00', @EndTime = '16:00',
         @Persons = 2, @GuestName = N'QA3 Staff', @GuestPhone = '+96170000353', @Source = 'Manual';
    IF NOT EXISTS (SELECT 1 FROM @made m JOIN booking.BOOKING b ON b.BookingId = m.BookingId WHERE b.[Status] = 'Confirmed' AND b.OnlineDeposit = 0)
        SET @fail = CONCAT(@fail, ' N5: a staff booking was not Confirmed at once;');
END TRY
BEGIN CATCH
    SET @fail = CONCAT(@fail, ' unexpected error: ', ERROR_MESSAGE(), ';');
END CATCH;
IF @@TRANCOUNT > 0 ROLLBACK;

IF @fail IS NOT NULL RAISERROR('deposit_before_confirm FAILED:%s', 16, 1, @fail);
ELSE PRINT 'ok deposit_before_confirm';
GO
