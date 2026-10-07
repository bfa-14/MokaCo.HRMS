/* ============================================================================
   deploy/test-env/neutralise-test-db.sql — make a copy of production safe to run a second API on.

   MokaCo_HRMS_Test is restored from a production backup, so it carries production's settings and
   devices. A test API started on it unchanged would:
     * e-mail and WhatsApp real staff and guests (EmailWorker, every minute);
     * read the real fingerprint terminals. Worse, "Clear machine log" reads a terminal into THIS
       database and then erases the terminal's own log, so production loses those punches for good.
       The Pull now / Clear buttons ignore MachinePullEnabled and IsActive: only an empty PullIp
       stops them (MachinePullService);
     * accept website bookings: a MISSING BookingWebsiteEnabled row means ON (PublicBookingGate).

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
    ('BookingNotifyEmail',    N'')
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

COMMIT;

/* What it left, for the operator to read. */
SELECT SettingKey, SettingValue
FROM core.SETTING
WHERE SettingKey IN ('SmtpHost', 'WhatsAppEnabled', 'MachinePullEnabled', 'BookingWebsiteEnabled',
                     'BookingCorsOrigins', 'BookingApiKey', 'BookingNotifyEmail')
ORDER BY SettingKey;

SELECT (SELECT COUNT(*) FROM core.EMAIL_OUTBOX WHERE [Status] = 'Pending')  AS PendingOutbox,
       (SELECT COUNT(*) FROM attendance.DEVICE WHERE PullIp IS NOT NULL)    AS DevicesWithAddress;
