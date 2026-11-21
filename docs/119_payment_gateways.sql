/* ============================================================================
   119_payment_gateways.sql - THE PAYMENT GATEWAYS IN HRMS: THEIR KEYS, THE PAYMENT LOG, THE PAYMENTS PAGE, THE TESTS.

   Until now the keys of the two gateways (the card: Bank of Beirut, MPGS; and Whish) lived only in the server
   file /etc/mokaco/api.env, nothing recorded what happened to an online payment between "opened" and "paid", and
   a gateway could only be tried through the website. This script adds what four screens need:

   1. KEYS ENTERED IN HRMS (Settings > Payment gateways), for TEST and for LIVE, each gateway:
        booking.GATEWAY          which mode a gateway works in ('test' | 'live'; NULL = as the server file says)
        booking.GATEWAY_CONFIG   the keys of one gateway in one mode, ENCRYPTED BY THE API before they are stored
                                 (AES-256-GCM with a key the database never sees: it is derived from the server's
                                 own signing key). This table holds no readable secret, and a copy of the database
                                 restored on another server cannot use them.
      Nothing is saved = everything works as before, from the server file.

      booking.BOOKING.PaymentMode says in which mode a booking's payment was opened: it is settled, and refunded,
      with the keys of THAT mode, so switching a gateway to test never loses sight of a live payment in flight.

   2. THE PAYMENT LOG
        booking.PAYMENT_EVENT    one row per step of an online payment: opened, the gateway asked (by the guest's
                                 return, the gateway's callback, the job, a member of staff), paid, released,
                                 refunded - with what the gateway said, in which mode, and who did it. Never a key.
                                 The same check with the same answer is counted on one row (Repeats), so a payment
                                 the job asks about every five minutes does not fill the table.

   3. THE PAYMENTS PAGE (Bookings > Payments)
        booking.fn_PaymentRows       every booking an online payment was opened or recorded for, with its state
        booking.usp_Payment_List     the page's list
        booking.usp_Payment_Get      one payment: the row, its log, the booking's money lines

   4. THE GATEWAY TESTS (Settings > Gateway test)
        booking.GATEWAY_TEST     a test payment opened from HRMS (reference GT-XXXXXXXX): never a booking, never
                                 on the payments page, never in the bookings report.

   THREE PERMISSIONS (Security > Role permissions, card Booking), granted once - on the run that creates each:
     BOOKING_PAYMENTS          see the online payments: history and log        -> Admin roles, Owner, General Manager
     BOOKING_PAYMENTS_MANAGE   act on one: ask the gateway again, refund       -> Admin roles, Owner, General Manager
     GATEWAY_ADMIN             the gateways' keys, mode and the test page      -> Admin roles and Owner only

   NOT CHANGED: BookingWhishEnabled and BookingDepositRequired stay as they are (off until somebody turns them on).

   The MARKER of this script for the deploy guard is booking.usp_GatewayTest_List, the last procedure it creates.

   Idempotent. Apply: sqlcmd -C -I -b -d <database> -i docs/119_payment_gateways.sql
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF OBJECT_ID('booking.usp_Booking_SetWhishPayer') IS NULL OR COL_LENGTH('booking.BOOKING', 'WhishAttempt') IS NULL
   OR OBJECT_ID('security.PERMISSION') IS NULL OR OBJECT_ID('security.ROLE_PERMISSION') IS NULL
BEGIN
    RAISERROR('119_payment_gateways.sql: script 118 (Whish deposits) is not in this database. Apply the earlier numbered scripts first. Nothing was applied.', 16, 1);
    SET NOEXEC ON;
END
GO

/* ---------------------------------------------------------------- 1. the tables */
IF OBJECT_ID('booking.GATEWAY') IS NULL
BEGIN
    CREATE TABLE booking.GATEWAY
    (
        Gateway          VARCHAR(10) NOT NULL CONSTRAINT PK_GATEWAY PRIMARY KEY,
        ActiveMode       VARCHAR(4)  NULL,          -- NULL = as the server file (api.env) says
        ModifiedByUserId INT         NULL,
        ModifiedAtUtc    DATETIME2   NOT NULL CONSTRAINT DF_GATEWAY_Modified DEFAULT SYSUTCDATETIME(),
        CONSTRAINT CK_GATEWAY_Name CHECK (Gateway IN ('card', 'whish')),
        CONSTRAINT CK_GATEWAY_Mode CHECK (ActiveMode IS NULL OR ActiveMode IN ('test', 'live'))
    );
    PRINT 'booking.GATEWAY created';
END
GO

IF OBJECT_ID('booking.GATEWAY_CONFIG') IS NULL
BEGIN
    CREATE TABLE booking.GATEWAY_CONFIG
    (
        Gateway          VARCHAR(10)     NOT NULL,
        Mode             VARCHAR(4)      NOT NULL,
        KeysCipher       VARBINARY(4000) NOT NULL,  -- encrypted by the API; unreadable here
        ModifiedByUserId INT             NULL,
        ModifiedAtUtc    DATETIME2       NOT NULL CONSTRAINT DF_GATEWAY_CONFIG_Modified DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_GATEWAY_CONFIG PRIMARY KEY (Gateway, Mode),
        CONSTRAINT CK_GATEWAY_CONFIG_Name CHECK (Gateway IN ('card', 'whish')),
        CONSTRAINT CK_GATEWAY_CONFIG_Mode CHECK (Mode IN ('test', 'live'))
    );
    PRINT 'booking.GATEWAY_CONFIG created';
END
GO

IF OBJECT_ID('booking.PAYMENT_EVENT') IS NULL
BEGIN
    CREATE TABLE booking.PAYMENT_EVENT
    (
        PaymentEventId BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_PAYMENT_EVENT PRIMARY KEY,
        BookingRef     VARCHAR(12)   NULL,          -- the booking (by its reference: ids can be renumbered)
        TestRef        VARCHAR(12)   NULL,          -- or a gateway test (GT-XXXXXXXX)
        Gateway        VARCHAR(10)   NOT NULL,      -- card | whish
        Mode           VARCHAR(4)    NULL,          -- test | live
        GatewayOrderId VARCHAR(40)   NULL,
        EventType      VARCHAR(20)   NOT NULL,      -- Opened, OpenFailed, Checked, Paid, Released, Refunded, RefundFailed,
                                                    -- KeysSaved, KeysRemoved, ModeChanged, ConnectionCheck
        Source         VARCHAR(12)   NOT NULL,      -- Website, Return, Callback, Job, Guest, Staff
        Outcome        VARCHAR(20)   NULL,
        GatewayStatus  NVARCHAR(80)  NULL,          -- what the gateway itself said
        Detail         NVARCHAR(400) NULL,
        Amount         DECIMAL(10,2) NULL,
        CurrencyCode   CHAR(3)       NULL,
        UserId         INT           NULL,
        Repeats        INT           NOT NULL CONSTRAINT DF_PAYMENT_EVENT_Repeats DEFAULT 1,
        CreatedAtUtc   DATETIME2     NOT NULL CONSTRAINT DF_PAYMENT_EVENT_Created DEFAULT SYSUTCDATETIME(),
        LastAtUtc      DATETIME2     NOT NULL CONSTRAINT DF_PAYMENT_EVENT_Last DEFAULT SYSUTCDATETIME()
    );
    CREATE NONCLUSTERED INDEX IX_PAYMENT_EVENT_Booking ON booking.PAYMENT_EVENT (BookingRef, PaymentEventId) WHERE BookingRef IS NOT NULL;
    CREATE NONCLUSTERED INDEX IX_PAYMENT_EVENT_Test ON booking.PAYMENT_EVENT (TestRef, PaymentEventId) WHERE TestRef IS NOT NULL;
    PRINT 'booking.PAYMENT_EVENT created';
END
GO

IF OBJECT_ID('booking.GATEWAY_TEST') IS NULL
BEGIN
    CREATE TABLE booking.GATEWAY_TEST
    (
        TestId          INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_GATEWAY_TEST PRIMARY KEY,
        TestRef         VARCHAR(12)   NOT NULL CONSTRAINT UQ_GATEWAY_TEST_Ref UNIQUE,   -- GT-XXXXXXXX, also the id sent to the gateway
        Gateway         VARCHAR(10)   NOT NULL,
        Mode            VARCHAR(4)    NOT NULL,
        Amount          DECIMAL(10,2) NOT NULL,
        CurrencyCode    CHAR(3)       NOT NULL,
        [Status]        VARCHAR(12)   NOT NULL CONSTRAINT DF_GATEWAY_TEST_Status DEFAULT 'Opened',  -- Opened, Paid, NotPaid, Unknown, Refunded, Error
        GatewayStatus   NVARCHAR(80)  NULL,
        Detail          NVARCHAR(400) NULL,
        PayUrl          NVARCHAR(600) NULL,        -- where the tester pays (the gateway's page)
        ReturnUrl       NVARCHAR(300) NULL,        -- where the tester's browser is sent back (the HRMS page)
        PayerPhone      VARCHAR(30)   NULL,
        TransactionId   VARCHAR(60)   NULL,
        CallbackAtUtc   DATETIME2     NULL,        -- the gateway's server reached ours
        ReturnedAtUtc   DATETIME2     NULL,        -- the tester's browser came back through our return address
        CheckedAtUtc    DATETIME2     NULL,
        RefundedAtUtc   DATETIME2     NULL,
        CreatedByUserId INT           NULL,
        CreatedAtUtc    DATETIME2     NOT NULL CONSTRAINT DF_GATEWAY_TEST_Created DEFAULT SYSUTCDATETIME(),
        CONSTRAINT CK_GATEWAY_TEST_Name CHECK (Gateway IN ('card', 'whish')),
        CONSTRAINT CK_GATEWAY_TEST_Mode CHECK (Mode IN ('test', 'live'))
    );
    PRINT 'booking.GATEWAY_TEST created';
END
GO

IF COL_LENGTH('booking.BOOKING', 'PaymentMode') IS NULL
BEGIN
    ALTER TABLE booking.BOOKING ADD PaymentMode VARCHAR(4) NULL;     -- test | live: the mode the payment was opened in
    PRINT 'booking.BOOKING.PaymentMode added';
END
GO

/* ---------------------------------------------------------------- 2. the three permissions, granted once */
DECLARE @new TABLE (Code VARCHAR(50) NOT NULL, AdminOnly BIT NOT NULL);
IF NOT EXISTS (SELECT 1 FROM security.PERMISSION WHERE Code = 'BOOKING_PAYMENTS')
BEGIN
    INSERT INTO security.PERMISSION (Code, Name, Module)
    VALUES ('BOOKING_PAYMENTS', N'See the online payments (Bank of Beirut, Whish): history and log', 'Booking');
    INSERT INTO @new VALUES ('BOOKING_PAYMENTS', 0);
    PRINT 'permission BOOKING_PAYMENTS created';
END
ELSE PRINT 'permission BOOKING_PAYMENTS already there (its role grants are left as they are)';
IF NOT EXISTS (SELECT 1 FROM security.PERMISSION WHERE Code = 'BOOKING_PAYMENTS_MANAGE')
BEGIN
    INSERT INTO security.PERMISSION (Code, Name, Module)
    VALUES ('BOOKING_PAYMENTS_MANAGE', N'Act on an online payment: ask the gateway again, refund on Whish', 'Booking');
    INSERT INTO @new VALUES ('BOOKING_PAYMENTS_MANAGE', 0);
    PRINT 'permission BOOKING_PAYMENTS_MANAGE created';
END
ELSE PRINT 'permission BOOKING_PAYMENTS_MANAGE already there (its role grants are left as they are)';
IF NOT EXISTS (SELECT 1 FROM security.PERMISSION WHERE Code = 'GATEWAY_ADMIN')
BEGIN
    INSERT INTO security.PERMISSION (Code, Name, Module)
    VALUES ('GATEWAY_ADMIN', N'Payment gateways: their keys, test or live, and the test page (admin)', 'Booking');
    INSERT INTO @new VALUES ('GATEWAY_ADMIN', 1);
    PRINT 'permission GATEWAY_ADMIN created';
END
ELSE PRINT 'permission GATEWAY_ADMIN already there (its role grants are left as they are)';

INSERT INTO security.ROLE_PERMISSION (RoleId, PermissionId)
SELECT r.RoleId, p.PermissionId
FROM security.[ROLE] r
JOIN @new n ON 1 = 1
JOIN security.PERMISSION p ON p.Code = n.Code
WHERE NOT EXISTS (SELECT 1 FROM security.ROLE_PERMISSION x WHERE x.RoleId = r.RoleId AND x.PermissionId = p.PermissionId)
  AND (   r.Name = N'Owner'
       OR (n.AdminOnly = 0 AND r.Name = N'General Manager')
       OR EXISTS (SELECT 1 FROM security.ROLE_PERMISSION rp JOIN security.PERMISSION q ON q.PermissionId = rp.PermissionId
                  WHERE rp.RoleId = r.RoleId AND q.Code IN ('ROLE_MANAGE', 'USER_MANAGE')));
PRINT CONCAT('default role grants made now: ', @@ROWCOUNT);
GO

/* ---------------------------------------------------------------- 3. the payment log: one step */
/* Called by the API after each step; never by a guest's request directly. A check that says what the last check
   of the same payment said (same source, same answer) is COUNTED on that row instead of added. */
CREATE OR ALTER PROCEDURE booking.usp_PaymentEvent_Add
    @Gateway        VARCHAR(10),
    @EventType      VARCHAR(20),
    @Source         VARCHAR(12),
    @BookingRef     VARCHAR(12)   = NULL,
    @TestRef        VARCHAR(12)   = NULL,
    @Mode           VARCHAR(4)    = NULL,
    @GatewayOrderId VARCHAR(40)   = NULL,
    @Outcome        VARCHAR(20)   = NULL,
    @GatewayStatus  NVARCHAR(80)  = NULL,
    @Detail         NVARCHAR(400) = NULL,
    @Amount         DECIMAL(10,2) = NULL,
    @CurrencyCode   CHAR(3)       = NULL,
    @UserId         INT           = NULL
AS BEGIN
    SET NOCOUNT ON;
    SET @BookingRef = NULLIF(LTRIM(RTRIM(@BookingRef)), '');
    SET @TestRef = NULLIF(LTRIM(RTRIM(@TestRef)), '');

    IF @EventType = 'Checked' AND (@BookingRef IS NOT NULL OR @TestRef IS NOT NULL)
    BEGIN
        DECLARE @LastId BIGINT, @Same BIT = 0;
        SELECT TOP 1 @LastId = e.PaymentEventId,
               @Same = CASE WHEN e.EventType = 'Checked' AND e.Source = @Source
                                 AND ISNULL(e.Outcome, '') = ISNULL(@Outcome, '')
                                 AND ISNULL(e.GatewayStatus, N'') = ISNULL(@GatewayStatus, N'')
                                 AND ISNULL(e.GatewayOrderId, '') = ISNULL(@GatewayOrderId, '')
                                 AND ISNULL(e.UserId, 0) = ISNULL(@UserId, 0)
                            THEN 1 ELSE 0 END
        FROM booking.PAYMENT_EVENT e
        WHERE (@BookingRef IS NOT NULL AND e.BookingRef = @BookingRef) OR (@BookingRef IS NULL AND e.TestRef = @TestRef)
        ORDER BY e.PaymentEventId DESC;

        IF @Same = 1
        BEGIN
            UPDATE booking.PAYMENT_EVENT SET Repeats = Repeats + 1, LastAtUtc = SYSUTCDATETIME(), Detail = ISNULL(@Detail, Detail)
            WHERE PaymentEventId = @LastId;
            RETURN;
        END
    END

    INSERT INTO booking.PAYMENT_EVENT (BookingRef, TestRef, Gateway, Mode, GatewayOrderId, EventType, Source, Outcome,
                                       GatewayStatus, Detail, Amount, CurrencyCode, UserId)
    VALUES (@BookingRef, @TestRef, @Gateway, @Mode, @GatewayOrderId, @EventType, @Source, @Outcome,
            LEFT(@GatewayStatus, 80), LEFT(@Detail, 400), @Amount, @CurrencyCode, @UserId);
END;
GO

/* ---------------------------------------------------------------- 4. the gateways: mode and keys */
CREATE OR ALTER PROCEDURE booking.usp_Gateway_Get
AS BEGIN
    SET NOCOUNT ON;
    SELECT v.Gateway, g.ActiveMode, g.ModifiedAtUtc, u.Username AS ModifiedBy
    FROM (VALUES ('card'), ('whish')) v (Gateway)
    LEFT JOIN booking.GATEWAY g ON g.Gateway = v.Gateway
    LEFT JOIN security.[USER] u ON u.UserId = g.ModifiedByUserId
    ORDER BY v.Gateway;

    SELECT c.Gateway, c.Mode, c.KeysCipher, c.ModifiedAtUtc, u.Username AS ModifiedBy
    FROM booking.GATEWAY_CONFIG c
    LEFT JOIN security.[USER] u ON u.UserId = c.ModifiedByUserId
    ORDER BY c.Gateway, c.Mode;
END;
GO

CREATE OR ALTER PROCEDURE booking.usp_Gateway_SaveKeys
    @Gateway VARCHAR(10), @Mode VARCHAR(4), @KeysCipher VARBINARY(4000), @UserId INT = NULL
AS BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    IF @Gateway NOT IN ('card', 'whish') OR @Mode NOT IN ('test', 'live') OR @KeysCipher IS NULL OR DATALENGTH(@KeysCipher) < 30
    BEGIN RAISERROR('The gateway, the mode and the keys are required.', 16, 1); RETURN; END

    BEGIN TRAN;
    UPDATE booking.GATEWAY_CONFIG WITH (UPDLOCK, HOLDLOCK)
    SET KeysCipher = @KeysCipher, ModifiedByUserId = @UserId, ModifiedAtUtc = SYSUTCDATETIME()
    WHERE Gateway = @Gateway AND Mode = @Mode;
    IF @@ROWCOUNT = 0
        INSERT INTO booking.GATEWAY_CONFIG (Gateway, Mode, KeysCipher, ModifiedByUserId) VALUES (@Gateway, @Mode, @KeysCipher, @UserId);

    EXEC booking.usp_PaymentEvent_Add @Gateway = @Gateway, @EventType = 'KeysSaved', @Source = 'Staff', @Mode = @Mode, @UserId = @UserId;
    COMMIT;
END;
GO

CREATE OR ALTER PROCEDURE booking.usp_Gateway_DeleteKeys
    @Gateway VARCHAR(10), @Mode VARCHAR(4), @UserId INT = NULL
AS BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRAN;
    DELETE FROM booking.GATEWAY_CONFIG WHERE Gateway = @Gateway AND Mode = @Mode;
    IF @@ROWCOUNT > 0
        EXEC booking.usp_PaymentEvent_Add @Gateway = @Gateway, @EventType = 'KeysRemoved', @Source = 'Staff', @Mode = @Mode, @UserId = @UserId;
    COMMIT;
END;
GO

/* @Mode NULL = back to what the server file says. */
CREATE OR ALTER PROCEDURE booking.usp_Gateway_SetMode
    @Gateway VARCHAR(10), @Mode VARCHAR(4) = NULL, @UserId INT = NULL
AS BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    SET @Mode = NULLIF(LTRIM(RTRIM(@Mode)), '');
    IF @Gateway NOT IN ('card', 'whish') OR (@Mode IS NOT NULL AND @Mode NOT IN ('test', 'live'))
    BEGIN RAISERROR('The mode must be test or live.', 16, 1); RETURN; END

    BEGIN TRAN;
    DECLARE @Was VARCHAR(4) = (SELECT ActiveMode FROM booking.GATEWAY WITH (UPDLOCK, HOLDLOCK) WHERE Gateway = @Gateway);
    IF EXISTS (SELECT 1 FROM booking.GATEWAY WHERE Gateway = @Gateway)
        UPDATE booking.GATEWAY SET ActiveMode = @Mode, ModifiedByUserId = @UserId, ModifiedAtUtc = SYSUTCDATETIME() WHERE Gateway = @Gateway;
    ELSE
        INSERT INTO booking.GATEWAY (Gateway, ActiveMode, ModifiedByUserId) VALUES (@Gateway, @Mode, @UserId);

    IF ISNULL(@Was, '') <> ISNULL(@Mode, '')
    BEGIN
        -- COALESCE, not ISNULL: ISNULL would cut 'the server file' to the four characters of a mode.
        DECLARE @Detail NVARCHAR(400) = CONCAT(N'from ', COALESCE(@Was, 'the server file'), N' to ', COALESCE(@Mode, 'the server file'));
        EXEC booking.usp_PaymentEvent_Add @Gateway = @Gateway, @EventType = 'ModeChanged', @Source = 'Staff', @Mode = @Mode,
                                          @Detail = @Detail, @UserId = @UserId;
    END
    COMMIT;
END;
GO

/* The last changes to the gateways' settings and the connection checks, newest first (the settings page's history). */
CREATE OR ALTER PROCEDURE booking.usp_Gateway_History
    @Top INT = 20
AS BEGIN
    SET NOCOUNT ON;
    SELECT TOP (CASE WHEN @Top BETWEEN 1 AND 200 THEN @Top ELSE 20 END)
           e.PaymentEventId, e.Gateway, e.Mode, e.EventType, e.Outcome, e.Detail, e.CreatedAtUtc, u.Username AS UserName
    FROM booking.PAYMENT_EVENT e
    LEFT JOIN security.[USER] u ON u.UserId = e.UserId
    WHERE e.EventType IN ('KeysSaved', 'KeysRemoved', 'ModeChanged', 'ConnectionCheck')
    ORDER BY e.PaymentEventId DESC;
END;
GO

/* The mode a booking's payment was opened in: written right after booking.usp_Booking_StartPayment, read by the
   settlement code before it asks a gateway. NULL (a payment older than this script) = the mode in use now. */
CREATE OR ALTER PROCEDURE booking.usp_Booking_SetPaymentMode
    @Ref VARCHAR(12), @Mode VARCHAR(4)
AS BEGIN
    SET NOCOUNT ON;
    IF @Mode NOT IN ('test', 'live') RETURN;
    UPDATE booking.BOOKING SET PaymentMode = @Mode WHERE BookingRef = @Ref AND PaymentOpenedUtc IS NOT NULL;
END;
GO

CREATE OR ALTER PROCEDURE booking.usp_Booking_GetPaymentMode
    @Ref VARCHAR(12)
AS BEGIN
    SET NOCOUNT ON;
    SELECT PaymentMode FROM booking.BOOKING WHERE BookingRef = @Ref;
END;
GO

/* ---------------------------------------------------------------- 5. the payments page */
/* Every booking an online payment was opened for, or recorded on. ONE STATE per row, in the order a person asks:
     Paid         the deposit is on the books (and nothing is owed back)
     RefundDue    paid, the booking was cancelled, money is owed back        (staff: refund)
     Refunded     paid and given back
     NeedsStaff   paid, but the booking could not be confirmed (its slot was taken meanwhile)
     Open         a payment was opened and the guest may still be paying
     Unconfirmed  opened long ago and the gateway still cannot say            (staff: look)
     NotPaid      opened and never paid (released, or decided by staff without it)
   The gateway is read off the order id, as the settlement code reads it: reference-A<n> is Whish, the bare
   reference a card order. */
CREATE OR ALTER FUNCTION booking.fn_PaymentRows (@GiveUpMinutes INT)
RETURNS TABLE
AS RETURN
    SELECT b.BookingId, b.BookingRef, b.GuestName, b.GuestPhone, r.[Name] AS RoomName, b.BookDate, b.StartMin, b.EndMin,
           b.[Status] AS BookingStatus, b.DepositDue, b.TotalAmount, b.CurrencyCode,
           b.PaymentOpenedUtc, b.PaymentCheckedUtc, b.HoldExpiresUtc, b.WhishAttempt AS Attempts, b.WhishPayerPhone AS PayerPhone,
           b.RefundAmount, b.RefundStatus, b.RefundedUtc,
           p.PaymentId, p.Amount AS PaidAmount, p.PaidUtc, p.GatewayTransactionId AS TransactionId,
           COALESCE(p.GatewayOrderId, b.GatewayOrderId, b.BookingRef) AS GatewayOrderId,
           COALESCE(p.PaidUtc, b.PaymentOpenedUtc) AS ActivityUtc,
           CAST(CASE WHEN COALESCE(p.GatewayOrderId, b.GatewayOrderId) LIKE b.BookingRef + '-A%' THEN 'whish' ELSE 'card' END AS VARCHAR(10)) AS Gateway,
           CAST(CASE WHEN p.PaymentId IS NOT NULL THEN
                          CASE WHEN b.RefundStatus = 'Refunded' THEN 'Refunded'
                               WHEN b.RefundStatus IN ('Due', 'Partial') THEN 'RefundDue'
                               WHEN b.[Status] = 'Pending' THEN 'NeedsStaff'
                               ELSE 'Paid' END
                     WHEN b.[Status] = 'Pending' THEN
                          CASE WHEN b.PaymentOpenedUtc < DATEADD(MINUTE, -ISNULL(@GiveUpMinutes, 30), SYSUTCDATETIME()) THEN 'Unconfirmed' ELSE 'Open' END
                     ELSE 'NotPaid' END AS VARCHAR(12)) AS PayState,
           ISNULL(rf.Refunded, 0) AS RefundedAmount,
           COALESCE(b.PaymentMode, m.Mode) AS Mode,
           CAST(CASE WHEN gr.PaymentEventId IS NOT NULL THEN 1 ELSE 0 END AS BIT) AS GatewayRefunded,
           le.EventType AS LastEventType, le.Outcome AS LastOutcome, le.Detail AS LastDetail, le.LastAtUtc AS LastEventUtc
    FROM booking.BOOKING b
    JOIN booking.ROOM r ON r.RoomId = b.RoomId
    OUTER APPLY (SELECT TOP 1 x.PaymentId, x.Amount, x.PaidUtc, x.GatewayOrderId, x.GatewayTransactionId
                 FROM booking.BOOKING_PAYMENT x
                 WHERE x.BookingId = b.BookingId AND x.GatewayOrderId IS NOT NULL AND x.IsRefund = 0
                 ORDER BY x.PaymentId) p
    OUTER APPLY (SELECT -SUM(x.Amount) AS Refunded FROM booking.BOOKING_PAYMENT x WHERE x.BookingId = b.BookingId AND x.IsRefund = 1) rf
    OUTER APPLY (SELECT TOP 1 e.Mode FROM booking.PAYMENT_EVENT e
                 WHERE e.BookingRef = b.BookingRef AND e.Mode IS NOT NULL ORDER BY e.PaymentEventId DESC) m
    OUTER APPLY (SELECT TOP 1 e.PaymentEventId FROM booking.PAYMENT_EVENT e
                 WHERE e.BookingRef = b.BookingRef AND e.EventType = 'Refunded' ORDER BY e.PaymentEventId DESC) gr
    OUTER APPLY (SELECT TOP 1 e.EventType, e.Outcome, e.Detail, e.LastAtUtc FROM booking.PAYMENT_EVENT e
                 WHERE e.BookingRef = b.BookingRef ORDER BY e.PaymentEventId DESC) le
    WHERE b.PaymentOpenedUtc IS NOT NULL OR p.PaymentId IS NOT NULL;
GO

CREATE OR ALTER PROCEDURE booking.usp_Payment_List
    @FromUtc       DATETIME2,
    @ToUtc         DATETIME2,
    @Gateway       VARCHAR(10)  = NULL,
    @State         VARCHAR(12)  = NULL,
    @Search        NVARCHAR(60) = NULL,
    @GiveUpMinutes INT          = 30
AS BEGIN
    SET NOCOUNT ON;
    SET @Gateway = NULLIF(LTRIM(RTRIM(@Gateway)), '');
    SET @State = NULLIF(LTRIM(RTRIM(@State)), '');
    DECLARE @Like NVARCHAR(70) = N'%' + REPLACE(REPLACE(REPLACE(NULLIF(LTRIM(RTRIM(@Search)), N''), N'[', N'[[]'), N'%', N'[%]'), N'_', N'[_]') + N'%';

    SELECT p.*
    FROM booking.fn_PaymentRows(@GiveUpMinutes) p
    WHERE (@Like IS NOT NULL OR (p.ActivityUtc >= @FromUtc AND p.ActivityUtc < @ToUtc))      -- a search looks at every date
      AND (@Gateway IS NULL OR p.Gateway = @Gateway)
      AND (@State IS NULL OR p.PayState = @State)
      AND (@Like IS NULL OR p.BookingRef LIKE @Like OR p.GuestName LIKE @Like OR p.GuestPhone LIKE @Like
           OR p.GatewayOrderId LIKE @Like OR p.PayerPhone LIKE @Like OR p.TransactionId LIKE @Like)
    ORDER BY p.ActivityUtc DESC, p.BookingId DESC;
END;
GO

/* One payment: its row, its log (newest last), every money line of the booking. */
CREATE OR ALTER PROCEDURE booking.usp_Payment_Get
    @BookingId     INT,
    @GiveUpMinutes INT = 30
AS BEGIN
    SET NOCOUNT ON;
    SELECT p.* FROM booking.fn_PaymentRows(@GiveUpMinutes) p WHERE p.BookingId = @BookingId;

    SELECT e.PaymentEventId, e.Gateway, e.Mode, e.GatewayOrderId, e.EventType, e.Source, e.Outcome, e.GatewayStatus, e.Detail,
           e.Amount, e.CurrencyCode, e.Repeats, e.CreatedAtUtc, e.LastAtUtc, u.Username AS UserName
    FROM booking.PAYMENT_EVENT e
    JOIN booking.BOOKING b ON b.BookingRef = e.BookingRef
    LEFT JOIN security.[USER] u ON u.UserId = e.UserId
    WHERE b.BookingId = @BookingId
    ORDER BY e.PaymentEventId;

    SELECT x.PaymentId, x.Amount, x.IsRefund, m.[Name] AS MethodName, x.Reference, x.PaidUtc, u.Username AS ReceivedBy,
           x.GatewayOrderId, x.GatewayTransactionId AS TransactionId
    FROM booking.BOOKING_PAYMENT x
    JOIN booking.PAYMENT_METHOD m ON m.PaymentMethodId = x.PaymentMethodId
    LEFT JOIN security.[USER] u ON u.UserId = x.ReceivedByUserId
    WHERE x.BookingId = @BookingId
    ORDER BY x.PaymentId;
END;
GO

/* ---------------------------------------------------------------- 6. the gateway tests */
CREATE OR ALTER PROCEDURE booking.usp_GatewayTest_Add
    @TestRef VARCHAR(12), @Gateway VARCHAR(10), @Mode VARCHAR(4), @Amount DECIMAL(10,2), @CurrencyCode CHAR(3),
    @ReturnUrl NVARCHAR(300) = NULL, @UserId INT = NULL
AS BEGIN
    SET NOCOUNT ON;
    IF @TestRef NOT LIKE 'GT-________' OR @Amount IS NULL OR @Amount <= 0
    BEGIN RAISERROR('A test needs a reference and an amount greater than zero.', 16, 1); RETURN; END

    INSERT INTO booking.GATEWAY_TEST (TestRef, Gateway, Mode, Amount, CurrencyCode, ReturnUrl, CreatedByUserId)
    VALUES (@TestRef, @Gateway, @Mode, @Amount, @CurrencyCode, @ReturnUrl, @UserId);

    SELECT t.*, u.Username AS CreatedBy
    FROM booking.GATEWAY_TEST t LEFT JOIN security.[USER] u ON u.UserId = t.CreatedByUserId
    WHERE t.TestRef = @TestRef;
END;
GO

/* Only what is given is changed. @Callback / @Returned / @Refunded = 1 stamp their time once. */
CREATE OR ALTER PROCEDURE booking.usp_GatewayTest_Update
    @TestRef VARCHAR(12),
    @Status VARCHAR(12) = NULL, @GatewayStatus NVARCHAR(80) = NULL, @Detail NVARCHAR(400) = NULL, @PayUrl NVARCHAR(600) = NULL,
    @PayerPhone VARCHAR(30) = NULL, @TransactionId VARCHAR(60) = NULL,
    @Checked BIT = 0, @Callback BIT = 0, @Returned BIT = 0, @Refunded BIT = 0
AS BEGIN
    SET NOCOUNT ON;
    DECLARE @Now DATETIME2 = SYSUTCDATETIME();
    UPDATE booking.GATEWAY_TEST
    SET [Status]      = CASE WHEN @Refunded = 1 THEN 'Refunded'
                             WHEN [Status] = 'Refunded' THEN [Status]                 -- a refunded test stays refunded
                             WHEN [Status] = 'Paid' AND ISNULL(@Status, 'Paid') <> 'Paid' THEN [Status]   -- a paid one is never un-paid by a later "cannot tell"
                             ELSE ISNULL(@Status, [Status]) END,
        GatewayStatus = ISNULL(LEFT(@GatewayStatus, 80), GatewayStatus),
        Detail        = ISNULL(LEFT(@Detail, 400), Detail),
        PayUrl        = ISNULL(@PayUrl, PayUrl),
        PayerPhone    = ISNULL(@PayerPhone, PayerPhone),
        TransactionId = ISNULL(@TransactionId, TransactionId),
        CheckedAtUtc  = CASE WHEN @Checked = 1 THEN @Now ELSE CheckedAtUtc END,
        CallbackAtUtc = CASE WHEN @Callback = 1 THEN ISNULL(CallbackAtUtc, @Now) ELSE CallbackAtUtc END,
        ReturnedAtUtc = CASE WHEN @Returned = 1 THEN ISNULL(ReturnedAtUtc, @Now) ELSE ReturnedAtUtc END,
        RefundedAtUtc = CASE WHEN @Refunded = 1 THEN ISNULL(RefundedAtUtc, @Now) ELSE RefundedAtUtc END
    WHERE TestRef = @TestRef;

    SELECT t.*, u.Username AS CreatedBy
    FROM booking.GATEWAY_TEST t LEFT JOIN security.[USER] u ON u.UserId = t.CreatedByUserId
    WHERE t.TestRef = @TestRef;
END;
GO

CREATE OR ALTER PROCEDURE booking.usp_GatewayTest_Get
    @TestRef VARCHAR(12)
AS BEGIN
    SET NOCOUNT ON;
    SELECT t.*, u.Username AS CreatedBy
    FROM booking.GATEWAY_TEST t LEFT JOIN security.[USER] u ON u.UserId = t.CreatedByUserId
    WHERE t.TestRef = @TestRef;

    SELECT e.PaymentEventId, e.Gateway, e.Mode, e.GatewayOrderId, e.EventType, e.Source, e.Outcome, e.GatewayStatus, e.Detail,
           e.Amount, e.CurrencyCode, e.Repeats, e.CreatedAtUtc, e.LastAtUtc, u.Username AS UserName
    FROM booking.PAYMENT_EVENT e LEFT JOIN security.[USER] u ON u.UserId = e.UserId
    WHERE e.TestRef = @TestRef
    ORDER BY e.PaymentEventId;
END;
GO

/* The MARKER of this script (the last procedure it creates). */
CREATE OR ALTER PROCEDURE booking.usp_GatewayTest_List
    @Top INT = 30
AS BEGIN
    SET NOCOUNT ON;
    SELECT TOP (CASE WHEN @Top BETWEEN 1 AND 200 THEN @Top ELSE 30 END) t.*, u.Username AS CreatedBy
    FROM booking.GATEWAY_TEST t LEFT JOIN security.[USER] u ON u.UserId = t.CreatedByUserId
    ORDER BY t.TestId DESC;
END;
GO

/* ---------------------------------------------------------------- 7. OWNER CHECK */
DECLARE @see NVARCHAR(MAX) = (SELECT STRING_AGG(r.Name, N', ') FROM security.[ROLE] r JOIN security.ROLE_PERMISSION rp ON rp.RoleId = r.RoleId
                              JOIN security.PERMISSION p ON p.PermissionId = rp.PermissionId WHERE p.Code = 'BOOKING_PAYMENTS');
DECLARE @act NVARCHAR(MAX) = (SELECT STRING_AGG(r.Name, N', ') FROM security.[ROLE] r JOIN security.ROLE_PERMISSION rp ON rp.RoleId = r.RoleId
                              JOIN security.PERMISSION p ON p.PermissionId = rp.PermissionId WHERE p.Code = 'BOOKING_PAYMENTS_MANAGE');
DECLARE @adm NVARCHAR(MAX) = (SELECT STRING_AGG(r.Name, N', ') FROM security.[ROLE] r JOIN security.ROLE_PERMISSION rp ON rp.RoleId = r.RoleId
                              JOIN security.PERMISSION p ON p.PermissionId = rp.PermissionId WHERE p.Code = 'GATEWAY_ADMIN');
DECLARE @whish NVARCHAR(10) = (SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'BookingWhishEnabled');
DECLARE @saved INT = (SELECT COUNT(*) FROM booking.GATEWAY_CONFIG);
PRINT CONCAT('OWNER CHECK (119): see the payments: ', ISNULL(@see, N'(no role)'), ' | act on them: ', ISNULL(@act, N'(no role)'),
             ' | gateway keys and test page: ', ISNULL(@adm, N'(no role)'), '. Change it on Security > Role permissions (card Booking).');
PRINT CONCAT('OWNER CHECK (119): keys saved in HRMS: ', @saved,
             ' (none = the gateways work from the server file, as before). Whish on the website is ',
             CASE WHEN @whish IN ('1', 'true') THEN 'ON' ELSE 'OFF' END, ' - this script does not change it.');
PRINT '119_payment_gateways.sql: gateway keys, payment log, payments page and gateway tests - in place.';
GO

SET NOEXEC OFF;
GO
