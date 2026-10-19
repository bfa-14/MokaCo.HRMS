/* ============================================================================
   105_qa3_security.sql - QA3 (deep test, 2026-10-19), unit G (security and platform).

   SEC-5  A PASSWORD CHANGE OR A DISABLE ENDS THE ACCOUNT'S SESSIONS.
          Before: a refresh token outlived both (it rotated forever after the password changed, and a
          disabled account's tokens worked again once it was re-enabled), and an access token stayed
          good until it expired.
          - security.[USER].SessionStamp (NEW column, UNIQUEIDENTIFIER NULL): changes whenever the
            account's sessions are ended. Every access token carries the stamp it was issued under
            (claim "sstamp"); the API refuses a token whose stamp is no longer the account's.
          - security.usp_User_EndSessions (NEW): a new stamp and every refresh token revoked, in one
            transaction. The API calls it after a password change and after a disable.
          - security.usp_RefreshToken_RotateChecked (NEW; replaces usp_RefreshToken_Rotate for the API):
            the base rotation, refused for a disabled account, returning the stamp with the new token.
          - security.usp_RefreshToken_Issue (NEW; replaces the API's inline INSERT at sign-in): the
            token is issued only while the account is active and its password hash is still the one
            the password was checked against; returns the stamp.
          All three lock the USER row before any token row, so a refresh or a sign-in that runs while
          sessions are being ended either finishes first (and its token is revoked) or starts after
          (and is refused) - never a token that survives.
          security.usp_RefreshToken_Rotate (base) is left as it is: the API no longer calls it.

   QA3 (item 10) SIGNATURE PASSWORDS COUNT AGAINST THE LOGIN LOCKOUT.
          A password typed to sign a decision (or to change the password) was checked with no limit:
          a borrowed session could guess the account's password at Argon2 speed. The API now counts
          a wrong one with the login's own counter (base usp_User_RegisterLoginFailure: 5 failures,
          15 minutes) and refuses while the account is locked.
          - security.usp_User_ClearLoginFailures (NEW): a right password clears the count, like a
            successful login, WITHOUT stamping LastLoginAt (a signature is not a sign-in).

   ATT-16 BRANCH SCOPE FOR THE ATTENDANCE SUMMARIES, RAW PUNCHES AND REPORTS (with REL-15's scoping).
          Script 87 scoped the attendance LISTS; the monthly summaries (one employee, all employees,
          per branch), the raw punches of a day and the printable reports answered every caller
          about every employee. Their procedures are NOT redefined here: the repo's copies are older
          than production (contract review CON-7: usp_Attendance_MonthlySummary_All lacks columns the
          API reads; report_procedures.sql still reads LEAVE_TYPE.AccrualPerMonth). Instead:
          - hr.usp_Scope_CallerEmployees (NEW): what one caller may see for a period, as (Kind, Id)
            rows - everyone; or their own employee, the branches they manage and the employees they
            may see (themselves, those whose branch today they manage, and those with an attendance
            day in the period filed to a branch they manage - script 87's two rules). The API filters
            the rows of those reads with it; reads of ONE employee use script 98's
            hr.usp_Scope_CallerSees ([InCallerScope]).

   Unit B handoff: attendance.usp_RawLog_GetUnresolved (the Unresolved PINs list) leaves out the punches HR set
          aside (RAW_DEVICE_LOG.DismissedUtc, script 100). Redefined behind a CON-7 guard (the live version must
          take and return nothing this one lacks) and only once 100 is applied; until then it is skipped with a
          message, and running 105 again after 100 applies it.

   Prerequisites: script 87 (hr.fn_CallerScope); the base security tables with the columns the API
   already uses. Adds security.REFRESH_TOKEN.ReplacedByHash if a database lacks it (the base rotation
   writes it). No data is changed; existing sessions stay valid until their account's sessions are
   ended (a token issued before this script carries no stamp, which matches an account that has none).

   Apply it together with the API built with these fixes (before or right after deploying it). Script 100 is not
   required (see the unit B handoff above). Re-runnable. QUOTED_IDENTIFIER ON. A refusal is RAISERROR(msg,16,1) +
   RETURN 1, except where the base contract answers with NO ROW (the two token procedures, as the base rotation).

   IF THE API IS DEPLOYED AND THIS SCRIPT IS NOT (the deploy runs the code and the SQL as separate steps), nobody
   is locked out. The API logs ONE warning per process, "DATABASE SCRIPT NOT APPLIED: docs/105_qa3_security.sql
   (<procedure> is missing, SQL error 2812)", and keeps the behaviour from before this script:
     - sign-in issues its refresh token with the old inline INSERT (no re-check of the account, no stamp);
     - refresh rotates with the base usp_RefreshToken_Rotate (a disabled account is still refused);
     - a password change or a disable succeeds but does NOT end the account's other sessions (a disabled
       account's access tokens are still refused at their next request);
     - a right signature (or current) password clears the failure count with the base
       usp_User_RegisterLoginSuccess, which also stamps LastLoginAt; wrong ones are counted as with the script;
     - the monthly summaries, the punches of a day and the three printable reports are NOT filtered by the
       caller's branches (the reads of one employee keep script 98's scope).
   Every call tries this script's procedure first, so applying it takes effect at the next call: no restart.
   Until it is applied, SEC-5 and ATT-16 are not fixed - apply it as soon as the API is deployed.
   ============================================================================ */
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* sqlcmd -b stops at the first RAISERROR; SET NOEXEC ON stops the rest in a tool that does not (pattern of 100) */
IF OBJECT_ID('hr.fn_CallerScope') IS NULL
BEGIN
    RAISERROR('105_qa3_security.sql needs script 87 (hr.fn_CallerScope). Apply 87 first.', 16, 1);
    SET NOEXEC ON;
END
GO

IF COL_LENGTH('security.[USER]', 'IsActive') IS NULL OR COL_LENGTH('security.[USER]', 'PasswordHash') IS NULL
   OR COL_LENGTH('security.[USER]', 'FailedLoginAttempts') IS NULL OR COL_LENGTH('security.[USER]', 'LockoutEnd') IS NULL
   OR COL_LENGTH('security.REFRESH_TOKEN', 'UserId') IS NULL OR COL_LENGTH('security.REFRESH_TOKEN', 'TokenHash') IS NULL
   OR COL_LENGTH('security.REFRESH_TOKEN', 'ExpiresAt') IS NULL OR COL_LENGTH('security.REFRESH_TOKEN', 'CreatedByIp') IS NULL
   OR COL_LENGTH('security.REFRESH_TOKEN', 'RevokedAt') IS NULL
BEGIN
    RAISERROR('105_qa3_security.sql: security.[USER] (IsActive, PasswordHash, FailedLoginAttempts, LockoutEnd) or security.REFRESH_TOKEN (UserId, TokenHash, ExpiresAt, CreatedByIp, RevokedAt) is not as the API uses it. Nothing changed.', 16, 1);
    SET NOEXEC ON;
END
GO

/* ------------------------- SEC-5: the stamp ------------------------- */
IF COL_LENGTH('security.[USER]', 'SessionStamp') IS NULL
BEGIN
    ALTER TABLE security.[USER] ADD SessionStamp UNIQUEIDENTIFIER NULL;
    PRINT 'security.[USER].SessionStamp added';
END
GO

IF COL_LENGTH('security.REFRESH_TOKEN', 'ReplacedByHash') IS NULL
BEGIN
    ALTER TABLE security.REFRESH_TOKEN ADD ReplacedByHash NVARCHAR(256) NULL;
    PRINT 'security.REFRESH_TOKEN.ReplacedByHash added (the base rotation writes it)';
END
GO

/* Ends every session of one account: a new stamp (live access tokens stop working) and every refresh
   token revoked. One row: TokensRevoked, SessionStamp. Unknown user: refused. */
CREATE OR ALTER PROCEDURE security.usp_User_EndSessions
    @UserId INT
AS
BEGIN
    SET NOCOUNT ON;

    -- The refusal comes before XACT_ABORT is switched on: raised under it, it would doom a caller's
    -- transaction instead of only refusing.
    IF NOT EXISTS (SELECT 1 FROM security.[USER] WHERE UserId = @UserId)
    BEGIN
        RAISERROR('User not found.', 16, 1);
        RETURN 1;
    END;

    SET XACT_ABORT ON;

    DECLARE @Stamp UNIQUEIDENTIFIER = NEWID(), @Revoked INT, @Outer INT = @@TRANCOUNT;

    -- A transaction of its own only when called alone. Every refusal below comes before any write, so
    -- inside a caller's transaction (or an INSERT ... EXEC capture, where ROLLBACK is error 3915) there
    -- is nothing to undo and the caller's transaction is left as it was.
    IF @Outer = 0 BEGIN TRAN;

    -- The USER row first, as usp_RefreshToken_RotateChecked and usp_RefreshToken_Issue lock it: one of
    -- them in flight finishes before this (its token is revoked below) or waits and is refused.
    UPDATE security.[USER] SET SessionStamp = @Stamp WHERE UserId = @UserId;
    IF @@ROWCOUNT = 0
    BEGIN
        IF @Outer = 0 ROLLBACK;
        RAISERROR('User not found.', 16, 1);
        RETURN 1;
    END;

    UPDATE security.REFRESH_TOKEN
    SET RevokedAt = SYSUTCDATETIME()
    WHERE UserId = @UserId AND RevokedAt IS NULL;
    SET @Revoked = @@ROWCOUNT;

    IF @Outer = 0 COMMIT;

    SELECT TokensRevoked = @Revoked, SessionStamp = @Stamp;
    RETURN 0;
END;
GO

/* The base rotation (usp_RefreshToken_Rotate: validate the old token, revoke it pointing at the new
   one, insert the new one, atomically), plus: refused while the account is disabled, the USER row
   locked first, and the account's stamp returned for the new access token. Same parameters; one row
   (RefreshTokenId, UserId, SessionStamp) on success, NO row when the token is unknown, revoked or
   expired or the account is disabled - the API answers that with 401, as before. */
CREATE OR ALTER PROCEDURE security.usp_RefreshToken_RotateChecked
    @OldTokenHash NVARCHAR(256),
    @NewTokenHash NVARCHAR(256),
    @ExpiresAt    DATETIME2,
    @CreatedByIp  VARCHAR(45) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Whose token it says it is, read without a lock: only to know which USER row to lock first.
    DECLARE @UserId INT = (SELECT TOP (1) UserId FROM security.REFRESH_TOKEN WHERE TokenHash = @OldTokenHash);
    IF @UserId IS NULL
        RETURN 0;

    DECLARE @Outer INT = @@TRANCOUNT;
    IF @Outer = 0 BEGIN TRAN;          -- see usp_User_EndSessions: refusals come before any write

    DECLARE @IsActive BIT, @Stamp UNIQUEIDENTIFIER;
    SELECT @IsActive = IsActive, @Stamp = SessionStamp
    FROM security.[USER] WITH (UPDLOCK, ROWLOCK)
    WHERE UserId = @UserId;

    DECLARE @TokenId BIGINT;
    SELECT @TokenId = RefreshTokenId
    FROM security.REFRESH_TOKEN WITH (UPDLOCK, ROWLOCK)
    WHERE TokenHash = @OldTokenHash AND UserId = @UserId
      AND RevokedAt IS NULL AND ExpiresAt > SYSUTCDATETIME();

    IF @TokenId IS NULL OR ISNULL(@IsActive, 0) = 0
    BEGIN
        IF @Outer = 0 ROLLBACK;
        RETURN 0;
    END;

    UPDATE security.REFRESH_TOKEN
    SET RevokedAt = SYSUTCDATETIME(), ReplacedByHash = @NewTokenHash
    WHERE RefreshTokenId = @TokenId;

    INSERT INTO security.REFRESH_TOKEN (UserId, TokenHash, ExpiresAt, CreatedByIp)
    VALUES (@UserId, @NewTokenHash, @ExpiresAt, @CreatedByIp);
    DECLARE @NewId BIGINT = CAST(SCOPE_IDENTITY() AS BIGINT);

    IF @Outer = 0 COMMIT;

    SELECT RefreshTokenId = @NewId, UserId = @UserId, SessionStamp = @Stamp;
    RETURN 0;
END;
GO

/* The refresh token of a new sign-in. The API has just checked the password against @PasswordHash; the
   token is issued only if the account is still active and that is still its hash - a password changed
   or an account disabled during the check (Argon2 takes a few hundred milliseconds) gets no session.
   One row (RefreshTokenId, UserId, SessionStamp), or NO row: the API answers "Invalid username or
   password." */
CREATE OR ALTER PROCEDURE security.usp_RefreshToken_Issue
    @UserId       INT,
    @PasswordHash NVARCHAR(1000),
    @TokenHash    NVARCHAR(256),
    @ExpiresAt    DATETIME2,
    @CreatedByIp  VARCHAR(45) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Outer INT = @@TRANCOUNT;
    IF @Outer = 0 BEGIN TRAN;          -- see usp_User_EndSessions: refusals come before any write

    DECLARE @IsActive BIT, @Current NVARCHAR(1000), @Stamp UNIQUEIDENTIFIER;
    SELECT @IsActive = IsActive, @Current = PasswordHash, @Stamp = SessionStamp
    FROM security.[USER] WITH (UPDLOCK, ROWLOCK)
    WHERE UserId = @UserId;

    IF ISNULL(@IsActive, 0) = 0 OR @Current IS NULL
       OR @Current COLLATE Latin1_General_BIN2 <> @PasswordHash COLLATE Latin1_General_BIN2
    BEGIN
        IF @Outer = 0 ROLLBACK;
        RETURN 0;
    END;

    INSERT INTO security.REFRESH_TOKEN (UserId, TokenHash, ExpiresAt, CreatedByIp)
    VALUES (@UserId, @TokenHash, @ExpiresAt, @CreatedByIp);
    DECLARE @NewId BIGINT = CAST(SCOPE_IDENTITY() AS BIGINT);

    IF @Outer = 0 COMMIT;

    SELECT RefreshTokenId = @NewId, UserId = @UserId, SessionStamp = @Stamp;
    RETURN 0;
END;
GO

/* ------------------------- item 10: a right signature password clears the count ------------------------- */
/* What usp_User_RegisterLoginSuccess does to the lockout (FailedLoginAttempts 0, LockoutEnd NULL), for a
   password checked after sign-in; LastLoginAt is left alone. Nothing to clear: nothing written. */
CREATE OR ALTER PROCEDURE security.usp_User_ClearLoginFailures
    @UserId INT
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE security.[USER]
    SET FailedLoginAttempts = 0, LockoutEnd = NULL
    WHERE UserId = @UserId AND (FailedLoginAttempts <> 0 OR LockoutEnd IS NOT NULL);
    RETURN 0;
END;
GO

/* ------------------------- ATT-16: what one caller may see ------------------------- */
/* One result set of (Kind, Id) rows - one shape, so a procedure can capture it with INSERT ... EXEC:
     'A', NULL  the caller sees everyone (EMP_VIEW_ALL, or the system when @CallerUserId is NULL);
                no other row then;
     'S', id    the caller's own employee;
     'B', id    a branch the caller manages;
     'E', id    an employee the caller may see for @FromDate..@ToDate (NULL = any day): the caller,
                the employees whose branch TODAY they manage (the employee list's rule), and those
                with an attendance day in the period filed to a branch they manage (the attendance
                lists' rule: the employee's branch of THAT day).
   No row at all: a caller with no employee and no EMP_VIEW_ALL, who sees nothing. */
CREATE OR ALTER PROCEDURE hr.usp_Scope_CallerEmployees
    @CallerUserId INT,
    @FromDate     DATE = NULL,
    @ToDate       DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @SeesAll BIT, @CallerEmp INT;
    SELECT @SeesAll = SeesAll, @CallerEmp = CallerEmployeeId FROM hr.fn_CallerScope(@CallerUserId);
    DECLARE @Limited BIT = CASE WHEN @SeesAll = 0 AND @CallerEmp IS NOT NULL THEN 1 ELSE 0 END;

    SELECT Kind = CAST('A' AS CHAR(1)), Id = CAST(NULL AS INT) WHERE @SeesAll = 1
    UNION ALL
    SELECT 'S', @CallerEmp WHERE @Limited = 1
    UNION ALL
    SELECT 'B', b.BranchId FROM hr.BRANCH b WHERE @Limited = 1 AND b.ManagerEmployeeId = @CallerEmp
    UNION ALL
    SELECT 'E', e.EmployeeId
    FROM hr.EMPLOYEE e
    WHERE @Limited = 1
      AND (e.EmployeeId = @CallerEmp
           OR EXISTS (SELECT 1 FROM hr.BRANCH mb WHERE mb.ManagerEmployeeId = @CallerEmp AND mb.BranchId = e.BranchId)
           OR EXISTS (SELECT 1
                      FROM attendance.ATTENDANCE_RECORD a
                      JOIN hr.BRANCH mb ON mb.BranchId = ISNULL(a.BranchId, e.BranchId)
                      WHERE a.EmployeeId = e.EmployeeId
                        AND mb.ManagerEmployeeId = @CallerEmp
                        AND (@FromDate IS NULL OR a.WorkDate >= @FromDate)
                        AND (@ToDate   IS NULL OR a.WorkDate <= @ToDate)));
    RETURN 0;
END;
GO

/* ------------------------- unit B handoff: Unresolved PINs leaves out what HR set aside ------------------------- */
/* Script 100 lets HR set aside the punches of a PIN that belongs to nobody (RAW_DEVICE_LOG.DismissedUtc); the
   quarantine view leaves them out, the Unresolved PINs list (usp_RawLog_GetUnresolved) did not. Skipped until 100
   is applied: run this script again afterwards.
   CON-7 GUARD: the repo's copy of usp_RawLog_GetUnresolved is the genesis one (attendance_full_v3.sql), which
   production may have outgrown. It is redefined only if the live one takes no parameter and returns no column
   that this version lacks; otherwise the script stops here, naming them, and nothing is overwritten. This version
   returns every column of the RawLog model the API reads it into (the genesis copy left three out), so a live one
   that already returns them passes. */
DECLARE @extra NVARCHAR(MAX);
IF COL_LENGTH('attendance.RAW_DEVICE_LOG', 'DismissedUtc') IS NULL
    PRINT 'QA3 security (105): usp_RawLog_GetUnresolved NOT changed - attendance.RAW_DEVICE_LOG.DismissedUtc is missing (script 100). Apply 100, then run 105 again.';
ELSE
BEGIN
    IF OBJECT_ID('attendance.usp_RawLog_GetUnresolved', 'P') IS NOT NULL
        SELECT @extra = STRING_AGG(x.what, N', ')
        FROM (SELECT what = CONCAT(N'parameter ', p.name)
              FROM sys.parameters p
              WHERE p.object_id = OBJECT_ID('attendance.usp_RawLog_GetUnresolved') AND p.name NOT IN (N'@FromDate', N'@ToDate')
              UNION ALL
              SELECT CASE WHEN d.error_number IS NOT NULL THEN CONCAT(N'a result that cannot be described (', d.error_message, N')')
                          ELSE CONCAT(N'column ', d.name) END
              FROM sys.dm_exec_describe_first_result_set_for_object(OBJECT_ID('attendance.usp_RawLog_GetUnresolved'), 0) d
              WHERE d.error_number IS NOT NULL
                 OR d.name NOT IN (N'RawLogId', N'DeviceId', N'SerialNumber', N'EnrollPin', N'PunchTimeUtc', N'PunchType',
                                   N'Source', N'DedupHash', N'IsProcessed', N'ImportBatchId', N'CreatedUtc')) x;

    IF @extra IS NOT NULL
        RAISERROR('105_qa3_security.sql: the live attendance.usp_RawLog_GetUnresolved has %s, which this script''s version lacks - it is newer than the repo (CON-7). NOT redefined: add "AND r.DismissedUtc IS NULL" to the live one by hand.', 16, 1, @extra);
    ELSE
    BEGIN
        EXEC (N'CREATE OR ALTER PROCEDURE attendance.usp_RawLog_GetUnresolved
    @FromDate DATE = NULL, @ToDate DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    /* the punches of PINs that belong to nobody, still waiting: QA3 leaves out those HR set aside (script 100) */
    SELECT r.RawLogId, r.DeviceId, d.SerialNumber, r.EnrollPin,
           r.PunchTimeUtc, r.PunchType, r.[Source], r.DedupHash, r.IsProcessed, r.ImportBatchId, r.CreatedUtc
    FROM attendance.RAW_DEVICE_LOG r
    JOIN attendance.DEVICE d ON d.DeviceId = r.DeviceId
    WHERE r.EmployeeId IS NULL
      AND r.DismissedUtc IS NULL
      AND (@FromDate IS NULL OR CAST(r.PunchTimeUtc AS DATE) >= @FromDate)
      AND (@ToDate   IS NULL OR CAST(r.PunchTimeUtc AS DATE) <= @ToDate)
    ORDER BY r.PunchTimeUtc DESC;
END;');
        PRINT 'QA3 security (105): usp_RawLog_GetUnresolved leaves out the punches HR set aside';
    END
END
GO

PRINT 'QA3 security (105): SEC-5 session ending, signature attempts, ATT-16 caller scope in place';
GO
SET NOEXEC OFF;
GO
