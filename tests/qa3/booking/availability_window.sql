/* ============================================================================
   tests/qa3/booking/availability_window.sql - QA3 BKG-11 and BKG-13 (docs/104_qa3_booking.sql).

     A1  BKG-11: a DEACTIVATED room is closed on every day of usp_Availability_GetMonth; an active
         room is not. (usp_Availability_GetDay answers two result sets, which INSERT ... EXEC cannot
         hold: its frame is checked by the API's DB test AvailabilityWindowDbTests.)
     A2  BKG-13: the 00:00-01:00 start of the LAST bookable night (sent, as the website does, as the
         next date with startMin 0) is accepted by usp_Booking_Validate - the night belongs to the
         last bookable date - while 01:00 on that next date's own window stays refused ("up to N
         days ahead"), and a slot one night further is still refused

   One transaction, rolled back; the throw-away room 'QA3 booking room' (open 07:00-01:00 every day).
   BookingLeadMaxDays is set to 30 inside the transaction. RAISERROR on a wrong result.
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
DECLARE @fail NVARCHAR(1000) = NULL, @Room INT, @Today DATE, @Last DATE, @rc INT, @Seats INT, @RoomName NVARCHAR(80), @Now DATETIME2(0), @Msg NVARCHAR(400);
DECLARE @month TABLE (OnDate DATE, IsClosed BIT, OpenMinutes INT, TakenMinutes INT, MaxFreeRun INT);
DECLARE @RoomOut INT, @Next DATE, @Next2 DATE;

BEGIN TRAN;
BEGIN TRY
    UPDATE core.SETTING SET SettingValue = '30' WHERE SettingKey = 'BookingLeadMaxDays';
    UPDATE core.SETTING SET SettingValue = '60' WHERE SettingKey = 'BookingSlotMinutes';
    INSERT INTO booking.ROOM (Code, [Name], Seats, MinPersons, PricePerHour, MinHours, MaxHours, SortOrder, IsActive)
    VALUES ('qa3-bk', N'QA3 booking room', 6, 1, 20, 1, 6, 999, 1);
    SET @Room = SCOPE_IDENTITY();
    INSERT INTO booking.ROOM_HOURS (RoomId, DayOfWeek, OpenTime, CloseTime, IsClosed)
    SELECT @Room, d, '07:00', '01:00', 0 FROM (VALUES (1),(2),(3),(4),(5),(6),(7)) v(d);
    SET @Today = CAST(booking.fn_LocalNow() AS DATE);
    SET @Last = DATEADD(DAY, 30, @Today);
    SET @Next = DATEADD(DAY, 1, @Last);
    SET @Next2 = DATEADD(DAY, 2, @Last);

    /* A1 */
    INSERT INTO @month EXEC booking.usp_Availability_GetMonth @RoomId = @Room, @MonthDate = @Last;
    IF EXISTS (SELECT 1 FROM @month WHERE IsClosed = 1 OR OpenMinutes <> 1080)
        SET @fail = CONCAT(@fail, ' A1: an active room open 07:00-01:00 has closed days in GetMonth;');
    UPDATE booking.ROOM SET IsActive = 0 WHERE RoomId = @Room;
    DELETE FROM @month;
    INSERT INTO @month EXEC booking.usp_Availability_GetMonth @RoomId = @Room, @MonthDate = @Last;
    IF NOT EXISTS (SELECT 1 FROM @month) OR EXISTS (SELECT 1 FROM @month WHERE IsClosed = 0 OR OpenMinutes <> 0)
        SET @fail = CONCAT(@fail, ' A1: a deactivated room has open days in GetMonth;');
    UPDATE booking.ROOM SET IsActive = 1 WHERE RoomId = @Room;

    /* A2: the last night's own late window, and its 00:00 start sent as the next date */
    SET @RoomOut = @Room;
    EXEC @rc = booking.usp_Booking_Validate @RoomId = @RoomOut OUTPUT, @BookDate = @Last, @StartMin = 1380, @EndMin = 1500, @Source = 'Website',
         @Seats = @Seats OUTPUT, @RoomName = @RoomName OUTPUT, @NowLocal = @Now OUTPUT;
    IF @rc <> 0 SET @fail = CONCAT(@fail, ' A2: the last night 23:00-01:00 was refused;');

    SET @Msg = NULL; SET @rc = NULL; SET @RoomOut = @Room;
    BEGIN TRY
        EXEC @rc = booking.usp_Booking_Validate @RoomId = @RoomOut OUTPUT, @BookDate = @Next, @StartMin = 0, @EndMin = 60, @Source = 'Website',
             @Seats = @Seats OUTPUT, @RoomName = @RoomName OUTPUT, @NowLocal = @Now OUTPUT;
    END TRY
    BEGIN CATCH SET @Msg = ERROR_MESSAGE(); END CATCH;
    IF @Msg IS NOT NULL OR ISNULL(@rc, 1) <> 0
        SET @fail = CONCAT(@fail, ' A2: the last night''s 00:00-01:00 (next date) was refused: ', ISNULL(@Msg, CONCAT('rc=', @rc)), ';');

    SET @Msg = NULL; SET @rc = NULL; SET @RoomOut = @Room;
    BEGIN TRY
        EXEC @rc = booking.usp_Booking_Validate @RoomId = @RoomOut OUTPUT, @BookDate = @Next, @StartMin = 600, @EndMin = 660, @Source = 'Website',
             @Seats = @Seats OUTPUT, @RoomName = @RoomName OUTPUT, @NowLocal = @Now OUTPUT;
    END TRY
    BEGIN CATCH SET @Msg = ERROR_MESSAGE(); END CATCH;
    IF ISNULL(@Msg, N'') NOT LIKE N'Bookings open up to%'
        SET @fail = CONCAT(@fail, ' A2: 10:00 on the day after the last bookable one answered ', ISNULL(@Msg, CONCAT('rc=', @rc)), ';');

    SET @Msg = NULL; SET @rc = NULL; SET @RoomOut = @Room;
    BEGIN TRY
        EXEC @rc = booking.usp_Booking_Validate @RoomId = @RoomOut OUTPUT, @BookDate = @Next2, @StartMin = 0, @EndMin = 60, @Source = 'Website',
             @Seats = @Seats OUTPUT, @RoomName = @RoomName OUTPUT, @NowLocal = @Now OUTPUT;
    END TRY
    BEGIN CATCH SET @Msg = ERROR_MESSAGE(); END CATCH;
    IF ISNULL(@Msg, N'') NOT LIKE N'Bookings open up to%'
        SET @fail = CONCAT(@fail, ' A2: the next night''s 00:00 answered ', ISNULL(@Msg, CONCAT('rc=', @rc)), ';');
END TRY
BEGIN CATCH
    SET @fail = CONCAT(@fail, ' unexpected error: ', ERROR_MESSAGE(), ';');
END CATCH;
IF @@TRANCOUNT > 0 ROLLBACK;

IF @fail IS NOT NULL RAISERROR('availability_window FAILED:%s', 16, 1, @fail);
ELSE PRINT 'ok availability_window';
GO
