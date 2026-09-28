/* ============================================================================
   89_booking_midnight_start.sql — a 00:00 start inside the previous day's late window.

   THE BUG (Reda's brief, item 1). A room open 22:00–01:00 on Monday has the window 1320–1500 in
   Monday's minutes, and availability offers "12:00 AM" as a start. The website sends that start in
   the contract shape: the NEXT date (Tuesday) with startMin 0. usp_Booking_Validate only looked at
   TUESDAY's hours, found 0 before Tuesday's opening, and refused quote and create with "The room is
   closed at that time".

   THE RULE. A slot is inside the opening hours when its own date's window covers it, OR when the
   PREVIOUS date's window covers it in the previous date's minutes:
       start + 1440 <= previous CloseMin   and   end + 1440 <= previous CloseMin
   (the previous OpenMin is at most 1439, so the start is always after it). 00:00–01:00 after a day
   closing at 01:00 is accepted; 00:30–01:30 is refused; 00:00 after a day closing at midnight
   (CloseMin 1440) is refused. A slot inside its own date's hours is judged exactly as before.

   WHAT ELSE HAS TO AGREE, or the fix would open a double booking:
     usp_Booking_Validate      the rule above (quote and create both call it).
     usp_Booking_Create        the overlap test compares ABSOLUTE time across midnight: a Monday
                               23:00–01:00 booking (Monday, 1380–1500) and a Tuesday 00:00–01:00 one
                               (Tuesday, 0–60) collide, in whichever order they arrive. Blocks too.
     usp_Availability_GetDay   the taken list adds the neighbouring dates' ranges that fall inside
                               this date's open hours, in this date's minutes, cut to those hours:
                               Monday shows Tuesday's 00:00–01:00 booking as 1440–1500.
     usp_Availability_GetMonth each day's taken minutes and longest free run count the same ranges,
                               cut to the day's hours, so the calendar agrees with the day view.
   usp_Booking_Quote needs no change: it only calls usp_Booking_Validate.

   Each procedure is its current definition (scripts 65 and 67) with only the midnight logic changed.
   Idempotent: CREATE OR ALTER. Apply with sqlcmd -C -I -b.
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/* ---- 7. Shared validation (quote + create) ---------------------------------- */
/* Returns 0 when the slot is valid for the room; otherwise raises the message
   and returns 1 — callers MUST check the return code (RAISERROR does not stop
   the caller). Overlap is NOT checked here (create does it under lock). */
CREATE OR ALTER PROCEDURE booking.usp_Booking_Validate
    @RoomId INT OUTPUT, @RoomCode VARCHAR(30) = NULL,
    @BookDate DATE, @StartMin INT, @EndMin INT,
    @Persons INT = NULL, @Source VARCHAR(10) = 'Website',
    @Seats INT OUTPUT, @RoomName NVARCHAR(80) OUTPUT, @NowLocal DATETIME2(0) OUTPUT
AS BEGIN SET NOCOUNT ON;
    IF @RoomId IS NULL AND @RoomCode IS NOT NULL
        SELECT @RoomId = RoomId FROM booking.ROOM WHERE Code = @RoomCode;

    DECLARE @MinP INT, @Active BIT, @MinH INT, @MaxH INT;
    SELECT @Seats = Seats, @MinP = MinPersons, @Active = IsActive, @RoomName = [Name],
           @MinH = ISNULL(MinHours, TRY_CAST((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'BookingMinHours') AS INT)),
           @MaxH = ISNULL(MaxHours, TRY_CAST((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'BookingMaxHours') AS INT))
    FROM booking.ROOM WHERE RoomId = @RoomId;
    IF @Seats IS NULL OR @Active = 0
    BEGIN RAISERROR('That room is not available for booking.',16,1); RETURN 1; END

    IF @StartMin IS NULL OR @EndMin IS NULL OR @StartMin < 0 OR @StartMin > 1439
       OR @EndMin <= @StartMin OR @EndMin > 1800
    BEGIN RAISERROR('Choose a valid start and end time.',16,1); RETURN 1; END

    DECLARE @Slot INT = ISNULL(TRY_CAST((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'BookingSlotMinutes') AS INT), 60);
    IF @Source = 'Website' AND @Slot > 0 AND (@StartMin % @Slot <> 0 OR @EndMin % @Slot <> 0)
    BEGIN RAISERROR('Times must be in %d-minute steps.',16,1,@Slot); RETURN 1; END

    DECLARE @DurH DECIMAL(6,2) = (@EndMin - @StartMin) / 60.0;
    IF @DurH < ISNULL(@MinH, 1) OR @DurH > ISNULL(@MaxH, 24)
    BEGIN RAISERROR('Booking length must be between %d and %d hours.',16,1,@MinH,@MaxH); RETURN 1; END

    IF @Persons IS NOT NULL AND (@Persons < ISNULL(@MinP, 1) OR @Persons > @Seats)
    BEGIN RAISERROR('%s takes %d to %d persons.',16,1,@RoomName,@MinP,@Seats); RETURN 1; END

    /* Opening hours: the date's own window, or (SQL 89) the PREVIOUS date's window running past
       midnight. A start after midnight arrives as the next date with startMin 0–1439, so it is
       judged in the previous date's minutes: start + 1440 and end + 1440 inside its window. */
    DECLARE @Dow TINYINT = ((DATEPART(WEEKDAY, @BookDate) + @@DATEFIRST - 2) % 7) + 1;
    DECLARE @PrevDow TINYINT = CASE WHEN @Dow = 1 THEN 7 ELSE @Dow - 1 END;
    IF NOT EXISTS (SELECT 1 FROM booking.ROOM_HOURS
                   WHERE RoomId = @RoomId AND DayOfWeek = @Dow AND IsClosed = 0
                     AND OpenMin <= @StartMin AND CloseMin >= @EndMin)
       AND NOT EXISTS (SELECT 1 FROM booking.ROOM_HOURS
                   WHERE RoomId = @RoomId AND DayOfWeek = @PrevDow AND IsClosed = 0
                     AND OpenMin <= @StartMin + 1440 AND CloseMin >= @EndMin + 1440)
    BEGIN RAISERROR('The room is closed at that time — pick a time inside its opening hours.',16,1); RETURN 1; END

    SET @NowLocal = booking.fn_LocalNow();
    DECLARE @StartDt DATETIME2(0) = DATEADD(MINUTE, @StartMin, CAST(@BookDate AS DATETIME2(0)));
    DECLARE @EndDt   DATETIME2(0) = DATEADD(MINUTE, @EndMin,   CAST(@BookDate AS DATETIME2(0)));
    IF @Source = 'Website'
    BEGIN
        DECLARE @LeadMaxD INT = ISNULL(TRY_CAST((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'BookingLeadMaxDays') AS INT), 30);
        DECLARE @LeadMinH INT = ISNULL(TRY_CAST((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'BookingLeadMinHours') AS INT), 0);
        IF @BookDate > DATEADD(DAY, @LeadMaxD, CAST(@NowLocal AS DATE))
        BEGIN RAISERROR('Bookings open up to %d days ahead.',16,1,@LeadMaxD); RETURN 1; END
        IF @StartDt < DATEADD(HOUR, @LeadMinH, @NowLocal)
        BEGIN RAISERROR('Online booking closes %d hour(s) before the start — call us instead.',16,1,@LeadMinH); RETURN 1; END
    END
    ELSE IF @EndDt < @NowLocal
    BEGIN RAISERROR('That time is already in the past.',16,1); RETURN 1; END

    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE booking.usp_Booking_Create
    @RoomId INT = NULL, @RoomCode VARCHAR(30) = NULL,
    @BookDate DATE, @StartTime TIME(0), @EndTime TIME(0),
    @Persons INT, @GuestName NVARCHAR(120), @GuestPhone VARCHAR(30),
    @GuestEmail NVARCHAR(150) = NULL, @Note NVARCHAR(500) = NULL,
    @AddonIds VARCHAR(200) = NULL, @Source VARCHAR(10) = 'Website', @CreatedByUserId INT = NULL
AS BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;

    IF LTRIM(RTRIM(ISNULL(@GuestName, N''))) = N'' OR LTRIM(RTRIM(ISNULL(@GuestPhone, ''))) = ''
    BEGIN RAISERROR('Guest name and phone are required.',16,1); RETURN; END

    DECLARE @StartMin INT = DATEPART(HOUR, @StartTime) * 60 + DATEPART(MINUTE, @StartTime);
    DECLARE @EndMin   INT = CASE WHEN @EndTime <= @StartTime THEN 1440 ELSE 0 END
                          + DATEPART(HOUR, @EndTime) * 60 + DATEPART(MINUTE, @EndTime);

    DECLARE @rc INT, @Seats INT, @RoomName NVARCHAR(80), @Now DATETIME2(0);
    EXEC @rc = booking.usp_Booking_Validate @RoomId = @RoomId OUTPUT, @RoomCode = @RoomCode,
         @BookDate = @BookDate, @StartMin = @StartMin, @EndMin = @EndMin, @Persons = @Persons,
         @Source = @Source, @Seats = @Seats OUTPUT, @RoomName = @RoomName OUTPUT, @NowLocal = @Now OUTPUT;
    IF @rc <> 0 RETURN;

    DECLARE @StartDt DATETIME2(0) = DATEADD(MINUTE, @StartMin, CAST(@BookDate AS DATETIME2(0)));
    DECLARE @Pct DECIMAL(5,2) = ISNULL(booking.fn_DepositPercent(@StartDt, @Now),
                                       (SELECT DepositPercent FROM booking.ROOM WHERE RoomId = @RoomId));
    DECLARE @Floor DECIMAL(10,2) = ISNULL(TRY_CAST((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'BookingDepositFloor') AS DECIMAL(10,2)), 0);
    DECLARE @Total DECIMAL(10,2), @Ccy CHAR(3), @DiscPct DECIMAL(5,2), @DiscAmt DECIMAL(10,2);
    SELECT @Total = Total, @Ccy = CurrencyCode, @DiscPct = DiscountPercent, @DiscAmt = DiscountAmount
    FROM booking.fn_PriceQuote(@RoomId, @StartMin, @EndMin, @AddonIds);
    DECLARE @Deposit DECIMAL(10,2) = ROUND(@Total * @Pct / 100.0, 2);
    IF @Deposit < @Floor SET @Deposit = @Floor;
    IF @Deposit > @Total SET @Deposit = @Total;

    DECLARE @AutoConfirm BIT = CASE WHEN (SELECT SettingValue FROM core.SETTING
        WHERE SettingKey = 'BookingAutoConfirm') = '1' THEN 1 ELSE 0 END;
    DECLARE @Status VARCHAR(12) =
        CASE WHEN @Source = 'Manual' OR @AutoConfirm = 1 THEN 'Confirmed' ELSE 'Pending' END;

    /* Overlap in ABSOLUTE time (SQL 89): the day before can run past midnight into this date
       (23:00–01:00 is 1380–1500 on its own date), and this booking can run into the next date's first
       hour. A neighbour's minutes move by 1440 per day of difference before they are compared. */
    BEGIN TRAN;
    IF EXISTS (SELECT 1 FROM booking.BOOKING WITH (UPDLOCK, HOLDLOCK)
               WHERE RoomId = @RoomId
                 AND BookDate BETWEEN DATEADD(DAY, -1, @BookDate) AND DATEADD(DAY, 1, @BookDate)
                 AND [Status] IN ('Pending','Confirmed')
                 AND NOT ([Status] = 'Pending' AND HoldExpiresUtc IS NOT NULL AND HoldExpiresUtc < SYSUTCDATETIME())
                 AND StartMin + 1440 * DATEDIFF(DAY, @BookDate, BookDate) < @EndMin
                 AND EndMin   + 1440 * DATEDIFF(DAY, @BookDate, BookDate) > @StartMin)
       OR EXISTS (SELECT 1 FROM booking.BOOKING_BLOCK WITH (UPDLOCK, HOLDLOCK)
               WHERE RoomId = @RoomId
                 AND BlockDate BETWEEN DATEADD(DAY, -1, @BookDate) AND DATEADD(DAY, 1, @BookDate)
                 AND StartMin + 1440 * DATEDIFF(DAY, @BookDate, BlockDate) < @EndMin
                 AND EndMin   + 1440 * DATEDIFF(DAY, @BookDate, BlockDate) > @StartMin)
    BEGIN ROLLBACK; RAISERROR('That time was just taken — pick another slot.',16,1); RETURN; END

    DECLARE @Ref VARCHAR(12);
    WHILE 1 = 1
    BEGIN
        SET @Ref = 'MC-' + UPPER(LEFT(REPLACE(CONVERT(VARCHAR(36), NEWID()), '-', ''), 8));
        IF NOT EXISTS (SELECT 1 FROM booking.BOOKING WHERE BookingRef = @Ref) BREAK;
    END

    INSERT INTO booking.BOOKING (RoomId, BookDate, StartTime, EndTime, Persons, GuestName, GuestPhone,
        GuestEmail, Note, TotalAmount, DepositDue, DepositPercent, CurrencyCode, [Status], [Source],
        CreatedByUserId, BookingRef, DiscountPercent, DiscountAmount)
    VALUES (@RoomId, @BookDate, @StartTime, @EndTime, @Persons, LTRIM(RTRIM(@GuestName)),
        LTRIM(RTRIM(@GuestPhone)), NULLIF(LTRIM(RTRIM(@GuestEmail)), N''), @Note,
        @Total, @Deposit, @Pct, @Ccy, @Status, @Source, @CreatedByUserId, @Ref, @DiscPct, @DiscAmt);
    DECLARE @Bid INT = SCOPE_IDENTITY();

    INSERT INTO booking.BOOKING_ADDON (BookingId, AddonId, [Name], Amount)
    SELECT @Bid, a.AddonId, a.[Name],
           CASE a.PriceType WHEN 'PerHour' THEN ROUND(a.Price * (@EndMin - @StartMin) / 60.0, 2) ELSE a.Price END
    FROM booking.ROOM_ADDON a
    JOIN STRING_SPLIT(ISNULL(@AddonIds, ''), ',') s ON TRY_CAST(s.value AS INT) = a.AddonId
    WHERE a.RoomId = @RoomId AND a.IsActive = 1;
    COMMIT;

    SELECT @Bid AS BookingId, @Ref AS BookingRef, @Total AS TotalAmount, @Deposit AS DepositDue,
           @Pct AS DepositPercent, @Ccy AS CurrencyCode, @Status AS [Status],
           CAST((@EndMin - @StartMin) / 60.0 AS DECIMAL(6,2)) AS Hours,
           @RoomName AS RoomName, @RoomId AS RoomId,
           @DiscPct AS DiscountPercent, @DiscAmt AS DiscountAmount;
END;
GO

/* ---- 10. Availability (minutes; expired payment holds are free) ------------- */
CREATE OR ALTER PROCEDURE booking.usp_Availability_GetDay
    @RoomId INT = NULL, @RoomCode VARCHAR(30) = NULL, @OnDate DATE
AS BEGIN SET NOCOUNT ON;
    IF @RoomId IS NULL SELECT @RoomId = RoomId FROM booking.ROOM WHERE Code = @RoomCode;
    DECLARE @Dow TINYINT = ((DATEPART(WEEKDAY, @OnDate) + @@DATEFIRST - 2) % 7) + 1;
    DECLARE @OpenMin INT, @CloseMin INT;      /* NULL when the date is closed */
    SELECT @OpenMin = OpenMin, @CloseMin = CloseMin FROM booking.ROOM_HOURS
    WHERE RoomId = @RoomId AND DayOfWeek = @Dow AND IsClosed = 0;

    /* 1: the day's frame + the rules the site needs to paint it */
    SELECT r.RoomId, r.Code AS RoomCode, @OnDate AS OnDate,
           ISNULL(h.IsClosed, 1) AS IsClosed, h.OpenMin, h.CloseMin,
           ISNULL(TRY_CAST((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'BookingSlotMinutes') AS INT), 60) AS SlotMinutes,
           ISNULL(r.MinHours, TRY_CAST((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'BookingMinHours') AS INT)) AS MinHours,
           ISNULL(r.MaxHours, TRY_CAST((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'BookingMaxHours') AS INT)) AS MaxHours,
           ISNULL(TRY_CAST((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'BookingLeadMinHours') AS INT), 0) AS LeadMinHours,
           ISNULL(TRY_CAST((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'BookingLeadMaxDays') AS INT), 30) AS LeadMaxDays,
           booking.fn_LocalNow() AS LocalNow
    FROM booking.ROOM r
    LEFT JOIN booking.ROOM_HOURS h ON h.RoomId = r.RoomId AND h.DayOfWeek = @Dow
    WHERE r.RoomId = @RoomId;

    /* 2: taken ranges — bookings and blocks look the same to the website. The date's own ranges as
       they are; and (SQL 89) the previous and next dates' ranges that fall inside this date's open
       hours, in this date's minutes and cut to those hours — a window running past midnight shows
       the next date's 00:00–01:00 booking as 1440–1500. */
    SELECT StartMin, EndMin FROM (
        SELECT StartMin, EndMin FROM booking.BOOKING
        WHERE RoomId = @RoomId AND BookDate = @OnDate AND [Status] IN ('Pending','Confirmed')
          AND NOT ([Status] = 'Pending' AND HoldExpiresUtc IS NOT NULL AND HoldExpiresUtc < SYSUTCDATETIME())
        UNION ALL
        SELECT StartMin, EndMin FROM booking.BOOKING_BLOCK
        WHERE RoomId = @RoomId AND BlockDate = @OnDate
        UNION ALL
        SELECT CASE WHEN n.S < @OpenMin THEN @OpenMin ELSE n.S END,
               CASE WHEN n.E > @CloseMin THEN @CloseMin ELSE n.E END
        FROM (SELECT StartMin + 1440 * DATEDIFF(DAY, @OnDate, BookDate) AS S,
                     EndMin   + 1440 * DATEDIFF(DAY, @OnDate, BookDate) AS E
              FROM booking.BOOKING
              WHERE RoomId = @RoomId AND BookDate IN (DATEADD(DAY, -1, @OnDate), DATEADD(DAY, 1, @OnDate))
                AND [Status] IN ('Pending','Confirmed')
                AND NOT ([Status] = 'Pending' AND HoldExpiresUtc IS NOT NULL AND HoldExpiresUtc < SYSUTCDATETIME())
              UNION ALL
              SELECT StartMin + 1440 * DATEDIFF(DAY, @OnDate, BlockDate),
                     EndMin   + 1440 * DATEDIFF(DAY, @OnDate, BlockDate)
              FROM booking.BOOKING_BLOCK
              WHERE RoomId = @RoomId AND BlockDate IN (DATEADD(DAY, -1, @OnDate), DATEADD(DAY, 1, @OnDate))) n
        WHERE n.S < @CloseMin AND n.E > @OpenMin
    ) t
    ORDER BY StartMin, EndMin;
END;
GO

/* Per day of the month: open minutes, taken minutes and the longest free run —
   the site colours the calendar (closed / full / partial / open). */
CREATE OR ALTER PROCEDURE booking.usp_Availability_GetMonth
    @RoomId INT = NULL, @RoomCode VARCHAR(30) = NULL, @MonthDate DATE
AS BEGIN SET NOCOUNT ON;
    IF @RoomId IS NULL SELECT @RoomId = RoomId FROM booking.ROOM WHERE Code = @RoomCode;
    DECLARE @From DATE = DATEFROMPARTS(YEAR(@MonthDate), MONTH(@MonthDate), 1);
    DECLARE @To   DATE = EOMONTH(@From);

    ;WITH days AS (
        SELECT @From AS D UNION ALL SELECT DATEADD(DAY, 1, D) FROM days WHERE D < @To),
    frame AS (
        SELECT d.D, ISNULL(h.IsClosed, 1) AS IsClosed,
               ISNULL(h.OpenMin, 0) AS OpenMin, ISNULL(h.CloseMin, 0) AS CloseMin
        FROM days d
        LEFT JOIN booking.ROOM_HOURS h ON h.RoomId = @RoomId
             AND h.DayOfWeek = ((DATEPART(WEEKDAY, d.D) + @@DATEFIRST - 2) % 7) + 1),
    raw AS (    /* the month's ranges, and the day before and after it */
        SELECT BookDate AS Dt, StartMin, EndMin FROM booking.BOOKING
        WHERE RoomId = @RoomId AND BookDate BETWEEN DATEADD(DAY, -1, @From) AND DATEADD(DAY, 1, @To)
          AND [Status] IN ('Pending','Confirmed')
          AND NOT ([Status] = 'Pending' AND HoldExpiresUtc IS NOT NULL AND HoldExpiresUtc < SYSUTCDATETIME())
        UNION ALL
        SELECT BlockDate, StartMin, EndMin FROM booking.BOOKING_BLOCK
        WHERE RoomId = @RoomId AND BlockDate BETWEEN DATEADD(DAY, -1, @From) AND DATEADD(DAY, 1, @To)),
    shifted AS (   /* SQL 89: every range in each open day's own minutes, the neighbouring dates' too */
        SELECT f.D, f.OpenMin, f.CloseMin,
               r.StartMin + 1440 * DATEDIFF(DAY, f.D, r.Dt) AS S,
               r.EndMin   + 1440 * DATEDIFF(DAY, f.D, r.Dt) AS E
        FROM frame f
        JOIN raw r ON r.Dt BETWEEN DATEADD(DAY, -1, f.D) AND DATEADD(DAY, 1, f.D)
        WHERE f.IsClosed = 0),
    taken AS (     /* ... cut to the day's open hours: what lies outside them takes nothing */
        SELECT D, CASE WHEN S < OpenMin THEN OpenMin ELSE S END AS StartMin,
                  CASE WHEN E > CloseMin THEN CloseMin ELSE E END AS EndMin
        FROM shifted
        WHERE S < CloseMin AND E > OpenMin),
    gaps AS (   /* free run before each taken range (running max handles overlaps) */
        SELECT t.D,
               t.StartMin - ISNULL(MAX(t.EndMin) OVER (PARTITION BY t.D ORDER BY t.StartMin, t.EndMin
                                        ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), f.OpenMin) AS Gap
        FROM taken t JOIN frame f ON f.D = t.D),
    tail AS (   /* free run after the last taken range */
        SELECT f.D, f.CloseMin - MAX(t.EndMin) AS Gap
        FROM frame f JOIN taken t ON t.D = f.D GROUP BY f.D, f.CloseMin)
    SELECT f.D AS OnDate, f.IsClosed,
           CASE WHEN f.IsClosed = 1 THEN 0 ELSE f.CloseMin - f.OpenMin END AS OpenMinutes,
           ISNULL(tk.TakenMinutes, 0) AS TakenMinutes,
           CASE WHEN f.IsClosed = 1 THEN 0
                WHEN tk.TakenMinutes IS NULL THEN f.CloseMin - f.OpenMin
                WHEN ISNULL(g1.G, 0) >= ISNULL(g2.G, 0) THEN ISNULL(g1.G, 0)
                ELSE ISNULL(g2.G, 0) END AS MaxFreeRun
    FROM frame f
    OUTER APPLY (SELECT SUM(EndMin - StartMin) AS TakenMinutes FROM taken t WHERE t.D = f.D) tk
    OUTER APPLY (SELECT MAX(CASE WHEN Gap < 0 THEN 0 ELSE Gap END) AS G FROM gaps WHERE gaps.D = f.D) g1
    OUTER APPLY (SELECT MAX(CASE WHEN Gap < 0 THEN 0 ELSE Gap END) AS G FROM tail WHERE tail.D = f.D) g2
    ORDER BY f.D
    OPTION (MAXRECURSION 40);
END;
GO

PRINT 'Script 89 applied.';
GO
