/* ============================================================================
   tests/qa3/booking/payment_gateways.sql - script 119 (docs/119_payment_gateways.sql).

   The gateways' keys and mode entered in HRMS, the payment log, the payments page's reads and the gateway tests.

     P1  keys: saved as a cipher per gateway and mode (the same row is replaced, never doubled), removed again;
         the mode in use is set, changed and handed back to the server file - each change leaves a line in the history
     P2  the log: a step is a row; the SAME check with the SAME answer is counted on its row (Repeats), a different
         answer is a new row; a step never needs a booking (a gateway test logs under its own reference)
     P3  the payments page: a booking whose payment was opened is listed as Open, in the mode it was opened in, read
         off its gateway order id as Whish; once paid it is Paid with the amount; cancelled with a refund due it is
         RefundDue; a refund makes it Refunded. A search finds it whatever the period. A booking nobody tried to pay
         online is not on the page at all.
     P4  gateway tests: opened, paid, refunded - a paid test is never un-paid by a later "cannot tell", a refunded one
         stays refunded - and never on the payments page
     P5  the three permissions exist

   One transaction, rolled back: nothing persists. RAISERROR on a wrong result; 'ok payment_gateways' otherwise.
   sqlcmd -I -b -i tests/qa3/booking/payment_gateways.sql
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
DECLARE @fail NVARCHAR(2000) = NULL, @Room INT, @D DATE, @Ref VARCHAR(12), @Bid INT, @Other INT, @OtherRef VARCHAR(12), @n INT;
DECLARE @made TABLE (BookingId INT, BookingRef VARCHAR(12), TotalAmount DECIMAL(10,2), DepositDue DECIMAL(10,2), DepositPercent DECIMAL(5,2), CurrencyCode CHAR(3), [Status] VARCHAR(12), Hours DECIMAL(6,2), RoomName NVARCHAR(80), RoomId INT, DiscountPercent DECIMAL(5,2), DiscountAmount DECIMAL(10,2));
DECLARE @sp TABLE (BookingId INT, BookingRef VARCHAR(12), DepositDue DECIMAL(10,2), CurrencyCode CHAR(3), TotalAmount DECIMAL(10,2), BookDate DATE, StartMin INT, EndMin INT, Hours DECIMAL(6,2), RoomName NVARCHAR(80), HoldExpiresUtc DATETIME2, PaymentOpenedUtc DATETIME2, PreviousOpenedUtc DATETIME2);
DECLARE @at TABLE (BookingId INT, BookingRef VARCHAR(12), ExternalId VARCHAR(40), Attempt INT, DepositDue DECIMAL(10,2), CurrencyCode CHAR(3), HoldExpiresUtc DATETIME2, PaymentOpenedUtc DATETIME2);
DECLARE @paid TABLE (Outcome VARCHAR(20), BookingId INT, BookingRef VARCHAR(12), [Status] VARCHAR(12), PaidAmount DECIMAL(10,2), BalanceDue DECIMAL(10,2));
DECLARE @rows TABLE (BookingId INT, BookingRef VARCHAR(12), Gateway VARCHAR(10), PayState VARCHAR(12), Mode VARCHAR(4), PaidAmount DECIMAL(10,2), RefundedAmount DECIMAL(10,2), GatewayOrderId VARCHAR(40));
DECLARE @From DATETIME2 = DATEADD(DAY, -1, SYSUTCDATETIME()), @To DATETIME2 = DATEADD(DAY, 1, SYSUTCDATETIME());
DECLARE @Long DATETIME2 = '2001-01-01', @LongTo DATETIME2 = '2001-01-02';

BEGIN TRAN;
BEGIN TRY
    DELETE FROM booking.GATEWAY_CONFIG; DELETE FROM booking.GATEWAY;

    /* ---- P1: keys and mode ---- */
    DECLARE @c1 VARBINARY(4000) = CAST(REPLICATE('a', 60) AS VARBINARY(4000)), @c2 VARBINARY(4000) = CAST(REPLICATE('b', 64) AS VARBINARY(4000));
    EXEC booking.usp_Gateway_SaveKeys @Gateway = 'whish', @Mode = 'test', @KeysCipher = @c1, @UserId = NULL;
    EXEC booking.usp_Gateway_SaveKeys @Gateway = 'whish', @Mode = 'test', @KeysCipher = @c2, @UserId = NULL;
    EXEC booking.usp_Gateway_SaveKeys @Gateway = 'whish', @Mode = 'live', @KeysCipher = @c1, @UserId = NULL;
    IF (SELECT COUNT(*) FROM booking.GATEWAY_CONFIG WHERE Gateway = 'whish') <> 2
       OR (SELECT KeysCipher FROM booking.GATEWAY_CONFIG WHERE Gateway = 'whish' AND Mode = 'test') <> @c2
        SET @fail = CONCAT(@fail, ' P1: saving the same mode twice did not replace its one row;');

    EXEC booking.usp_Gateway_SetMode @Gateway = 'whish', @Mode = 'live';
    EXEC booking.usp_Gateway_SetMode @Gateway = 'whish', @Mode = 'live';          -- the same again: no second history line
    IF (SELECT ActiveMode FROM booking.GATEWAY WHERE Gateway = 'whish') <> 'live'
        SET @fail = CONCAT(@fail, ' P1: the mode in use was not set;');
    EXEC booking.usp_Gateway_SetMode @Gateway = 'whish', @Mode = NULL;
    IF (SELECT ActiveMode FROM booking.GATEWAY WHERE Gateway = 'whish') IS NOT NULL
        SET @fail = CONCAT(@fail, ' P1: the mode was not handed back to the server file;');
    EXEC booking.usp_Gateway_DeleteKeys @Gateway = 'whish', @Mode = 'live';
    EXEC booking.usp_Gateway_DeleteKeys @Gateway = 'whish', @Mode = 'live';       -- nothing left to remove: no history line
    IF EXISTS (SELECT 1 FROM booking.GATEWAY_CONFIG WHERE Gateway = 'whish' AND Mode = 'live')
        SET @fail = CONCAT(@fail, ' P1: the live keys were not removed;');

    IF NOT EXISTS (SELECT 1 FROM booking.PAYMENT_EVENT WHERE Gateway = 'whish' AND EventType = 'ModeChanged' AND Detail = N'from the server file to live')
       OR NOT EXISTS (SELECT 1 FROM booking.PAYMENT_EVENT WHERE Gateway = 'whish' AND EventType = 'ModeChanged' AND Detail = N'from live to the server file')
        SET @fail = CONCAT(@fail, ' P1: the history does not say from what to what the mode changed;');

    SET @n = (SELECT COUNT(*) FROM booking.PAYMENT_EVENT WHERE Gateway = 'whish' AND EventType IN ('KeysSaved', 'KeysRemoved', 'ModeChanged') AND CreatedAtUtc >= @From);
    IF @n <> 6          -- 3 saves, 2 mode changes (live, back to the server file), 1 removal
        SET @fail = CONCAT(@fail, ' P1: the history holds ', @n, ' lines, not 6;');

    /* ---- P2: the log ---- */
    EXEC booking.usp_PaymentEvent_Add @Gateway = 'card', @EventType = 'Checked', @Source = 'Job', @TestRef = 'GT-QA3TEST1', @Outcome = 'Unconfirmed', @GatewayStatus = N'pending';
    EXEC booking.usp_PaymentEvent_Add @Gateway = 'card', @EventType = 'Checked', @Source = 'Job', @TestRef = 'GT-QA3TEST1', @Outcome = 'Unconfirmed', @GatewayStatus = N'pending';
    EXEC booking.usp_PaymentEvent_Add @Gateway = 'card', @EventType = 'Checked', @Source = 'Job', @TestRef = 'GT-QA3TEST1', @Outcome = 'Unconfirmed', @GatewayStatus = N'pending';
    IF (SELECT CONCAT(COUNT(*), '|', MAX(Repeats)) FROM booking.PAYMENT_EVENT WHERE TestRef = 'GT-QA3TEST1') <> '1|3'
        SET @fail = CONCAT(@fail, ' P2: the same check with the same answer was not counted on one row;');
    EXEC booking.usp_PaymentEvent_Add @Gateway = 'card', @EventType = 'Checked', @Source = 'Job', @TestRef = 'GT-QA3TEST1', @Outcome = 'Failed', @GatewayStatus = N'FAILURE / FAILED';
    EXEC booking.usp_PaymentEvent_Add @Gateway = 'card', @EventType = 'Checked', @Source = 'Staff', @TestRef = 'GT-QA3TEST1', @Outcome = 'Failed', @GatewayStatus = N'FAILURE / FAILED';
    EXEC booking.usp_PaymentEvent_Add @Gateway = 'card', @EventType = 'Released', @Source = 'Job', @TestRef = 'GT-QA3TEST1', @Outcome = 'Released';
    EXEC booking.usp_PaymentEvent_Add @Gateway = 'card', @EventType = 'Released', @Source = 'Job', @TestRef = 'GT-QA3TEST1', @Outcome = 'Released';
    IF (SELECT COUNT(*) FROM booking.PAYMENT_EVENT WHERE TestRef = 'GT-QA3TEST1') <> 5
        SET @fail = CONCAT(@fail, ' P2: a different answer, another asker or a step that is not a check must each be a row of its own;');

    /* ---- P3: the payments page ---- */
    UPDATE core.SETTING SET SettingValue = '60' WHERE SettingKey IN ('BookingSlotMinutes', 'BookingLeadMaxDays');
    UPDATE core.SETTING SET SettingValue = '1'  WHERE SettingKey = 'BookingLeadMinHours';
    UPDATE core.SETTING SET SettingValue = '0'  WHERE SettingKey = 'BookingAutoConfirm';
    UPDATE core.SETTING SET SettingValue = '1'  WHERE SettingKey = 'BookingDepositRequired';

    INSERT INTO booking.ROOM (Code, [Name], Seats, MinPersons, PricePerHour, MinHours, MaxHours, SortOrder, IsActive)
    VALUES ('qa3-pg', N'QA3 gateway room', 6, 1, 20, 1, 6, 999, 1);
    SET @Room = SCOPE_IDENTITY();
    INSERT INTO booking.ROOM_HOURS (RoomId, DayOfWeek, OpenTime, CloseTime, IsClosed)
    SELECT @Room, d, '07:00', '01:00', 0 FROM (VALUES (1),(2),(3),(4),(5),(6),(7)) v(d);
    SET @D = DATEADD(DAY, 10, CAST(booking.fn_LocalNow() AS DATE));

    INSERT INTO @made EXEC booking.usp_Booking_Create @RoomId = @Room, @BookDate = @D, @StartTime = '10:00', @EndTime = '12:00',
         @Persons = 2, @GuestName = N'QA3 Gateways', @GuestPhone = '+96170000319', @Source = 'Website';
    SELECT @Ref = BookingRef, @Bid = BookingId FROM @made;
    DELETE FROM @made;
    INSERT INTO @made EXEC booking.usp_Booking_Create @RoomId = @Room, @BookDate = @D, @StartTime = '14:00', @EndTime = '15:00',
         @Persons = 2, @GuestName = N'QA3 Nobody paid', @GuestPhone = '+96170000320', @Source = 'Website';
    SELECT @OtherRef = BookingRef, @Other = BookingId FROM @made;

    -- nobody tried to pay either of them: neither is on the page
    IF EXISTS (SELECT 1 FROM booking.fn_OnlinePaymentRows(30) WHERE BookingId IN (@Bid, @Other))
        SET @fail = CONCAT(@fail, ' P3: a booking no payment was opened for is on the payments page;');

    -- opened on Whish, in live mode
    INSERT INTO @sp EXEC booking.usp_Booking_StartPayment @Ref = @Ref;
    INSERT INTO @at EXEC booking.usp_Booking_StartWhishAttempt @Ref = @Ref;
    EXEC booking.usp_Booking_SetPaymentMode @Ref = @Ref, @Mode = 'live';
    EXEC booking.usp_Booking_SetPaymentMode @Ref = @OtherRef, @Mode = 'live';      -- no payment was opened on it: not written
    IF (SELECT PaymentMode FROM booking.BOOKING WHERE BookingId = @Other) IS NOT NULL
        SET @fail = CONCAT(@fail, ' P3: a mode was noted on a booking no payment was opened for;');

    INSERT INTO @rows SELECT BookingId, BookingRef, Gateway, PayState, Mode, PaidAmount, RefundedAmount, GatewayOrderId FROM booking.fn_OnlinePaymentRows(30) WHERE BookingId = @Bid;
    IF NOT EXISTS (SELECT 1 FROM @rows WHERE Gateway = 'whish' AND PayState = 'Open' AND Mode = 'live' AND PaidAmount IS NULL AND GatewayOrderId = CONCAT(@Ref, '-A1'))
        SET @fail = CONCAT(@fail, ' P3: an opened Whish attempt does not read Open / whish / live;');
    -- opened 45 minutes ago and still not settled: past the patience (30 minutes) it reads Unconfirmed
    UPDATE booking.BOOKING SET PaymentOpenedUtc = DATEADD(MINUTE, -45, SYSUTCDATETIME()) WHERE BookingId = @Bid;
    IF NOT EXISTS (SELECT 1 FROM booking.fn_OnlinePaymentRows(30) WHERE BookingId = @Bid AND PayState = 'Unconfirmed')
       OR NOT EXISTS (SELECT 1 FROM booking.fn_OnlinePaymentRows(60) WHERE BookingId = @Bid AND PayState = 'Open')
        SET @fail = CONCAT(@fail, ' P3: a payment opened longer ago than the patience does not read Unconfirmed (or one within it not Open);');

    -- paid
    DECLARE @Deposit DECIMAL(10,2) = (SELECT DepositDue FROM booking.BOOKING WHERE BookingId = @Bid);
    DECLARE @Ext VARCHAR(40) = CONCAT(@Ref, '-A1');
    INSERT INTO @paid EXEC booking.usp_Booking_ConfirmOnlinePayment @Ref = @Ref, @Amount = @Deposit, @CurrencyCode = 'USD',
         @GatewayOrderId = @Ext, @TransactionId = '96170000319', @MethodName = N'Whish';
    EXEC booking.usp_PaymentEvent_Add @Gateway = 'whish', @EventType = 'Paid', @Source = 'Return', @BookingRef = @Ref, @Mode = 'live', @GatewayOrderId = @Ext, @Outcome = 'Confirmed', @Amount = @Deposit, @CurrencyCode = 'USD';
    DELETE FROM @rows;
    INSERT INTO @rows SELECT BookingId, BookingRef, Gateway, PayState, Mode, PaidAmount, RefundedAmount, GatewayOrderId FROM booking.fn_OnlinePaymentRows(30) WHERE BookingId = @Bid;
    IF NOT EXISTS (SELECT 1 FROM @rows WHERE Gateway = 'whish' AND PayState = 'Paid' AND Mode = 'live' AND PaidAmount = @Deposit)
        SET @fail = CONCAT(@fail, ' P3: a paid deposit does not read Paid with its amount;');

    -- the list: in the period, by gateway, by state, by search - and a search looks at every date
    DECLARE @list TABLE (BookingId INT);
    INSERT INTO @list SELECT BookingId FROM booking.fn_OnlinePaymentRows(30) p WHERE p.ActivityUtc >= @From AND p.ActivityUtc < @To AND p.Gateway = 'whish' AND p.PayState = 'Paid';
    IF NOT EXISTS (SELECT 1 FROM @list WHERE BookingId = @Bid) SET @fail = CONCAT(@fail, ' P3: the paid booking is not in its own period;');
    CREATE TABLE #pl (BookingId INT, BookingRef VARCHAR(12), GuestName NVARCHAR(120), GuestPhone VARCHAR(30), RoomName NVARCHAR(80), BookDate DATE, StartMin INT, EndMin INT,
        BookingStatus VARCHAR(12), DepositDue DECIMAL(10,2), TotalAmount DECIMAL(10,2), CurrencyCode CHAR(3), PaymentOpenedUtc DATETIME2, PaymentCheckedUtc DATETIME2,
        HoldExpiresUtc DATETIME2, Attempts INT, PayerPhone VARCHAR(30), RefundAmount DECIMAL(10,2), RefundStatus VARCHAR(10), RefundedUtc DATETIME2, PaymentId INT,
        PaidAmount DECIMAL(10,2), PaidUtc DATETIME2, TransactionId VARCHAR(60), GatewayOrderId VARCHAR(40), ActivityUtc DATETIME2, Gateway VARCHAR(10), PayState VARCHAR(12),
        RefundedAmount DECIMAL(10,2), Mode VARCHAR(4), GatewayRefunded BIT, LastEventType VARCHAR(20), LastOutcome VARCHAR(20), LastDetail NVARCHAR(400), LastEventUtc DATETIME2);
    INSERT INTO #pl EXEC booking.usp_OnlinePayment_List @FromUtc = @Long, @ToUtc = @LongTo;
    IF EXISTS (SELECT 1 FROM #pl WHERE BookingId = @Bid) SET @fail = CONCAT(@fail, ' P3: the booking is listed in a period it was not paid in;');
    DELETE FROM #pl;
    INSERT INTO #pl EXEC booking.usp_OnlinePayment_List @FromUtc = @Long, @ToUtc = @LongTo, @Search = @Ref;
    IF NOT EXISTS (SELECT 1 FROM #pl WHERE BookingId = @Bid AND LastEventType = 'Paid' AND LastOutcome = 'Confirmed')
        SET @fail = CONCAT(@fail, ' P3: a search by reference did not find the booking outside the period, with its last step;');
    DELETE FROM #pl;
    INSERT INTO #pl EXEC booking.usp_OnlinePayment_List @FromUtc = @From, @ToUtc = @To, @Gateway = 'card';
    IF EXISTS (SELECT 1 FROM #pl WHERE BookingId = @Bid) SET @fail = CONCAT(@fail, ' P3: a Whish payment is listed under the card;');

    -- cancelled by staff: everything paid is owed back
    UPDATE booking.BOOKING SET [Status] = 'Cancelled', CancelledBy = 'Staff', CancelReason = N'qa3', RefundAmount = @Deposit, RefundStatus = 'Due' WHERE BookingId = @Bid;
    IF NOT EXISTS (SELECT 1 FROM booking.fn_OnlinePaymentRows(30) WHERE BookingId = @Bid AND PayState = 'RefundDue')
        SET @fail = CONCAT(@fail, ' P3: a paid then cancelled booking does not read RefundDue;');

    -- refunded, through the procedure every refund goes through
    DECLARE @Whish INT = (SELECT TOP 1 PaymentMethodId FROM booking.PAYMENT_METHOD WHERE [Name] = N'Whish' ORDER BY PaymentMethodId);
    DECLARE @Why NVARCHAR(80) = CONCAT(N'Whish refund ', @Ext);
    DECLARE @rf TABLE (PaymentId INT, RefundedTotal DECIMAL(10,2), RefundDue DECIMAL(10,2), RefundStatus VARCHAR(10));
    INSERT INTO @rf EXEC booking.usp_Refund_Add @BookingId = @Bid, @Amount = @Deposit, @PaymentMethodId = @Whish, @Reference = @Why;
    EXEC booking.usp_PaymentEvent_Add @Gateway = 'whish', @EventType = 'Refunded', @Source = 'Staff', @BookingRef = @Ref, @Mode = 'live', @GatewayOrderId = @Ext, @Outcome = 'Refunded', @Amount = @Deposit;
    IF NOT EXISTS (SELECT 1 FROM booking.fn_OnlinePaymentRows(30) WHERE BookingId = @Bid AND PayState = 'Refunded' AND RefundedAmount = @Deposit AND GatewayRefunded = 1)
        SET @fail = CONCAT(@fail, ' P3: a refunded payment does not read Refunded with what was given back;');

    -- one payment: its row, its log (two steps), its money lines (the payment and the refund)
    CREATE TABLE #ev (PaymentEventId BIGINT, Gateway VARCHAR(10), Mode VARCHAR(4), GatewayOrderId VARCHAR(40), EventType VARCHAR(20), Source VARCHAR(12), Outcome VARCHAR(20),
        GatewayStatus NVARCHAR(80), Detail NVARCHAR(400), Amount DECIMAL(10,2), CurrencyCode CHAR(3), Repeats INT, CreatedAtUtc DATETIME2, LastAtUtc DATETIME2, UserName NVARCHAR(200));
    INSERT INTO #ev SELECT e.PaymentEventId, e.Gateway, e.Mode, e.GatewayOrderId, e.EventType, e.Source, e.Outcome, e.GatewayStatus, e.Detail, e.Amount, e.CurrencyCode,
                           e.Repeats, e.CreatedAtUtc, e.LastAtUtc, NULL FROM booking.PAYMENT_EVENT e WHERE e.BookingRef = @Ref;
    IF (SELECT STRING_AGG(EventType, ',') WITHIN GROUP (ORDER BY PaymentEventId) FROM #ev) <> 'Paid,Refunded'
        SET @fail = CONCAT(@fail, ' P3: the log of the payment is not Paid then Refunded;');
    IF (SELECT COUNT(*) FROM booking.BOOKING_PAYMENT WHERE BookingId = @Bid) <> 2
        SET @fail = CONCAT(@fail, ' P3: the booking does not carry its payment and its refund;');

    /* ---- P4: gateway tests ---- */
    DECLARE @t TABLE (TestId INT, TestRef VARCHAR(12), Gateway VARCHAR(10), Mode VARCHAR(4), Amount DECIMAL(10,2), CurrencyCode CHAR(3), [Status] VARCHAR(12), GatewayStatus NVARCHAR(80),
        Detail NVARCHAR(400), PayUrl NVARCHAR(600), ReturnUrl NVARCHAR(300), PayerPhone VARCHAR(30), TransactionId VARCHAR(60), CallbackAtUtc DATETIME2, ReturnedAtUtc DATETIME2,
        CheckedAtUtc DATETIME2, RefundedAtUtc DATETIME2, CreatedByUserId INT, CreatedAtUtc DATETIME2, CreatedBy NVARCHAR(200));
    INSERT INTO @t EXEC booking.usp_GatewayTest_Add @TestRef = 'GT-QA3TEST2', @Gateway = 'whish', @Mode = 'test', @Amount = 1, @CurrencyCode = 'USD', @ReturnUrl = N'https://hrms.example.test/bookings/gateway-test?test=GT-QA3TEST2';
    IF NOT EXISTS (SELECT 1 FROM @t WHERE [Status] = 'Opened' AND Amount = 1) SET @fail = CONCAT(@fail, ' P4: a new test is not Opened;');
    DELETE FROM @t;
    INSERT INTO @t EXEC booking.usp_GatewayTest_Update @TestRef = 'GT-QA3TEST2', @Status = 'Paid', @GatewayStatus = N'success', @PayerPhone = '96170000000', @Checked = 1, @Callback = 1;
    DELETE FROM @t;
    INSERT INTO @t EXEC booking.usp_GatewayTest_Update @TestRef = 'GT-QA3TEST2', @Status = 'Unknown', @GatewayStatus = N'no answer (timed out)', @Checked = 1;
    IF NOT EXISTS (SELECT 1 FROM @t WHERE [Status] = 'Paid' AND PayerPhone = '96170000000' AND CallbackAtUtc IS NOT NULL AND CheckedAtUtc IS NOT NULL)
        SET @fail = CONCAT(@fail, ' P4: a paid test was un-paid by a later "cannot tell";');
    DELETE FROM @t;
    INSERT INTO @t EXEC booking.usp_GatewayTest_Update @TestRef = 'GT-QA3TEST2', @Refunded = 1;
    DELETE FROM @t;
    INSERT INTO @t EXEC booking.usp_GatewayTest_Update @TestRef = 'GT-QA3TEST2', @Status = 'Paid', @Checked = 1;
    IF NOT EXISTS (SELECT 1 FROM @t WHERE [Status] = 'Refunded' AND RefundedAtUtc IS NOT NULL)
        SET @fail = CONCAT(@fail, ' P4: a refunded test did not stay refunded;');
    IF EXISTS (SELECT 1 FROM booking.fn_OnlinePaymentRows(30) WHERE BookingRef LIKE 'GT-%' OR GatewayOrderId LIKE 'GT-%')
        SET @fail = CONCAT(@fail, ' P4: a gateway test is on the payments page;');

    /* ---- P5: the permissions ---- */
    IF (SELECT COUNT(*) FROM security.PERMISSION WHERE Code IN ('BOOKING_PAYMENTS', 'BOOKING_PAYMENTS_MANAGE', 'GATEWAY_ADMIN') AND Module = 'Booking') <> 3
        SET @fail = CONCAT(@fail, ' P5: the three permissions are not all there;');
END TRY
BEGIN CATCH
    SET @fail = CONCAT(@fail, ' ERROR ', ERROR_NUMBER(), ' line ', ERROR_LINE(), ': ', ERROR_MESSAGE());
END CATCH
IF @@TRANCOUNT > 0 ROLLBACK;

IF @fail IS NOT NULL
BEGIN
    RAISERROR('payment_gateways FAILED:%s', 16, 1, @fail);
END
ELSE PRINT 'ok payment_gateways';
