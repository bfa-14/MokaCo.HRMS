/* ============================================================================
   deploy/test-env/neutralise-test-db.sql — make a copy of production safe to run a second API on.

   MokaCo_HRMS_Test is restored from a production backup, so it carries production's settings and
   devices. A test API started on it unchanged would:
     * e-mail and WhatsApp real staff and guests (EmailWorker, every minute);
     * read the real fingerprint terminals. Worse, "Clear machine log" reads a terminal into THIS
       database and then erases the terminal's own log, so production loses those punches for good.
       The Pull now / Clear buttons ignore MachinePullEnabled and IsActive: only an empty PullIp
       stops them (MachinePullService);
     * accept website bookings: a MISSING BookingWebsiteEnabled row means ON (PublicBookingGate);
     * carry production's payment keys (script 119). The test server has its own signing key, so it cannot
       open them - and a saved key it cannot open hides the test keys of its own server file.
   It also turns the copy's Google sign-in gate off (docs/97_google_signin_gate.sql): production's
   switch would otherwise come along, and the test copy's gate is turned on by hand when it is tried.

   Run it after every restore and BEFORE mokaco-api-test starts; refresh-test-db.sh does both.
   Refuses to run in any database but MokaCo_HRMS_Test. Idempotent.
     sqlcmd -S 127.0.0.1 -U sa -C -I -b -d MokaCo_HRMS_Test -i neutralise-test-db.sql
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT ON;

-- ONE BATCH, NO GO: the guard's THROW ends the whole script, whatever runs it and with or without
-- sqlcmd -b. Split into batches, the ones after the guard would still run in the wrong database.
IF DB_NAME() <> N'MokaCo_HRMS_Test'
    THROW 50000, N'neutralise-test-db.sql runs only in MokaCo_HRMS_Test (sqlcmd -d MokaCo_HRMS_Test). Nothing was changed.', 1;

BEGIN TRANSACTION;

/* 1. Settings. A missing row already means "off" for each of these except BookingWebsiteEnabled,
      so that one is inserted when absent. The two secrets are blanked as well: production's mail
      password and WhatsApp token have no business in a copy. */
UPDATE s
SET SettingValue = v.V, ModifiedAt = SYSUTCDATETIME()
FROM core.SETTING s
JOIN (VALUES
    ('SmtpHost',              N''),     -- EmailWorker: no host = nothing queued or sent
    ('SmtpPassword',          N''),
    ('WhatsAppEnabled',       N'0'),
    ('WhatsAppAccessToken',   N''),
    ('MachinePullEnabled',    N'0'),    -- the scheduled pull; the buttons are step 3
    ('BookingWebsiteEnabled', N'0'),
    ('BookingCorsOrigins',    N''),
    ('BookingApiKey',         N''),
    ('BookingNotifyEmail',    N''),
    ('BookingSmtpHost',       N''),     -- QA3: booking mail now has its own account (script 104);
    ('BookingSmtpUser',       N''),     --   blank it too, or a test status change on a copied
    ('BookingSmtpPassword',   N''),     --   booking mails the real guest from the real mailbox
    ('GoogleSignInRequired',  N'0')     -- the gate; a missing row is off as well
) v (K, V) ON v.K = s.SettingKey;

IF NOT EXISTS (SELECT 1 FROM core.SETTING WHERE SettingKey = 'BookingWebsiteEnabled')
    INSERT INTO core.SETTING (SettingKey, SettingValue, DataType, [Description], ModifiedAt)
    VALUES ('BookingWebsiteEnabled', N'0', 'bool',
            N'Test copy: website bookings off (deploy/test-env/neutralise-test-db.sql).', SYSUTCDATETIME());

/* 2. The outbox. Pending rows would go out the moment somebody gives this copy a mail server.
      Failed is never picked up again (core.usp_Email_GetPending reads Pending only). */
UPDATE core.EMAIL_OUTBOX
SET [Status] = 'Failed',
    Error    = N'Not sent: test copy of production (deploy/test-env/neutralise-test-db.sql).'
WHERE [Status] = 'Pending';

/* 3. The fingerprint terminals: no address, so neither the worker nor a button can reach one. */
UPDATE attendance.DEVICE
SET PullEnabled = 0, PullIp = NULL
WHERE PullEnabled = 1 OR PullIp IS NOT NULL;

/* 4. Production's sign-ins. The copy holds the refresh tokens that were live in production when
      the backup was taken; with them, a production session could be renewed on the test API.
      Everyone signs in to the test copy afresh. */
DELETE FROM security.REFRESH_TOKEN;

/* 5. Payment gateways (script 119; a backup older than it has no such tables). The saved keys that CAME WITH
      THE BACKUP, test and live alike, are removed: they are production's secrets, this server cannot open them,
      and while they sit there the gateway reads "keys cannot be opened" instead of using the test keys of its
      own server file. A gateway production runs live is put on test, so nothing on the test side (Check,
      Refund, the gateway test page) starts out pointing at the real bank or at Whish with real money.
      "Came with the backup" = saved before this database was last restored (msdb keeps that time, in the
      server's local time). Keys typed into the test side afterwards are newer and are left alone, so running
      this again (refresh-test-db.sh --in-place, setup-test-api.sh) does not wipe them. No restore on record:
      nothing here came from a backup, nothing is removed. The history and the payment log stay: they are what
      one comes here to look at. Dynamic SQL: the tables may not exist. */
DECLARE @RestoredUtc DATETIME2(0) =
    (SELECT DATEADD(MINUTE, DATEDIFF(MINUTE, GETDATE(), GETUTCDATE()), MAX(restore_date))
     FROM msdb.dbo.restorehistory WHERE destination_database_name = DB_NAME());
IF OBJECT_ID(N'booking.GATEWAY_CONFIG', N'U') IS NOT NULL
    EXEC sys.sp_executesql N'DELETE FROM booking.GATEWAY_CONFIG WHERE ModifiedAtUtc < @At;',
         N'@At DATETIME2(0)', @At = @RestoredUtc;
IF OBJECT_ID(N'booking.GATEWAY', N'U') IS NOT NULL
    EXEC sys.sp_executesql N'UPDATE booking.GATEWAY SET ActiveMode = ''test''
                             WHERE ActiveMode = ''live'' AND (ModifiedAtUtc IS NULL OR ModifiedAtUtc < @At);',
         N'@At DATETIME2(0)', @At = @RestoredUtc;

COMMIT;

/* What it left, for the operator to read. */
SELECT SettingKey, SettingValue
FROM core.SETTING
WHERE SettingKey IN ('SmtpHost', 'WhatsAppEnabled', 'MachinePullEnabled', 'BookingWebsiteEnabled',
                     'BookingCorsOrigins', 'BookingApiKey', 'BookingNotifyEmail', 'BookingSmtpHost',
                     'GoogleSignInRequired')
ORDER BY SettingKey;

SELECT (SELECT COUNT(*) FROM core.EMAIL_OUTBOX WHERE [Status] = 'Pending')  AS PendingOutbox,
       (SELECT COUNT(*) FROM attendance.DEVICE WHERE PullIp IS NOT NULL)    AS DevicesWithAddress;

IF OBJECT_ID(N'booking.GATEWAY_CONFIG', N'U') IS NOT NULL
    EXEC sys.sp_executesql N'SELECT
       (SELECT COUNT(*) FROM booking.GATEWAY_CONFIG WHERE ModifiedAtUtc < @At)                    AS CopiedGatewayKeys,
       (SELECT COUNT(*) FROM booking.GATEWAY WHERE ActiveMode = ''live''
                                               AND (ModifiedAtUtc IS NULL OR ModifiedAtUtc < @At)) AS CopiedGatewaysOnLive,
       (SELECT COUNT(*) FROM booking.GATEWAY_CONFIG)                                              AS KeysTypedHere;',
         N'@At DATETIME2(0)', @At = @RestoredUtc;
