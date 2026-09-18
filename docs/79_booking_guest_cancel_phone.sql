/* ============================================================================
   79_booking_guest_cancel_phone.sql — QA fix pack Q4 (public booking API).

   booking.usp_Booking_CancelByGuest took nothing but the reference, so anybody who had seen an
   MC- reference (a screenshot, a forwarded mail) could cancel the booking from the website. The
   public endpoint POST /api/public/booking/{ref}/cancel now sends the guest's phone number, and the
   procedure REFUSES unless the LAST 8 DIGITS of the number given match the last 8 digits of the
   phone stored on the booking (digits only are compared, so "+961 70 000 005", "70-000-005" and
   "0096170000005" all match "+96170000005"). Everything else is unchanged: only a Pending or
   Confirmed booking, only inside core.SETTING BookingCancelHours of the start, always as
   CancelledBy = 'Guest' (refund = paid − deposit unless BookingDepositRefundableOnGuestCancel = 1),
   and the recap (usp_Booking_GetByRef) is returned.

   REFUSAL TEXTS are read by the API's error mapping — keep the opening words if they are reworded:
     'Booking not found.'                                  → 404 not_found
     'This booking can no longer be cancelled online.'     → 409 not_cancellable
     'Online cancellation closes %d hours before ...'      → 409 cancel_window
     'The phone number does not match this booking.'       → 400 invalid_input
   Idempotent (CREATE OR ALTER). Run after 74.
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/* Digits only — what two spellings of one phone number have in common. */
CREATE OR ALTER FUNCTION booking.fn_PhoneDigits (@Phone VARCHAR(30)) RETURNS VARCHAR(30)
WITH SCHEMABINDING
AS BEGIN
    DECLARE @s VARCHAR(30) = ISNULL(@Phone, ''), @out VARCHAR(30) = '', @i INT = 1;
    WHILE @i <= LEN(@s)
    BEGIN
        IF SUBSTRING(@s, @i, 1) LIKE '[0-9]' SET @out += SUBSTRING(@s, @i, 1);
        SET @i += 1;
    END
    RETURN @out;
END;
GO

CREATE OR ALTER PROCEDURE booking.usp_Booking_CancelByGuest
    @Ref VARCHAR(12),
    @Phone VARCHAR(30) = NULL        -- the number the guest typed; must match the booking's last 8 digits
AS BEGIN SET NOCOUNT ON;
    DECLARE @Bid INT, @Status VARCHAR(12), @Date DATE, @StartMin INT, @Stored VARCHAR(30);
    SELECT @Bid = BookingId, @Status = [Status], @Date = BookDate, @StartMin = StartMin, @Stored = GuestPhone
    FROM booking.BOOKING WHERE BookingRef = @Ref;
    IF @Bid IS NULL BEGIN RAISERROR('Booking not found.',16,1); RETURN; END

    /* Digits only, last 8 — the local part of a Lebanese number, whichever prefix was typed. */
    DECLARE @given VARCHAR(30) = booking.fn_PhoneDigits(@Phone);
    DECLARE @kept  VARCHAR(30) = booking.fn_PhoneDigits(@Stored);
    IF LEN(@given) < 8 OR LEN(@kept) < 8 OR RIGHT(@given, 8) <> RIGHT(@kept, 8)
    BEGIN RAISERROR('The phone number does not match this booking.',16,1); RETURN; END

    IF @Status NOT IN ('Pending','Confirmed')
    BEGIN RAISERROR('This booking can no longer be cancelled online.',16,1); RETURN; END

    DECLARE @Hours INT = ISNULL(TRY_CAST((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'BookingCancelHours') AS INT), 24);
    DECLARE @StartDt DATETIME2(0) = DATEADD(MINUTE, @StartMin, CAST(@Date AS DATETIME2(0)));
    IF @StartDt < DATEADD(HOUR, @Hours, booking.fn_LocalNow())
    BEGIN RAISERROR('Online cancellation closes %d hours before the start — please call us.',16,1,@Hours); RETURN; END

    DECLARE @Refund DECIMAL(10,2) = booking.fn_RefundDue(@Bid, 'Guest');
    UPDATE booking.BOOKING
    SET [Status] = 'Cancelled', DecidedUtc = SYSUTCDATETIME(),
        CancelReason = N'Cancelled by the guest online.', CancelledBy = 'Guest',
        RefundAmount = @Refund, RefundStatus = CASE WHEN @Refund > 0 THEN 'Due' ELSE 'None' END,
        HoldExpiresUtc = NULL
    WHERE BookingId = @Bid;
    EXEC booking.usp_Booking_GetByRef @Ref;
END;
GO
PRINT 'booking.usp_Booking_CancelByGuest now takes @Phone (last-8-digit match).';
GO
