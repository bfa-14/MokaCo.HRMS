/* ============================================================================
   121_booking_unpaid_never_stays.sql - a website booking that is waiting for its online deposit is HELD, not
   booked: it is released by itself when the deposit is not paid, and nobody is told about it until it is
   (22 Nov 2026).

   THE FAULT (after script 120, which stopped such a booking being Confirmed at once). A booking that must pay
   its deposit online started Pending with NO hold. Its hold was only stamped by POST /{ref}/pay. So when the
   payment never started - the guest closed the page, the payment page could not be opened and nothing was
   stamped, no card gateway was set up on that system - the booking stayed Pending with no time limit: the
   room was taken until a person cancelled it. And at creation the notification trigger had already written
   "we have received your booking request" to the guest and "a booking request is waiting to be confirmed"
   to the staff, so to everybody it looked booked.

   NOW
     booking.fn_DepositHoldUntil   NEW. The hold of a booking that starts Pending and must pay a deposit online:
                                   now + BookingHoldMinutes (15 when unset). NULL for every other booking.
     booking.usp_Booking_Create    script 120's body, plus: the row is inserted with that hold, and for a held
                                   booking the 'Request' and 'StaffAlert' messages the trigger queued are removed
                                   in the same transaction. Parameters and result shape unchanged.
   What happens to a held booking, with procedures that already exist and are not changed:
     paid                          usp_Booking_ConfirmOnlinePayment: Confirmed, the payment line, the guest's
                                   Confirmation and the staff's "online deposit received".
     declined / cancelled          released at once (usp_Booking_ReleaseHold through the API's settlement).
     payment opened, never paid    the reconciliation job asks the gateway, then releases it.
     payment never opened          usp_Booking_ExpireHolds releases it when the hold runs out (it only sweeps
                                   holds whose payment was never opened).
   A request taken without an online deposit (deposits off) is untouched: no hold, the messages as before.

   Bookings already made are not touched: the Pending deposit bookings the old rule left with no time limit
   are listed at the end for staff to confirm or cancel (a deploy never cancels a real guest's booking).

   Needs 120. Pure ASCII; QUOTED_IDENTIFIER ON; re-runnable (CREATE OR ALTER).
   Apply with: sqlcmd -S <server> -U <login> -C -I -b -d MokaCo_HRMS -i docs/121_booking_unpaid_never_stays.sql
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

DECLARE @def NVARCHAR(MAX) = ISNULL(OBJECT_DEFINITION(OBJECT_ID('booking.usp_Booking_Create')), N'');
IF OBJECT_ID('booking.fn_NewBookingStatus') IS NULL OR @def NOT LIKE N'%fn_NewBookingStatus%'
    RAISERROR('121_booking_unpaid_never_stays.sql needs script 120. Apply it first.', 16, 1);
ELSE IF OBJECT_ID('booking.usp_Booking_ReleaseHold') IS NULL OR OBJECT_ID('booking.usp_Booking_ExpireHolds') IS NULL
        OR COL_LENGTH('booking.BOOKING', 'HoldExpiresUtc') IS NULL OR COL_LENGTH('core.EMAIL_OUTBOX', 'MailKind') IS NULL
    RAISERROR('121: the booking base (usp_Booking_ReleaseHold, usp_Booking_ExpireHolds, BOOKING.HoldExpiresUtc, EMAIL_OUTBOX.MailKind) is not complete here. Nothing was changed; tell the developer.', 16, 1);
GO

/* ---- 1. The hold of a booking that waits for its online deposit --------------------------- */
CREATE OR ALTER FUNCTION booking.fn_DepositHoldUntil
    (@Status VARCHAR(12), @OnlineDeposit BIT, @Deposit DECIMAL(10,2))
RETURNS DATETIME2(0)
AS
BEGIN
    /* script 121 */
    IF @Status <> 'Pending' OR ISNULL(@OnlineDeposit, 0) = 0 OR ISNULL(@Deposit, 0) <= 0 RETURN NULL;

    DECLARE @Hold INT = ISNULL(TRY_CAST((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'BookingHoldMinutes') AS INT), 15);
    IF @Hold < 1 SET @Hold = 15;
    RETURN DATEADD(MINUTE, @Hold, SYSUTCDATETIME());
END;
GO

/* ---- 2. Create: script 120's body, held from the start and announced only when paid --------- */
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

    /* script 121: A BOOKING WAITING FOR ITS ONLINE DEPOSIT IS HELD, NOT BOOKED. It carries its hold from the
       moment it exists (booking.fn_DepositHoldUntil), so one that is never paid - the guest left before the
       payment page, the page could not be opened, no gateway is set up - is released by the sweep
       (usp_Booking_ExpireHolds) instead of holding the room for ever. /pay re-stamps the hold as before. */
    DECLARE @HoldUntil DATETIME2(0) = booking.fn_DepositHoldUntil(@Status, @OnlineDeposit, @Deposit);

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
        CreatedByUserId, BookingRef, DiscountPercent, DiscountAmount, OnlineDeposit, HoldExpiresUtc)
    VALUES (@RoomId, @BookDate, @StartTime, @EndTime, @Persons, LTRIM(RTRIM(@GuestName)),
        LTRIM(RTRIM(@GuestPhone)), NULLIF(LTRIM(RTRIM(@GuestEmail)), N''), @Note,
        @Total, @Deposit, @Pct, @Ccy, @Status, @Source, @CreatedByUserId, @Ref, @DiscPct, @DiscAmt, @OnlineDeposit, @HoldUntil);
    DECLARE @Bid INT = SCOPE_IDENTITY();

    /* script 121: NOTHING IS ANNOUNCED UNTIL IT IS PAID. The notification trigger has just written "we have
       received your booking request" for the guest and "a booking request is waiting to be confirmed" for the
       staff. For a booking held for its deposit both are untrue: there is nothing for staff to confirm, and
       the guest has not booked until the payment goes through. They are taken back here, in the same
       transaction, before anything can send them. What goes out instead: the Confirmation and the staff's
       "online deposit received" when it is paid, or the Cancellation when it is not. */
    IF @HoldUntil IS NOT NULL
        DELETE FROM core.EMAIL_OUTBOX
        WHERE BookingId = @Bid AND MailKind IN ('Request', 'StaffAlert') AND [Status] = 'Pending';

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

/* ---- 3. For the owner: what the old rule left behind (listed, never changed) ----------------- */
DECLARE @stuck TABLE (BookingId INT PRIMARY KEY, BookingRef VARCHAR(20) NULL);
INSERT INTO @stuck (BookingId, BookingRef)
SELECT b.BookingId, b.BookingRef
FROM booking.BOOKING b
WHERE b.[Status] = 'Pending' AND b.[Source] = 'Website' AND b.OnlineDeposit = 1 AND b.DepositDue > 0
  AND b.HoldExpiresUtc IS NULL AND b.PaymentOpenedUtc IS NULL
  AND NOT EXISTS (SELECT 1 FROM booking.BOOKING_PAYMENT p WHERE p.BookingId = b.BookingId);

DECLARE @n INT = (SELECT COUNT(*) FROM @stuck);
DECLARE @refs NVARCHAR(MAX) = (SELECT STRING_AGG(CAST(x.BookingRef AS NVARCHAR(MAX)), N', ') FROM (SELECT TOP 30 BookingRef FROM @stuck ORDER BY BookingId) x);
PRINT CONCAT(N'OWNER CHECK (121): website bookings still Pending from before, waiting for an online deposit with no time limit: ', @n,
             IIF(@n > 0, CONCAT(N' (', @refs, IIF(@n > 30, N', ...', N''), N'). This script does not touch them: staff decide each, confirm it by hand or cancel it.'), N'.'));
PRINT N'121_booking_unpaid_never_stays.sql: a booking waiting for its online deposit is held, announced when paid, released when not - in place.';
GO
