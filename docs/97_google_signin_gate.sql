/* ============================================================================
   97_google_signin_gate.sql - the Google sign-in gate in front of the HRMS: who may pass, its
   settings, the extra addresses and the sign-in log. The specification is docs/GOOGLE_SIGNIN_GATE.md.

   THE IDEA. When the owner or an admin turns it on, nginx asks the API about every request to the
   HRMS host (auth_request). A browser passes when it holds a gate cookie of a person who is allowed
   NOW; the cookie is given after a Google sign-in whose verified email is the Gmail on an active
   employee with an active HRMS login, or an address on the short extra list. The normal HRMS login
   follows, unchanged. Every request re-checks the cookie against this database's answer (kept by the
   API for up to 20 seconds), so blocking someone or "Sign everyone out" works within seconds. The
   answer names each person with their normalised email, and a cookie passes only while its email is
   still that person's: correcting a Gmail ends the cookies made for the old one.
   Off = open as today.

   WHO PASSES (G3): an employee with IsDeleted = 0, not left (TerminationDate NULL or >= Beirut
   today), whose linked HRMS user is active, who is not blocked here and whose Email matches; or an
   active address on security.GATE_EXTRA_EMAIL. Emails are compared normalised
   (security.fn_GateNormalizeEmail): lower case, trimmed, and for gmail.com / googlemail.com the dots
   and a +tag in the part before the @ are ignored.

   COLUMN   hr.EMPLOYEE.GoogleSignInBlocked   1 = the admin switched Google sign-in off for this
                                              employee (the "Allowed" switch on the Settings tab).
   TABLES
     security.GATE_EXTRA_EMAIL   Google accounts that are not employees (the owner, the accountant).
                                 EmailNorm is unique: one row per Google account.
     security.GATE_SIGNIN_LOG    every Google sign-in, allowed or refused, kept 180 days, so the admin
                                 sees who tried with which Gmail. No foreign keys: the wipe and reset
                                 scripts delete employees.
   SETTINGS (core.SETTING, Section 'Security'): GoogleSignInRequired, GoogleClientId,
     GoogleSignInDays, GoogleSignInEpoch. Changed only through usp_Gate_SaveSettings and
     usp_Gate_SignOutEveryone (/api/access, ACCESS_MANAGE); PUT /api/settings/{key} refuses them.
     A re-run keeps the values and refreshes the type, the description and the place on the page.
     A bool is on when its value is 1, true, yes or on (any case).
   PERMISSION ACCESS_MANAGE, granted to Admin and Owner.

   PROCEDURES - the caller is always the last parameter.
     usp_Gate_GetState            the settings and every person allowed now (the API's 20-second cache)
     usp_Gate_SignIn              decides a Google sign-in, writes the log row, prunes the log
     usp_Gate_GetAdmin            the Settings tab: settings, people, extra addresses, recent sign-ins
     usp_Gate_SaveSettings / _SetBlocked / _ExtraEmail_Save / _ExtraEmail_Delete / _SignOutEveryone

   THIS FILE IS DELIBERATELY PURE ASCII (see booking_queue_email.sql): the em dash of two refusals is
   NCHAR(8212), so no client can store it as three other characters.

   Every refusal is RAISERROR(msg,16,1) + RETURN 1.
   Idempotent: IF NOT EXISTS / CREATE OR ALTER. Apply with sqlcmd -C -I (test database: apply-sql-test.sh).
   ============================================================================ */
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ------------------------- 1. the column and the tables ------------------------- */

IF COL_LENGTH('hr.EMPLOYEE', 'GoogleSignInBlocked') IS NULL
    ALTER TABLE hr.EMPLOYEE ADD GoogleSignInBlocked BIT NOT NULL
        CONSTRAINT DF_Employee_GoogleSignInBlocked DEFAULT (0);
GO

IF OBJECT_ID('security.GATE_EXTRA_EMAIL') IS NULL
BEGIN
    CREATE TABLE security.GATE_EXTRA_EMAIL (
        GateExtraEmailId INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_GATE_EXTRA_EMAIL PRIMARY KEY,
        Email            NVARCHAR(254) NOT NULL,       -- as typed (trimmed)
        EmailNorm        NVARCHAR(320) NOT NULL,       -- security.fn_GateNormalizeEmail(Email)
        Note             NVARCHAR(200) NULL,           -- who it is: shown, and the name after a sign-in
        IsActive         BIT           NOT NULL CONSTRAINT DF_GateExtraEmail_IsActive  DEFAULT (1),
        CreatedAt        DATETIME2(3)  NOT NULL CONSTRAINT DF_GateExtraEmail_CreatedAt DEFAULT (SYSUTCDATETIME()),
        CreatedBy        INT           NULL,
        ModifiedAt       DATETIME2(3)  NULL,
        ModifiedBy       INT           NULL
    );
END
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('security.GATE_EXTRA_EMAIL') AND name = 'UQ_GateExtraEmail_EmailNorm')
    CREATE UNIQUE INDEX UQ_GateExtraEmail_EmailNorm ON security.GATE_EXTRA_EMAIL (EmailNorm);
GO

/* Outcome: Allowed | NotFound | Blocked | NoUser | Left. EmployeeId / GateExtraEmailId = the person the attempt
   was decided on (also for a refusal), NULL when nobody matched. */
IF OBJECT_ID('security.GATE_SIGNIN_LOG') IS NULL
BEGIN
    CREATE TABLE security.GATE_SIGNIN_LOG (
        GateSignInLogId  BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_GATE_SIGNIN_LOG PRIMARY KEY,
        AttemptedAt      DATETIME2(3)  NOT NULL CONSTRAINT DF_GateSignInLog_AttemptedAt DEFAULT (SYSUTCDATETIME()),
        Email            NVARCHAR(320) NOT NULL,       -- as Google gave it (trimmed)
        GoogleSub        VARCHAR(255)  NULL,
        Outcome          VARCHAR(20)   NOT NULL,
        EmployeeId       INT           NULL,
        GateExtraEmailId INT           NULL,
        Ip               VARCHAR(45)   NULL,
        UserAgent        NVARCHAR(300) NULL
    );
END
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('security.GATE_SIGNIN_LOG') AND name = 'IX_GateSignInLog_AttemptedAt')
    CREATE INDEX IX_GateSignInLog_AttemptedAt ON security.GATE_SIGNIN_LOG (AttemptedAt);
GO

/* ------------------------- 2. settings (Section 'Security') ------------------------- */
DECLARE @s TABLE (SettingKey VARCHAR(60), SettingValue NVARCHAR(200), DataType VARCHAR(60), [Description] NVARCHAR(300), Section VARCHAR(30), SortOrder INT);
INSERT INTO @s (SettingKey, SettingValue, DataType, [Description], Section, SortOrder) VALUES
 ('GoogleSignInRequired', '0', 'bool',
  N'1 = whoever opens the HRMS first signs in with a Google account that is on the list. 0 = open as before. Changed only on the Google sign-in tab of Settings.', 'Security', 10),
 ('GoogleClientId', '', 'string',
  N'The Google client ID of the sign-in button (it ends with .apps.googleusercontent.com). Changed only on the Google sign-in tab of Settings.', 'Security', 20),
 ('GoogleSignInDays', '30', 'int',
  N'How many days a Google sign-in lasts in a browser before Google is asked again (1 to 365).', 'Security', 30),
 ('GoogleSignInEpoch', '1', 'int',
  N'Goes up by one with "Sign everyone out": every Google sign-in made before stops working.', 'Security', 40);

INSERT INTO core.SETTING (SettingKey, SettingValue, DataType, [Description], Section, SortOrder, ModifiedAt)
SELECT s.SettingKey, s.SettingValue, s.DataType, s.[Description], s.Section, s.SortOrder, SYSUTCDATETIME()
FROM @s s
WHERE NOT EXISTS (SELECT 1 FROM core.SETTING x WHERE x.SettingKey = s.SettingKey);
PRINT CONCAT('SETTINGS | Security: ', @@ROWCOUNT, ' new key(s)');

/* a re-run keeps the values; the type, the description and the place on the Settings page follow this script */
UPDATE x
SET x.DataType = s.DataType, x.[Description] = s.[Description], x.Section = s.Section, x.SortOrder = s.SortOrder
FROM core.SETTING x
JOIN @s s ON s.SettingKey = x.SettingKey;
GO

/* ------------------------- 3. the permission ------------------------- */
IF NOT EXISTS (SELECT 1 FROM security.PERMISSION WHERE Code = 'ACCESS_MANAGE')
BEGIN
    INSERT INTO security.PERMISSION (Code, Name, Module)
    VALUES ('ACCESS_MANAGE', N'Turn Google sign-in on or off and manage who can open the HRMS', 'Security');
    PRINT 'permission ACCESS_MANAGE created';
END
ELSE PRINT 'permission ACCESS_MANAGE already there';

DECLARE @granted TABLE (RoleId INT);
INSERT INTO security.ROLE_PERMISSION (RoleId, PermissionId)
OUTPUT inserted.RoleId INTO @granted
SELECT r.RoleId, p.PermissionId
FROM security.[ROLE] r
CROSS JOIN security.PERMISSION p
WHERE p.Code = 'ACCESS_MANAGE'
  AND r.Name IN (N'Admin', N'Owner')
  AND NOT EXISTS (SELECT 1 FROM security.ROLE_PERMISSION x WHERE x.RoleId = r.RoleId AND x.PermissionId = p.PermissionId);
DECLARE @g NVARCHAR(400) = (SELECT STRING_AGG(r.Name, N', ') WITHIN GROUP (ORDER BY r.Name)
                            FROM @granted g JOIN security.[ROLE] r ON r.RoleId = g.RoleId);
PRINT CONCAT('ACCESS_MANAGE granted now to: ', ISNULL(@g, N'(nobody - already granted)'));
GO

/* ------------------------- 4. security.fn_GateNormalizeEmail ------------------------- */
/* The form two addresses are compared in. NULL or blank -> NULL. Trimmed and lower-cased, split at the LAST @
   (none -> returned as it is). For gmail.com and googlemail.com Google ignores the dots and a +tag in the part
   before the @, and googlemail.com is gmail.com: John.Doe+hr@GoogleMail.com -> johndoe@gmail.com. Any other
   domain (Google Workspace) keeps its dots and +tag. */
CREATE OR ALTER FUNCTION security.fn_GateNormalizeEmail (@Email NVARCHAR(320))
RETURNS NVARCHAR(320)
WITH SCHEMABINDING
AS
BEGIN
    DECLARE @e NVARCHAR(320) = LOWER(LTRIM(RTRIM(@Email)));
    IF @e IS NULL OR @e = N'' RETURN NULL;
    IF CHARINDEX(N'@', @e) = 0 RETURN @e;

    DECLARE @At INT = LEN(@e) - CHARINDEX(N'@', REVERSE(@e)) + 1;     -- the last @
    DECLARE @Local NVARCHAR(320) = LEFT(@e, @At - 1);
    DECLARE @Domain NVARCHAR(320) = SUBSTRING(@e, @At + 1, 320);
    IF @Domain IN (N'gmail.com', N'googlemail.com')
    BEGIN
        IF CHARINDEX(N'+', @Local) > 0 SET @Local = LEFT(@Local, CHARINDEX(N'+', @Local) - 1);
        SET @Local = REPLACE(@Local, N'.', N'');
        SET @Domain = N'gmail.com';
    END
    RETURN @Local + N'@' + @Domain;
END;
GO

/* ------------------------- 5. what the API reads ------------------------- */
/* RS1 the settings, read the way every reader must read them: Required on for 1/true/yes/on, Days a whole number
   1..365 (30 when missing, blank or unreadable), Epoch 1 when missing, blank or unreadable, ClientId trimmed ('' when
   missing). A blank counts as missing: TRY_CAST('' AS INT) alone would give 0.
   RS2 every person allowed now: 'e' + EmployeeId (G3), 'x' + GateExtraEmailId (an active extra address), each with
   EmailNorm, their normalised email (the same text usp_Gate_SignIn gives them). The API keeps this for 20 seconds
   and lets a cookie through only while its person is in it WITH the email the cookie was made for: when the admin
   corrects an employee's Gmail or edits an extra address, or an id is reused after a reseed, the old cookies stop. */
CREATE OR ALTER PROCEDURE security.usp_Gate_GetState
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE);

    DECLARE @Required NVARCHAR(200) = (SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'GoogleSignInRequired');
    DECLARE @ClientId NVARCHAR(200) = (SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'GoogleClientId');
    DECLARE @Days     INT = TRY_CAST((SELECT NULLIF(LTRIM(RTRIM(SettingValue)), N'') FROM core.SETTING WHERE SettingKey = 'GoogleSignInDays') AS INT);
    DECLARE @Epoch    INT = TRY_CAST((SELECT NULLIF(LTRIM(RTRIM(SettingValue)), N'') FROM core.SETTING WHERE SettingKey = 'GoogleSignInEpoch') AS INT);
    SET @Days = ISNULL(@Days, 30);
    IF @Days < 1   SET @Days = 1;
    IF @Days > 365 SET @Days = 365;

    SELECT CAST(CASE WHEN LOWER(LTRIM(RTRIM(@Required))) IN (N'1', N'true', N'yes', N'on') THEN 1 ELSE 0 END AS BIT) AS Required,
           CAST(LTRIM(RTRIM(ISNULL(@ClientId, N''))) AS NVARCHAR(200)) AS ClientId,
           @Days AS Days,
           ISNULL(@Epoch, 1) AS Epoch;

    SELECT CAST('e' AS CHAR(1)) AS Kind, e.EmployeeId AS PersonId, security.fn_GateNormalizeEmail(e.Email) AS EmailNorm
    FROM hr.EMPLOYEE e
    JOIN security.[USER] u ON u.UserId = e.UserId
    WHERE e.IsDeleted = 0
      AND (e.TerminationDate IS NULL OR e.TerminationDate >= @Today)
      AND u.IsActive = 1
      AND e.GoogleSignInBlocked = 0
      AND security.fn_GateNormalizeEmail(e.Email) IS NOT NULL
    UNION ALL
    SELECT CAST('x' AS CHAR(1)), x.GateExtraEmailId, x.EmailNorm
    FROM security.GATE_EXTRA_EMAIL x
    WHERE x.IsActive = 1
    ORDER BY Kind, PersonId;
END;
GO

/* A Google sign-in whose token the API has already verified. Decided in this order:
     1. an active extra address with the same normalised email -> Allowed 'x' (the name shown: its Note, else the
        address);
     2. the employees (IsDeleted = 0) with that email: none -> NotFound; one who has not left, has an active login
        and is not blocked -> Allowed 'e' (the lowest EmployeeId when two share a Gmail); someone who would pass but
        all such are blocked -> Blocked; someone who has not left (no active login) -> NoUser; else Left.
   Kind / PersonId / DisplayName / EmailNorm are given for Allowed only. EmailNorm is that person's normalised email,
   the same text usp_Gate_GetState gives them: the API puts it in the cookie. One log row per call (the email as
   given, trimmed); rows older than 180 days go. */
CREATE OR ALTER PROCEDURE security.usp_Gate_SignIn
    @Email     NVARCHAR(320),
    @GoogleSub VARCHAR(255)  = NULL,
    @Ip        VARCHAR(45)   = NULL,
    @UserAgent NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @Today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE);
    DECLARE @Norm NVARCHAR(320) = security.fn_GateNormalizeEmail(@Email);
    DECLARE @Outcome VARCHAR(20), @Kind CHAR(1), @PersonId INT, @DisplayName NVARCHAR(150), @EmailNorm NVARCHAR(320),
            @ExtraId INT, @EmployeeId INT, @ExtraName NVARCHAR(150), @ExtraNorm NVARCHAR(320), @EmployeeNorm NVARCHAR(320);

    SELECT TOP (1) @ExtraId = x.GateExtraEmailId,
                   @ExtraName = LEFT(COALESCE(NULLIF(LTRIM(RTRIM(x.Note)), N''), x.Email), 150),
                   @ExtraNorm = x.EmailNorm
    FROM security.GATE_EXTRA_EMAIL x
    WHERE x.IsActive = 1 AND x.EmailNorm = @Norm
    ORDER BY x.GateExtraEmailId;

    IF @ExtraId IS NOT NULL
        SELECT @Outcome = 'Allowed', @Kind = 'x', @PersonId = @ExtraId, @DisplayName = @ExtraName, @EmailNorm = @ExtraNorm;
    ELSE
    BEGIN
        DECLARE @cand TABLE (EmployeeId INT PRIMARY KEY, FullName NVARCHAR(150), EmailNorm NVARCHAR(320), NotLeft BIT, UserActive BIT, Blocked BIT);
        INSERT INTO @cand (EmployeeId, FullName, EmailNorm, NotLeft, UserActive, Blocked)
        SELECT e.EmployeeId, e.FullName, security.fn_GateNormalizeEmail(e.Email),
               CASE WHEN e.TerminationDate IS NULL OR e.TerminationDate >= @Today THEN 1 ELSE 0 END,
               CASE WHEN u.IsActive = 1 THEN 1 ELSE 0 END,
               e.GoogleSignInBlocked
        FROM hr.EMPLOYEE e
        LEFT JOIN security.[USER] u ON u.UserId = e.UserId
        WHERE e.IsDeleted = 0
          AND @Norm IS NOT NULL
          AND security.fn_GateNormalizeEmail(e.Email) = @Norm;

        SELECT TOP (1) @EmployeeId = c.EmployeeId, @DisplayName = c.FullName, @EmployeeNorm = c.EmailNorm
        FROM @cand c WHERE c.NotLeft = 1 AND c.UserActive = 1 AND c.Blocked = 0
        ORDER BY c.EmployeeId;

        IF @EmployeeId IS NOT NULL
            SELECT @Outcome = 'Allowed', @Kind = 'e', @PersonId = @EmployeeId, @EmailNorm = @EmployeeNorm;
        ELSE IF NOT EXISTS (SELECT 1 FROM @cand)
            SET @Outcome = 'NotFound';
        ELSE IF EXISTS (SELECT 1 FROM @cand WHERE NotLeft = 1 AND UserActive = 1)
            SELECT @Outcome = 'Blocked', @EmployeeId = MIN(EmployeeId) FROM @cand WHERE NotLeft = 1 AND UserActive = 1;
        ELSE IF EXISTS (SELECT 1 FROM @cand WHERE NotLeft = 1)
            SELECT @Outcome = 'NoUser', @EmployeeId = MIN(EmployeeId) FROM @cand WHERE NotLeft = 1;
        ELSE
            SELECT @Outcome = 'Left', @EmployeeId = MIN(EmployeeId) FROM @cand;
    END

    INSERT INTO security.GATE_SIGNIN_LOG (Email, GoogleSub, Outcome, EmployeeId, GateExtraEmailId, Ip, UserAgent)
    VALUES (LEFT(LTRIM(RTRIM(ISNULL(@Email, N''))), 320), @GoogleSub, @Outcome, @EmployeeId, @ExtraId, @Ip, @UserAgent);

    DELETE FROM security.GATE_SIGNIN_LOG WHERE AttemptedAt < DATEADD(DAY, -180, SYSUTCDATETIME());

    SELECT @Outcome AS Outcome, @Kind AS Kind, @PersonId AS PersonId, @DisplayName AS DisplayName, @EmailNorm AS EmailNorm;
    RETURN 0;
END;
GO

/* ------------------------- 6. the Settings tab ------------------------- */
/* RS1 the settings as usp_Gate_GetState reads them, and when the switch row was last saved.
   RS2 every employee (IsDeleted = 0) with why they pass or not. Status, the first that applies: Left, NoEmail,
       NoUser (no login), UserDisabled, Blocked, Allowed. LastSignInAt = their latest Allowed sign-in.
   RS3 the extra addresses.  RS4 the last 100 sign-ins, newest first. */
CREATE OR ALTER PROCEDURE security.usp_Gate_GetAdmin
    @CallerUserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE);

    DECLARE @Required NVARCHAR(200), @ModifiedAt DATETIME2;
    SELECT @Required = SettingValue, @ModifiedAt = ModifiedAt FROM core.SETTING WHERE SettingKey = 'GoogleSignInRequired';
    DECLARE @ClientId NVARCHAR(200) = (SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'GoogleClientId');
    DECLARE @Days     INT = TRY_CAST((SELECT NULLIF(LTRIM(RTRIM(SettingValue)), N'') FROM core.SETTING WHERE SettingKey = 'GoogleSignInDays') AS INT);
    DECLARE @Epoch    INT = TRY_CAST((SELECT NULLIF(LTRIM(RTRIM(SettingValue)), N'') FROM core.SETTING WHERE SettingKey = 'GoogleSignInEpoch') AS INT);
    SET @Days = ISNULL(@Days, 30);
    IF @Days < 1   SET @Days = 1;
    IF @Days > 365 SET @Days = 365;

    SELECT CAST(CASE WHEN LOWER(LTRIM(RTRIM(@Required))) IN (N'1', N'true', N'yes', N'on') THEN 1 ELSE 0 END AS BIT) AS Required,
           CAST(LTRIM(RTRIM(ISNULL(@ClientId, N''))) AS NVARCHAR(200)) AS ClientId,
           @Days AS Days,
           ISNULL(@Epoch, 1) AS Epoch,
           @ModifiedAt AS ModifiedAt;

    SELECT e.EmployeeId, e.FullName, b.Name AS BranchName, e.Email,
           e.UserId, u.Username, u.IsActive AS UserIsActive, e.TerminationDate,
           e.GoogleSignInBlocked AS IsBlocked,
           CAST(CASE WHEN e.TerminationDate < @Today                          THEN 'Left'
                     WHEN security.fn_GateNormalizeEmail(e.Email) IS NULL      THEN 'NoEmail'
                     WHEN u.UserId IS NULL                                     THEN 'NoUser'
                     WHEN ISNULL(u.IsActive, 0) = 0                            THEN 'UserDisabled'
                     WHEN e.GoogleSignInBlocked = 1                            THEN 'Blocked'
                     ELSE 'Allowed' END AS VARCHAR(20)) AS Status,
           (SELECT MAX(l.AttemptedAt) FROM security.GATE_SIGNIN_LOG l
            WHERE l.EmployeeId = e.EmployeeId AND l.Outcome = 'Allowed') AS LastSignInAt
    FROM hr.EMPLOYEE e
    LEFT JOIN hr.BRANCH b ON b.BranchId = e.BranchId
    LEFT JOIN security.[USER] u ON u.UserId = e.UserId
    WHERE e.IsDeleted = 0
    ORDER BY e.FullName, e.EmployeeId;

    SELECT x.GateExtraEmailId, x.Email, x.Note, x.IsActive, x.CreatedAt,
           (SELECT MAX(l.AttemptedAt) FROM security.GATE_SIGNIN_LOG l
            WHERE l.GateExtraEmailId = x.GateExtraEmailId AND l.Outcome = 'Allowed') AS LastSignInAt
    FROM security.GATE_EXTRA_EMAIL x
    ORDER BY x.Email, x.GateExtraEmailId;

    SELECT TOP (100) l.GateSignInLogId, l.AttemptedAt, l.Email, l.Outcome, l.EmployeeId, e.FullName, l.Ip
    FROM security.GATE_SIGNIN_LOG l
    LEFT JOIN hr.EMPLOYEE e ON e.EmployeeId = l.EmployeeId
    ORDER BY l.AttemptedAt DESC, l.GateSignInLogId DESC;
END;
GO

/* The switch, the client ID and the days. The API refuses to turn it on unless the caller's own browser has
   passed Google just now (no lock-out); here only the values themselves are checked. */
CREATE OR ALTER PROCEDURE security.usp_Gate_SaveSettings
    @Required     BIT,
    @ClientId     NVARCHAR(200),
    @Days         INT,
    @CallerUserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @Dash NCHAR(1) = NCHAR(8212);   -- em dash, spelled out; see the header
    SET @Required = ISNULL(@Required, 0);
    SET @ClientId = LTRIM(RTRIM(ISNULL(@ClientId, N'')));

    IF @Days IS NULL OR @Days < 1 OR @Days > 365
    BEGIN RAISERROR('Keep a Google sign-in between 1 and 365 days.', 16, 1); RETURN 1; END
    IF @ClientId <> N'' AND @ClientId NOT LIKE N'%_.apps.googleusercontent.com'
    BEGIN RAISERROR(N'That is not a Google client ID %s it ends with .apps.googleusercontent.com.', 16, 1, @Dash); RETURN 1; END
    IF @Required = 1 AND @ClientId = N''
    BEGIN RAISERROR('Enter the Google client ID before turning Google sign-in on.', 16, 1); RETURN 1; END

    DECLARE @v TABLE (SettingKey VARCHAR(60), SettingValue NVARCHAR(200), DataType VARCHAR(60), SortOrder INT);
    INSERT INTO @v (SettingKey, SettingValue, DataType, SortOrder) VALUES
        ('GoogleSignInRequired', CASE WHEN @Required = 1 THEN N'1' ELSE N'0' END, 'bool',   10),
        ('GoogleClientId',       @ClientId,                                      'string', 20),
        ('GoogleSignInDays',     CAST(@Days AS NVARCHAR(10)),                    'int',    30);

    BEGIN TRAN;
        UPDATE x
        SET x.SettingValue = v.SettingValue, x.ModifiedAt = SYSUTCDATETIME(), x.ModifiedBy = @CallerUserId
        FROM core.SETTING x
        JOIN @v v ON v.SettingKey = x.SettingKey;
        /* a row deleted by hand comes back (a re-run of this script gives it its description again) */
        INSERT INTO core.SETTING (SettingKey, SettingValue, DataType, Section, SortOrder, ModifiedAt, ModifiedBy)
        SELECT v.SettingKey, v.SettingValue, v.DataType, 'Security', v.SortOrder, SYSUTCDATETIME(), @CallerUserId
        FROM @v v
        WHERE NOT EXISTS (SELECT 1 FROM core.SETTING x WHERE x.SettingKey = v.SettingKey);
    COMMIT;
    RETURN 0;
END;
GO

/* The "Allowed" switch of one employee. Nobody can block the employee their own login belongs to. */
CREATE OR ALTER PROCEDURE security.usp_Gate_SetBlocked
    @EmployeeId   INT,
    @Blocked      BIT,
    @CallerUserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @Dash NCHAR(1) = NCHAR(8212);   -- em dash, spelled out; see the header
    SET @Blocked = ISNULL(@Blocked, 0);

    IF NOT EXISTS (SELECT 1 FROM hr.EMPLOYEE WHERE EmployeeId = @EmployeeId AND IsDeleted = 0)
    BEGIN RAISERROR('Employee not found.', 16, 1); RETURN 1; END
    IF @Blocked = 1 AND EXISTS (SELECT 1 FROM hr.EMPLOYEE WHERE EmployeeId = @EmployeeId AND UserId = @CallerUserId)
    BEGIN RAISERROR(N'You can''t block yourself %s you would lose access.', 16, 1, @Dash); RETURN 1; END

    UPDATE hr.EMPLOYEE
    SET GoogleSignInBlocked = @Blocked, ModifiedAt = SYSUTCDATETIME(), ModifiedBy = @CallerUserId
    WHERE EmployeeId = @EmployeeId;
    RETURN 0;
END;
GO

/* ------------------------- 7. the extra addresses ------------------------- */
/* Adds (@GateExtraEmailId NULL) or changes one address. A full address: one @, text before it, and a dot with text
   on both sides after it. One row per Google account: john.doe@gmail.com and johndoe+x@gmail.com are the same. */
CREATE OR ALTER PROCEDURE security.usp_Gate_ExtraEmail_Save
    @GateExtraEmailId INT = NULL,
    @Email            NVARCHAR(254),
    @Note             NVARCHAR(200) = NULL,
    @IsActive         BIT = NULL,           -- NULL = active for a new address, unchanged for an existing one
    @CallerUserId     INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @Email = LTRIM(RTRIM(@Email));
    SET @Note  = NULLIF(LTRIM(RTRIM(@Note)), N'');

    IF @Email IS NULL
       OR DATALENGTH(@Email) - DATALENGTH(REPLACE(@Email, N'@', N'')) <> 2      -- exactly one @ (2 bytes each)
       OR @Email NOT LIKE N'_%@_%._%'
    BEGIN RAISERROR('Enter a full Google email address.', 16, 1); RETURN 1; END
    IF @GateExtraEmailId IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM security.GATE_EXTRA_EMAIL WHERE GateExtraEmailId = @GateExtraEmailId)
    BEGIN RAISERROR('That address is not on the list.', 16, 1); RETURN 1; END

    DECLARE @Norm NVARCHAR(320) = security.fn_GateNormalizeEmail(@Email);
    IF EXISTS (SELECT 1 FROM security.GATE_EXTRA_EMAIL
               WHERE EmailNorm = @Norm AND (@GateExtraEmailId IS NULL OR GateExtraEmailId <> @GateExtraEmailId))
    BEGIN RAISERROR('This Gmail is already on the list.', 16, 1); RETURN 1; END

    IF @GateExtraEmailId IS NULL
    BEGIN
        INSERT INTO security.GATE_EXTRA_EMAIL (Email, EmailNorm, Note, IsActive, CreatedBy)
        VALUES (@Email, @Norm, @Note, ISNULL(@IsActive, 1), @CallerUserId);
        SET @GateExtraEmailId = CAST(SCOPE_IDENTITY() AS INT);
    END
    ELSE
        UPDATE security.GATE_EXTRA_EMAIL
        SET Email = @Email, EmailNorm = @Norm, Note = @Note, IsActive = ISNULL(@IsActive, IsActive),
            ModifiedAt = SYSUTCDATETIME(), ModifiedBy = @CallerUserId
        WHERE GateExtraEmailId = @GateExtraEmailId;

    SELECT @GateExtraEmailId AS GateExtraEmailId;
    RETURN 0;
END;
GO

/* Its log rows stay (with the id): the Recent sign-ins list still shows the address that was used. */
CREATE OR ALTER PROCEDURE security.usp_Gate_ExtraEmail_Delete
    @GateExtraEmailId INT,
    @CallerUserId     INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF NOT EXISTS (SELECT 1 FROM security.GATE_EXTRA_EMAIL WHERE GateExtraEmailId = @GateExtraEmailId)
    BEGIN RAISERROR('That address is not on the list.', 16, 1); RETURN 1; END

    DELETE FROM security.GATE_EXTRA_EMAIL WHERE GateExtraEmailId = @GateExtraEmailId;
    RETURN 0;
END;
GO

/* ------------------------- 8. sign everyone out ------------------------- */
/* Every gate cookie carries the epoch it was made in; one more makes all of them invalid at the API's next read.
   An unreadable or missing value counts as 1 (as usp_Gate_GetState reads it). Result: the new Epoch. */
CREATE OR ALTER PROCEDURE security.usp_Gate_SignOutEveryone
    @CallerUserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @Epoch INT;

    BEGIN TRAN;
        SELECT @Epoch = TRY_CAST(NULLIF(LTRIM(RTRIM(SettingValue)), N'') AS INT)
        FROM core.SETTING WITH (UPDLOCK, HOLDLOCK)
        WHERE SettingKey = 'GoogleSignInEpoch';
        SET @Epoch = ISNULL(@Epoch, 1) + 1;

        UPDATE core.SETTING
        SET SettingValue = CAST(@Epoch AS NVARCHAR(10)), ModifiedAt = SYSUTCDATETIME(), ModifiedBy = @CallerUserId
        WHERE SettingKey = 'GoogleSignInEpoch';
        IF @@ROWCOUNT = 0
            INSERT INTO core.SETTING (SettingKey, SettingValue, DataType, Section, SortOrder, ModifiedAt, ModifiedBy)
            VALUES ('GoogleSignInEpoch', CAST(@Epoch AS NVARCHAR(10)), 'int', 'Security', 40, SYSUTCDATETIME(), @CallerUserId);
    COMMIT;

    SELECT @Epoch AS Epoch;
    RETURN 0;
END;
GO

PRINT 'Google sign-in gate: column, tables, Security settings, ACCESS_MANAGE and procedures in place';
GO
