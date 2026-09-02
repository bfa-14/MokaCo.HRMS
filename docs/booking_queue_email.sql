/* ============================================================================
   booking.usp_Booking_QueueEmail   -   the guest's copy of what just happened
   MokaCo_HRMS
   ----------------------------------------------------------------------------
   WHY THIS FILE EXISTS. The booking schema shipped with fifteen procedures and
   no way to tell the guest anything. Every write path in the API - the website
   POST, the manual booking, a confirm and a cancel - is specified to queue a
   message after it succeeds, and there was no procedure to call. This is it.

   IT WRITES A ROW, IT DOES NOT SEND. core.EMAIL_OUTBOX is drained by EmailWorker
   once a minute; that separation is the whole point of the outbox and is copied
   here unchanged from core.usp_Email_QueueForRequest. A booking that committed
   must not be undone because a mail server was unreachable.

   RequestInstanceId IS LEFT NULL, deliberately. That column ties a row to a
   workflow request and is what makes the worker attach the request PDF; a
   booking is not a request and has no PDF, and the worker already treats the
   NULL as "no attachment" (EmailWorker.cs - `if (row.RequestInstanceId is { }`).
   There is no FK on the column, so nothing else needs to change to allow this.

   NO EMAIL IS NOT AN ERROR. GuestEmail is optional on the public form - a phone
   number is the only contact we insist on - so a guest without one must leave
   this procedure quietly. Raising here would turn "booked, but we can't email
   you" into a 400 on a booking that already exists in the room's calendar.

   PLAIN TEXT WITH CRLFs, matching the bodies core.fn_RequestEmailBody produces:
   the worker sends with IsBodyHtml = false, so HTML would arrive as markup and
   a body with bare LFs would arrive as one paragraph.

   THIS FILE IS DELIBERATELY PURE ASCII. sqlcmd reads a file without a BOM in the
   client's ANSI codepage, not UTF-8, so a literal em dash in here is stored as
   the three characters "a-hat, euro, quote" and every guest receives them in
   their subject line. The one em dash the subject wants is written as
   NCHAR(8212) below, which cannot be mangled by whoever applies this.

   Re-runnable (CREATE OR ALTER). Writes only to core.EMAIL_OUTBOX.
   ============================================================================ */
USE MokaCo_HRMS;
GO

/* NOT BOILERPLATE EITHER. A procedure PERMANENTLY REMEMBERS the SET options in
   force when it was created, and core.EMAIL_OUTBOX carries an index that refuses
   an INSERT from a session with QUOTED_IDENTIFIER OFF - which is exactly what
   sqlcmd gives you unless it is run with -I. Without these two lines the
   procedure compiles fine and then fails with error 1934 the first time a guest
   books. Setting them here makes the file correct regardless of who applies it. */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE booking.usp_Booking_QueueEmail
    @BookingId INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @To NVARCHAR(150), @Guest NVARCHAR(120), @RoomName NVARCHAR(80),
            @BookDate DATE, @StartTime TIME(0), @EndTime TIME(0), @Persons INT,
            @Total DECIMAL(10,2), @Deposit DECIMAL(10,2), @Ccy CHAR(3),
            @Status VARCHAR(12), @Policy NVARCHAR(1000), @CancelReason NVARCHAR(300),
            @Paid DECIMAL(10,2);

    SELECT @To         = NULLIF(LTRIM(RTRIM(b.GuestEmail)), N''),
           @Guest      = b.GuestName,
           @RoomName   = r.[Name],
           @BookDate   = b.BookDate,
           @StartTime  = b.StartTime,
           @EndTime    = b.EndTime,
           @Persons    = b.Persons,
           @Total      = b.TotalAmount,
           @Deposit    = b.DepositDue,
           @Ccy        = b.CurrencyCode,
           @Status     = b.[Status],
           @Policy     = r.PolicyText,
           @CancelReason = b.CancelReason,
           @Paid       = ISNULL(p.Paid, 0)
    FROM booking.BOOKING b
    JOIN booking.ROOM r ON r.RoomId = b.RoomId
    OUTER APPLY (SELECT SUM(Amount) AS Paid FROM booking.BOOKING_PAYMENT
                 WHERE BookingId = b.BookingId) p
    WHERE b.BookingId = @BookingId;

    /* A missing booking IS a caller bug and is worth the refusal - unlike a
       missing address, which is an ordinary guest with a phone and no inbox. */
    IF @Status IS NULL
    BEGIN RAISERROR('Booking not found.',16,1); RETURN; END

    IF @To IS NULL
    BEGIN
        SELECT 0 AS Queued, CAST(NULL AS NVARCHAR(150)) AS ToAddress;
        RETURN;
    END

    DECLARE @CRLF NCHAR(2) = CHAR(13) + CHAR(10);
    DECLARE @Dash NCHAR(1) = NCHAR(8212);   -- em dash, spelled out; see the header

    /* The one line that says what the message is FOR, in the guest's terms
       rather than the column's. 'Pending' is the state that needs explaining:
       the slot is held, nobody has agreed to it yet. */
    DECLARE @Headline NVARCHAR(200) =
        CASE @Status
            WHEN 'Pending'   THEN N'We have received your booking request and are holding the slot. You will hear from us once it is confirmed.'
            WHEN 'Confirmed' THEN N'Your booking is confirmed. We look forward to seeing you.'
            WHEN 'Completed' THEN N'Thank you for visiting us. Your booking is now closed.'
            WHEN 'Cancelled' THEN N'Your booking has been cancelled.'
            WHEN 'NoShow'    THEN N'This booking was marked as a no-show.'
            ELSE N'Your booking has been updated.'
        END;

    DECLARE @AddonLines NVARCHAR(MAX) = N'';
    SELECT @AddonLines = @AddonLines + N'  - ' + ba.[Name] + N'  '
                       + CONVERT(NVARCHAR(20), ba.Amount) + N' ' + @Ccy + @CRLF
    FROM booking.BOOKING_ADDON ba
    WHERE ba.BookingId = @BookingId;

    DECLARE @Subject NVARCHAR(200) =
        CONCAT(N'Booking #', @BookingId, N' ', @Status, N' ', @Dash, N' ', @RoomName);

    DECLARE @Body NVARCHAR(MAX) =
        CONCAT(
            N'Dear ', @Guest, N',', @CRLF, @CRLF,
            @Headline, @CRLF, @CRLF,
            N'Booking reference: #', @BookingId, @CRLF,
            N'Room:     ', @RoomName, @CRLF,
            N'Date:     ', CONVERT(NVARCHAR(10), @BookDate, 120), @CRLF,
            N'Time:     ', CONVERT(NVARCHAR(5), @StartTime, 108),
                    N' - ', CONVERT(NVARCHAR(5), @EndTime, 108), @CRLF,
            N'Persons:  ', @Persons, @CRLF,
            CASE WHEN @AddonLines = N'' THEN N''
                 ELSE CONCAT(@CRLF, N'Add-ons:', @CRLF, @AddonLines) END,
            @CRLF,
            N'Total:    ', CONVERT(NVARCHAR(20), @Total),   N' ', @Ccy, @CRLF,
            N'Deposit:  ', CONVERT(NVARCHAR(20), @Deposit), N' ', @Ccy, @CRLF,
            N'Paid:     ', CONVERT(NVARCHAR(20), @Paid),    N' ', @Ccy, @CRLF,
            N'Balance:  ', CONVERT(NVARCHAR(20), @Total - @Paid), N' ', @Ccy, @CRLF,
            CASE WHEN @Status = 'Cancelled' AND LTRIM(RTRIM(ISNULL(@CancelReason, N''))) <> N''
                 THEN CONCAT(@CRLF, N'Reason: ', @CancelReason, @CRLF) ELSE N'' END,
            CASE WHEN LTRIM(RTRIM(ISNULL(@Policy, N''))) <> N''
                 THEN CONCAT(@CRLF, N'---', @CRLF, @Policy, @CRLF) ELSE N'' END,
            @CRLF, N'MokaCo', @CRLF);

    INSERT INTO core.EMAIL_OUTBOX (ToAddress, [Subject], Body, RequestInstanceId, Channel, Lang)
    VALUES (@To, @Subject, @Body, NULL, 'Email', 'en');

    SELECT 1 AS Queued, @To AS ToAddress;
END;
GO
