/* ============================================================================
   tests/qa3/booking/switches_and_senders.sql - QA3 settings dialects and BKG-7 (docs/104_qa3_booking.sql).

     S1  booking.fn_SettingIsOn: '1', 'true', 'TRUE', ' on ', 'yes' are ON; '0', 'false', 'off', '' and
         a missing row are OFF (the Settings page writes 'true'/'false' to a row with no dialect)
     S2  usp_Booking_Create reads BookingAutoConfirm in both dialects: 'true' confirms a website
         booking at once, 'false' leaves it Pending
     S3  core.usp_Email_GetBookingSenders answers, for the ids it is given, the sender / SMTP account of
         the BOOKING mail only (a request's mail is not returned; an id not asked for is not returned)

   One transaction, rolled back. RAISERROR on a wrong result; 'ok ...' otherwise.
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
DECLARE @fail NVARCHAR(1000) = NULL, @Room INT, @D DATE, @Ref1 VARCHAR(12), @Ref2 VARCHAR(12), @Bid INT, @E1 INT, @E2 INT, @E3 INT, @Ids VARCHAR(100);
DECLARE @made TABLE (BookingId INT, BookingRef VARCHAR(12), TotalAmount DECIMAL(10,2), DepositDue DECIMAL(10,2), DepositPercent DECIMAL(5,2), CurrencyCode CHAR(3), [Status] VARCHAR(12), Hours DECIMAL(6,2), RoomName NVARCHAR(80), RoomId INT, DiscountPercent DECIMAL(5,2), DiscountAmount DECIMAL(10,2));
DECLARE @senders TABLE (EmailId INT, BookingId INT, MailKind VARCHAR(20), FromEmail NVARCHAR(150), FromName NVARCHAR(100), SmtpAccount VARCHAR(20), Template VARCHAR(60));

BEGIN TRAN;
BEGIN TRY
    /* S1 */
    DELETE FROM core.SETTING WHERE SettingKey = 'QA3SwitchProbe';
    INSERT INTO core.SETTING (SettingKey, SettingValue, DataType) VALUES ('QA3SwitchProbe', '1', 'bool');
    DECLARE @v TABLE (V NVARCHAR(20), Expect BIT);
    INSERT INTO @v VALUES (N'1', 1), (N'true', 1), (N'TRUE', 1), (N' on ', 1), (N'yes', 1), (N'0', 0), (N'false', 0), (N'off', 0), (N'', 0);
    DECLARE @val NVARCHAR(20), @exp BIT;
    DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT V, Expect FROM @v;
    OPEN c; FETCH NEXT FROM c INTO @val, @exp;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        UPDATE core.SETTING SET SettingValue = @val WHERE SettingKey = 'QA3SwitchProbe';
        IF booking.fn_SettingIsOn('QA3SwitchProbe') <> @exp SET @fail = CONCAT(@fail, ' S1: ''', @val, ''' read as ', CASE WHEN @exp = 1 THEN 'off' ELSE 'on' END, ';');
        FETCH NEXT FROM c INTO @val, @exp;
    END
    CLOSE c; DEALLOCATE c;
    DELETE FROM core.SETTING WHERE SettingKey = 'QA3SwitchProbe';
    IF booking.fn_SettingIsOn('QA3SwitchProbe') <> 0 SET @fail = CONCAT(@fail, ' S1: a missing row read as on;');

    /* S2 */
    UPDATE core.SETTING SET SettingValue = '60' WHERE SettingKey IN ('BookingSlotMinutes', 'BookingLeadMaxDays');
    UPDATE core.SETTING SET SettingValue = '1'  WHERE SettingKey = 'BookingLeadMinHours';
    UPDATE core.SETTING SET SettingValue = '0'  WHERE SettingKey = 'BookingDepositRequired';
    IF NOT EXISTS (SELECT 1 FROM core.SETTING WHERE SettingKey = 'BookingAutoConfirm')
        INSERT INTO core.SETTING (SettingKey, SettingValue, DataType) VALUES ('BookingAutoConfirm', '0', 'bool');
    INSERT INTO booking.ROOM (Code, [Name], Seats, MinPersons, PricePerHour, MinHours, MaxHours, SortOrder, IsActive)
    VALUES ('qa3-bk', N'QA3 booking room', 6, 1, 20, 1, 6, 999, 1);
    SET @Room = SCOPE_IDENTITY();
    INSERT INTO booking.ROOM_HOURS (RoomId, DayOfWeek, OpenTime, CloseTime, IsClosed)
    SELECT @Room, d, '07:00', '01:00', 0 FROM (VALUES (1),(2),(3),(4),(5),(6),(7)) v(d);
    SET @D = DATEADD(DAY, 10, CAST(booking.fn_LocalNow() AS DATE));

    UPDATE core.SETTING SET SettingValue = 'true' WHERE SettingKey = 'BookingAutoConfirm';
    INSERT INTO @made EXEC booking.usp_Booking_Create @RoomId = @Room, @BookDate = @D, @StartTime = '10:00', @EndTime = '11:00',
         @Persons = 2, @GuestName = N'QA3 Auto', @GuestPhone = '+96170000341', @Source = 'Website';
    SELECT @Ref1 = BookingRef, @Bid = BookingId FROM @made;
    UPDATE core.SETTING SET SettingValue = 'false' WHERE SettingKey = 'BookingAutoConfirm';
    DELETE FROM @made;
    INSERT INTO @made EXEC booking.usp_Booking_Create @RoomId = @Room, @BookDate = @D, @StartTime = '12:00', @EndTime = '13:00',
         @Persons = 2, @GuestName = N'QA3 Not auto', @GuestPhone = '+96170000342', @Source = 'Website';
    SELECT @Ref2 = BookingRef FROM @made;
    IF (SELECT [Status] FROM booking.BOOKING WHERE BookingRef = @Ref1) <> 'Confirmed' SET @fail = CONCAT(@fail, ' S2: AutoConfirm = true did not confirm;');
    IF (SELECT [Status] FROM booking.BOOKING WHERE BookingRef = @Ref2) <> 'Pending'   SET @fail = CONCAT(@fail, ' S2: AutoConfirm = false confirmed;');

    /* S3 */
    INSERT INTO core.EMAIL_OUTBOX (ToAddress, [Subject], Body, Channel, Lang, BookingId, MailKind, FromEmail, FromName, SmtpAccount)
    VALUES (N'qa3-guest@example.invalid', N'QA3 booking mail', N'QA3', 'Email', 'en', @Bid, 'QA3Probe', N'qa3-bookings@example.invalid', N'QA3 Bookings', 'Booking');
    SET @E1 = SCOPE_IDENTITY();
    INSERT INTO core.EMAIL_OUTBOX (ToAddress, [Subject], Body, Channel, Lang)
    VALUES (N'qa3-employee@example.invalid', N'QA3 request mail', N'QA3', 'Email', 'en');
    SET @E2 = SCOPE_IDENTITY();
    INSERT INTO core.EMAIL_OUTBOX (ToAddress, [Subject], Body, Channel, Lang, BookingId, MailKind, FromEmail, FromName, SmtpAccount)
    VALUES (N'qa3-other@example.invalid', N'QA3 booking mail 2', N'QA3', 'Email', 'en', @Bid, 'QA3Probe2', N'qa3-bookings@example.invalid', N'QA3 Bookings', 'Booking');
    SET @E3 = SCOPE_IDENTITY();

    SET @Ids = CONCAT(@E1, ',', @E2);
    INSERT INTO @senders EXEC core.usp_Email_GetBookingSenders @EmailIds = @Ids;
    IF (SELECT COUNT(*) FROM @senders) <> 1
       OR NOT EXISTS (SELECT 1 FROM @senders WHERE EmailId = @E1 AND BookingId = @Bid AND FromEmail = N'qa3-bookings@example.invalid'
                                              AND FromName = N'QA3 Bookings' AND SmtpAccount = 'Booking')
        SET @fail = CONCAT(@fail, ' S3: expected only the booking row ', @E1, ' with its sender, got ',
                           ISNULL((SELECT STRING_AGG(CONCAT(EmailId, '/', SmtpAccount), ',') FROM @senders), 'nothing'), ';');
END TRY
BEGIN CATCH
    SET @fail = CONCAT(@fail, ' unexpected error: ', ERROR_MESSAGE(), ';');
END CATCH;
IF @@TRANCOUNT > 0 ROLLBACK;

IF @fail IS NOT NULL RAISERROR('switches_and_senders FAILED:%s', 16, 1, @fail);
ELSE PRINT 'ok switches_and_senders';
GO
