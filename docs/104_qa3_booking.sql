/* ============================================================================
   104_qa3_booking.sql - QA3 (deep test, 2026-10-19): room bookings and booking mail.

   THE FIXES, by QA3 id
     BKG-1  Anyone holding an MC- reference could CANCEL a step-1 website request: POST /{ref}/pay
            stamped a payment hold on it (usp_Booking_StartPayment looked only at Pending + Website),
            and POST /{ref}/release (or the reconciliation job, once the hold ran out) then cancelled
            it. Now:
              booking.BOOKING.OnlineDeposit  BIT, set by usp_Booking_Create when a WEBSITE booking is
                  taken while core.SETTING BookingDepositRequired is on ("deposit mode"). 0 = a request
                  staff confirm. One-time backfill when the column is added: website bookings already
                  in a payment flow, and (only if deposits are on today) the Pending website bookings.
              usp_Booking_StartPayment  refuses unless BookingDepositRequired is on AND the booking was
                  taken in deposit mode ('This booking is not waiting for a payment ...' = 409
                  not_pending), so a request can no longer be put on hold, released or expired.
     BKG-2  Blocks after midnight: NEW booking.usp_Block_Add (the API calls it instead of the base
            usp_Block_Create, whose body is not in the repo): an end at or before the start is the next
            morning (up to 06:00, EndMin <= 1800, the booking rule), and the "real bookings exist"
            check compares ABSOLUTE time across midnight (the day before and after, as SQL 89 does
            for bookings).
     BKG-3  usp_Booking_ConfirmOnlinePayment judged "somebody else holds the slot now" on the same
            DATE only, so a paid 00:00-01:00 booking (stored on the next date) was confirmed over a
            live 23:00-01:00 booking of the day before: a double booking. The clash test is now the
            SQL 89 one (neighbouring dates, minutes shifted by 1440 per day), bookings and blocks.
     BKG-4  usp_Booking_ListPaymentsToReconcile listed Pending bookings only: a deposit paid on the
            gateway while staff confirmed or cancelled the booking was never recorded. It now also
            lists bookings of ANY status whose payment was opened in the last 72 hours and carries no
            gateway line, re-checked at most hourly (the API records Paid for any status and
            releases or keeps a hold only on a Pending booking). The result shape is unchanged.
     BKG-5  usp_Booking_CancelByGuest compared the last 8 digits, which refuses the 7-digit Lebanese
            numbers ("+961 3 123 456" on file, "03 123 456" typed). NEW booking.fn_PhoneNational
            (digits, without 00 / +961 / the trunk 0): the national numbers must be equal (7 digits
            or more), or - as before - the last 8 digits. The booking row is now locked while it is
            judged and cancelled.
     BKG-7  NEW core.usp_Email_GetBookingSenders: the sender, SMTP account and template of the
            booking rows the e-mail worker has just claimed (core.usp_Email_GetPending is NOT
            redefined: the live one claims rows and the repo copy is older - CON-7).
     BKG-11 usp_Availability_GetDay / _GetMonth offered free time in a DEACTIVATED room (create then
            refused it): an inactive room is closed there now.
     BKG-13 usp_Booking_Validate measured "Bookings open up to N days ahead" on the booking's own
            date, so the 00:00 start of the last bookable night (sent as the NEXT date, SQL 89) was
            offered and then refused. A slot accepted through the previous date's window is now
            measured on that previous date.
     Settings: NEW booking.fn_SettingIsOn reads a switch in both dialects the Settings page writes
            ('1'/'0' and 'true'/'false', also yes/on); used for BookingDepositRequired and
            BookingAutoConfirm in the procedures below (the API reads BookingWebsiteEnabled and
            BookingDepositRequired the same way).

   Every procedure redefined here starts from its effective body - usp_Booking_Validate,
   usp_Booking_Create, usp_Availability_GetDay and _GetMonth from script 89; usp_Booking_StartPayment,
   usp_Booking_ConfirmOnlinePayment and usp_Booking_ListPaymentsToReconcile from 88;
   usp_Booking_CancelByGuest from 79 - and changes only what the fix needs. Result shapes and
   parameters are unchanged (INSERT ... EXEC callers keep working). Refusal sentences keep their
   opening words (the API's BookingRefusals reads them); their em dash is NCHAR(8212).

   Needs 79, 88 and 89. Pure ASCII; QUOTED_IDENTIFIER ON; re-runnable (CREATE OR ALTER, guarded
   ALTER TABLE). No data is changed except the one-time OnlineDeposit backfill above.
   Apply with: sqlcmd -S <server> -U <login> -C -I -b -d MokaCo_HRMS -i docs/104_qa3_booking.sql
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF OBJECT_ID('booking.fn_PhoneDigits') IS NULL
   OR COL_LENGTH('booking.BOOKING', 'PaymentOpenedUtc') IS NULL
   OR ISNULL(OBJECT_DEFINITION(OBJECT_ID('booking.usp_Booking_Validate')), N'') NOT LIKE N'%@PrevDow%'
   OR COL_LENGTH('core.EMAIL_OUTBOX', 'SmtpAccount') IS NULL
   OR COL_LENGTH('booking.BOOKING_BLOCK', 'EndMin') IS NULL
    RAISERROR('104_qa3_booking.sql needs scripts 79, 88 and 89 (and the booking tables of the base). Apply them first.', 16, 1);
GO

/* ---- 1. Helpers --------------------------------------------------------------------------- */

/* A switch in core.SETTING, ON in either dialect: '1' / 'true' / 'yes' / 'on' (any case, trimmed).
   The Settings page keeps the dialect a row already has and writes 'true'/'false' to a row that
   has none, so a reader that knows only '1' turns the switch off while the page shows it on.
   A missing row is OFF. */
CREATE OR ALTER FUNCTION booking.fn_SettingIsOn (@Key VARCHAR(100))
RETURNS BIT
AS
BEGIN
    DECLARE @v NVARCHAR(4000) = LOWER(LTRIM(RTRIM(ISNULL((SELECT TOP 1 SettingValue FROM core.SETTING WHERE SettingKey = @Key), N''))));
    RETURN CASE WHEN @v IN (N'1', N'true', N'yes', N'on') THEN 1 ELSE 0 END;
END;
GO

/* QA3 BKG-5. The NATIONAL number of a phone, as digits: the international prefix (00 or +) and
   Lebanon's 961 are dropped when what follows is a whole national number (7 or 8 digits), and so is
   the trunk 0. "+961 3 123 456", "00961 3 123 456", "03 123 456" and "3123456" are all 3123456;
   "+961 70 000 005" and "70 000 005" are 70000005. A number from elsewhere keeps its digits
   (less a leading 00 or trunk 0) and is matched by the last-8-digits rule of script 79. */
CREATE OR ALTER FUNCTION booking.fn_PhoneNational (@Phone VARCHAR(30))
RETURNS VARCHAR(30)
AS
BEGIN
    DECLARE @d VARCHAR(30) = booking.fn_PhoneDigits(@Phone);
    IF LEFT(@d, 2) = '00' SET @d = SUBSTRING(@d, 3, 30);
    IF LEFT(@d, 3) = '961' AND LEN(@d) - 3 IN (7, 8) SET @d = SUBSTRING(@d, 4, 30);
    IF LEFT(@d, 1) = '0' SET @d = SUBSTRING(@d, 2, 30);
    RETURN @d;
END;
GO

/* ---- 2. BKG-1: the deposit mode of a booking ------------------------------------------------ */
IF COL_LENGTH('booking.BOOKING', 'OnlineDeposit') IS NULL
BEGIN
    ALTER TABLE booking.BOOKING ADD OnlineDeposit BIT NOT NULL CONSTRAINT DF_BOOKING_OnlineDeposit DEFAULT (0);

    /* ONE-TIME BACKFILL, only on the run that adds the column (a later run must not turn step-1
       requests into deposit bookings): website bookings already in a payment flow, and - when
       online deposits are on today - the Pending website bookings, which were taken in that mode. */
    EXEC (N'UPDATE booking.BOOKING SET OnlineDeposit = 1
            WHERE [Source] = ''Website''
              AND (PaymentOpenedUtc IS NOT NULL
                   OR ([Status] = ''Pending'' AND booking.fn_SettingIsOn(''BookingDepositRequired'') = 1));
            PRINT CONCAT(''OnlineDeposit backfilled on '', @@ROWCOUNT, '' booking(s).'');');
END
GO

/* ---- 3. Shared validation (quote + create): SQL 89 + BKG-13 -------------------------------- */
/* Returns 0 when the slot is valid for the room; otherwise raises the message
   and returns 1 - callers MUST check the return code (RAISERROR does not stop
   the caller). Overlap is NOT checked here (create does it under lock). */
CREATE OR ALTER PROCEDURE booking.usp_Booking_Validate
    @RoomId INT OUTPUT, @RoomCode VARCHAR(30) = NULL,
    @BookDate DATE, @StartMin INT, @EndMin INT,
    @Persons INT = NULL, @Source VARCHAR(10) = 'Website',
    @Seats INT OUTPUT, @RoomName NVARCHAR(80) OUTPUT, @NowLocal DATETIME2(0) OUTPUT
AS BEGIN SET NOCOUNT ON;
    DECLARE @Msg NVARCHAR(300);
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
       midnight. A start after midnight arrives as the next date with startMin 0-1439, so it is
       judged in the previous date's minutes: start + 1440 and end + 1440 inside its window. */
    DECLARE @Dow TINYINT = ((DATEPART(WEEKDAY, @BookDate) + @@DATEFIRST - 2) % 7) + 1;
    DECLARE @PrevDow TINYINT = CASE WHEN @Dow = 1 THEN 7 ELSE @Dow - 1 END;
    DECLARE @OwnWindow BIT = CASE WHEN EXISTS (SELECT 1 FROM booking.ROOM_HOURS
                                               WHERE RoomId = @RoomId AND DayOfWeek = @Dow AND IsClosed = 0
                                                 AND OpenMin <= @StartMin AND CloseMin >= @EndMin) THEN 1 ELSE 0 END;
    IF @OwnWindow = 0
       AND NOT EXISTS (SELECT 1 FROM booking.ROOM_HOURS
                   WHERE RoomId = @RoomId AND DayOfWeek = @PrevDow AND IsClosed = 0
                     AND OpenMin <= @StartMin + 1440 AND CloseMin >= @EndMin + 1440)
    BEGIN
        SET @Msg = CONCAT(N'The room is closed at that time ', NCHAR(8212), N' pick a time inside its opening hours.');
        RAISERROR(@Msg,16,1); RETURN 1;
    END

    /* QA3 BKG-13: the night a slot belongs to. A slot accepted through the previous date's window
       (the 00:00 start of a night running past midnight) is that previous date's, so the booking
       window ("up to N days ahead") is measured on it. */
    DECLARE @WindowDate DATE = CASE WHEN @OwnWindow = 1 THEN @BookDate ELSE DATEADD(DAY, -1, @BookDate) END;

    SET @NowLocal = booking.fn_LocalNow();
    DECLARE @StartDt DATETIME2(0) = DATEADD(MINUTE, @StartMin, CAST(@BookDate AS DATETIME2(0)));
    DECLARE @EndDt   DATETIME2(0) = DATEADD(MINUTE, @EndMin,   CAST(@BookDate AS DATETIME2(0)));
    IF @Source = 'Website'
    BEGIN
        DECLARE @LeadMaxD INT = ISNULL(TRY_CAST((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'BookingLeadMaxDays') AS INT), 30);
        DECLARE @LeadMinH INT = ISNULL(TRY_CAST((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'BookingLeadMinHours') AS INT), 0);
        IF @WindowDate > DATEADD(DAY, @LeadMaxD, CAST(@NowLocal AS DATE))
        BEGIN RAISERROR('Bookings open up to %d days ahead.',16,1,@LeadMaxD); RETURN 1; END
        IF @StartDt < DATEADD(HOUR, @LeadMinH, @NowLocal)
        BEGIN
            SET @Msg = CONCAT(N'Online booking closes %d hour(s) before the start ', NCHAR(8212), N' call us instead.');
            RAISERROR(@Msg,16,1,@LeadMinH); RETURN 1;
        END
    END
    ELSE IF @EndDt < @NowLocal
    BEGIN RAISERROR('That time is already in the past.',16,1); RETURN 1; END

    RETURN 0;
END;
GO

/* ---- 4. Create: SQL 89 + BKG-1 (the deposit mode is stamped on the row) -------------------- */
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

    /* QA3: both switches read in either dialect ('1'/'true'). */
    DECLARE @AutoConfirm BIT = booking.fn_SettingIsOn('BookingAutoConfirm');
    DECLARE @Status VARCHAR(12) =
        CASE WHEN @Source = 'Manual' OR @AutoConfirm = 1 THEN 'Confirmed' ELSE 'Pending' END;

    /* QA3 BKG-1: a website booking taken while online deposits are on is a DEPOSIT booking - the only
       kind usp_Booking_StartPayment will open a payment (and so a hold) on. */
    DECLARE @OnlineDeposit BIT = CASE WHEN @Source = 'Website' AND booking.fn_SettingIsOn('BookingDepositRequired') = 1
                                      THEN 1 ELSE 0 END;

    /* Overlap in ABSOLUTE time (SQL 89): the day before can run past midnight into this date
       (23:00-01:00 is 1380-1500 on its own date), and this booking can run into the next date's first
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
    BEGIN
        ROLLBACK;
        DECLARE @Taken NVARCHAR(200) = CONCAT(N'That time was just taken ', NCHAR(8212), N' pick another slot.');
        RAISERROR(@Taken,16,1); RETURN;
    END

    DECLARE @Ref VARCHAR(12);
    WHILE 1 = 1
    BEGIN
        SET @Ref = 'MC-' + UPPER(LEFT(REPLACE(CONVERT(VARCHAR(36), NEWID()), '-', ''), 8));
        IF NOT EXISTS (SELECT 1 FROM booking.BOOKING WHERE BookingRef = @Ref) BREAK;
    END

    INSERT INTO booking.BOOKING (RoomId, BookDate, StartTime, EndTime, Persons, GuestName, GuestPhone,
        GuestEmail, Note, TotalAmount, DepositDue, DepositPercent, CurrencyCode, [Status], [Source],
        CreatedByUserId, BookingRef, DiscountPercent, DiscountAmount, OnlineDeposit)
    VALUES (@RoomId, @BookDate, @StartTime, @EndTime, @Persons, LTRIM(RTRIM(@GuestName)),
        LTRIM(RTRIM(@GuestPhone)), NULLIF(LTRIM(RTRIM(@GuestEmail)), N''), @Note,
        @Total, @Deposit, @Pct, @Ccy, @Status, @Source, @CreatedByUserId, @Ref, @DiscPct, @DiscAmt, @OnlineDeposit);
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

/* ---- 5. Availability: SQL 89 + BKG-11 (an inactive room is closed) ------------------------- */
CREATE OR ALTER PROCEDURE booking.usp_Availability_GetDay
    @RoomId INT = NULL, @RoomCode VARCHAR(30) = NULL, @OnDate DATE
AS BEGIN SET NOCOUNT ON;
    IF @RoomId IS NULL SELECT @RoomId = RoomId FROM booking.ROOM WHERE Code = @RoomCode;
    DECLARE @Dow TINYINT = ((DATEPART(WEEKDAY, @OnDate) + @@DATEFIRST - 2) % 7) + 1;
    DECLARE @OpenMin INT, @CloseMin INT;      /* NULL when the date is closed, or the room is retired (QA3 BKG-11) */
    SELECT @OpenMin = h.OpenMin, @CloseMin = h.CloseMin
    FROM booking.ROOM_HOURS h JOIN booking.ROOM r ON r.RoomId = h.RoomId
    WHERE h.RoomId = @RoomId AND h.DayOfWeek = @Dow AND h.IsClosed = 0 AND r.IsActive = 1;

    /* 1: the day's frame + the rules the site needs to paint it */
    SELECT r.RoomId, r.Code AS RoomCode, @OnDate AS OnDate,
           CAST(CASE WHEN r.IsActive = 0 THEN 1 ELSE ISNULL(h.IsClosed, 1) END AS BIT) AS IsClosed, h.OpenMin, h.CloseMin,
           ISNULL(TRY_CAST((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'BookingSlotMinutes') AS INT), 60) AS SlotMinutes,
           ISNULL(r.MinHours, TRY_CAST((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'BookingMinHours') AS INT)) AS MinHours,
           ISNULL(r.MaxHours, TRY_CAST((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'BookingMaxHours') AS INT)) AS MaxHours,
           ISNULL(TRY_CAST((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'BookingLeadMinHours') AS INT), 0) AS LeadMinHours,
           ISNULL(TRY_CAST((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'BookingLeadMaxDays') AS INT), 30) AS LeadMaxDays,
           booking.fn_LocalNow() AS LocalNow
    FROM booking.ROOM r
    LEFT JOIN booking.ROOM_HOURS h ON h.RoomId = r.RoomId AND h.DayOfWeek = @Dow
    WHERE r.RoomId = @RoomId;

    /* 2: taken ranges - bookings and blocks look the same to the website. The date's own ranges as
       they are; and (SQL 89) the previous and next dates' ranges that fall inside this date's open
       hours, in this date's minutes and cut to those hours - a window running past midnight shows
       the next date's 00:00-01:00 booking as 1440-1500. */
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

/* Per day of the month: open minutes, taken minutes and the longest free run -
   the site colours the calendar (closed / full / partial / open). */
CREATE OR ALTER PROCEDURE booking.usp_Availability_GetMonth
    @RoomId INT = NULL, @RoomCode VARCHAR(30) = NULL, @MonthDate DATE
AS BEGIN SET NOCOUNT ON;
    IF @RoomId IS NULL SELECT @RoomId = RoomId FROM booking.ROOM WHERE Code = @RoomCode;
    DECLARE @From DATE = DATEFROMPARTS(YEAR(@MonthDate), MONTH(@MonthDate), 1);
    DECLARE @To   DATE = EOMONTH(@From);
    /* QA3 BKG-11: a retired room (or an unknown one) is closed on every day. */
    DECLARE @Active BIT = ISNULL((SELECT IsActive FROM booking.ROOM WHERE RoomId = @RoomId), 0);

    ;WITH days AS (
        SELECT @From AS D UNION ALL SELECT DATEADD(DAY, 1, D) FROM days WHERE D < @To),
    frame AS (
        SELECT d.D, CASE WHEN @Active = 0 THEN CAST(1 AS BIT) ELSE ISNULL(h.IsClosed, 1) END AS IsClosed,
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

/* ---- 6. Start a payment: SQL 88 + BKG-1 ---------------------------------------------------
   Only a Pending WEBSITE booking taken in DEPOSIT MODE (OnlineDeposit = 1) while online deposits are
   still on (BookingDepositRequired), whose hold has not run out. Stamps HoldExpiresUtc = now +
   BookingHoldMinutes and PaymentOpenedUtc = now, and sets the gateway order id to the reference.
   Calling it again for the same reference is allowed (a new checkout session on the SAME order):
   the hold is re-stamped. THE AMOUNT IS THE ROW'S DepositDue; the caller never supplies it. */
CREATE OR ALTER PROCEDURE booking.usp_Booking_StartPayment
    @Ref VARCHAR(12)
AS BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @Hold INT = ISNULL(TRY_CAST((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'BookingHoldMinutes') AS INT), 15);
    IF @Hold < 1 SET @Hold = 15;
    DECLARE @DepositsOn BIT = booking.fn_SettingIsOn('BookingDepositRequired');

    DECLARE @Bid INT, @Status VARCHAR(12), @Source VARCHAR(10), @Expires DATETIME2, @Deposit DECIMAL(10,2),
            @Previous DATETIME2, @Online BIT, @Now DATETIME2 = SYSUTCDATETIME(), @Err NVARCHAR(200);

    /* A refusal COMMITS (nothing was written) and raises after: a ROLLBACK here would also roll back
       a caller's own transaction (the QA case and the DB tests run inside one). */
    BEGIN TRAN;
    SELECT @Bid = BookingId, @Status = [Status], @Source = [Source], @Expires = HoldExpiresUtc,
           @Deposit = DepositDue, @Previous = PaymentOpenedUtc, @Online = OnlineDeposit
    FROM booking.BOOKING WITH (UPDLOCK, HOLDLOCK)
    WHERE BookingRef = @Ref;

    SET @Err = CASE
        WHEN @Bid IS NULL THEN N'Booking not found.'
        WHEN EXISTS (SELECT 1 FROM booking.BOOKING_PAYMENT WHERE BookingId = @Bid AND GatewayOrderId IS NOT NULL AND IsRefund = 0)
             THEN N'This booking has already been paid.'
        WHEN @Status <> 'Pending' OR @Source <> 'Website'
             THEN CONCAT(N'This booking is not waiting for a payment (it is ', @Status, N').')
        /* QA3 BKG-1: a request staff confirm (taken without an online deposit) is never paid, held or
           released through the website. */
        WHEN @DepositsOn = 0 OR ISNULL(@Online, 0) = 0
             THEN N'This booking is not waiting for a payment (it is a request our staff will confirm).'
        WHEN @Expires IS NOT NULL AND @Expires < @Now THEN N'The payment hold has expired. Please choose the slot again.'
        WHEN ISNULL(@Deposit, 0) <= 0 THEN N'There is no deposit to pay on this booking.'
    END;

    IF @Err IS NULL
        UPDATE booking.BOOKING
        SET HoldExpiresUtc = DATEADD(MINUTE, @Hold, @Now),
            PaymentOpenedUtc = @Now,
            PaymentCheckedUtc = NULL,
            GatewayOrderId = @Ref
        WHERE BookingId = @Bid;
    COMMIT;

    IF @Err IS NOT NULL BEGIN RAISERROR(@Err, 16, 1); RETURN 1; END

    SELECT b.BookingId, b.BookingRef, b.DepositDue, b.CurrencyCode, b.TotalAmount,
           b.BookDate, b.StartMin, b.EndMin, b.Hours, r.[Name] AS RoomName,
           b.HoldExpiresUtc, b.PaymentOpenedUtc, @Previous AS PreviousOpenedUtc
    FROM booking.BOOKING b JOIN booking.ROOM r ON r.RoomId = b.RoomId
    WHERE b.BookingId = @Bid;
END;
GO

/* ---- 7. Record the deposit and confirm: SQL 88 + BKG-3 ------------------------------------
   IDEMPOTENT, ONE transaction; outcomes Confirmed / Recorded / Replay / PaidButClosed / SlotClash as
   in script 88. QA3 BKG-3: "another live booking or a block now covers the slot" is judged in
   ABSOLUTE time - the neighbouring dates' rows with their minutes shifted by 1440 per day, exactly
   as usp_Booking_Create judges an overlap (SQL 89) - so a paid Tuesday 00:00-01:00 is a SlotClash
   when Monday 23:00-01:00 is live. */
CREATE OR ALTER PROCEDURE booking.usp_Booking_ConfirmOnlinePayment
    @Ref VARCHAR(12), @Amount DECIMAL(10,2), @CurrencyCode CHAR(3),
    @GatewayOrderId VARCHAR(40), @TransactionId VARCHAR(60) = NULL,
    @MethodName NVARCHAR(80) = N'Card (MPGS)'
AS BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    IF @Amount IS NULL OR @Amount <= 0 BEGIN RAISERROR('The paid amount must be more than 0.',16,1); RETURN 1; END
    IF LTRIM(RTRIM(ISNULL(@GatewayOrderId, ''))) = '' BEGIN RAISERROR('The gateway order id is required.',16,1); RETURN 1; END

    DECLARE @Bid INT, @Status VARCHAR(12), @Room INT, @Date DATE, @StartMin INT, @EndMin INT,
            @Outcome VARCHAR(20), @Now DATETIME2 = SYSUTCDATETIME();

    BEGIN TRAN;
    SELECT @Bid = BookingId, @Status = [Status], @Room = RoomId, @Date = BookDate, @StartMin = StartMin, @EndMin = EndMin
    FROM booking.BOOKING WITH (UPDLOCK, HOLDLOCK)
    WHERE BookingRef = @Ref;
    IF @Bid IS NULL BEGIN COMMIT; RAISERROR('Booking not found.',16,1); RETURN 1; END   -- nothing written; see StartPayment

    IF EXISTS (SELECT 1 FROM booking.BOOKING_PAYMENT WITH (UPDLOCK, HOLDLOCK)
               WHERE GatewayOrderId = @GatewayOrderId AND IsRefund = 0)
        SET @Outcome = 'Replay';
    ELSE
    BEGIN
        DECLARE @Mid INT = (SELECT TOP 1 PaymentMethodId FROM booking.PAYMENT_METHOD
                            WHERE [Name] = @MethodName ORDER BY IsActive DESC, PaymentMethodId);
        IF @Mid IS NULL
        BEGIN
            INSERT INTO booking.PAYMENT_METHOD ([Name], IsOnline, IsActive) VALUES (@MethodName, 1, 1);
            SET @Mid = SCOPE_IDENTITY();
        END

        INSERT INTO booking.BOOKING_PAYMENT (BookingId, PaymentMethodId, Amount, Reference, ReceivedByUserId,
                                             IsRefund, GatewayOrderId, GatewayTransactionId, CurrencyCode)
        VALUES (@Bid, @Mid, @Amount, LEFT(CONCAT(N'MPGS ', @GatewayOrderId, N' / ', ISNULL(@TransactionId, N'?')), 80), NULL,
                0, @GatewayOrderId, @TransactionId, @CurrencyCode);

        IF @Status = 'Pending'
        BEGIN
            IF EXISTS (SELECT 1 FROM booking.BOOKING
                       WHERE RoomId = @Room AND BookingId <> @Bid
                         AND BookDate BETWEEN DATEADD(DAY, -1, @Date) AND DATEADD(DAY, 1, @Date)
                         AND [Status] IN ('Pending','Confirmed')
                         AND NOT ([Status] = 'Pending' AND HoldExpiresUtc IS NOT NULL AND HoldExpiresUtc < @Now)
                         AND StartMin + 1440 * DATEDIFF(DAY, @Date, BookDate) < @EndMin
                         AND EndMin   + 1440 * DATEDIFF(DAY, @Date, BookDate) > @StartMin)
               OR EXISTS (SELECT 1 FROM booking.BOOKING_BLOCK
                          WHERE RoomId = @Room
                            AND BlockDate BETWEEN DATEADD(DAY, -1, @Date) AND DATEADD(DAY, 1, @Date)
                            AND StartMin + 1440 * DATEDIFF(DAY, @Date, BlockDate) < @EndMin
                            AND EndMin   + 1440 * DATEDIFF(DAY, @Date, BlockDate) > @StartMin)
            BEGIN
                UPDATE booking.BOOKING
                SET HoldExpiresUtc = NULL, PaidConfirmedUtc = ISNULL(PaidConfirmedUtc, @Now), PaymentCheckedUtc = @Now
                WHERE BookingId = @Bid;
                SET @Outcome = 'SlotClash';
            END
            ELSE
            BEGIN
                UPDATE booking.BOOKING
                SET [Status] = 'Confirmed', DecidedUtc = @Now, HoldExpiresUtc = NULL,
                    PaidConfirmedUtc = ISNULL(PaidConfirmedUtc, @Now), PaymentCheckedUtc = @Now
                WHERE BookingId = @Bid;
                SET @Outcome = 'Confirmed';
            END
        END
        ELSE IF @Status IN ('Cancelled','NoShow')
        BEGIN
            DECLARE @Due DECIMAL(10,2) = booking.fn_RefundDue(@Bid, 'Staff');   -- everything paid, net of refunds
            UPDATE booking.BOOKING
            SET RefundAmount = @Due, RefundStatus = CASE WHEN @Due > 0 THEN 'Due' ELSE RefundStatus END,
                PaidConfirmedUtc = ISNULL(PaidConfirmedUtc, @Now), PaymentCheckedUtc = @Now, HoldExpiresUtc = NULL
            WHERE BookingId = @Bid;
            SET @Outcome = 'PaidButClosed';
        END
        ELSE
        BEGIN
            UPDATE booking.BOOKING
            SET PaidConfirmedUtc = ISNULL(PaidConfirmedUtc, @Now), PaymentCheckedUtc = @Now, HoldExpiresUtc = NULL
            WHERE BookingId = @Bid;
            SET @Outcome = 'Recorded';
        END

        DECLARE @Detail NVARCHAR(400) = CONCAT(N'Captured ', @CurrencyCode, N' ', CONVERT(varchar(20), @Amount),
                                               N', gateway transaction ', ISNULL(@TransactionId, N'?'), N'.');
        DECLARE @Kind VARCHAR(20) = CASE @Outcome WHEN 'PaidButClosed' THEN 'PayAfterCancel'
                                                  WHEN 'SlotClash'     THEN 'PaySlotClash'
                                                  ELSE 'PayReceived' END;
        EXEC booking.usp_Booking_QueuePaymentAlert @Bid, @Kind, @Detail, @Quiet = 1;
    END
    COMMIT;

    SELECT @Outcome AS Outcome, b.BookingId, b.BookingRef, b.[Status],
           ISNULL(p.Paid, 0) AS PaidAmount, b.TotalAmount - ISNULL(p.Paid, 0) AS BalanceDue
    FROM booking.BOOKING b
    OUTER APPLY (SELECT SUM(Amount) AS Paid FROM booking.BOOKING_PAYMENT WHERE BookingId = b.BookingId) p
    WHERE b.BookingId = @Bid;
END;
GO

/* ---- 8. The reconciliation job's work list: SQL 88 + BKG-4 --------------------------------
   Bookings whose payment was opened at least @OpenedMinutesAgo minutes ago and that carry no gateway
   payment line yet:
     Pending  - every run, as before (the job settles them: paid, released or kept);
     any other status (staff confirmed, cancelled or marked a no-show while the guest was paying) -
              for 72 hours after the payment was opened, re-checked at most once an hour, so that a
              deposit captured on the gateway is still recorded (and a cancelled one marked Refund
              Due) instead of being lost.
   The result shape is unchanged. UnconfirmedAlerted says whether staff were already told. */
CREATE OR ALTER PROCEDURE booking.usp_Booking_ListPaymentsToReconcile
    @OpenedMinutesAgo INT = 10
AS BEGIN SET NOCOUNT ON;
    DECLARE @Now DATETIME2 = SYSUTCDATETIME();
    SELECT b.BookingId, b.BookingRef, b.DepositDue, b.CurrencyCode, b.PaymentOpenedUtc, b.PaymentCheckedUtc, b.HoldExpiresUtc,
           CAST(CASE WHEN EXISTS (SELECT 1 FROM core.EMAIL_OUTBOX o
                                  WHERE o.BookingId = b.BookingId AND o.MailKind = 'PayUnconfirmed' AND o.Channel = 'Email')
                     THEN 1 ELSE 0 END AS BIT) AS UnconfirmedAlerted
    FROM booking.BOOKING b
    WHERE b.PaymentOpenedUtc IS NOT NULL
      AND b.PaymentOpenedUtc <= DATEADD(MINUTE, -@OpenedMinutesAgo, @Now)
      AND NOT EXISTS (SELECT 1 FROM booking.BOOKING_PAYMENT p
                      WHERE p.BookingId = b.BookingId AND p.GatewayOrderId IS NOT NULL AND p.IsRefund = 0)
      AND (b.[Status] = 'Pending'
           OR (b.PaymentOpenedUtc >= DATEADD(HOUR, -72, @Now)
               AND (b.PaymentCheckedUtc IS NULL OR b.PaymentCheckedUtc <= DATEADD(MINUTE, -60, @Now))))
    ORDER BY b.PaymentOpenedUtc;
END;
GO

/* ---- 9. The guest cancels online: SQL 79 + BKG-5 -------------------------------------------
   The phone given must be the booking's: the same NATIONAL number (booking.fn_PhoneNational, 7 digits
   or more), or - as in script 79 - the same last 8 digits. Everything else is 79's: only a Pending or
   Confirmed booking, only outside BookingCancelHours of the start, always CancelledBy = 'Guest'. The
   row is locked while it is judged and changed (a staff decision or a payment cannot slip in
   between); a refusal commits nothing and raises after, as usp_Booking_StartPayment does. */
CREATE OR ALTER PROCEDURE booking.usp_Booking_CancelByGuest
    @Ref VARCHAR(12),
    @Phone VARCHAR(30) = NULL        -- the number the guest typed; must be the booking's
AS BEGIN SET NOCOUNT ON;             -- XACT_ABORT is the caller's, as in 79 (a refusal must not doom its transaction)
    DECLARE @Bid INT, @Status VARCHAR(12), @Date DATE, @StartMin INT, @Stored VARCHAR(30), @Err NVARCHAR(300);
    DECLARE @Hours INT = ISNULL(TRY_CAST((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'BookingCancelHours') AS INT), 24);

    BEGIN TRAN;
    SELECT @Bid = BookingId, @Status = [Status], @Date = BookDate, @StartMin = StartMin, @Stored = GuestPhone
    FROM booking.BOOKING WITH (UPDLOCK, HOLDLOCK) WHERE BookingRef = @Ref;

    DECLARE @givenDigits VARCHAR(30) = booking.fn_PhoneDigits(@Phone), @keptDigits VARCHAR(30) = booking.fn_PhoneDigits(@Stored);
    DECLARE @given VARCHAR(30) = booking.fn_PhoneNational(@Phone), @kept VARCHAR(30) = booking.fn_PhoneNational(@Stored);
    DECLARE @Match BIT = CASE
        WHEN LEN(@given) >= 7 AND @given = @kept THEN 1
        WHEN LEN(@givenDigits) >= 8 AND LEN(@keptDigits) >= 8 AND RIGHT(@givenDigits, 8) = RIGHT(@keptDigits, 8) THEN 1
        ELSE 0 END;
    DECLARE @StartDt DATETIME2(0) = DATEADD(MINUTE, @StartMin, CAST(@Date AS DATETIME2(0)));

    SET @Err = CASE
        WHEN @Bid IS NULL THEN N'Booking not found.'
        WHEN @Match = 0 THEN N'The phone number does not match this booking.'
        WHEN @Status NOT IN ('Pending','Confirmed') THEN N'This booking can no longer be cancelled online.'
        WHEN @StartDt < DATEADD(HOUR, @Hours, booking.fn_LocalNow())
             THEN CONCAT(N'Online cancellation closes ', @Hours, N' hours before the start ', NCHAR(8212), N' please call us.')
    END;

    IF @Err IS NULL
    BEGIN
        DECLARE @Refund DECIMAL(10,2) = booking.fn_RefundDue(@Bid, 'Guest');
        UPDATE booking.BOOKING
        SET [Status] = 'Cancelled', DecidedUtc = SYSUTCDATETIME(),
            CancelReason = N'Cancelled by the guest online.', CancelledBy = 'Guest',
            RefundAmount = @Refund, RefundStatus = CASE WHEN @Refund > 0 THEN 'Due' ELSE 'None' END,
            HoldExpiresUtc = NULL
        WHERE BookingId = @Bid;
    END
    COMMIT;

    IF @Err IS NOT NULL BEGIN RAISERROR(@Err, 16, 1); RETURN 1; END
    EXEC booking.usp_Booking_GetByRef @Ref;
END;
GO

/* ---- 10. BKG-2: a block, after midnight too ------------------------------------------------
   Holds a room back (maintenance, a private event). Called by the API instead of the base
   usp_Block_Create, which stays in place unused. Times follow the booking rule: an end at or before
   the start is the NEXT morning, up to 06:00 (EndMin <= 1800); an end equal to the start is refused.
   A block may not be laid over a LIVE booking (Pending with a running or no hold, or Confirmed),
   compared in ABSOLUTE time: the day before and after, minutes shifted by 1440 per day (SQL 89).
   Answers BlockId. */
CREATE OR ALTER PROCEDURE booking.usp_Block_Add
    @RoomId INT, @BlockDate DATE, @StartTime TIME(0), @EndTime TIME(0),
    @Reason NVARCHAR(200) = NULL, @CreatedByUserId INT = NULL
AS BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    IF NOT EXISTS (SELECT 1 FROM booking.ROOM WHERE RoomId = @RoomId)
    BEGIN RAISERROR('Room not found.',16,1); RETURN 1; END
    IF @BlockDate IS NULL OR @StartTime IS NULL OR @EndTime IS NULL
    BEGIN RAISERROR('Choose the date and the start and end times.',16,1); RETURN 1; END
    IF @EndTime = @StartTime
    BEGIN RAISERROR('The end time must be after the start time.',16,1); RETURN 1; END

    DECLARE @StartMin INT = DATEPART(HOUR, @StartTime) * 60 + DATEPART(MINUTE, @StartTime);
    DECLARE @EndMin   INT = CASE WHEN @EndTime <= @StartTime THEN 1440 ELSE 0 END
                          + DATEPART(HOUR, @EndTime) * 60 + DATEPART(MINUTE, @EndTime);
    IF @EndMin > 1800
    BEGIN RAISERROR('The end time must be after the start time (an end up to 06:00 is read as the next morning).',16,1); RETURN 1; END

    BEGIN TRAN;
    IF EXISTS (SELECT 1 FROM booking.BOOKING WITH (UPDLOCK, HOLDLOCK)
               WHERE RoomId = @RoomId
                 AND BookDate BETWEEN DATEADD(DAY, -1, @BlockDate) AND DATEADD(DAY, 1, @BlockDate)
                 AND [Status] IN ('Pending','Confirmed')
                 AND NOT ([Status] = 'Pending' AND HoldExpiresUtc IS NOT NULL AND HoldExpiresUtc < SYSUTCDATETIME())
                 AND StartMin + 1440 * DATEDIFF(DAY, @BlockDate, BookDate) < @EndMin
                 AND EndMin   + 1440 * DATEDIFF(DAY, @BlockDate, BookDate) > @StartMin)
    BEGIN
        ROLLBACK;
        DECLARE @Live NVARCHAR(200) = CONCAT(N'Real bookings exist in that period ', NCHAR(8212), N' cancel or move them first.');
        RAISERROR(@Live,16,1); RETURN 1;
    END

    INSERT INTO booking.BOOKING_BLOCK (RoomId, BlockDate, StartTime, EndTime, Reason, CreatedByUserId)
    VALUES (@RoomId, @BlockDate, @StartTime, @EndTime, NULLIF(LTRIM(RTRIM(@Reason)), N''), @CreatedByUserId);
    DECLARE @BlockId INT = SCOPE_IDENTITY();

    /* The table computes EndMin itself; a definition without the next-day rule would store a block
       that ends before it starts. Refuse rather than store it. */
    IF (SELECT EndMin FROM booking.BOOKING_BLOCK WHERE BlockId = @BlockId) <> @EndMin
    BEGIN
        ROLLBACK;
        RAISERROR('This database cannot store a block past midnight: block up to 00:00, then the next day from 00:00.',16,1);
        RETURN 1;
    END
    COMMIT;

    SELECT @BlockId AS BlockId;
    RETURN 0;
END;
GO

/* ---- 11. BKG-7: the sender of the booking mail the worker has claimed ----------------------
   core.usp_Email_GetPending claims the rows and answers the common columns only (it is NOT redefined
   here: the live one claims rows, the repo copy is older). For the ids it handed out, this answers
   the booking rows' own sender (FromEmail, FromName), SMTP account ('Booking' = the bookings
   mailbox) and WhatsApp template, as trg_Booking_Notify and usp_Booking_QueuePaymentAlert wrote
   them. @EmailIds is a comma-separated list. Rows that are not booking mail are not returned.
   The Template column is read only where the table has one (dynamic SQL for that reason). */
CREATE OR ALTER PROCEDURE core.usp_Email_GetBookingSenders
    @EmailIds VARCHAR(MAX)
AS BEGIN SET NOCOUNT ON;
    DECLARE @sql NVARCHAR(MAX) = N'
SELECT o.EmailId, o.BookingId, o.MailKind, o.FromEmail, o.FromName, o.SmtpAccount, '
        + CASE WHEN COL_LENGTH('core.EMAIL_OUTBOX', 'Template') IS NULL
               THEN N'CAST(NULL AS VARCHAR(60))' ELSE N'CAST(o.Template AS VARCHAR(60))' END + N' AS Template
FROM core.EMAIL_OUTBOX o
WHERE o.EmailId IN (SELECT TRY_CAST(LTRIM(RTRIM(value)) AS INT) FROM STRING_SPLIT(@Ids, '',''))
  AND (o.BookingId IS NOT NULL OR o.MailKind IS NOT NULL OR o.SmtpAccount IS NOT NULL)
ORDER BY o.EmailId;';
    EXEC sys.sp_executesql @sql, N'@Ids VARCHAR(MAX)', @Ids = @EmailIds;
END;
GO

PRINT 'QA3 booking (104): deposit mode, after-midnight blocks and clashes, reconciliation, guest phone, booking senders, availability and lead window in place';
GO
