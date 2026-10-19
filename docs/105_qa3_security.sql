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

   Prerequisites: script 87 (hr.fn_CallerScope); the base security tables with the columns the API
   already uses. Adds security.REFRESH_TOKEN.ReplacedByHash if a database lacks it (the base rotation
   writes it). No data is changed; existing sessions stay valid until their account's sessions are
   ended (a token issued before this script carries no stamp, which matches an account that has none).

   Apply BEFORE deploying the API built with these fixes: that API calls the new procedures.
   Re-runnable. QUOTED_IDENTIFIER ON. Every refusal is RAISERROR(msg,16,1) + RETURN 1.
   ============================================================================ */
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF OBJECT_ID('hr.fn_CallerScope') IS NULL
    RAISERROR('105_qa3_security.sql needs script 87 (hr.fn_CallerScope). Apply 87 first.', 16, 1);
GO

IF COL_LENGTH('security.[USER]', 'IsActive') IS NULL OR COL_LENGTH('security.[USER]', 'PasswordHash') IS NULL
   OR COL_LENGTH('security.REFRESH_TOKEN', 'UserId') IS NULL OR COL_LENGTH('security.REFRESH_TOKEN', 'TokenHash') IS NULL
   OR COL_LENGTH('security.REFRESH_TOKEN', 'ExpiresAt') IS NULL OR COL_LENGTH('security.REFRESH_TOKEN', 'CreatedByIp') IS NULL
   OR COL_LENGTH('security.REFRESH_TOKEN', 'RevokedAt') IS NULL
    RAISERROR('105_qa3_security.sql: security.[USER] (IsActive, PasswordHash) or security.REFRESH_TOKEN (UserId, TokenHash, ExpiresAt, CreatedByIp, RevokedAt) is not as the API uses it. Nothing changed.', 16, 1);
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

PRINT 'QA3 security (105): SEC-5 session ending in place';
GO
