/* ============================================================================
   cases/08_booking_midnight_start.sql — SQL 89 (a 00:00 start inside the previous day's late
   window) at procedure level. Reda's brief, item 1: availability offers "12:00 AM" inside a window
   running past midnight (Aden: 10:00 PM – 1:00 AM), the website sends it as the NEXT date with
   startMin 0, and quote/create answered 400 "closed".

   Rule: a slot is inside the opening hours when its own date's window covers it, or when the
   PREVIOUS date's window covers it in that date's minutes (start + 1440 and end + 1440 <= its CloseMin).

   M1  Tuesday 00:00–01:00 after Monday closing at 01:00: quoted (1 hour), created, stored on Tuesday 0–60
   M2  Tuesday 00:30–01:30 runs past Monday's 01:00 close: refused "closed"
   M3  Wednesday 00:00–01:00 after Tuesday closing AT midnight: refused "closed"
   M4  slots inside a date's own hours are judged exactly as before
   M5  the month view counts the Tuesday 00:00 booking inside MONDAY's window, not in Tuesday's hours
   M6  Monday 23:00–01:00 is refused while Tuesday 00:00–01:00 is booked (no double booking)
   M7  Tuesday 00:00–01:00 is refused while Monday 23:00–01:00 is booked (the other direction)

   A throw-away room "QA midnight room" with its own week: Monday 22:00–01:00, Tuesday 10:00–00:00,
   every other day 10:00–22:00; dates Monday 15 – Wednesday 17 June 2099; Source Manual (no lead-time
   rules this far out). Two transactions, both rolled back: nothing persists. The quote refusals are
   caught inside the transaction (usp_Booking_Quote does not set XACT_ABORT); a refusal from
   usp_Booking_Create ends its transaction, so M6 and M7 each come last in theirs.
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
DECLARE @Mon DATE = '2099-06-15', @Tue DATE = '2099-06-16', @Wed DATE = '2099-06-17';
DECLARE @Room INT;
DECLARE @a1 NVARCHAR(600) = N'not run', @p1 BIT = 0, @a2 NVARCHAR(600) = N'not run', @p2 BIT = 0,
        @a3 NVARCHAR(600) = N'not run', @p3 BIT = 0, @a4 NVARCHAR(600) = N'', @p4 BIT = 1,
        @a5 NVARCHAR(600) = N'not run', @p5 BIT = 0, @a6 NVARCHAR(600) = N'not run', @p6 BIT = 0;
DECLARE @quote TABLE (RoomId INT, RoomCode VARCHAR(30), RoomName NVARCHAR(80), Hours DECIMAL(6,2), PricePerHour DECIMAL(18,6),
                      RoomGross DECIMAL(18,6), DiscountPercent DECIMAL(18,6), DiscountFromHours DECIMAL(18,6), DiscountAmount DECIMAL(18,6),
                      RoomTotal DECIMAL(18,6), AddonTotal DECIMAL(18,6), TotalAmount DECIMAL(18,6), DepositPercent DECIMAL(18,6),
                      DepositDue DECIMAL(18,6), CurrencyCode CHAR(3), LocalNow DATETIME2(0), DepositRequired BIT);
DECLARE @made TABLE (BookingId INT, BookingRef VARCHAR(12), TotalAmount DECIMAL(10,2), DepositDue DECIMAL(10,2), DepositPercent DECIMAL(5,2), CurrencyCode CHAR(3), [Status] VARCHAR(12), Hours DECIMAL(6,2), RoomName NVARCHAR(80), RoomId INT, DiscountPercent DECIMAL(5,2), DiscountAmount DECIMAL(10,2));
DECLARE @month TABLE (OnDate DATE, IsClosed BIT, OpenMinutes INT, TakenMinutes INT, MaxFreeRun INT);
DECLARE @slots TABLE (Seq INT IDENTITY(1,1), Label VARCHAR(20), Dt DATE, S INT, E INT, Expect VARCHAR(10));
DECLARE @i INT, @Label VARCHAR(20), @Dt DATE, @S INT, @E INT, @Expect VARCHAR(10), @Got VARCHAR(10);

BEGIN TRAN;
BEGIN TRY
    INSERT INTO booking.ROOM (Code, [Name], Seats, MinPersons, PricePerHour, MinHours, MaxHours, SortOrder, IsActive)
    VALUES ('qa-midnight', N'QA midnight room', 8, 1, 10, 1, 6, 999, 1);
    SET @Room = SCOPE_IDENTITY();
    INSERT INTO booking.ROOM_HOURS (RoomId, DayOfWeek, OpenTime, CloseTime)
    VALUES (@Room, 1, '22:00', '01:00'), (@Room, 2, '10:00', '00:00'), (@Room, 3, '10:00', '22:00'), (@Room, 4, '10:00', '22:00'),
           (@Room, 5, '10:00', '22:00'), (@Room, 6, '10:00', '22:00'), (@Room, 7, '10:00', '22:00');

    /* M1: the contract shape of Monday's 12:00 AM start */
    INSERT INTO @quote EXEC booking.usp_Booking_Quote @RoomId = @Room, @BookDate = @Tue, @StartMin = 0, @EndMin = 60, @Source = 'Manual';
    INSERT INTO @made EXEC booking.usp_Booking_Create @RoomId = @Room, @BookDate = @Tue, @StartTime = '00:00', @EndTime = '01:00',
         @Persons = 2, @GuestName = N'QA Midnight A', @GuestPhone = '+96170000081', @Source = 'Manual';
    SELECT @a1 = CONCAT('quoted hours=', (SELECT Hours FROM @quote), ' stored=', CONVERT(CHAR(10), b.BookDate, 23), ' ', b.StartMin, '-', b.EndMin),
           @p1 = CASE WHEN (SELECT Hours FROM @quote) = 1 AND b.BookDate = @Tue AND b.StartMin = 0 AND b.EndMin = 60 THEN 1 ELSE 0 END
    FROM booking.BOOKING b WHERE b.BookingId = (SELECT BookingId FROM @made);

    /* M2 */
    BEGIN TRY
        INSERT INTO @quote EXEC booking.usp_Booking_Quote @RoomId = @Room, @BookDate = @Tue, @StartMin = 30, @EndMin = 90, @Source = 'Manual';
        SET @a2 = N'accepted';
    END TRY
    BEGIN CATCH
        SET @a2 = ERROR_MESSAGE();
        SET @p2 = CASE WHEN ERROR_MESSAGE() LIKE 'The room is closed%' THEN 1 ELSE 0 END;
    END CATCH;

    /* M3 */
    BEGIN TRY
        INSERT INTO @quote EXEC booking.usp_Booking_Quote @RoomId = @Room, @BookDate = @Wed, @StartMin = 0, @EndMin = 60, @Source = 'Manual';
        SET @a3 = N'accepted';
    END TRY
    BEGIN CATCH
        SET @a3 = ERROR_MESSAGE();
        SET @p3 = CASE WHEN ERROR_MESSAGE() LIKE 'The room is closed%' THEN 1 ELSE 0 END;
    END CATCH;

    /* M4: inside a date's own hours, as before */
    INSERT INTO @slots (Label, Dt, S, E, Expect) VALUES
        ('Wed10-12', @Wed, 600, 720, 'ok'), ('Wed09-10', @Wed, 540, 600, 'closed'), ('Wed21-23', @Wed, 1260, 1380, 'closed'),
        ('Mon22-01', @Mon, 1320, 1500, 'ok'), ('Mon21-22', @Mon, 1260, 1320, 'closed'),
        ('Tue22-00', @Tue, 1320, 1440, 'ok'), ('Tue23-01', @Tue, 1380, 1500, 'closed'), ('Tue01-02', @Tue, 60, 120, 'closed');
    SET @i = 1;
    WHILE @i <= (SELECT MAX(Seq) FROM @slots)
    BEGIN
        SELECT @Label = Label, @Dt = Dt, @S = S, @E = E, @Expect = Expect FROM @slots WHERE Seq = @i;
        BEGIN TRY
            INSERT INTO @quote EXEC booking.usp_Booking_Quote @RoomId = @Room, @BookDate = @Dt, @StartMin = @S, @EndMin = @E, @Source = 'Manual';
            SET @Got = 'ok';
        END TRY
        BEGIN CATCH
            SET @Got = CASE WHEN ERROR_MESSAGE() LIKE 'The room is closed%' THEN 'closed' ELSE 'error' END;
        END CATCH;
        SET @a4 = CONCAT(@a4, CASE WHEN @i > 1 THEN ' ' ELSE '' END, @Label, '=', @Got);
        IF @Got <> @Expect SET @p4 = 0;
        SET @i += 1;
    END;

    /* M5: the month view, with the Tuesday 00:00–01:00 booking in place */
    INSERT INTO @month EXEC booking.usp_Availability_GetMonth @RoomId = @Room, @MonthDate = @Mon;
    SELECT @a5 = CONCAT('Mon open=', m.OpenMinutes, ' taken=', m.TakenMinutes, ' freeRun=', m.MaxFreeRun,
                        ' | Tue open=', t.OpenMinutes, ' taken=', t.TakenMinutes, ' freeRun=', t.MaxFreeRun),
           @p5 = CASE WHEN m.OpenMinutes = 180 AND m.TakenMinutes = 60 AND m.MaxFreeRun = 120
                           AND t.OpenMinutes = 840 AND t.TakenMinutes = 0 AND t.MaxFreeRun = 840 THEN 1 ELSE 0 END
    FROM @month m CROSS JOIN @month t WHERE m.OnDate = @Mon AND t.OnDate = @Tue;

    /* M6: last — a refusal from usp_Booking_Create ends the transaction */
    BEGIN TRY
        EXEC booking.usp_Booking_Create @RoomId = @Room, @BookDate = @Mon, @StartTime = '23:00', @EndTime = '01:00',
             @Persons = 2, @GuestName = N'QA Midnight B', @GuestPhone = '+96170000082', @Source = 'Manual';
        SET @a6 = N'accepted';
    END TRY
    BEGIN CATCH
        SET @a6 = ERROR_MESSAGE();
        SET @p6 = CASE WHEN ERROR_MESSAGE() LIKE 'That time was just taken%' THEN 1 ELSE 0 END;
    END CATCH;
END TRY
BEGIN CATCH
    SET @a1 = CONCAT(@a1, ' | aborted: ', ERROR_MESSAGE());
END CATCH;
IF @@TRANCOUNT > 0 ROLLBACK;

EXEC dbo.QA_Check 'M1', 'Tuesday 00:00-01:00 after Monday closing at 01:00 (the website''s shape of Monday''s 12:00 AM start) is quoted and created on Tuesday', 'quoted hours=1.00 stored=2099-06-16 0-60', @a1, @p1;
EXEC dbo.QA_Check 'M2', 'Tuesday 00:30-01:30 runs past Monday''s 01:00 close and is refused', 'The room is closed at that time ...', @a2, @p2;
EXEC dbo.QA_Check 'M3', 'Wednesday 00:00-01:00 after Tuesday closing at midnight is refused', 'The room is closed at that time ...', @a3, @p3;
EXEC dbo.QA_Check 'M4', 'slots inside a date''s own hours are judged as before', 'Wed10-12=ok Wed09-10=closed Wed21-23=closed Mon22-01=ok Mon21-22=closed Tue22-00=ok Tue23-01=closed Tue01-02=closed', @a4, @p4;
EXEC dbo.QA_Check 'M5', 'the month view counts the Tuesday 00:00 booking inside Monday''s window, not in Tuesday''s hours', 'Mon open=180 taken=60 freeRun=120 | Tue open=840 taken=0 freeRun=840', @a5, @p5;
EXEC dbo.QA_Check 'M6', 'Monday 23:00-01:00 is refused while Tuesday 00:00-01:00 is booked', 'That time was just taken ...', @a6, @p6;
GO

/* M7: the other direction, in its own transaction (the refusal ends it) */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
DECLARE @Mon DATE = '2099-06-15', @Tue DATE = '2099-06-16';
DECLARE @Room INT, @a7 NVARCHAR(600) = N'not run', @p7 BIT = 0;
DECLARE @made TABLE (BookingId INT, BookingRef VARCHAR(12), TotalAmount DECIMAL(10,2), DepositDue DECIMAL(10,2), DepositPercent DECIMAL(5,2), CurrencyCode CHAR(3), [Status] VARCHAR(12), Hours DECIMAL(6,2), RoomName NVARCHAR(80), RoomId INT, DiscountPercent DECIMAL(5,2), DiscountAmount DECIMAL(10,2));

BEGIN TRAN;
BEGIN TRY
    INSERT INTO booking.ROOM (Code, [Name], Seats, MinPersons, PricePerHour, MinHours, MaxHours, SortOrder, IsActive)
    VALUES ('qa-midnight', N'QA midnight room', 8, 1, 10, 1, 6, 999, 1);
    SET @Room = SCOPE_IDENTITY();
    INSERT INTO booking.ROOM_HOURS (RoomId, DayOfWeek, OpenTime, CloseTime)
    VALUES (@Room, 1, '22:00', '01:00'), (@Room, 2, '10:00', '00:00'), (@Room, 3, '10:00', '22:00'), (@Room, 4, '10:00', '22:00'),
           (@Room, 5, '10:00', '22:00'), (@Room, 6, '10:00', '22:00'), (@Room, 7, '10:00', '22:00');

    INSERT INTO @made EXEC booking.usp_Booking_Create @RoomId = @Room, @BookDate = @Mon, @StartTime = '23:00', @EndTime = '01:00',
         @Persons = 2, @GuestName = N'QA Midnight C', @GuestPhone = '+96170000083', @Source = 'Manual';

    BEGIN TRY
        EXEC booking.usp_Booking_Create @RoomId = @Room, @BookDate = @Tue, @StartTime = '00:00', @EndTime = '01:00',
             @Persons = 2, @GuestName = N'QA Midnight D', @GuestPhone = '+96170000084', @Source = 'Manual';
        SET @a7 = N'accepted';
    END TRY
    BEGIN CATCH
        SET @a7 = ERROR_MESSAGE();
        SET @p7 = CASE WHEN ERROR_MESSAGE() LIKE 'That time was just taken%' THEN 1 ELSE 0 END;
    END CATCH;
END TRY
BEGIN CATCH
    SET @a7 = CONCAT(@a7, ' | aborted: ', ERROR_MESSAGE());
END CATCH;
IF @@TRANCOUNT > 0 ROLLBACK;

EXEC dbo.QA_Check 'M7', 'Tuesday 00:00-01:00 is refused while Monday 23:00-01:00 is booked', 'That time was just taken ...', @a7, @p7;
GO
