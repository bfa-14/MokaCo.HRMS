/* ============================================================================
   51_email_notifications.sql — email the employee when their request CLOSES.
   · hr.EMPLOYEE + Email / PhoneNumber (form fields via prompts; phone is
     stored now — SMS needs a gateway provider later).
   · Company mail settings (Section "Notifications"): SmtpHost/Port/User/
     Password/FromEmail/FromName + NotifyOnRequestClosed.
   · Outbox pattern: core.EMAIL_OUTBOX + queue/fetch/mark procs; a backend
     worker sends via SMTP. One email per request, queued only for requests
     closed in the last 7 days (first run doesn't mail history).
   Idempotent. Run in SSMS against MokaCo_HRMS.
   ============================================================================ */

/* ---- 1. Contact fields ------------------------------------------------------ */
IF COL_LENGTH('hr.EMPLOYEE','Email') IS NULL
    ALTER TABLE hr.EMPLOYEE ADD Email NVARCHAR(150) NULL;
IF COL_LENGTH('hr.EMPLOYEE','PhoneNumber') IS NULL
    ALTER TABLE hr.EMPLOYEE ADD PhoneNumber VARCHAR(30) NULL;
GO

CREATE OR ALTER PROCEDURE [hr].[usp_Employee_Create]
    @UserId INT = NULL, @BranchId INT, @DepartmentId INT, @PositionId INT,
    @FullName NVARCHAR(150), @NationalId VARCHAR(50) = NULL, @NssfNumber VARCHAR(50) = NULL,
    @HireDate DATE, @CreatedBy INT = NULL,
    @Email NVARCHAR(150) = NULL, @PhoneNumber VARCHAR(30) = NULL
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
                             NationalId, NssfNumber, HireDate, CreatedBy, Email, PhoneNumber)
    VALUES (@UserId, @BranchId, @DepartmentId, @PositionId, @FullName,
            @NationalId, @NssfNumber, @HireDate, @CreatedBy,
            NULLIF(LTRIM(RTRIM(@Email)), N''), NULLIF(LTRIM(RTRIM(@PhoneNumber)), ''));
    SELECT CAST(SCOPE_IDENTITY() AS INT) AS EmployeeId;
END;
GO

CREATE OR ALTER PROCEDURE [hr].[usp_Employee_Update]
    @EmployeeId INT, @BranchId INT, @DepartmentId INT, @PositionId INT,
    @FullName NVARCHAR(150), @NationalId VARCHAR(50) = NULL, @NssfNumber VARCHAR(50) = NULL,
    @HireDate DATE, @TerminationDate DATE = NULL, @ModifiedBy INT = NULL,
    @Email NVARCHAR(150) = NULL, @PhoneNumber VARCHAR(30) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE hr.EMPLOYEE
    SET BranchId = @BranchId, DepartmentId = @DepartmentId, PositionId = @PositionId,
        FullName = @FullName, NationalId = @NationalId, NssfNumber = @NssfNumber,
        HireDate = @HireDate, TerminationDate = @TerminationDate,
        Email = NULLIF(LTRIM(RTRIM(@Email)), N''),
        PhoneNumber = NULLIF(LTRIM(RTRIM(@PhoneNumber)), ''),
        ModifiedAt = SYSUTCDATETIME(), ModifiedBy = @ModifiedBy
    WHERE EmployeeId = @EmployeeId;
END;
GO
PRINT '1) Email/PhoneNumber on EMPLOYEE + Create/Update carry them (GetProfile is SELECT e.* — flows).';
GO

/* ---- 2. Company mail settings ---------------------------------------------- */
INSERT INTO core.SETTING (SettingKey, SettingValue, DataType, [Description], Section, SortOrder)
SELECT v.K, v.V, v.T, v.D, 'Notifications', v.S
FROM (VALUES
 ('SmtpHost',              '',              'string', 'Mail server host. Empty = email sending disabled.',            1),
 ('SmtpPort',              '587',           'int',    'Mail server port (587 = STARTTLS).',                           2),
 ('SmtpUser',              '',              'string', 'Mail account user name.',                                      3),
 ('SmtpPassword',          '',              'string', 'Mail account password.',                                       4),
 ('SmtpFromEmail',         '',              'string', 'The company address the system sends from.',                   5),
 ('SmtpFromName',          'MokaCo HRMS',   'string', 'Display name on outgoing mail.',                               6),
 ('NotifyOnRequestClosed', '1',             'bool',   'Email the employee when their request is approved or rejected.', 7)
) v(K, V, T, D, S)
WHERE NOT EXISTS (SELECT 1 FROM core.SETTING s WHERE s.SettingKey = v.K);
GO
PRINT '2) Notification settings seeded (Section: Notifications).';
GO

/* ---- 3. Outbox -------------------------------------------------------------- */
IF OBJECT_ID('core.EMAIL_OUTBOX') IS NULL
BEGIN
    CREATE TABLE core.EMAIL_OUTBOX (
        EmailId           INT IDENTITY(1,1) PRIMARY KEY,
        ToAddress         NVARCHAR(150) NOT NULL,
        [Subject]         NVARCHAR(200) NOT NULL,
        Body              NVARCHAR(MAX) NOT NULL,
        RequestInstanceId INT NULL,
        [Status]          VARCHAR(10) NOT NULL DEFAULT('Pending'),  -- Pending/Sent/Failed
        Error             NVARCHAR(500) NULL,
        CreatedUtc        DATETIME2 NOT NULL DEFAULT(SYSUTCDATETIME()),
        SentUtc           DATETIME2 NULL);
    CREATE UNIQUE INDEX UX_EMAIL_OUTBOX_Request
        ON core.EMAIL_OUTBOX(RequestInstanceId) WHERE RequestInstanceId IS NOT NULL;
END
GO

CREATE OR ALTER PROCEDURE [core].[usp_Email_QueueClosedRequests]
AS
BEGIN
    SET NOCOUNT ON;
    IF ISNULL((SELECT SettingValue FROM core.SETTING
               WHERE SettingKey='NotifyOnRequestClosed'), '1') <> '1' RETURN;

    INSERT INTO core.EMAIL_OUTBOX (ToAddress, [Subject], Body, RequestInstanceId)
    SELECT e.Email,
           CONCAT(N'Request #', r.RequestInstanceId, N' ', r.[Status], N' — ', rt.Name),
           CONCAT(N'Dear ', e.FullName, N',', CHAR(13), CHAR(10), CHAR(13), CHAR(10),
                  N'Your request #', r.RequestInstanceId, N' (', rt.Name,
                  CASE WHEN r.Title IS NOT NULL AND r.Title <> N''
                       THEN CONCAT(N' — ', r.Title) ELSE N'' END,
                  N') was ', LOWER(r.[Status]), N' on ',
                  CONVERT(char(10), r.ClosedAt, 120), N'.',
                  CASE WHEN r.ClosedReason IS NOT NULL AND r.ClosedReason <> N''
                       THEN CONCAT(CHAR(13), CHAR(10), N'Note: ', r.ClosedReason) ELSE N'' END,
                  CHAR(13), CHAR(10), CHAR(13), CHAR(10), N'MokaCo HRMS'),
           r.RequestInstanceId
    FROM workflow.REQUEST_INSTANCE r
    JOIN workflow.REQUEST_TYPE rt ON rt.RequestTypeId = r.RequestTypeId
    JOIN hr.EMPLOYEE e ON e.EmployeeId = r.EmployeeId AND e.IsDeleted = 0
    WHERE r.[Status] IN ('Approved','Rejected')
      AND r.ClosedAt >= DATEADD(DAY, -7, SYSUTCDATETIME())
      AND e.Email IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM core.EMAIL_OUTBOX o
                      WHERE o.RequestInstanceId = r.RequestInstanceId);
    SELECT @@ROWCOUNT AS Queued;
END;
GO

CREATE OR ALTER PROCEDURE [core].[usp_Email_GetPending]
AS BEGIN SET NOCOUNT ON;
    SELECT TOP 20 EmailId, ToAddress, [Subject], Body
    FROM core.EMAIL_OUTBOX WHERE [Status] = 'Pending' ORDER BY EmailId;
END;
GO

CREATE OR ALTER PROCEDURE [core].[usp_Email_MarkResult]
    @EmailId INT, @Ok BIT, @Error NVARCHAR(500) = NULL
AS BEGIN SET NOCOUNT ON;
    UPDATE core.EMAIL_OUTBOX
    SET [Status] = CASE WHEN @Ok = 1 THEN 'Sent' ELSE 'Failed' END,
        Error = @Error, SentUtc = CASE WHEN @Ok = 1 THEN SYSUTCDATETIME() END
    WHERE EmailId = @EmailId;
END;
GO
PRINT '3) Outbox + queue/fetch/mark procs installed.';
