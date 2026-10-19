/* ============================================================================
   tests/qa3/booking/block_after_midnight.sql - QA3 BKG-2, the server half (docs/104_qa3_booking.sql).

   A staff block could not run past midnight (the API refused an end at or before the start) and
   its "real bookings exist" check was the base procedure's, on the same date. booking.usp_Block_Add:

     B1  Monday 23:00 -> 01:00 is stored as Monday 1380-1500 (the next-morning rule, EndMin <= 1800)
     B2  an end after 06:00 the next morning is refused; an end equal to the start is refused
     B3  Tuesday 00:00-00:30 is refused while Monday 23:00-01:00 is a live booking (absolute time)
     B4  Monday 23:30 -> 00:30 is refused while Tuesday 00:00-01:00 is a live booking (the other way)
     B5  a lapsed payment hold (Pending, HoldExpiresUtc past) and a cancelled booking do not stop a block

   Each case in its own transaction (a refused block rolls back), all rolled back; the throw-away room
   'QA3 booking room', dates 15-16 June 2099. RAISERROR on a wrong result; 'ok ...' otherwise.
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
DECLARE @fail NVARCHAR(2000) = NULL, @Room INT, @Mon DATE = '2099-06-15', @Tue DATE = '2099-06-16', @Msg NVARCHAR(400), @case INT = 1;
DECLARE @made TABLE (BookingId INT, BookingRef VARCHAR(12), TotalAmount DECIMAL(10,2), DepositDue DECIMAL(10,2), DepositPercent DECIMAL(5,2), CurrencyCode CHAR(3), [Status] VARCHAR(12), Hours DECIMAL(6,2), RoomName NVARCHAR(80), RoomId INT, DiscountPercent DECIMAL(5,2), DiscountAmount DECIMAL(10,2));
DECLARE @blk TABLE (BlockId INT);
DECLARE @Stored VARCHAR(40);

WHILE @case <= 6
BEGIN
    DELETE FROM @made; DELETE FROM @blk; SELECT @Msg = NULL, @Stored = NULL;
    BEGIN TRAN;
    BEGIN TRY
        INSERT INTO booking.ROOM (Code, [Name], Seats, MinPersons, PricePerHour, MinHours, MaxHours, SortOrder, IsActive)
        VALUES ('qa3-bk', N'QA3 booking room', 6, 1, 20, 1, 6, 999, 1);
        SET @Room = SCOPE_IDENTITY();
        INSERT INTO booking.ROOM_HOURS (RoomId, DayOfWeek, OpenTime, CloseTime, IsClosed)
        SELECT @Room, d, '07:00', '01:00', 0 FROM (VALUES (1),(2),(3),(4),(5),(6),(7)) v(d);

        IF @case = 1
        BEGIN
            INSERT INTO @blk EXEC booking.usp_Block_Add @RoomId = @Room, @BlockDate = @Mon, @StartTime = '23:00', @EndTime = '01:00', @Reason = N'QA3 late block';
            SELECT @Stored = CONCAT(CONVERT(CHAR(10), BlockDate, 23), ' ', StartMin, '-', EndMin) FROM booking.BOOKING_BLOCK WHERE BlockId = (SELECT BlockId FROM @blk);
            IF ISNULL(@Stored, '') <> '2099-06-15 1380-1500' SET @fail = CONCAT(@fail, ' B1: stored ', ISNULL(@Stored, 'nothing'), ';');
        END

        IF @case = 2
        BEGIN
            BEGIN TRY
                INSERT INTO @blk EXEC booking.usp_Block_Add @RoomId = @Room, @BlockDate = @Mon, @StartTime = '22:00', @EndTime = '07:00';
            END TRY
            BEGIN CATCH SET @Msg = ERROR_MESSAGE(); END CATCH;
            IF @Msg IS NULL OR @Msg NOT LIKE 'The end time must be after the start time%' SET @fail = CONCAT(@fail, ' B2: 22:00-07:00 answered ', ISNULL(@Msg, 'success'), ';');
            SET @Msg = NULL;
            BEGIN TRY
                INSERT INTO @blk EXEC booking.usp_Block_Add @RoomId = @Room, @BlockDate = @Mon, @StartTime = '10:00', @EndTime = '10:00';
            END TRY
            BEGIN CATCH SET @Msg = ERROR_MESSAGE(); END CATCH;
            IF @Msg IS NULL OR @Msg NOT LIKE 'The end time must be after the start time%' SET @fail = CONCAT(@fail, ' B2: 10:00-10:00 answered ', ISNULL(@Msg, 'success'), ';');
            IF EXISTS (SELECT 1 FROM @blk) SET @fail = CONCAT(@fail, ' B2: a refused block was stored;');
        END

        IF @case = 3      /* the refusal rolls the whole case back: it comes last */
        BEGIN
            INSERT INTO @made EXEC booking.usp_Booking_Create @RoomId = @Room, @BookDate = @Mon, @StartTime = '23:00', @EndTime = '01:00',
                 @Persons = 2, @GuestName = N'QA3 Late guest', @GuestPhone = '+96170000331', @Source = 'Manual';
            BEGIN TRY
                /* a plain EXEC: the refusal ROLLBACKs, which INSERT ... EXEC does not allow (error 3915) */
                EXEC booking.usp_Block_Add @RoomId = @Room, @BlockDate = @Tue, @StartTime = '00:00', @EndTime = '00:30';
            END TRY
            BEGIN CATCH SET @Msg = ERROR_MESSAGE(); END CATCH;
            IF @Msg IS NULL OR @Msg NOT LIKE 'Real bookings exist in that period%' SET @fail = CONCAT(@fail, ' B3: answered ', ISNULL(@Msg, 'success'), ';');
        END

        IF @case = 4
        BEGIN
            INSERT INTO @made EXEC booking.usp_Booking_Create @RoomId = @Room, @BookDate = @Tue, @StartTime = '00:00', @EndTime = '01:00',
                 @Persons = 2, @GuestName = N'QA3 Midnight guest', @GuestPhone = '+96170000332', @Source = 'Manual';
            BEGIN TRY
                EXEC booking.usp_Block_Add @RoomId = @Room, @BlockDate = @Mon, @StartTime = '23:30', @EndTime = '00:30';
            END TRY
            BEGIN CATCH SET @Msg = ERROR_MESSAGE(); END CATCH;
            IF @Msg IS NULL OR @Msg NOT LIKE 'Real bookings exist in that period%' SET @fail = CONCAT(@fail, ' B4: answered ', ISNULL(@Msg, 'success'), ';');
        END

        IF @case = 5
        BEGIN
            INSERT INTO @made EXEC booking.usp_Booking_Create @RoomId = @Room, @BookDate = @Tue, @StartTime = '00:00', @EndTime = '01:00',
                 @Persons = 2, @GuestName = N'QA3 Lapsed hold', @GuestPhone = '+96170000333', @Source = 'Manual';
            UPDATE booking.BOOKING SET [Status] = 'Pending', HoldExpiresUtc = DATEADD(MINUTE, -1, SYSUTCDATETIME())
            WHERE BookingId = (SELECT BookingId FROM @made);
            INSERT INTO @blk EXEC booking.usp_Block_Add @RoomId = @Room, @BlockDate = @Mon, @StartTime = '23:00', @EndTime = '01:00';
            IF NOT EXISTS (SELECT 1 FROM @blk) SET @fail = CONCAT(@fail, ' B5: a lapsed hold stopped the block;');
        END

        IF @case = 6
        BEGIN
            INSERT INTO @made EXEC booking.usp_Booking_Create @RoomId = @Room, @BookDate = @Mon, @StartTime = '23:00', @EndTime = '01:00',
                 @Persons = 2, @GuestName = N'QA3 Cancelled', @GuestPhone = '+96170000334', @Source = 'Manual';
            UPDATE booking.BOOKING SET [Status] = 'Cancelled', CancelledBy = 'Staff', CancelReason = N'QA3' WHERE BookingId = (SELECT BookingId FROM @made);
            INSERT INTO @blk EXEC booking.usp_Block_Add @RoomId = @Room, @BlockDate = @Tue, @StartTime = '00:00', @EndTime = '00:30';
            IF NOT EXISTS (SELECT 1 FROM @blk) SET @fail = CONCAT(@fail, ' B5: a cancelled booking stopped the block;');
        END
    END TRY
    BEGIN CATCH
        SET @fail = CONCAT(@fail, ' case ', @case, ': unexpected error: ', ERROR_MESSAGE(), ';');
    END CATCH;
    IF @@TRANCOUNT > 0 ROLLBACK;
    SET @case += 1;
END

IF @fail IS NOT NULL RAISERROR('block_after_midnight FAILED:%s', 16, 1, @fail);
ELSE PRINT 'ok block_after_midnight';
GO
