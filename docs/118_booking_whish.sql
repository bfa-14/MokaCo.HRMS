/* ============================================================================
   118_booking_whish.sql - WHISH AS A SECOND WAY TO PAY THE BOOKING DEPOSIT.

   The website's deposit is paid by card (Bank of Beirut, MPGS; scripts 88 and 104). Whish Pay becomes a second
   method BEHIND THE SAME PIPELINE: the same hold, the same settlement code (OnlineDepositService.SettleAsync), the
   same procedure that records a paid deposit and confirms the booking (booking.usp_Booking_ConfirmOnlinePayment,
   which already takes the payment method's name). What Whish needs of the database is small:

   - AN ATTEMPT ID. A Whish payment link allows ONE attempt and lives five minutes; a retry is a new payment with a
     new id. So the id sent to Whish is the reference plus an attempt number - MC-K7Q2M9PW-A1, -A2, ... - and it is
     kept where the card flow keeps its order id: booking.BOOKING.GatewayOrderId. That is also how the settlement
     code tells the two methods apart: the reference itself is a card order, reference-A<n> a Whish attempt.
       booking.BOOKING.WhishAttempt       how many Whish attempts were opened on the booking
       booking.BOOKING.WhishPayerPhone    the phone that paid, as Whish reports it (a breadcrumb for staff)
   - A SWITCH. BookingWhishEnabled (Settings, section Booking): the website offers Whish only while it is on AND the
     API holds the Whish keys. Off by default: turning it on is a decision, not a deployment.

   Procedures (the API calls these; booking.usp_Booking_SetWhishPayer, the last one, is the MARKER of this script)
     booking.usp_Booking_StartWhishAttempt  @Ref -> the next attempt of a booking whose payment was just started
                                            (usp_Booking_StartPayment validated it and stamped the hold)
     booking.usp_Booking_SetWhishPayer      @Ref, @ExternalId, @Phone -> after a paid attempt was recorded: the
                                            payer's phone on the booking, and the payment line named as Whish's

   Nothing here knows a Whish key: they live in /etc/mokaco/api.env (WHISH_BASE, WHISH_CHANNEL, WHISH_SECRET,
   WHISH_WEBSITE_URL), never in the database and never in a repository.

   Idempotent. Apply: sqlcmd -C -I -b -d <database> -i docs/118_booking_whish.sql
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF OBJECT_ID('booking.BOOKING') IS NULL OR OBJECT_ID('booking.usp_Booking_StartPayment') IS NULL
   OR OBJECT_ID('booking.usp_Booking_ConfirmOnlinePayment') IS NULL OR COL_LENGTH('booking.BOOKING', 'PaymentOpenedUtc') IS NULL
BEGIN
    RAISERROR('118_booking_whish.sql: the online deposit of the bookings (scripts 88 and 104) is not in this database. Apply the earlier numbered scripts first. Nothing was applied.', 16, 1);
    SET NOEXEC ON;
END
GO

/* ---------------------------------------------------------------- 1. the columns */
IF COL_LENGTH('booking.BOOKING', 'WhishAttempt') IS NULL
BEGIN
    ALTER TABLE booking.BOOKING ADD WhishAttempt INT NOT NULL CONSTRAINT DF_BOOKING_WhishAttempt DEFAULT 0;
    PRINT 'booking.BOOKING.WhishAttempt added';
END
IF COL_LENGTH('booking.BOOKING', 'WhishPayerPhone') IS NULL
BEGIN
    ALTER TABLE booking.BOOKING ADD WhishPayerPhone VARCHAR(30) NULL;
    PRINT 'booking.BOOKING.WhishPayerPhone added';
END
GO

/* ---------------------------------------------------------------- 2. the switch */
IF NOT EXISTS (SELECT 1 FROM core.SETTING WHERE SettingKey = 'BookingWhishEnabled')
BEGIN
    INSERT INTO core.SETTING (SettingKey, SettingValue, DataType, [Description], Section, SortOrder, ModifiedAt)
    VALUES ('BookingWhishEnabled', '0', 'bool',
            N'Offer Whish as a way to pay the online booking deposit, beside the card. It shows on the website only while this is on AND the API holds the Whish keys (WHISH_* in api.env). Needs online deposits (BookingDepositRequired) to be on.',
            'Booking', 24, SYSUTCDATETIME());
    PRINT 'setting BookingWhishEnabled added (off)';
END
GO

/* ---------------------------------------------------------------- 3. the next Whish attempt of a booking */
/* Called right after booking.usp_Booking_StartPayment, which decided that the booking may be paid and stamped the
   hold and PaymentOpenedUtc. Numbers the attempt and makes its id the booking's gateway order id (it was the bare
   reference, as for a card). Refused - nothing written - for a booking that is not Pending or whose payment was not
   started: an attempt id is never handed out for something that cannot be paid. */
CREATE OR ALTER PROCEDURE booking.usp_Booking_StartWhishAttempt
    @Ref VARCHAR(12)
AS BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @Bid INT, @Status VARCHAR(12), @Opened DATETIME2, @Attempt INT, @Err NVARCHAR(200);

    BEGIN TRAN;
    SELECT @Bid = BookingId, @Status = [Status], @Opened = PaymentOpenedUtc, @Attempt = WhishAttempt
    FROM booking.BOOKING WITH (UPDLOCK, HOLDLOCK)
    WHERE BookingRef = @Ref;

    SET @Err = CASE
        WHEN @Bid IS NULL THEN N'Booking not found.'
        WHEN @Status <> 'Pending' OR @Opened IS NULL
             THEN CONCAT(N'This booking is not waiting for a payment (it is ', @Status, N').')
        WHEN @Attempt >= 99 THEN N'This booking is not waiting for a payment (too many Whish attempts; our staff will help).'
    END;

    IF @Err IS NULL
    BEGIN
        SET @Attempt = @Attempt + 1;
        UPDATE booking.BOOKING
        SET WhishAttempt = @Attempt,
            GatewayOrderId = CONCAT(@Ref, '-A', @Attempt)
        WHERE BookingId = @Bid;
    END
    COMMIT;      -- a refusal commits (nothing was written) and raises after, like usp_Booking_StartPayment

    IF @Err IS NOT NULL BEGIN RAISERROR(@Err, 16, 1); RETURN 1; END

    SELECT b.BookingId, b.BookingRef, b.GatewayOrderId AS ExternalId, b.WhishAttempt AS Attempt,
           b.DepositDue, b.CurrencyCode, b.HoldExpiresUtc, b.PaymentOpenedUtc
    FROM booking.BOOKING b
    WHERE b.BookingId = @Bid;
END;
GO

/* ---------------------------------------------------------------- 4. who paid, and the payment line's name */
/* After booking.usp_Booking_ConfirmOnlinePayment recorded a paid Whish attempt (method name 'Whish'). That procedure
   words every line 'MPGS <order> / <transaction>': the line of a Whish attempt is re-worded here, and the phone that
   paid is kept on the booking. Changes nothing when the attempt has no payment line. */
CREATE OR ALTER PROCEDURE booking.usp_Booking_SetWhishPayer
    @Ref        VARCHAR(12),
    @ExternalId VARCHAR(40),
    @Phone      VARCHAR(30) = NULL
AS BEGIN
    SET NOCOUNT ON;
    SET @Phone = NULLIF(LTRIM(RTRIM(@Phone)), '');

    UPDATE p
    SET p.Reference = LEFT(CONCAT(N'Whish ', @ExternalId, CASE WHEN @Phone IS NULL THEN N'' ELSE CONCAT(N' / paid from ', @Phone) END), 80)
    FROM booking.BOOKING_PAYMENT p
    JOIN booking.BOOKING b ON b.BookingId = p.BookingId
    WHERE b.BookingRef = @Ref AND p.GatewayOrderId = @ExternalId AND p.IsRefund = 0;

    IF @@ROWCOUNT > 0 AND @Phone IS NOT NULL
        UPDATE booking.BOOKING SET WhishPayerPhone = @Phone WHERE BookingRef = @Ref;
END;
GO

/* ---------------------------------------------------------------- 5. OWNER CHECK */
DECLARE @On NVARCHAR(10) = (SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'BookingWhishEnabled');
DECLARE @Deposits NVARCHAR(10) = (SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'BookingDepositRequired');
PRINT CONCAT('OWNER CHECK (118): Whish for booking deposits is ', CASE WHEN @On IN ('1', 'true') THEN 'ON' ELSE 'OFF' END,
             ' (Settings > Booking > BookingWhishEnabled); online deposits are ', CASE WHEN @Deposits IN ('1', 'true') THEN 'ON' ELSE 'OFF' END,
             '. The website offers Whish only when both are on and the API has the Whish keys in api.env.');
PRINT '118_booking_whish.sql: Whish deposits - in place.';
GO

SET NOEXEC OFF;
GO
