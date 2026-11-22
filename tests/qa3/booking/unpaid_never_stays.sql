/* ============================================================================
   tests/qa3/booking/unpaid_never_stays.sql - script 121 (docs/121_booking_unpaid_never_stays.sql).

     U1  booking.fn_DepositHoldUntil: a hold only for a Pending booking that must pay a deposit online; it is
         BookingHoldMinutes long (15 when unset or nonsense)
     U2  deposits ON: a website booking is created Pending WITH its hold, and the 'Request' and 'StaffAlert'
         messages are not left in the outbox
     U3  never paid, payment never opened: once the hold has run out the sweep (usp_Booking_ExpireHolds) releases
         it, and the slot can be booked again
     U4  the guest gives it back before paying: usp_Booking_ReleaseHold cancels it
     U5  paid: Confirmed, hold gone, the guest's Confirmation is queued
     U6  deposits OFF: a request has NO hold, keeps its 'Request' message, and the sweep never touches it
     U7  a staff booking has no hold

   One transaction, rolled back. RAISERROR on a wrong result; 'ok ...' otherwise.
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
DECLARE @fail NVARCHAR(1500) = NULL, @Room INT, @D DATE, @Ref VARCHAR(12), @Bid INT, @Dep DECIMAL(10,2), @Ccy CHAR(3), @Hold DATETIME2, @Mins INT;
DECLARE @made TABLE (BookingId INT, BookingRef VARCHAR(12), TotalAmount DECIMAL(10,2), DepositDue DECIMAL(10,2), DepositPercent DECIMAL(5,2), CurrencyCode CHAR(3), [Status] VARCHAR(12), Hours DECIMAL(6,2), RoomName NVARCHAR(80), RoomId INT, DiscountPercent DECIMAL(5,2), DiscountAmount DECIMAL(10,2));
DECLARE @swept TABLE (Expired INT);
DECLARE @rel TABLE (BookingRef VARCHAR(12), [Status] VARCHAR(12));
DECLARE @paid TABLE (Outcome VARCHAR(20), BookingId INT, BookingRef VARCHAR(12), [Status] VARCHAR(12), PaidAmount DECIMAL(10,2), BalanceDue DECIMAL(10,2));

BEGIN TRAN;
BEGIN TRY
    /* U1 */
    IF NOT EXISTS (SELECT 1 FROM core.SETTING WHERE SettingKey = 'BookingHoldMinutes')
        INSERT INTO core.SETTING (SettingKey, SettingValue, DataType) VALUES ('BookingHoldMinutes', '15', 'int');
    UPDATE core.SETTING SET SettingValue = '20' WHERE SettingKey = 'BookingHoldMinutes';
    SET @Mins = DATEDIFF(SECOND, SYSUTCDATETIME(), booking.fn_DepositHoldUntil('Pending', 1, 10));
    IF @Mins NOT BETWEEN 20 * 60 - 5 AND 20 * 60 + 5 SET @fail = CONCAT(@fail, ' U1: a 20-minute hold is ', @Mins, ' seconds;');
    IF booking.fn_DepositHoldUntil('Confirmed', 1, 10) IS NOT NULL OR booking.fn_DepositHoldUntil('Pending', 0, 10) IS NOT NULL
       OR booking.fn_DepositHoldUntil('Pending', 1, 0) IS NOT NULL OR booking.fn_DepositHoldUntil('Pending', NULL, NULL) IS NOT NULL
        SET @fail = CONCAT(@fail, ' U1: a hold where there is nothing to pay online;');
    UPDATE core.SETTING SET SettingValue = 'soon' WHERE SettingKey = 'BookingHoldMinutes';
    SET @Mins = DATEDIFF(SECOND, SYSUTCDATETIME(), booking.fn_DepositHoldUntil('Pending', 1, 10));
    IF @Mins NOT BETWEEN 15 * 60 - 5 AND 15 * 60 + 5 SET @fail = CONCAT(@fail, ' U1: the default hold is ', @Mins, ' seconds;');
    UPDATE core.SETTING SET SettingValue = '15' WHERE SettingKey = 'BookingHoldMinutes';

    UPDATE core.SETTING SET SettingValue = '60' WHERE SettingKey IN ('BookingSlotMinutes', 'BookingLeadMaxDays');
    UPDATE core.SETTING SET SettingValue = '1'  WHERE SettingKey = 'BookingLeadMinHours';
    IF NOT EXISTS (SELECT 1 FROM core.SETTING WHERE SettingKey = 'BookingAutoConfirm')
        INSERT INTO core.SETTING (SettingKey, SettingValue, DataType) VALUES ('BookingAutoConfirm', '0', 'bool');
    IF NOT EXISTS (SELECT 1 FROM core.SETTING WHERE SettingKey = 'BookingDepositRequired')
        INSERT INTO core.SETTING (SettingKey, SettingValue, DataType) VALUES ('BookingDepositRequired', '0', 'bool');
    IF NOT EXISTS (SELECT 1 FROM core.SETTING WHERE SettingKey = 'BookingNotifyEmail')
        INSERT INTO core.SETTING (SettingKey, SettingValue, DataType) VALUES ('BookingNotifyEmail', N'', 'string');
    UPDATE core.SETTING SET SettingValue = N'qa3-staff@example.invalid' WHERE SettingKey = 'BookingNotifyEmail';
    UPDATE core.SETTING SET SettingValue = '0' WHERE SettingKey = 'BookingAutoConfirm';
    INSERT INTO booking.ROOM (Code, [Name], Seats, MinPersons, PricePerHour, MinHours, MaxHours, SortOrder, IsActive, DepositPercent)
    VALUES ('qa3-un', N'QA3 unpaid room', 6, 1, 20, 1, 6, 999, 1, 20);
    SET @Room = SCOPE_IDENTITY();
    INSERT INTO booking.ROOM_HOURS (RoomId, DayOfWeek, OpenTime, CloseTime, IsClosed)
    SELECT @Room, d, '07:00', '01:00', 0 FROM (VALUES (1),(2),(3),(4),(5),(6),(7)) v(d);
    SET @D = DATEADD(DAY, 10, CAST(booking.fn_LocalNow() AS DATE));

    /* U2 */
    UPDATE core.SETTING SET SettingValue = '1' WHERE SettingKey = 'BookingDepositRequired';
    INSERT INTO @made EXEC booking.usp_Booking_Create @RoomId = @Room, @BookDate = @D, @StartTime = '10:00', @EndTime = '12:00',
         @Persons = 2, @GuestName = N'QA3 Unpaid', @GuestPhone = '+96170000361', @GuestEmail = N'qa3-unpaid@example.invalid', @Source = 'Website';
    SELECT @Ref = BookingRef, @Bid = BookingId, @Dep = DepositDue, @Ccy = CurrencyCode FROM @made;
    SELECT @Hold = HoldExpiresUtc FROM booking.BOOKING WHERE BookingId = @Bid;
    IF (SELECT [Status] FROM booking.BOOKING WHERE BookingId = @Bid) <> 'Pending' OR @Hold IS NULL
       OR DATEDIFF(SECOND, SYSUTCDATETIME(), @Hold) NOT BETWEEN 15 * 60 - 5 AND 15 * 60 + 5
        SET @fail = CONCAT(@fail, ' U2: a deposit booking was created without its 15-minute hold (', ISNULL(CONVERT(VARCHAR(19), @Hold, 120), 'no hold'), ');');
    IF EXISTS (SELECT 1 FROM core.EMAIL_OUTBOX WHERE BookingId = @Bid)
        SET @fail = CONCAT(@fail, ' U2: announced before it was paid: ',
                           (SELECT STRING_AGG(CONCAT(MailKind, '/', Channel), ', ') FROM core.EMAIL_OUTBOX WHERE BookingId = @Bid), ';');

    /* U3 */
    UPDATE booking.BOOKING SET HoldExpiresUtc = DATEADD(MINUTE, -1, SYSUTCDATETIME()) WHERE BookingId = @Bid;
    INSERT INTO @swept EXEC booking.usp_Booking_ExpireHolds;
    IF (SELECT [Status] FROM booking.BOOKING WHERE BookingId = @Bid) <> 'Cancelled'
        SET @fail = CONCAT(@fail, ' U3: the sweep did not release an unpaid deposit booking whose hold ran out;');
    DELETE FROM @made;
    INSERT INTO @made EXEC booking.usp_Booking_Create @RoomId = @Room, @BookDate = @D, @StartTime = '10:00', @EndTime = '12:00',
         @Persons = 2, @GuestName = N'QA3 Next', @GuestPhone = '+96170000362', @GuestEmail = N'qa3-next@example.invalid', @Source = 'Website';
    SELECT @Ref = BookingRef, @Bid = BookingId, @Dep = DepositDue, @Ccy = CurrencyCode FROM @made;
    IF @Bid IS NULL SET @fail = CONCAT(@fail, ' U3: the released slot could not be booked again;');

    /* U4 */
    INSERT INTO @rel EXEC booking.usp_Booking_ReleaseHold @Ref = @Ref;
    IF NOT EXISTS (SELECT 1 FROM @rel WHERE BookingRef = @Ref AND [Status] = 'Cancelled')
        SET @fail = CONCAT(@fail, ' U4: the guest could not give back a held booking;');

    /* U5 */
    DELETE FROM @made;
    INSERT INTO @made EXEC booking.usp_Booking_Create @RoomId = @Room, @BookDate = @D, @StartTime = '10:00', @EndTime = '12:00',
         @Persons = 2, @GuestName = N'QA3 Pays', @GuestPhone = '+96170000363', @GuestEmail = N'qa3-pays@example.invalid', @Source = 'Website';
    SELECT @Ref = BookingRef, @Bid = BookingId, @Dep = DepositDue, @Ccy = CurrencyCode FROM @made;
    INSERT INTO @paid EXEC booking.usp_Booking_ConfirmOnlinePayment @Ref = @Ref, @Amount = @Dep, @CurrencyCode = @Ccy,
         @GatewayOrderId = @Ref, @TransactionId = 'QA3-121';
    IF NOT EXISTS (SELECT 1 FROM booking.BOOKING WHERE BookingId = @Bid AND [Status] = 'Confirmed' AND HoldExpiresUtc IS NULL)
        SET @fail = CONCAT(@fail, ' U5: paid, but not Confirmed with its hold cleared;');
    IF NOT EXISTS (SELECT 1 FROM core.EMAIL_OUTBOX WHERE BookingId = @Bid AND MailKind = 'Confirmation' AND Channel = 'Email')
       OR EXISTS (SELECT 1 FROM core.EMAIL_OUTBOX WHERE BookingId = @Bid AND MailKind = 'Request')
        SET @fail = CONCAT(@fail, ' U5: the messages after paying are ',
                           ISNULL((SELECT STRING_AGG(CONCAT(MailKind, '/', Channel), ', ') FROM core.EMAIL_OUTBOX WHERE BookingId = @Bid), 'none'), ';');

    /* U6 */
    UPDATE core.SETTING SET SettingValue = '0' WHERE SettingKey = 'BookingDepositRequired';
    DELETE FROM @made;
    INSERT INTO @made EXEC booking.usp_Booking_Create @RoomId = @Room, @BookDate = @D, @StartTime = '13:00', @EndTime = '14:00',
         @Persons = 2, @GuestName = N'QA3 Request', @GuestPhone = '+96170000364', @GuestEmail = N'qa3-request@example.invalid', @Source = 'Website';
    SELECT @Bid = BookingId FROM @made;
    IF NOT EXISTS (SELECT 1 FROM booking.BOOKING WHERE BookingId = @Bid AND [Status] = 'Pending' AND HoldExpiresUtc IS NULL)
        SET @fail = CONCAT(@fail, ' U6: a request staff confirm got a hold;');
    IF NOT EXISTS (SELECT 1 FROM core.EMAIL_OUTBOX WHERE BookingId = @Bid AND MailKind = 'Request' AND Channel = 'Email')
       OR NOT EXISTS (SELECT 1 FROM core.EMAIL_OUTBOX WHERE BookingId = @Bid AND MailKind = 'StaffAlert')
        SET @fail = CONCAT(@fail, ' U6: a request lost its messages (',
                           ISNULL((SELECT STRING_AGG(CONCAT(MailKind, '/', Channel), ', ') FROM core.EMAIL_OUTBOX WHERE BookingId = @Bid), 'none'), ');');
    DELETE FROM @swept;
    INSERT INTO @swept EXEC booking.usp_Booking_ExpireHolds;
    IF (SELECT [Status] FROM booking.BOOKING WHERE BookingId = @Bid) <> 'Pending'
        SET @fail = CONCAT(@fail, ' U6: the sweep touched a request;');

    /* U7 */
    UPDATE core.SETTING SET SettingValue = '1' WHERE SettingKey = 'BookingDepositRequired';
    DELETE FROM @made;
    INSERT INTO @made EXEC booking.usp_Booking_Create @RoomId = @Room, @BookDate = @D, @StartTime = '15:00', @EndTime = '16:00',
         @Persons = 2, @GuestName = N'QA3 Staff', @GuestPhone = '+96170000365', @Source = 'Manual';
    IF NOT EXISTS (SELECT 1 FROM @made m JOIN booking.BOOKING b ON b.BookingId = m.BookingId WHERE b.[Status] = 'Confirmed' AND b.HoldExpiresUtc IS NULL)
        SET @fail = CONCAT(@fail, ' U7: a staff booking is not Confirmed without a hold;');
END TRY
BEGIN CATCH
    SET @fail = CONCAT(@fail, ' unexpected error: ', ERROR_MESSAGE(), ';');
END CATCH;
IF @@TRANCOUNT > 0 ROLLBACK;

IF @fail IS NOT NULL RAISERROR('unpaid_never_stays FAILED:%s', 16, 1, @fail);
ELSE PRINT 'ok unpaid_never_stays';
GO
