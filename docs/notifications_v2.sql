/* =============================================================================================
   NOTIFICATIONS v2 - the DATABASE half.

   core.EMAIL_OUTBOX already carries Channel, Lang, AttemptCount and NextAttemptUtc, and
   hr.EMPLOYEE already carries PreferredLanguage. The PROCEDURES over them were never updated,
   which is why the worker cannot see a row's language or its request, why a failed send is
   terminal on the first attempt, and why passing @PreferredLanguage to the employee procedures
   would fail outright with "too many arguments specified".

   Everything here is idempotent: CREATE OR ALTER for the procedures, existence-guarded inserts
   for the settings. Safe to run twice.
   ============================================================================================= */

/* ---- 1. The worker's fetch: language and request, and only rows that are DUE -----------------
   Adds Lang (which template language a WhatsApp message asks for) and RequestInstanceId (what the
   PDF is built from). Also honours NextAttemptUtc, which is what makes the retry below a DELAY
   rather than an immediate re-send on the very next cycle. */
CREATE OR ALTER PROCEDURE [core].[usp_Email_GetPending]
AS BEGIN SET NOCOUNT ON;
    SELECT TOP 20 EmailId, ToAddress, [Subject], Body, Channel, Lang, RequestInstanceId
    FROM core.EMAIL_OUTBOX
    WHERE [Status] = 'Pending'
      AND (NextAttemptUtc IS NULL OR NextAttemptUtc <= SYSUTCDATETIME())
    ORDER BY EmailId;
END;
GO

/* ---- 2. The outcome, WITH the retry ----------------------------------------------------------
   SIGNATURE UNCHANGED, deliberately: the worker reports what happened and nothing else. Whether a
   failure is worth another go is a policy, and a policy living in the worker would be re-decided
   by every future caller of this procedure.

   THREE ATTEMPTS, then it stops. A row that has failed three times is failing for a reason no
   amount of repetition fixes - a wrong address, a rejected password - and the Failed status is
   what puts it in front of a person on the request page. The backoff is 2 then 4 minutes, which
   clears a mail server that was restarting without hammering one that is genuinely refusing. */
CREATE OR ALTER PROCEDURE [core].[usp_Email_MarkResult]
    @EmailId INT, @Ok BIT, @Error NVARCHAR(500) = NULL
AS BEGIN SET NOCOUNT ON;
    IF @Ok = 1
    BEGIN
        UPDATE core.EMAIL_OUTBOX
        SET [Status] = 'Sent', Error = NULL, SentUtc = SYSUTCDATETIME(),
            AttemptCount = AttemptCount + 1, NextAttemptUtc = NULL
        WHERE EmailId = @EmailId;
        RETURN;
    END

    UPDATE core.EMAIL_OUTBOX
    SET AttemptCount   = AttemptCount + 1,
        Error          = @Error,
        /* Still Pending while attempts remain - that IS the retry. Failed only when they run out. */
        [Status]       = CASE WHEN AttemptCount + 1 >= 3 THEN 'Failed' ELSE 'Pending' END,
        NextAttemptUtc = CASE WHEN AttemptCount + 1 >= 3 THEN NULL
                              ELSE DATEADD(MINUTE, POWER(2, AttemptCount + 1), SYSUTCDATETIME()) END
    WHERE EmailId = @EmailId;
END;
GO

/* ---- 3. The WhatsApp settings ----------------------------------------------------------------
   Rows, not code: the settings page renders whatever core.SETTING returns and groups it by
   Section, so these appear under Notifications beside the SMTP values with no frontend change.
   Guarded so a re-run never overwrites a token somebody has since entered. */
IF NOT EXISTS (SELECT 1 FROM core.SETTING WHERE SettingKey = 'WhatsAppEnabled')
    INSERT INTO core.SETTING (SettingKey, SettingValue, DataType, Description, Section, SortOrder)
    VALUES ('WhatsAppEnabled', '0', 'bool',
            'Send request notifications over WhatsApp as well as email. Off until the four values below are filled in.',
            'Notifications', 10);

IF NOT EXISTS (SELECT 1 FROM core.SETTING WHERE SettingKey = 'WhatsAppApiUrl')
    INSERT INTO core.SETTING (SettingKey, SettingValue, DataType, Description, Section, SortOrder)
    VALUES ('WhatsAppApiUrl', 'https://graph.facebook.com/v21.0', 'string',
            'Base URL of the WhatsApp Cloud API, with no trailing slash.', 'Notifications', 11);

IF NOT EXISTS (SELECT 1 FROM core.SETTING WHERE SettingKey = 'WhatsAppPhoneNumberId')
    INSERT INTO core.SETTING (SettingKey, SettingValue, DataType, Description, Section, SortOrder)
    VALUES ('WhatsAppPhoneNumberId', '', 'string',
            'The sending number id from the Meta app dashboard - an id, not the phone number itself.',
            'Notifications', 12);

IF NOT EXISTS (SELECT 1 FROM core.SETTING WHERE SettingKey = 'WhatsAppAccessToken')
    INSERT INTO core.SETTING (SettingKey, SettingValue, DataType, Description, Section, SortOrder)
    VALUES ('WhatsAppAccessToken', '', 'string',
            'Bearer token for the Cloud API. Stored in plain text - treat it as a password and rotate it if it leaks.',
            'Notifications', 13);

IF NOT EXISTS (SELECT 1 FROM core.SETTING WHERE SettingKey = 'WhatsAppTemplateName')
    INSERT INTO core.SETTING (SettingKey, SettingValue, DataType, Description, Section, SortOrder)
    VALUES ('WhatsAppTemplateName', 'request_update', 'string',
            'The approved message template to send. It must take exactly one body parameter.',
            'Notifications', 14);
GO

/* ---- 4. The employee's preferred language ----------------------------------------------------
   The COLUMN already exists and usp_Employee_GetProfile already returns it; only these two write
   procedures never accepted it, so it could be read but never set. Defaulted 'en' so an older
   caller that omits it keeps working unchanged. */
CREATE OR ALTER PROCEDURE [hr].[usp_Employee_Create]
    @UserId INT = NULL, @BranchId INT, @DepartmentId INT, @PositionId INT,
    @FullName NVARCHAR(150), @NationalId VARCHAR(50) = NULL, @NssfNumber VARCHAR(50) = NULL,
    @HireDate DATE, @CreatedBy INT = NULL,
    @Email NVARCHAR(150) = NULL, @PhoneNumber VARCHAR(30) = NULL,
    @PreferredLanguage CHAR(2) = 'en'
AS
BEGIN
    SET NOCOUNT ON;
    IF @UserId IS NOT NULL
    BEGIN
        DECLARE @TakenBy NVARCHAR(150) = (
            SELECT TOP 1 e.FullName FROM hr.EMPLOYEE e
            WHERE e.UserId = @UserId AND e.IsDeleted = 0);
        IF @TakenBy IS NOT NULL
        BEGIN
            RAISERROR('That account is already linked to %s. Unlink it from them first.', 16, 1, @TakenBy);
            RETURN;
        END
    END
    INSERT INTO hr.EMPLOYEE (UserId, BranchId, DepartmentId, PositionId, FullName,
                             NationalId, NssfNumber, HireDate, CreatedBy, Email, PhoneNumber,
                             PreferredLanguage)
    VALUES (@UserId, @BranchId, @DepartmentId, @PositionId, @FullName,
            @NationalId, @NssfNumber, @HireDate, @CreatedBy,
            NULLIF(LTRIM(RTRIM(@Email)), N''), NULLIF(LTRIM(RTRIM(@PhoneNumber)), ''),
            /* Anything that is not 'ar' is 'en'. The column is NOT NULL and two characters wide; a
               typo must land on the language every screen already reads, never on a third state. */
            CASE WHEN LOWER(LTRIM(RTRIM(ISNULL(@PreferredLanguage, 'en')))) = 'ar' THEN 'ar' ELSE 'en' END);
    SELECT CAST(SCOPE_IDENTITY() AS INT) AS EmployeeId;
END;
GO

CREATE OR ALTER PROCEDURE [hr].[usp_Employee_Update]
    @EmployeeId INT, @BranchId INT, @DepartmentId INT, @PositionId INT,
    @FullName NVARCHAR(150), @NationalId VARCHAR(50) = NULL, @NssfNumber VARCHAR(50) = NULL,
    @HireDate DATE, @TerminationDate DATE = NULL, @ModifiedBy INT = NULL,
    @Email NVARCHAR(150) = NULL, @PhoneNumber VARCHAR(30) = NULL,
    @PreferredLanguage CHAR(2) = 'en'
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE hr.EMPLOYEE
    SET BranchId = @BranchId, DepartmentId = @DepartmentId, PositionId = @PositionId,
        FullName = @FullName, NationalId = @NationalId, NssfNumber = @NssfNumber,
        HireDate = @HireDate, TerminationDate = @TerminationDate,
        Email = NULLIF(LTRIM(RTRIM(@Email)), N''),
        PhoneNumber = NULLIF(LTRIM(RTRIM(@PhoneNumber)), ''),
        PreferredLanguage =
            CASE WHEN LOWER(LTRIM(RTRIM(ISNULL(@PreferredLanguage, 'en')))) = 'ar' THEN 'ar' ELSE 'en' END,
        ModifiedAt = SYSUTCDATETIME(), ModifiedBy = @ModifiedBy
    WHERE EmployeeId = @EmployeeId;
END;
GO

/* ---- 5. NotifyOnRequestClosed: normalise the value, do NOT touch the procedure -------------
   core.SETTING stores bools as '1' in some rows and 'true' in others, and
   usp_Email_QueueClosedRequests tests SettingValue <> '1' - so the moment this value was saved as 'true' the
   automatic queue stopped dead while the settings page went on displaying it as ON.

   ONLY THE VALUE IS CORRECTED HERE. The procedure itself is left exactly as it stands: it has been
   rewritten for v2 to queue an Email row and a WhatsApp row per request, each in the employee's own
   language, and re-issuing an older single-channel body over it would undo that silently. The
   frontend writes bools back in whichever dialect the row already holds, so normalising the row once
   is what keeps both halves agreeing from here on.

   If the value ever reverts, the durable fix is to widen the procedure's own test to accept
   ('1','true','yes','on') - a change to make in the v2 procedure, not by replacing it. */
UPDATE core.SETTING SET SettingValue = '1'
WHERE SettingKey = 'NotifyOnRequestClosed'
  AND LOWER(LTRIM(RTRIM(SettingValue))) IN ('true', 'yes', 'on');
GO
