/* ============================================================================
   tests/qa3/booking/guest_phone_national.sql - QA3 BKG-5 (docs/104_qa3_booking.sql).

   usp_Booking_CancelByGuest compared the LAST 8 DIGITS, so a 7-digit Lebanese number never matched
   ("+961 3 123 456" on file, "03 123 456" typed: ...13123456 against 03123456). It now compares the
   national numbers (booking.fn_PhoneNational), and still accepts a last-8-digits match.

     N1..N6  the same number written another way -> cancelled (CancelledBy Guest)
     W1..W4  a different number                   -> 'The phone number does not match this booking.',
                                                    booking untouched
   One booking per case on 2099-06-15 (staff bookings: no lead-time rules), each case in its own
   transaction (a successful cancel ends the case), all rolled back. RAISERROR on a wrong result.
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
DECLARE @fail NVARCHAR(2000) = NULL, @Room INT, @Ref VARCHAR(12), @Msg NVARCHAR(400), @Status VARCHAR(12), @n INT = 1;
DECLARE @made TABLE (BookingId INT, BookingRef VARCHAR(12), TotalAmount DECIMAL(10,2), DepositDue DECIMAL(10,2), DepositPercent DECIMAL(5,2), CurrencyCode CHAR(3), [Status] VARCHAR(12), Hours DECIMAL(6,2), RoomName NVARCHAR(80), RoomId INT, DiscountPercent DECIMAL(5,2), DiscountAmount DECIMAL(10,2));
DECLARE @cases TABLE (N INT IDENTITY(1,1), Label VARCHAR(4), Stored VARCHAR(30), Typed VARCHAR(30), Match BIT);
INSERT INTO @cases (Label, Stored, Typed, Match) VALUES
    ('N1', '+961 3 123 456', '03 123 456',     1),   -- 7-digit mobile, international on file, local typed
    ('N2', '03 123 456',     '+961 3 123 456', 1),   -- the other way round
    ('N3', '03123456',       '3123456',        1),   -- typed without the trunk 0
    ('N4', '+961 1 234 567', '01 234 567',     1),   -- Beirut landline
    ('N5', '+96170000005',   '70 000 005',     1),   -- 8-digit mobile (script 79's case)
    ('N6', '+96170000005',   '0096170000005',  1),   -- 00 instead of +
    ('W1', '+961 3 123 456', '03 123 457',     0),   -- one digit off
    ('W2', '+961 71 123 456','01 123 456',     0),   -- the last 7 digits of an 8-digit mobile are not enough
    ('W3', '+96170000005',   '70 999 999',     0),
    ('W4', '+961 3 123 456', NULL,             0);

WHILE @n <= (SELECT MAX(N) FROM @cases)
BEGIN
    DELETE FROM @made; SELECT @Msg = NULL, @Status = NULL;
    BEGIN TRAN;
    BEGIN TRY
        INSERT INTO booking.ROOM (Code, [Name], Seats, MinPersons, PricePerHour, MinHours, MaxHours, SortOrder, IsActive)
        VALUES ('qa3-bk', N'QA3 booking room', 6, 1, 20, 1, 6, 999, 1);
        SET @Room = SCOPE_IDENTITY();
        INSERT INTO booking.ROOM_HOURS (RoomId, DayOfWeek, OpenTime, CloseTime, IsClosed)
        SELECT @Room, d, '07:00', '01:00', 0 FROM (VALUES (1),(2),(3),(4),(5),(6),(7)) v(d);

        DECLARE @Stored VARCHAR(30) = (SELECT Stored FROM @cases WHERE N = @n), @Typed VARCHAR(30) = (SELECT Typed FROM @cases WHERE N = @n);
        INSERT INTO @made EXEC booking.usp_Booking_Create @RoomId = @Room, @BookDate = '2099-06-15', @StartTime = '10:00', @EndTime = '12:00',
             @Persons = 2, @GuestName = N'QA3 Phone', @GuestPhone = @Stored, @Source = 'Manual';
        SELECT @Ref = BookingRef FROM @made;
        BEGIN TRY
            EXEC booking.usp_Booking_CancelByGuest @Ref = @Ref, @Phone = @Typed;
        END TRY
        BEGIN CATCH
            SET @Msg = ERROR_MESSAGE();
        END CATCH;
        SELECT @Status = [Status] FROM booking.BOOKING WHERE BookingRef = @Ref;

        IF (SELECT Match FROM @cases WHERE N = @n) = 1
           AND NOT (@Msg IS NULL AND @Status = 'Cancelled' AND (SELECT CancelledBy FROM booking.BOOKING WHERE BookingRef = @Ref) = 'Guest')
            SET @fail = CONCAT(@fail, ' ', (SELECT Label FROM @cases WHERE N = @n), ': refused (', ISNULL(@Msg, @Status), ');');
        IF (SELECT Match FROM @cases WHERE N = @n) = 0
           AND NOT (@Msg LIKE 'The phone number does not match this booking%' AND @Status = 'Confirmed')
            SET @fail = CONCAT(@fail, ' ', (SELECT Label FROM @cases WHERE N = @n), ': accepted or wrong refusal (', ISNULL(@Msg, @Status), ');');
    END TRY
    BEGIN CATCH
        SET @fail = CONCAT(@fail, ' case ', @n, ': unexpected error: ', ERROR_MESSAGE(), ';');
    END CATCH;
    IF @@TRANCOUNT > 0 ROLLBACK;
    SET @n += 1;
END

IF @fail IS NOT NULL RAISERROR('guest_phone_national FAILED:%s', 16, 1, @fail);
ELSE PRINT 'ok guest_phone_national';
GO
