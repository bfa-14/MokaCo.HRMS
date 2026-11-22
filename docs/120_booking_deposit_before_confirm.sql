/* ============================================================================
   120_booking_deposit_before_confirm.sql - a website booking that must be paid online is confirmed by its
   payment, never by "auto-confirm" (22 Nov 2026).

   THE FAULT. usp_Booking_Create wrote a website booking as Confirmed whenever core.SETTING BookingAutoConfirm
   was on - also while online deposits were on (BookingDepositRequired). Such a booking was Confirmed before the
   guest saw a payment page; POST /{ref}/pay then refused it ("This booking is not waiting for a payment (it is
   Confirmed)", 409), so the guest could not pay even if they wanted to, the website said the payment had failed,
   and the room stayed booked with nothing paid and nothing on the Payments page.

   THE RULE NOW, in one function (booking.fn_NewBookingStatus):
       staff booking (Source 'Manual')                       -> Confirmed, as before
       website booking that must pay a deposit online        -> Pending: usp_Booking_ConfirmOnlinePayment
                                                                confirms it when the money is captured
       any other website booking                             -> Confirmed when BookingAutoConfirm is on,
                                                                else Pending (a request staff confirm), as before
   "Must pay a deposit online" = taken while BookingDepositRequired is on (the row's OnlineDeposit, QA3 BKG-1)
   and its deposit is more than 0. A booking with nothing to pay keeps the auto-confirm rule.

   usp_Booking_Create is redefined from its effective body (script 104) with that one change; parameters and
   result shape are unchanged. Bookings already made are not touched: a website booking confirmed without its
   deposit before this script stays Confirmed (staff settle those; the list is printed at the end).

   Needs 104. Pure ASCII; QUOTED_IDENTIFIER ON; re-runnable (CREATE OR ALTER).
   Apply with: sqlcmd -S <server> -U <login> -C -I -b -d MokaCo_HRMS -i docs/120_booking_deposit_before_confirm.sql
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* The procedure this script redefines must be script 104's (or already this script's): production carries
   procedures the repo never had, and a newer live version must not be overwritten blindly. */
DECLARE @def NVARCHAR(MAX) = ISNULL(OBJECT_DEFINITION(OBJECT_ID('booking.usp_Booking_Create')), N'');
IF OBJECT_ID('booking.fn_SettingIsOn') IS NULL OR COL_LENGTH('booking.BOOKING', 'OnlineDeposit') IS NULL
    RAISERROR('120_booking_deposit_before_confirm.sql needs script 104. Apply it first.', 16, 1);
ELSE IF @def NOT LIKE N'%fn_NewBookingStatus%'
        AND (@def NOT LIKE N'%@OnlineDeposit%' OR @def NOT LIKE N'%fn_SettingIsOn(''BookingAutoConfirm'')%' OR @def NOT LIKE N'%fn_PriceQuote%')
    RAISERROR('120: booking.usp_Booking_Create in this database is not the version of script 104. Nothing was changed; tell the developer.', 16, 1);
GO

/* ---- 1. The status a new booking starts in ------------------------------------------------ */
CREATE OR ALTER FUNCTION booking.fn_NewBookingStatus
    (@Source VARCHAR(10), @OnlineDeposit BIT, @Deposit DECIMAL(10,2), @AutoConfirm BIT)
RETURNS VARCHAR(12)
AS
BEGIN
    /* script 120 */
    RETURN CASE WHEN @Source = 'Manual' THEN 'Confirmed'
                WHEN ISNULL(@OnlineDeposit, 0) = 1 AND ISNULL(@Deposit, 0) > 0 THEN 'Pending'
                WHEN ISNULL(@AutoConfirm, 0) = 1 THEN 'Confirmed'
                ELSE 'Pending' END;
END;
GO

/* ---- 2. Create: script 104's body, the status from the function above ----------------------- */
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

    /* QA3 BKG-1: a website booking taken while online deposits are on is a DEPOSIT booking - the only
       kind usp_Booking_StartPayment will open a payment (and so a hold) on. */
    DECLARE @OnlineDeposit BIT = CASE WHEN @Source = 'Website' AND booking.fn_SettingIsOn('BookingDepositRequired') = 1
                                      THEN 1 ELSE 0 END;

    /* script 120: the status a booking starts in, decided in ONE place (booking.fn_NewBookingStatus). A deposit
       booking starts Pending whatever BookingAutoConfirm says: its payment is what confirms it. Both switches
       are read in either dialect ('1'/'true'). */
    DECLARE @AutoConfirm BIT = booking.fn_SettingIsOn('BookingAutoConfirm');
    DECLARE @Status VARCHAR(12) = booking.fn_NewBookingStatus(@Source, @OnlineDeposit, @Deposit, @AutoConfirm);

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

/* ---- 3. For the owner: what the old rule left behind --------------------------------------- */
DECLARE @n INT = (SELECT COUNT(*) FROM booking.BOOKING b
                  WHERE b.[Source] = 'Website' AND b.[Status] = 'Confirmed' AND b.OnlineDeposit = 1 AND b.DepositDue > 0
                    AND b.BookDate >= CAST(DATEADD(DAY, -1, SYSUTCDATETIME()) AS DATE)
                    AND NOT EXISTS (SELECT 1 FROM booking.BOOKING_PAYMENT p WHERE p.BookingId = b.BookingId AND p.IsRefund = 0));
DECLARE @refs NVARCHAR(MAX) = (SELECT STRING_AGG(CAST(x.BookingRef AS NVARCHAR(MAX)), N', ')
                               FROM (SELECT TOP 30 b.BookingRef FROM booking.BOOKING b
                                     WHERE b.[Source] = 'Website' AND b.[Status] = 'Confirmed' AND b.OnlineDeposit = 1 AND b.DepositDue > 0
                                       AND b.BookDate >= CAST(DATEADD(DAY, -1, SYSUTCDATETIME()) AS DATE)
                                       AND NOT EXISTS (SELECT 1 FROM booking.BOOKING_PAYMENT p WHERE p.BookingId = b.BookingId AND p.IsRefund = 0)
                                     ORDER BY b.BookDate, b.BookingId) x);
PRINT CONCAT(N'OWNER CHECK (120): auto-confirm (BookingAutoConfirm) is ', IIF(booking.fn_SettingIsOn('BookingAutoConfirm') = 1, N'ON', N'off'),
             N', online deposits (BookingDepositRequired) are ', IIF(booking.fn_SettingIsOn('BookingDepositRequired') = 1, N'ON', N'off'), N'.');
PRINT CONCAT(N'OWNER CHECK (120): upcoming website bookings that are Confirmed with a deposit due and NOTHING paid: ', @n,
             IIF(@n > 0, CONCAT(N' (', @refs, IIF(@n > 30, N', ...', N''), N'). Staff decide each: take the deposit by hand, or cancel it.'), N'.'));
PRINT N'120_booking_deposit_before_confirm.sql: a booking that must be paid online now starts Pending - in place.';
GO
