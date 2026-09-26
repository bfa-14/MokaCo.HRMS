/* ============================================================================
   88_booking_online_deposit.sql — HRMS step 2: online deposits (MPGS hosted checkout).

   The website creates a booking (Pending), then asks POST /api/public/booking/{ref}/pay for a
   checkout session; the guest pays on the gateway's page and comes back through
   GET /api/public/booking/verify?ref=, where the API asks the gateway (RETRIEVE_ORDER) what really
   happened. A Quartz job settles the payments whose return trip never arrived. The gateway order id
   IS the booking reference (MC-XXXXXXXX): one booking, one order, one deposit.

   WHAT THIS SCRIPT ADDS
     booking.BOOKING          PaymentOpenedUtc   when /pay last opened a checkout session (NULL = never)
                              PaymentCheckedUtc  when the gateway was last asked about it
     booking.BOOKING_PAYMENT  GatewayOrderId, GatewayTransactionId, CurrencyCode — the gateway's
                              identity of an online payment line, and its currency.
                              UX_BOOKING_PAYMENT_GatewayOrder: ONE payment line per gateway order.
                              This, not the C#, is what makes a replay harmless: a refresh of the
                              return page, the reconciliation job and a double return can all try to
                              record the same order and only the first insert can succeed.
                              (Unique on the ORDER, not on the transaction id alone: MPGS transaction
                              ids are only unique inside their order — two orders can both have "1".)
     booking.PAYMENT_METHOD   'Card (MPGS)', IsOnline = 1 — the method online deposits are recorded
                              against, kept apart from the card terminal in the café ('Card').
     booking.usp_Booking_StartPayment          validate + stamp the hold, in one transaction
     booking.usp_Booking_GetPaymentState       what the settlement code needs to decide
     booking.usp_Booking_ConfirmOnlinePayment  record the deposit + confirm, idempotent, one transaction
     booking.usp_Booking_PaymentChecked        the gateway was asked; optionally keep the hold alive
     booking.usp_Booking_SetPaymentSession     remember the checkout session id (audit only)
     booking.usp_Booking_QueuePaymentAlert     one staff e-mail per booking per kind
     booking.usp_Booking_ListPaymentsToReconcile  the reconciliation job's work list

   WHAT IT CHANGES
     booking.usp_Booking_ExpireHolds — THE RACE. The sweep cancelled every Pending hold past
     HoldExpiresUtc with no payment line. A guest who paid in the last minute, whose return trip
     (/verify) arrived after the sweep, was cancelled while charged. A booking whose payment was
     opened (PaymentOpenedUtc set) is now LEFT ALONE by the sweep: the reconciliation job asks the
     gateway first and settles it (paid → Confirmed, failed/abandoned → released through
     usp_Booking_ReleaseHold). The @ReturnRows contract of script 80 is unchanged.

   REFUSAL TEXTS are read by the API's error mapping (BookingRefusals) — keep the opening words:
     'Booking not found.'                                 → 404 not_found
     'This booking is not waiting for a payment ...'      → 409 not_pending
     'The payment hold has expired ...'                   → 409 hold_expired
     'This booking has already been paid.'                → 409 already_paid
     'There is no deposit to pay on this booking.'        → 409 nothing_due

   NOT TOUCHED: core.SETTING BookingDepositRequired stays as it is (0 until the website is wired).
   booking.usp_Booking_ConfirmPaid and usp_Booking_SetGateway (from the full install) are left in
   place and are not used by the API; they are superseded by the procedures here.

   Idempotent: columns and indexes only when missing, procedures CREATE OR ALTER.
   Apply with: sqlcmd -S <server> -U <login> -C -I -d MokaCo_HRMS -i docs/88_booking_online_deposit.sql
   (-I = QUOTED_IDENTIFIER ON, required for the filtered unique index). Run after 74, 79 and 80.
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF OBJECT_ID('booking.usp_Booking_ExpireHolds') IS NULL OR COL_LENGTH('booking.BOOKING_PAYMENT', 'IsRefund') IS NULL
BEGIN
    RAISERROR('Apply docs/74 and docs/80 before this script.', 16, 1);
    RETURN;
END
GO

/* ---- 1. Columns ------------------------------------------------------------------------ */
IF COL_LENGTH('booking.BOOKING', 'PaymentOpenedUtc') IS NULL
    ALTER TABLE booking.BOOKING ADD PaymentOpenedUtc DATETIME2 NULL;
IF COL_LENGTH('booking.BOOKING', 'PaymentCheckedUtc') IS NULL
    ALTER TABLE booking.BOOKING ADD PaymentCheckedUtc DATETIME2 NULL;

IF COL_LENGTH('booking.BOOKING_PAYMENT', 'GatewayOrderId') IS NULL
    ALTER TABLE booking.BOOKING_PAYMENT ADD GatewayOrderId VARCHAR(40) NULL;
IF COL_LENGTH('booking.BOOKING_PAYMENT', 'GatewayTransactionId') IS NULL
    ALTER TABLE booking.BOOKING_PAYMENT ADD GatewayTransactionId VARCHAR(60) NULL;
IF COL_LENGTH('booking.BOOKING_PAYMENT', 'CurrencyCode') IS NULL
    ALTER TABLE booking.BOOKING_PAYMENT ADD CurrencyCode CHAR(3) NULL;
GO

/* ---- 2. One payment line per gateway order --------------------------------------------- */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('booking.BOOKING_PAYMENT') AND name = 'UX_BOOKING_PAYMENT_GatewayOrder')
    CREATE UNIQUE NONCLUSTERED INDEX UX_BOOKING_PAYMENT_GatewayOrder
        ON booking.BOOKING_PAYMENT (GatewayOrderId)
        WHERE GatewayOrderId IS NOT NULL AND IsRefund = 0;
GO

/* A booking is looked up by the settlement code by its payment state; the job scans this. */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('booking.BOOKING') AND name = 'IX_BOOKING_PaymentOpened')
    CREATE NONCLUSTERED INDEX IX_BOOKING_PaymentOpened
        ON booking.BOOKING (PaymentOpenedUtc)
        INCLUDE ([Status], BookingRef)
        WHERE PaymentOpenedUtc IS NOT NULL;
GO

/* ---- 3. The online payment method -------------------------------------------------------- */
IF NOT EXISTS (SELECT 1 FROM booking.PAYMENT_METHOD WHERE [Name] = N'Card (MPGS)')
    INSERT INTO booking.PAYMENT_METHOD ([Name], IsOnline, IsActive) VALUES (N'Card (MPGS)', 1, 1);
GO

/* ---- 4. Staff alerts: one e-mail per booking per kind ------------------------------------
   Kinds: 'PayReceived'     an online deposit was recorded (FYI)
          'PayAfterCancel'  money arrived on a booking that was already Cancelled/NoShow (ACTION)
          'PaySlotClash'    money arrived but somebody else holds the slot now (ACTION)
          'PayUnconfirmed'  the gateway could not confirm a payment for too long (ACTION)
   UX_EMAIL_OUTBOX_Booking (BookingId, MailKind, Channel) already allows one row per kind; a second
   call for the same kind is a no-op. No BookingNotifyEmail = nothing queued. */
CREATE OR ALTER PROCEDURE booking.usp_Booking_QueuePaymentAlert
    @BookingId INT, @Kind VARCHAR(20), @Detail NVARCHAR(400) = NULL,
    @Quiet BIT = 0                   -- 1 = no result set (called from another procedure; INSERT-EXEC cannot nest)
AS BEGIN SET NOCOUNT ON;
    IF @Kind NOT IN ('PayReceived','PayAfterCancel','PaySlotClash','PayUnconfirmed')
    BEGIN RAISERROR('Unknown payment alert kind.',16,1); RETURN; END

    DECLARE @To NVARCHAR(150) = NULLIF(LTRIM(RTRIM((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'BookingNotifyEmail'))), N'');
    IF @To IS NULL OR EXISTS (SELECT 1 FROM core.EMAIL_OUTBOX WHERE BookingId = @BookingId AND MailKind = @Kind AND Channel = 'Email')
    BEGIN IF @Quiet = 0 SELECT CAST(0 AS BIT) AS Queued; RETURN; END

    DECLARE @nl NCHAR(2) = CHAR(13) + CHAR(10);
    DECLARE @Ref VARCHAR(12), @Subject NVARCHAR(200), @Body NVARCHAR(MAX);
    SELECT @Ref = b.BookingRef,
           @Subject = CONCAT(CASE @Kind WHEN 'PayReceived' THEN N'Online deposit received '
                                        ELSE N'ACTION NEEDED: online payment ' END,
                             b.BookingRef, N' · ', r.[Name], N' · ', CONVERT(char(10), b.BookDate, 120)),
           @Body = CONCAT(
               CASE @Kind
                    WHEN 'PayReceived'    THEN N'An online deposit was received and recorded.'
                    WHEN 'PayAfterCancel' THEN N'A card payment was captured on a booking that is already closed. The payment is recorded and the booking is marked Refund Due: refund it (Bookings → Refund) or re-instate the booking.'
                    WHEN 'PaySlotClash'   THEN N'A card payment was captured, but another booking now holds this slot. The payment is recorded and the booking is still Pending: decide which booking keeps the slot and refund the other.'
                    ELSE                       N'The payment gateway has not confirmed this payment for a while. The slot is still held. Check the order in the gateway''s merchant portal, then confirm or cancel the booking.' END, @nl, @nl,
               N'Booking: ', b.BookingRef, N' (', b.[Status], N')', @nl,
               N'Room: ', r.[Name], N'  ', CONVERT(char(10), b.BookDate, 120), @nl,
               N'Guest: ', b.GuestName, N'  ', b.GuestPhone, @nl,
               N'Deposit due ', b.CurrencyCode, N' ', CONVERT(varchar(20), b.DepositDue),
               N' · Paid ', CONVERT(varchar(20), ISNULL((SELECT SUM(Amount) FROM booking.BOOKING_PAYMENT WHERE BookingId = b.BookingId), 0)), @nl,
               N'Gateway order: ', ISNULL(b.GatewayOrderId, b.BookingRef), @nl,
               CASE WHEN @Detail IS NOT NULL THEN CONCAT(@Detail, @nl) ELSE N'' END)
    FROM booking.BOOKING b JOIN booking.ROOM r ON r.RoomId = b.RoomId
    WHERE b.BookingId = @BookingId;
    IF @Ref IS NULL BEGIN RAISERROR('Booking not found.',16,1); RETURN; END

    DECLARE @FromEmail NVARCHAR(150) = NULLIF((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'BookingFromEmail'), '');
    DECLARE @FromName  NVARCHAR(100) = NULLIF((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'BookingFromName'), '');
    DECLARE @Acct VARCHAR(20) = CASE WHEN NULLIF((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'BookingSmtpUser'), '') IS NOT NULL
                                     THEN 'Booking' ELSE NULL END;

    INSERT INTO core.EMAIL_OUTBOX (ToAddress, [Subject], Body, RequestInstanceId, Channel, Lang, BookingId, MailKind,
                                   FromEmail, FromName, SmtpAccount)
    VALUES (@To, @Subject, @Body, NULL, 'Email', 'en', @BookingId, @Kind, @FromEmail, @FromName, @Acct);
    IF @Quiet = 0 SELECT CAST(1 AS BIT) AS Queued;
END;
GO

/* ---- 5. Start a payment: validate + stamp, ONE transaction --------------------------------
   Only a Pending WEBSITE booking whose hold has not run out. Stamps HoldExpiresUtc = now +
   BookingHoldMinutes and PaymentOpenedUtc = now, and sets the gateway order id to the reference.
   Calling it again for the same reference is allowed (a new checkout session on the SAME order):
   the hold is re-stamped and PreviousOpenedUtc tells the API a session was opened before, so it
   asks the gateway first whether that one was paid. THE AMOUNT IS THE ROW'S DepositDue, priced by
   usp_Booking_Create exactly as usp_Booking_Quote prices it; the caller never supplies it. */
CREATE OR ALTER PROCEDURE booking.usp_Booking_StartPayment
    @Ref VARCHAR(12)
AS BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @Hold INT = ISNULL(TRY_CAST((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'BookingHoldMinutes') AS INT), 15);
    IF @Hold < 1 SET @Hold = 15;

    DECLARE @Bid INT, @Status VARCHAR(12), @Source VARCHAR(10), @Expires DATETIME2, @Deposit DECIMAL(10,2),
            @Previous DATETIME2, @Now DATETIME2 = SYSUTCDATETIME(), @Err NVARCHAR(200);

    /* A refusal COMMITS (nothing was written) and raises after: a ROLLBACK here would also roll back
       a caller's own transaction (the QA case and the DB tests run inside one). */
    BEGIN TRAN;
    SELECT @Bid = BookingId, @Status = [Status], @Source = [Source], @Expires = HoldExpiresUtc,
           @Deposit = DepositDue, @Previous = PaymentOpenedUtc
    FROM booking.BOOKING WITH (UPDLOCK, HOLDLOCK)
    WHERE BookingRef = @Ref;

    SET @Err = CASE
        WHEN @Bid IS NULL THEN N'Booking not found.'
        WHEN EXISTS (SELECT 1 FROM booking.BOOKING_PAYMENT WHERE BookingId = @Bid AND GatewayOrderId IS NOT NULL AND IsRefund = 0)
             THEN N'This booking has already been paid.'
        WHEN @Status <> 'Pending' OR @Source <> 'Website'
             THEN CONCAT(N'This booking is not waiting for a payment (it is ', @Status, N').')
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

    IF @Err IS NOT NULL BEGIN RAISERROR(@Err, 16, 1); RETURN; END

    SELECT b.BookingId, b.BookingRef, b.DepositDue, b.CurrencyCode, b.TotalAmount,
           b.BookDate, b.StartMin, b.EndMin, b.Hours, r.[Name] AS RoomName,
           b.HoldExpiresUtc, b.PaymentOpenedUtc, @Previous AS PreviousOpenedUtc
    FROM booking.BOOKING b JOIN booking.ROOM r ON r.RoomId = b.RoomId
    WHERE b.BookingId = @Bid;
END;
GO

/* ---- 6. What the settlement code decides from --------------------------------------------- */
CREATE OR ALTER PROCEDURE booking.usp_Booking_GetPaymentState
    @Ref VARCHAR(12)
AS BEGIN SET NOCOUNT ON;
    SELECT b.BookingId, b.BookingRef, b.[Status], b.[Source], b.DepositDue, b.CurrencyCode,
           b.HoldExpiresUtc, b.PaymentOpenedUtc, b.PaymentCheckedUtc, b.GatewayOrderId,
           CAST(CASE WHEN EXISTS (SELECT 1 FROM booking.BOOKING_PAYMENT p
                                  WHERE p.BookingId = b.BookingId AND p.GatewayOrderId IS NOT NULL AND p.IsRefund = 0)
                     THEN 1 ELSE 0 END AS BIT) AS GatewayPaid
    FROM booking.BOOKING b
    WHERE b.BookingRef = @Ref;
END;
GO

/* ---- 7. Record the deposit and confirm: IDEMPOTENT, ONE transaction -------------------------
   The API calls this only when the gateway said: result SUCCESS, status CAPTURED, the whole amount
   captured, in the booking's currency. The booking row is locked (UPDLOCK, HOLDLOCK) first, so
   two callers for the same booking queue behind each other; the second finds the line the first
   wrote and changes nothing ('Replay'). UX_BOOKING_PAYMENT_GatewayOrder refuses a second line even
   if something ever bypassed this procedure.

   Outcome
     Confirmed      Pending → Confirmed. trg_Booking_Notify queues the guest's Confirmation (e-mail and
                    WhatsApp, per settings); a 'PayReceived' staff e-mail is queued here.
     Recorded       the booking was already Confirmed/Completed (staff got there first): line added.
     Replay         this order was already recorded: nothing changed.
     PaidButClosed  the booking was Cancelled/NoShow when the money arrived (e.g. released by a
                    failed verification the gateway later reversed). The money is on the books, the
                    booking is marked RefundStatus 'Due' for the full amount, staff are alerted.
                    REFUNDS STAY MANUAL.
     SlotClash      Pending, but another live booking or a block now covers the slot (its hold had
                    lapsed and somebody booked it). The line is recorded, the booking stays Pending
                    with no expiry (it keeps its claim), staff are alerted to decide. */
CREATE OR ALTER PROCEDURE booking.usp_Booking_ConfirmOnlinePayment
    @Ref VARCHAR(12), @Amount DECIMAL(10,2), @CurrencyCode CHAR(3),
    @GatewayOrderId VARCHAR(40), @TransactionId VARCHAR(60) = NULL,
    @MethodName NVARCHAR(80) = N'Card (MPGS)'
AS BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    IF @Amount IS NULL OR @Amount <= 0 BEGIN RAISERROR('The paid amount must be more than 0.',16,1); RETURN; END
    IF LTRIM(RTRIM(ISNULL(@GatewayOrderId, ''))) = '' BEGIN RAISERROR('The gateway order id is required.',16,1); RETURN; END

    DECLARE @Bid INT, @Status VARCHAR(12), @Room INT, @Date DATE, @StartMin INT, @EndMin INT,
            @Outcome VARCHAR(20), @Now DATETIME2 = SYSUTCDATETIME();

    BEGIN TRAN;
    SELECT @Bid = BookingId, @Status = [Status], @Room = RoomId, @Date = BookDate, @StartMin = StartMin, @EndMin = EndMin
    FROM booking.BOOKING WITH (UPDLOCK, HOLDLOCK)
    WHERE BookingRef = @Ref;
    IF @Bid IS NULL BEGIN COMMIT; RAISERROR('Booking not found.',16,1); RETURN; END   -- nothing written; see StartPayment

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
                       WHERE RoomId = @Room AND BookDate = @Date AND BookingId <> @Bid
                         AND [Status] IN ('Pending','Confirmed')
                         AND NOT ([Status] = 'Pending' AND HoldExpiresUtc IS NOT NULL AND HoldExpiresUtc < @Now)
                         AND StartMin < @EndMin AND EndMin > @StartMin)
               OR EXISTS (SELECT 1 FROM booking.BOOKING_BLOCK
                          WHERE RoomId = @Room AND BlockDate = @Date AND StartMin < @EndMin AND EndMin > @StartMin)
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

/* ---- 8. The gateway was asked -------------------------------------------------------------
   Stamps PaymentCheckedUtc. @KeepHold = 1 (the answer was "not settled yet") also pushes the hold
   out to at least now + BookingHoldMinutes, so that while the gateway cannot say, the slot is NOT
   offered to somebody else — every availability query frees a Pending hold whose clock ran out. */
CREATE OR ALTER PROCEDURE booking.usp_Booking_PaymentChecked
    @Ref VARCHAR(12), @KeepHold BIT = 0
AS BEGIN SET NOCOUNT ON;
    DECLARE @Hold INT = ISNULL(TRY_CAST((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'BookingHoldMinutes') AS INT), 15);
    IF @Hold < 1 SET @Hold = 15;
    DECLARE @Now DATETIME2 = SYSUTCDATETIME();
    DECLARE @Until DATETIME2 = DATEADD(MINUTE, @Hold, @Now);

    UPDATE booking.BOOKING
    SET PaymentCheckedUtc = @Now,
        HoldExpiresUtc = CASE WHEN @KeepHold = 1 AND [Status] = 'Pending'
                                   AND (HoldExpiresUtc IS NULL OR HoldExpiresUtc < @Until)
                              THEN @Until ELSE HoldExpiresUtc END
    WHERE BookingRef = @Ref;

    SELECT BookingRef, [Status], HoldExpiresUtc, PaymentCheckedUtc FROM booking.BOOKING WHERE BookingRef = @Ref;
END;
GO

/* ---- 9. The checkout session id (audit only; the session itself lives at the gateway) ------ */
CREATE OR ALTER PROCEDURE booking.usp_Booking_SetPaymentSession
    @Ref VARCHAR(12), @SessionId VARCHAR(60)
AS BEGIN SET NOCOUNT ON;
    UPDATE booking.BOOKING SET GatewaySessionId = @SessionId WHERE BookingRef = @Ref;
END;
GO

/* ---- 10. The reconciliation job's work list ----------------------------------------------
   Pending bookings whose payment was opened at least @OpenedMinutesAgo minutes ago and that carry no
   gateway payment line yet. UnconfirmedAlerted says whether staff were already told. */
CREATE OR ALTER PROCEDURE booking.usp_Booking_ListPaymentsToReconcile
    @OpenedMinutesAgo INT = 10
AS BEGIN SET NOCOUNT ON;
    SELECT b.BookingId, b.BookingRef, b.DepositDue, b.CurrencyCode, b.PaymentOpenedUtc, b.PaymentCheckedUtc, b.HoldExpiresUtc,
           CAST(CASE WHEN EXISTS (SELECT 1 FROM core.EMAIL_OUTBOX o
                                  WHERE o.BookingId = b.BookingId AND o.MailKind = 'PayUnconfirmed' AND o.Channel = 'Email')
                     THEN 1 ELSE 0 END AS BIT) AS UnconfirmedAlerted
    FROM booking.BOOKING b
    WHERE b.[Status] = 'Pending'
      AND b.PaymentOpenedUtc IS NOT NULL
      AND b.PaymentOpenedUtc <= DATEADD(MINUTE, -@OpenedMinutesAgo, SYSUTCDATETIME())
      AND NOT EXISTS (SELECT 1 FROM booking.BOOKING_PAYMENT p
                      WHERE p.BookingId = b.BookingId AND p.GatewayOrderId IS NOT NULL AND p.IsRefund = 0)
    ORDER BY b.PaymentOpenedUtc;
END;
GO

/* ---- 11. The sweep: never cancel a booking whose payment was opened ------------------------
   Unchanged from script 80 except the one line marked. A payment that was opened is settled by the
   reconciliation job, which asks the gateway first; the sweep only tidies holds nobody tried to pay. */
CREATE OR ALTER PROCEDURE booking.usp_Booking_ExpireHolds
    @ReturnRows BIT = 0
AS BEGIN SET NOCOUNT ON;
    DECLARE @Expired TABLE (BookingId INT NOT NULL, BookingRef VARCHAR(20) NULL);

    UPDATE b SET [Status] = 'Cancelled', CancelReason = N'Payment not completed in time.',
                 DecidedUtc = SYSUTCDATETIME(), HoldExpiresUtc = NULL
    OUTPUT inserted.BookingId, inserted.BookingRef INTO @Expired (BookingId, BookingRef)
    FROM booking.BOOKING b
    WHERE b.[Status] = 'Pending' AND b.HoldExpiresUtc IS NOT NULL AND b.HoldExpiresUtc < SYSUTCDATETIME()
      AND b.PaymentOpenedUtc IS NULL                                   -- script 88: the job settles these
      AND NOT EXISTS (SELECT 1 FROM booking.BOOKING_PAYMENT p WHERE p.BookingId = b.BookingId);

    IF @ReturnRows = 1
        SELECT BookingId, BookingRef FROM @Expired ORDER BY BookingId;
    ELSE
        SELECT COUNT(*) AS Expired FROM @Expired;
END;
GO

PRINT 'Script 88 applied.';
GO
