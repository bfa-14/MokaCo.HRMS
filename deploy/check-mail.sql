/* ============================================================================
   deploy/check-mail.sql - why did a booking e-mail go out, or not? READ-ONLY: it changes nothing, so it is
   safe on production. Run it through deploy/check-mail.sh, or by hand:
     sqlcmd -S 127.0.0.1 -U sa -C -d MokaCo_HRMS -i deploy/check-mail.sql

   It prints, in plain words: the two mail accounts as the e-mail worker reads them (EmailWorker.ReadSettingsAsync),
   the booking mail switches (booking.trg_Booking_Notify), what happened to the booking mail of the last 7 days,
   the last messages with the mail server's own error, the last bookings, and a verdict.
   It never prints a password, a login (a login can be a provider token) or a guest's address.
   ============================================================================ */
SET NOCOUNT ON;

DECLARE @nl NCHAR(2) = NCHAR(13) + NCHAR(10);
DECLARE @now DATETIME2(0) = SYSUTCDATETIME();
DECLARE @out NVARCHAR(MAX) = CONCAT(N'Database: ', DB_NAME(), N'.  Now: ', CONVERT(NVARCHAR(16), @now, 120), N' UTC.', @nl);

/* ---- the settings, exactly as the worker and the trigger read them --------------------------------- */
DECLARE @set TABLE (K VARCHAR(60) PRIMARY KEY, V NVARCHAR(MAX) NULL, There BIT NOT NULL);
INSERT INTO @set (K, V, There)
SELECT v.K, NULLIF(LTRIM(RTRIM(s.SettingValue)), N''), IIF(s.SettingKey IS NULL, 0, 1)
FROM (VALUES ('SmtpHost'), ('SmtpPort'), ('SmtpUser'), ('SmtpPassword'), ('SmtpFromEmail'),
             ('BookingSmtpHost'), ('BookingSmtpPort'), ('BookingSmtpUser'), ('BookingSmtpPassword'),
             ('BookingFromEmail'), ('BookingFromName'), ('BookingNotifyEmail'),
             ('BookingEmailOnRequest'), ('BookingEmailOnConfirm'), ('BookingEmailOnCancel'), ('BookingStaffAlert'),
             ('WhatsAppEnabled'), ('WhatsAppApiUrl'), ('WhatsAppPhoneNumberId'), ('WhatsAppAccessToken')) v (K)
LEFT JOIN core.SETTING s ON s.SettingKey = v.K;

DECLARE @Host NVARCHAR(200) = (SELECT V FROM @set WHERE K = 'SmtpHost');
DECLARE @Port NVARCHAR(20)  = ISNULL((SELECT V FROM @set WHERE K = 'SmtpPort'), N'587');
DECLARE @BHost NVARCHAR(200) = (SELECT V FROM @set WHERE K = 'BookingSmtpHost');
DECLARE @BPort NVARCHAR(20)  = (SELECT V FROM @set WHERE K = 'BookingSmtpPort');
DECLARE @BUser BIT = IIF((SELECT V FROM @set WHERE K = 'BookingSmtpUser') IS NULL, 0, 1);
DECLARE @BPass BIT = IIF((SELECT V FROM @set WHERE K = 'BookingSmtpPassword') IS NULL, 0, 1);
DECLARE @BFrom NVARCHAR(200) = (SELECT V FROM @set WHERE K = 'BookingFromEmail');
DECLARE @WhatsApp BIT = IIF(LOWER(ISNULL((SELECT V FROM @set WHERE K = 'WhatsAppEnabled'), N'0')) IN (N'1', N'true', N'yes', N'on')
                            AND NOT EXISTS (SELECT 1 FROM @set WHERE K IN ('WhatsAppApiUrl', 'WhatsAppPhoneNumberId', 'WhatsAppAccessToken') AND V IS NULL), 1, 0);
DECLARE @OwnAccount BIT = IIF(@BUser = 1 AND @BPass = 1, 1, 0);
/* The bookings mailbox with a server of its own needs no HR mail server (API of 22 Nov 2026 and later). */
DECLARE @Alone BIT = IIF(@OwnAccount = 1 AND @BHost IS NOT NULL, 1, 0);
DECLARE @WorkerOn BIT = IIF(@Host IS NOT NULL OR @WhatsApp = 1 OR @Alone = 1, 1, 0);
DECLARE @SendHost NVARCHAR(200) = ISNULL(@BHost, @Host);
DECLARE @SendPort NVARCHAR(20)  = ISNULL(@BPort, @Port);
DECLARE @missing NVARCHAR(MAX) = (SELECT STRING_AGG(CAST(K AS NVARCHAR(MAX)), N', ') FROM @set
                                  WHERE There = 0 AND K IN ('BookingSmtpHost', 'BookingSmtpPort', 'BookingSmtpUser', 'BookingSmtpPassword', 'BookingFromEmail', 'BookingFromName'));

SET @out += CONCAT(@nl, N'== The two mail accounts', @nl,
    N'HR mail (Settings > Notifications): server ', IIF(@Host IS NULL, N'EMPTY', CONCAT(@Host, N':', @Port)),
        N'; login ', IIF((SELECT V FROM @set WHERE K = 'SmtpUser') IS NULL, N'EMPTY', N'filled'),
        N'; password ', IIF((SELECT V FROM @set WHERE K = 'SmtpPassword') IS NULL, N'EMPTY', N'filled'),
        N'; from ', ISNULL((SELECT V FROM @set WHERE K = 'SmtpFromEmail'), N'(the login)'), @nl,
    N'Bookings mailbox: from ', ISNULL(@BFrom, N'EMPTY'),
        N'; login (BookingSmtpUser) ', IIF(@BUser = 1, N'filled', N'EMPTY'),
        N'; password (BookingSmtpPassword) ', IIF(@BPass = 1, N'filled', N'EMPTY'),
        N'; server ', CASE WHEN @BHost IS NOT NULL THEN CONCAT(N'its own, ', @BHost) ELSE N'the HR server' END,
        N'; port ', ISNULL(@BPort, CONCAT(N'the HR port, ', @Port)), @nl,
    IIF(@missing IS NULL, N'', CONCAT(N'Rows that do not exist in the settings table at all: ', @missing, @nl)),
    N'Booking mail is sent through: ',
        CASE WHEN @WorkerOn = 0 THEN N'NOTHING - the mail service is off (no mail server, WhatsApp off)'
             WHEN @OwnAccount = 1 AND @SendHost IS NULL THEN N'NOTHING - the bookings mailbox has a login but no mail server (its own or the HR one)'
             WHEN @OwnAccount = 0 AND @Host IS NULL THEN N'NOTHING - there is no HR mail server and the bookings mailbox has no login of its own'
             WHEN @OwnAccount = 1 THEN CONCAT(N'the bookings mailbox, ', @SendHost, N':', @SendPort, N', written as ', ISNULL(@BFrom, N'its login'))
             ELSE N'the HR account and the HR address (the bookings mailbox has no login and password)' END, @nl,
    N'Staff are told of website bookings at (BookingNotifyEmail): ', IIF((SELECT V FROM @set WHERE K = 'BookingNotifyEmail') IS NULL, N'EMPTY - no staff alert', N'filled'), @nl);

SET @out += CONCAT(@nl, N'== Switches (an absent row means ON)', @nl,
    (SELECT STRING_AGG(CAST(CONCAT(K, N' ', CASE WHEN There = 0 THEN N'on (no row)'
                                                 WHEN LOWER(ISNULL(V, N'')) IN (N'1', N'true', N'yes', N'on') THEN N'on' ELSE N'OFF' END) AS NVARCHAR(MAX)), N';  ')
     FROM @set WHERE K IN ('BookingEmailOnRequest', 'BookingEmailOnConfirm', 'BookingEmailOnCancel', 'BookingStaffAlert')), @nl);

/* ---- what happened to booking e-mail in the last 7 days --------------------------------------------- */
DECLARE @box TABLE (EmailId INT PRIMARY KEY, BookingId INT NULL, MailKind VARCHAR(20) NULL, [Status] VARCHAR(20) NULL,
                    Attempts INT NULL, Acct VARCHAR(20) NULL, FromEmail NVARCHAR(150) NULL, CreatedUtc DATETIME2 NULL,
                    SentUtc DATETIME2 NULL, NextUtc DATETIME2 NULL, Error NVARCHAR(400) NULL);
INSERT INTO @box
SELECT o.EmailId, o.BookingId, o.MailKind, o.[Status], o.AttemptCount, o.SmtpAccount, o.FromEmail, o.CreatedUtc, o.SentUtc,
       o.NextAttemptUtc, LEFT(REPLACE(REPLACE(ISNULL(o.Error, N''), NCHAR(13), N' '), NCHAR(10), N' '), 400)
FROM core.EMAIL_OUTBOX o
WHERE o.Channel = 'Email' AND (o.BookingId IS NOT NULL OR o.MailKind IS NOT NULL)
  AND (o.CreatedUtc >= DATEADD(DAY, -7, @now) OR o.[Status] IN ('Pending', 'Sending'));

DECLARE @Waiting INT = (SELECT COUNT(*) FROM @box WHERE [Status] IN ('Pending', 'Sending'));
DECLARE @Oldest DATETIME2 = (SELECT MIN(CreatedUtc) FROM @box WHERE [Status] IN ('Pending', 'Sending'));
DECLARE @AllWaiting INT = (SELECT COUNT(*) FROM core.EMAIL_OUTBOX WHERE [Status] = 'Pending');

SET @out += CONCAT(@nl, N'== Booking e-mail, last 7 days', @nl,
    N'Sent ', (SELECT COUNT(*) FROM @box WHERE [Status] = 'Sent'),
    N';  Failed ', (SELECT COUNT(*) FROM @box WHERE [Status] = 'Failed'),
    N';  waiting ', @Waiting, IIF(@Waiting > 0, CONCAT(N' (the oldest since ', CONVERT(NVARCHAR(16), @Oldest, 120), N' UTC)'), N''),
    N'.  Waiting messages of every kind: ', @AllWaiting, N'.', @nl);

SET @out += CONCAT(@nl, N'== The last booking messages (newest first; the text after "-" is the mail server''s own answer)', @nl,
    ISNULL((SELECT STRING_AGG(CAST(CONCAT(N'#', x.EmailId, N'  ', CONVERT(NVARCHAR(16), x.CreatedUtc, 120), N'  ',
                                          ISNULL(k.Ref, N'-'), N'  ', ISNULL(x.MailKind, N'?'), N'  ', UPPER(ISNULL(x.[Status], N'?')),
                                          N' (attempts ', ISNULL(x.Attempts, 0), N')  through ',
                                          IIF(x.Acct = 'Booking', N'the bookings mailbox', N'the HR account'),
                                          IIF(x.Error = N'', N'', CONCAT(N'  - ', x.Error))) AS NVARCHAR(MAX)), @nl)
                   WITHIN GROUP (ORDER BY x.EmailId DESC)
            FROM (SELECT TOP 12 * FROM @box ORDER BY EmailId DESC) x
            OUTER APPLY (SELECT TOP 1 ISNULL(b.BookingRef, CONCAT('#', b.BookingId)) AS Ref FROM booking.BOOKING b WHERE b.BookingId = x.BookingId) k),
           N'(none: no booking message was written in the last 7 days)'), @nl);

SET @out += CONCAT(@nl, N'== The last bookings', @nl,
    ISNULL((SELECT STRING_AGG(CAST(CONCAT(ISNULL(b.BookingRef, CONCAT('#', b.BookingId)), N'  ', CONVERT(NVARCHAR(16), b.CreatedUtc, 120), N'  ',
                                          b.[Status], N'  ', ISNULL(b.[Source], N'?'), N'  guest e-mail: ',
                                          IIF(NULLIF(LTRIM(RTRIM(b.GuestEmail)), N'') IS NULL, N'NONE', N'yes'), N'  messages: ',
                                          ISNULL(m.List, N'none')) AS NVARCHAR(MAX)), @nl) WITHIN GROUP (ORDER BY b.BookingId DESC)
            FROM (SELECT TOP 6 * FROM booking.BOOKING ORDER BY BookingId DESC) b
            OUTER APPLY (SELECT STRING_AGG(CAST(CONCAT(o.MailKind, N'/', o.Channel, N':', o.[Status]) AS NVARCHAR(MAX)), N', ') AS List
                         FROM core.EMAIL_OUTBOX o WHERE o.BookingId = b.BookingId) m),
           N'(no booking)'), @nl);

/* ---- the verdict: the first thing that explains it ----------------------------------------------------- */
DECLARE @LastId INT, @LastStatus VARCHAR(20), @LastErr NVARCHAR(400), @LastAcct VARCHAR(20), @LastNext DATETIME2, @LastKind VARCHAR(20);
SELECT TOP 1 @LastId = EmailId, @LastStatus = [Status], @LastErr = Error, @LastAcct = Acct, @LastNext = NextUtc, @LastKind = MailKind
FROM @box WHERE MailKind <> 'StaffAlert' OR MailKind IS NULL ORDER BY EmailId DESC;

DECLARE @NewRef NVARCHAR(40), @NewHasMail BIT, @NewId INT;
SELECT TOP 1 @NewId = b.BookingId, @NewRef = ISNULL(b.BookingRef, CONCAT('#', b.BookingId)),
             @NewHasMail = IIF(NULLIF(LTRIM(RTRIM(b.GuestEmail)), N'') IS NULL, 0, 1)
FROM booking.BOOKING b ORDER BY b.BookingId DESC;
DECLARE @NewQueued BIT = IIF(EXISTS (SELECT 1 FROM core.EMAIL_OUTBOX WHERE BookingId = @NewId AND Channel = 'Email' AND MailKind <> 'StaffAlert'), 1, 0);

DECLARE @hint NVARCHAR(400) = CASE
    WHEN @LastErr LIKE N'%TEST SYSTEM%' THEN N'This is a TEST system: it writes only to the test recipients listed on Settings > Notifications. Add the address there to receive this message.'
    WHEN @LastErr LIKE N'%No SmtpHost%' THEN N'There is no mail server for it: fill the bookings mailbox''s own Mail server, or Settings > Notifications > Mail server.'
    WHEN @LastErr LIKE N'%authenticat%' OR @LastErr LIKE N'%5.7.%' OR @LastErr LIKE N'%credential%' OR @LastErr LIKE N'%535%' OR @LastErr LIKE N'%534%'
         THEN N'The mail server REFUSED THE LOGIN. Wrong login or password, a mailbox that needs an "app password" (Google), a mailbox where sending by password is switched off (Microsoft 365), or an account that may not send as this From address.'
    WHEN @LastErr LIKE N'%timed out%' OR @LastErr LIKE N'%No such host%' OR @LastErr LIKE N'%name or service%' OR @LastErr LIKE N'%refused%' OR @LastErr LIKE N'%Failure sending%' OR @LastErr LIKE N'%Unable to connect%'
         THEN N'The mail server could NOT BE REACHED. Wrong server name or port (use 587; HRMS cannot send through 465), or the server''s network does not let it out on that port.'
    WHEN @LastErr LIKE N'%5.1.%' OR @LastErr LIKE N'%5.5.%' OR @LastErr LIKE N'%Mailbox unavailable%' OR @LastErr LIKE N'%not allowed%' OR @LastErr LIKE N'%SendAs%'
         THEN N'The mail server refused the MESSAGE: the From address is not one this login may send as, or the recipient was refused.'
    ELSE N'Read the mail server''s answer after "-" on that line above.' END;

SET @out += CONCAT(@nl, N'== VERDICT', @nl, CASE
    WHEN @WorkerOn = 0
        THEN N'The mail service is OFF: there is no mail server at all (Settings > Notifications > Mail server is empty, and the bookings mailbox has no server and login of its own), so HRMS sends nothing.'
    WHEN @Host IS NULL AND @Alone = 0
        THEN N'There is no mail server for booking mail: the HR Mail server is empty and the bookings mailbox has no server and login of its own.'
    WHEN @NewId IS NOT NULL AND @NewQueued = 0 AND @NewHasMail = 0
        THEN CONCAT(N'The newest booking (', @NewRef, N') has NO guest e-mail address, so there was nobody to write to. Give the booking an e-mail address and try again.')
    WHEN @NewId IS NOT NULL AND @NewQueued = 0
        THEN CONCAT(N'The newest booking (', @NewRef, N') has an e-mail address but no message was written for it: the switch for its status is OFF above, or its status sends no message.')
    WHEN @LastStatus = 'Failed'
        THEN CONCAT(N'Message #', @LastId, N' (', @LastKind, N') FAILED, sent through ', IIF(@LastAcct = 'Booking', N'the bookings mailbox', N'the HR account'), N'. ', @hint)
    WHEN @LastStatus IN ('Pending', 'Sending') AND ISNULL(@LastErr, N'') <> N''
        THEN CONCAT(N'Message #', @LastId, N' (', @LastKind, N') failed and HRMS will try again', IIF(@LastNext IS NULL, N'', CONCAT(N' at ', CONVERT(NVARCHAR(16), @LastNext, 120), N' UTC')), N' (three tries, five minutes apart). ', @hint)
    WHEN @LastStatus IN ('Pending', 'Sending')
        THEN CONCAT(N'Message #', @LastId, N' is still WAITING. ', IIF(@AllWaiting > 20, CONCAT(@AllWaiting, N' messages are waiting and HRMS sends 20 a minute, oldest first. '), N''),
                    N'If it is still waiting after a few minutes the API is not running its mail worker: look at the API log.')
    WHEN @LastStatus = 'Sent' AND @LastAcct = 'Booking'
        THEN CONCAT(N'Message #', @LastId, N' (', @LastKind, N') was SENT through the bookings mailbox and the mail server accepted it. If it did not arrive, look in the spam folder; the rest is between the mail provider and the recipient.')
    WHEN @LastStatus = 'Sent'
        THEN CONCAT(N'Message #', @LastId, N' (', @LastKind, N') was SENT, but through the HR account and as the HR address: when it was written the bookings mailbox had no login (BookingSmtpUser). Bookings made after the login was saved use the bookings mailbox.')
    ELSE N'No booking message in the last 7 days: nothing was written, so nothing could be sent.' END, @nl);

DECLARE @Stale INT = (SELECT COUNT(*) FROM @box WHERE [Status] IN ('Pending', 'Sending') AND CreatedUtc < DATEADD(DAY, -1, @now));
IF @Host IS NULL AND @Alone = 1
    SET @out += CONCAT(N'NOTE: the HR mail server is empty and the bookings mailbox uses its own. That works with the API of 22 Nov 2026 and later; an older API sends nothing until the HR Mail server is filled.', @nl);
IF @Stale > 0
    SET @out += CONCAT(N'CAREFUL: ', @Stale, N' booking message(s) have been waiting for more than a day. The moment mail works they ALL go out, old ones included. Tell Claude before fixing the mail settings.', @nl);

/* PRINT cuts at 4000 characters: line by line. */
DECLARE @p INT = 1, @e INT;
WHILE @p <= LEN(@out)
BEGIN
    SET @e = CHARINDEX(@nl, @out, @p);
    IF @e = 0 SET @e = LEN(@out) + 1;
    PRINT SUBSTRING(@out, @p, @e - @p);
    SET @p = @e + 2;
END
