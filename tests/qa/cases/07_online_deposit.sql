/* ============================================================================
   cases/07_online_deposit.sql — SQL 88 (online deposits, MPGS) at procedure level.

   D1  usp_Booking_StartPayment stamps the hold and PaymentOpenedUtc in one go
   D2  THE REPLAY: usp_Booking_ConfirmOnlinePayment called twice for the same gateway order
       (a refreshed return page, the reconciliation job, a double return) → ONE payment line,
       outcomes Confirmed then Replay, the booking Confirmed once
   D3  the unique key refuses a second line for the same gateway order even outside the procedure
   D4  THE RACE: usp_Booking_ExpireHolds leaves a lapsed hold alone when its payment was opened,
       and still cancels a lapsed hold nobody tried to pay (@ReturnRows = 1 contract of script 80)
   D5  usp_Booking_ListPaymentsToReconcile lists the opened, unsettled one and not the paid one
   D6  paying an already-paid booking is refused ('already been paid' → 409 already_paid)

   Everything runs inside ONE transaction that is rolled back: the three throw-away bookings (on
   2099-06-15, a Monday), their payment line and the outbox rows the triggers write never persist.
   The results are kept in variables and recorded with QA_Check after the rollback.
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT OFF;     -- D3 expects a statement-level unique-key error inside the open transaction
DECLARE @Room INT = (SELECT RoomId FROM booking.ROOM WHERE Code = 'qa-room');
IF @Room IS NULL
    SET @Room = (SELECT TOP 1 r.RoomId FROM booking.ROOM r
                 WHERE r.IsActive = 1 AND EXISTS (SELECT 1 FROM booking.ROOM_HOURS h WHERE h.RoomId = r.RoomId AND h.DayOfWeek = 1
                                                  AND h.IsClosed = 0 AND h.OpenMin <= 600 AND h.CloseMin >= 960)
                 ORDER BY r.SortOrder);
DECLARE @Day DATE = '2099-06-15';
DECLARE @a1 NVARCHAR(600) = N'not run', @p1 BIT = 0, @a2 NVARCHAR(600) = N'not run', @p2 BIT = 0,
        @a3 NVARCHAR(600) = N'not run', @p3 BIT = 0, @a4 NVARCHAR(600) = N'not run', @p4 BIT = 0,
        @a5 NVARCHAR(600) = N'not run', @p5 BIT = 0, @a6 NVARCHAR(600) = N'not run', @p6 BIT = 0;
DECLARE @HoldMin INT = ISNULL(TRY_CAST((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'BookingHoldMinutes') AS INT), 15);

DECLARE @made TABLE (BookingId INT, BookingRef VARCHAR(12), TotalAmount DECIMAL(10,2), DepositDue DECIMAL(10,2), DepositPercent DECIMAL(5,2), CurrencyCode CHAR(3), [Status] VARCHAR(12), Hours DECIMAL(6,2), RoomName NVARCHAR(80), RoomId INT, DiscountPercent DECIMAL(5,2), DiscountAmount DECIMAL(10,2));
DECLARE @sp TABLE (BookingId INT, BookingRef VARCHAR(12), DepositDue DECIMAL(10,2), CurrencyCode CHAR(3), TotalAmount DECIMAL(10,2), BookDate DATE, StartMin INT, EndMin INT, Hours DECIMAL(6,2), RoomName NVARCHAR(80), HoldExpiresUtc DATETIME2, PaymentOpenedUtc DATETIME2, PreviousOpenedUtc DATETIME2);
DECLARE @cf TABLE (Seq INT IDENTITY(1,1), Outcome VARCHAR(20), BookingId INT, BookingRef VARCHAR(12), [Status] VARCHAR(12), PaidAmount DECIMAL(10,2), BalanceDue DECIMAL(10,2));
DECLARE @ex TABLE (BookingId INT, BookingRef VARCHAR(20));
DECLARE @rc TABLE (BookingId INT, BookingRef VARCHAR(12), DepositDue DECIMAL(10,2), CurrencyCode CHAR(3), PaymentOpenedUtc DATETIME2, PaymentCheckedUtc DATETIME2, HoldExpiresUtc DATETIME2, UnconfirmedAlerted BIT);
DECLARE @BidA INT, @RefA VARCHAR(12), @BidB INT, @RefB VARCHAR(12), @BidC INT, @RefC VARCHAR(12), @Dep DECIMAL(10,2), @n INT;

BEGIN TRAN;
BEGIN TRY
    /* three website bookings waiting for payment: made as staff bookings (no lead-time rules this far out), then turned Pending/Website */
    INSERT INTO @made EXEC booking.usp_Booking_Create @RoomId = @Room, @BookDate = @Day, @StartTime = '10:00', @EndTime = '12:00', @Persons = 1, @GuestName = N'QA Deposit A', @GuestPhone = '+96170000071', @Source = 'Manual';
    INSERT INTO @made EXEC booking.usp_Booking_Create @RoomId = @Room, @BookDate = @Day, @StartTime = '13:00', @EndTime = '14:00', @Persons = 1, @GuestName = N'QA Deposit B', @GuestPhone = '+96170000072', @Source = 'Manual';
    INSERT INTO @made EXEC booking.usp_Booking_Create @RoomId = @Room, @BookDate = @Day, @StartTime = '15:00', @EndTime = '16:00', @Persons = 1, @GuestName = N'QA Deposit C', @GuestPhone = '+96170000073', @Source = 'Manual';
    SELECT @BidA = MIN(BookingId) FROM @made;                        SELECT @RefA = BookingRef FROM @made WHERE BookingId = @BidA;
    SELECT @BidB = MIN(BookingId) FROM @made WHERE BookingId > @BidA;  SELECT @RefB = BookingRef FROM @made WHERE BookingId = @BidB;
    SELECT @BidC = MAX(BookingId) FROM @made;                        SELECT @RefC = BookingRef FROM @made WHERE BookingId = @BidC;
    UPDATE booking.BOOKING SET [Status] = 'Pending', [Source] = 'Website' WHERE BookingId IN (@BidA, @BidB, @BidC);

    /* D1 */
    INSERT INTO @sp EXEC booking.usp_Booking_StartPayment @Ref = @RefA;
    SELECT @Dep = DepositDue FROM @sp;
    SELECT @a1 = CONCAT('deposit=', b.DepositDue, ' holdMinutes=', DATEDIFF(MINUTE, b.PaymentOpenedUtc, b.HoldExpiresUtc),
                        ' opened=', CASE WHEN b.PaymentOpenedUtc IS NULL THEN 'NULL' ELSE 'set' END,
                        ' orderId=', CASE WHEN b.GatewayOrderId = b.BookingRef THEN 'ref' ELSE ISNULL(b.GatewayOrderId, 'NULL') END,
                        ' previous=', CASE WHEN s.PreviousOpenedUtc IS NULL THEN 'NULL' ELSE 'set' END),
           @p1 = CASE WHEN b.PaymentOpenedUtc IS NOT NULL AND DATEDIFF(MINUTE, b.PaymentOpenedUtc, b.HoldExpiresUtc) = @HoldMin
                           AND b.GatewayOrderId = b.BookingRef AND s.DepositDue = b.DepositDue AND s.PreviousOpenedUtc IS NULL THEN 1 ELSE 0 END
    FROM booking.BOOKING b CROSS JOIN @sp s WHERE b.BookingId = @BidA;

    /* D2: the replay */
    INSERT INTO @cf (Outcome, BookingId, BookingRef, [Status], PaidAmount, BalanceDue)
        EXEC booking.usp_Booking_ConfirmOnlinePayment @Ref = @RefA, @Amount = @Dep, @CurrencyCode = 'USD', @GatewayOrderId = @RefA, @TransactionId = 'QA-TXN-1';
    INSERT INTO @cf (Outcome, BookingId, BookingRef, [Status], PaidAmount, BalanceDue)
        EXEC booking.usp_Booking_ConfirmOnlinePayment @Ref = @RefA, @Amount = @Dep, @CurrencyCode = 'USD', @GatewayOrderId = @RefA, @TransactionId = 'QA-TXN-1';
    SELECT @n = COUNT(*) FROM booking.BOOKING_PAYMENT WHERE BookingId = @BidA;
    SELECT @a2 = CONCAT('outcomes=', (SELECT STRING_AGG(Outcome, ',') WITHIN GROUP (ORDER BY Seq) FROM @cf),
                        ' lines=', @n, ' status=', b.[Status],
                        ' paid=', (SELECT SUM(Amount) FROM booking.BOOKING_PAYMENT WHERE BookingId = @BidA),
                        ' line=', (SELECT TOP 1 CONCAT(pm.[Name], '/', p.CurrencyCode, '/', p.GatewayTransactionId) FROM booking.BOOKING_PAYMENT p JOIN booking.PAYMENT_METHOD pm ON pm.PaymentMethodId = p.PaymentMethodId WHERE p.BookingId = @BidA),
                        ' confirmations queued=', (SELECT COUNT(*) FROM core.EMAIL_OUTBOX WHERE BookingId = @BidA AND MailKind = 'Confirmation' AND Channel = 'Email')),
           @p2 = CASE WHEN @n = 1 AND b.[Status] = 'Confirmed'
                           AND (SELECT STRING_AGG(Outcome, ',') WITHIN GROUP (ORDER BY Seq) FROM @cf) = 'Confirmed,Replay'
                           AND (SELECT SUM(Amount) FROM booking.BOOKING_PAYMENT WHERE BookingId = @BidA) = @Dep THEN 1 ELSE 0 END
    FROM booking.BOOKING b WHERE b.BookingId = @BidA;

    /* D3: the unique key, bypassing the procedure */
    BEGIN TRY
        INSERT INTO booking.BOOKING_PAYMENT (BookingId, PaymentMethodId, Amount, Reference, IsRefund, GatewayOrderId, GatewayTransactionId, CurrencyCode)
        VALUES (@BidA, (SELECT PaymentMethodId FROM booking.PAYMENT_METHOD WHERE [Name] = N'Card (MPGS)'), @Dep, N'QA duplicate', 0, @RefA, 'QA-TXN-2', 'USD');
        SET @a3 = N'second line was ACCEPTED';
    END TRY
    BEGIN CATCH
        SET @a3 = CONCAT('refused: error ', ERROR_NUMBER(), CASE WHEN ERROR_MESSAGE() LIKE '%UX_BOOKING_PAYMENT_GatewayOrder%' THEN ' on UX_BOOKING_PAYMENT_GatewayOrder' ELSE '' END);
        SET @p3 = CASE WHEN ERROR_NUMBER() IN (2601, 2627) AND ERROR_MESSAGE() LIKE '%UX_BOOKING_PAYMENT_GatewayOrder%' THEN 1 ELSE 0 END;
    END CATCH;

    /* D4: B's hold lapsed while its payment was open; C's lapsed with no payment ever opened */
    UPDATE booking.BOOKING SET HoldExpiresUtc = DATEADD(MINUTE, -1, SYSUTCDATETIME()), PaymentOpenedUtc = DATEADD(MINUTE, -20, SYSUTCDATETIME()), GatewayOrderId = BookingRef WHERE BookingId = @BidB;
    UPDATE booking.BOOKING SET HoldExpiresUtc = DATEADD(MINUTE, -1, SYSUTCDATETIME()) WHERE BookingId = @BidC;
    INSERT INTO @ex EXEC booking.usp_Booking_ExpireHolds @ReturnRows = 1;
    SELECT @a4 = CONCAT('B(payment opened)=', (SELECT [Status] FROM booking.BOOKING WHERE BookingId = @BidB),
                        CASE WHEN EXISTS (SELECT 1 FROM @ex WHERE BookingId = @BidB) THEN ' listed' ELSE ' not listed' END,
                        '; C(never opened)=', (SELECT [Status] FROM booking.BOOKING WHERE BookingId = @BidC),
                        CASE WHEN EXISTS (SELECT 1 FROM @ex WHERE BookingId = @BidC AND BookingRef = @RefC) THEN ' listed' ELSE ' not listed' END),
           @p4 = CASE WHEN (SELECT [Status] FROM booking.BOOKING WHERE BookingId = @BidB) = 'Pending' AND NOT EXISTS (SELECT 1 FROM @ex WHERE BookingId = @BidB)
                           AND (SELECT [Status] FROM booking.BOOKING WHERE BookingId = @BidC) = 'Cancelled' AND EXISTS (SELECT 1 FROM @ex WHERE BookingId = @BidC AND BookingRef = @RefC)
                      THEN 1 ELSE 0 END;

    /* D5 */
    INSERT INTO @rc EXEC booking.usp_Booking_ListPaymentsToReconcile @OpenedMinutesAgo = 10;
    SET @a5 = CONCAT('B ', CASE WHEN EXISTS (SELECT 1 FROM @rc WHERE BookingId = @BidB) THEN 'listed' ELSE 'not listed' END,
                     '; A(paid) ', CASE WHEN EXISTS (SELECT 1 FROM @rc WHERE BookingId = @BidA) THEN 'listed' ELSE 'not listed' END);
    SET @p5 = CASE WHEN EXISTS (SELECT 1 FROM @rc WHERE BookingId = @BidB) AND NOT EXISTS (SELECT 1 FROM @rc WHERE BookingId = @BidA) THEN 1 ELSE 0 END;

    /* D6: last, a refusal */
    BEGIN TRY
        EXEC booking.usp_Booking_StartPayment @Ref = @RefA;
        SET @a6 = N'accepted';
    END TRY
    BEGIN CATCH
        SET @a6 = ERROR_MESSAGE();
        SET @p6 = CASE WHEN ERROR_MESSAGE() LIKE 'This booking has already been paid%' THEN 1 ELSE 0 END;
    END CATCH;
END TRY
BEGIN CATCH
    SET @a1 = CONCAT(@a1, ' | aborted: ', ERROR_MESSAGE());
END CATCH;
IF @@TRANCOUNT > 0 ROLLBACK;

EXEC dbo.QA_Check 'D1', 'usp_Booking_StartPayment on a Pending website booking stamps HoldExpiresUtc = now + BookingHoldMinutes and PaymentOpenedUtc, order id = the reference, deposit = the priced DepositDue', 'holdMinutes = BookingHoldMinutes, opened=set, orderId=ref, previous=NULL', @a1, @p1;
EXEC dbo.QA_Check 'D2', 'replay: usp_Booking_ConfirmOnlinePayment twice for the same gateway order records ONE payment line and confirms once', 'outcomes=Confirmed,Replay lines=1 status=Confirmed paid=deposit', @a2, @p2;
EXEC dbo.QA_Check 'D3', 'a second payment line for the same gateway order is refused by UX_BOOKING_PAYMENT_GatewayOrder even when inserted directly', 'refused: error 2601 on UX_BOOKING_PAYMENT_GatewayOrder', @a3, @p3;
EXEC dbo.QA_Check 'D4', 'usp_Booking_ExpireHolds leaves a lapsed hold with PaymentOpenedUtc set to the reconciliation job, and still cancels a lapsed hold nobody tried to pay', 'B(payment opened)=Pending not listed; C(never opened)=Cancelled listed', @a4, @p4;
EXEC dbo.QA_Check 'D5', 'usp_Booking_ListPaymentsToReconcile lists an opened, unsettled payment and not a paid one', 'B listed; A(paid) not listed', @a5, @p5;
EXEC dbo.QA_Check 'D6', 'usp_Booking_StartPayment on a booking that already carries its gateway payment is refused', 'This booking has already been paid.', @a6, @p6;
GO
