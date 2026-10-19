/* QA3 SEC-5 scenario (docs/105_qa3_security.sql): a password change or a disable ends every session.
   Runs inside BEGIN TRAN ... ROLLBACK on a dev database (rows named 'QA3 ...'); RAISERRORs on a wrong
   result, prints 'ok sec5_end_sessions' otherwise. sqlcmd -I -b -d <db> -i tests/qa3/security/sec5_end_sessions.sql */
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
BEGIN TRAN;

DECLARE @u INT, @stamp UNIQUEIDENTIFIER, @n INT;
DECLARE @exp DATETIME2 = DATEADD(DAY, 7, SYSUTCDATETIME());
DECLARE @tok TABLE (RefreshTokenId BIGINT, UserId INT, SessionStamp UNIQUEIDENTIFIER);
DECLARE @end TABLE (TokensRevoked INT, SessionStamp UNIQUEIDENTIFIER);

INSERT INTO security.[USER] (Username, PasswordHash, IsActive, PasswordChangedAt)
VALUES (N'QA3 sec5 user', N'QA3-hash-1', 1, SYSUTCDATETIME());
SET @u = SCOPE_IDENTITY();

/* 1. sign-in, password checked against QA3-hash-1: a token, no stamp yet */
INSERT @tok EXEC security.usp_RefreshToken_Issue @UserId = @u, @PasswordHash = N'QA3-hash-1', @TokenHash = N'QA3-sec5-t1', @ExpiresAt = @exp, @CreatedByIp = '10.0.0.1';
IF (SELECT COUNT(*) FROM @tok WHERE UserId = @u AND SessionStamp IS NULL) <> 1
    RAISERROR('sec5 1: a sign-in with the checked hash must get one token, without a stamp', 16, 1);
DELETE @tok;

/* 2. the password changed while it was being checked (another hash stored): no token */
INSERT @tok EXEC security.usp_RefreshToken_Issue @UserId = @u, @PasswordHash = N'QA3-hash-0', @TokenHash = N'QA3-sec5-tx', @ExpiresAt = @exp;
IF EXISTS (SELECT 1 FROM @tok) OR EXISTS (SELECT 1 FROM security.REFRESH_TOKEN WHERE TokenHash = N'QA3-sec5-tx')
    RAISERROR('sec5 2: a sign-in checked against an old hash must get no token', 16, 1);

/* 3. refresh t1 -> t2: t1 revoked and pointing at t2 */
INSERT @tok EXEC security.usp_RefreshToken_RotateChecked @OldTokenHash = N'QA3-sec5-t1', @NewTokenHash = N'QA3-sec5-t2', @ExpiresAt = @exp;
IF (SELECT COUNT(*) FROM @tok WHERE UserId = @u) <> 1
   OR NOT EXISTS (SELECT 1 FROM security.REFRESH_TOKEN WHERE TokenHash = N'QA3-sec5-t1' AND RevokedAt IS NOT NULL AND ReplacedByHash = N'QA3-sec5-t2')
    RAISERROR('sec5 3: rotation must revoke the old token, link it to the new one and return the new one', 16, 1);
DELETE @tok;

/* 4. t1 a second time: nothing */
INSERT @tok EXEC security.usp_RefreshToken_RotateChecked @OldTokenHash = N'QA3-sec5-t1', @NewTokenHash = N'QA3-sec5-t9', @ExpiresAt = @exp;
IF EXISTS (SELECT 1 FROM @tok) RAISERROR('sec5 4: a revoked token must not rotate', 16, 1);

/* 5. a second device */
INSERT @tok EXEC security.usp_RefreshToken_Issue @UserId = @u, @PasswordHash = N'QA3-hash-1', @TokenHash = N'QA3-sec5-t3', @ExpiresAt = @exp;
DELETE @tok;

/* 6. the password is changed (or the account disabled): every session ends */
INSERT @end EXEC security.usp_User_EndSessions @UserId = @u;
SELECT @n = TokensRevoked, @stamp = SessionStamp FROM @end;
IF @n <> 2 OR @stamp IS NULL OR (SELECT SessionStamp FROM security.[USER] WHERE UserId = @u) <> @stamp
   OR EXISTS (SELECT 1 FROM security.REFRESH_TOKEN WHERE UserId = @u AND RevokedAt IS NULL)
    RAISERROR('sec5 6: ending the sessions must revoke both live tokens and store a new stamp', 16, 1);

/* 7. neither device can refresh any more */
INSERT @tok EXEC security.usp_RefreshToken_RotateChecked @OldTokenHash = N'QA3-sec5-t2', @NewTokenHash = N'QA3-sec5-t8', @ExpiresAt = @exp;
INSERT @tok EXEC security.usp_RefreshToken_RotateChecked @OldTokenHash = N'QA3-sec5-t3', @NewTokenHash = N'QA3-sec5-t7', @ExpiresAt = @exp;
IF EXISTS (SELECT 1 FROM @tok) RAISERROR('sec5 7: a token from before the end must not rotate', 16, 1);

/* 8. a sign-in after the end carries the new stamp, and so does its refresh */
INSERT @tok EXEC security.usp_RefreshToken_Issue @UserId = @u, @PasswordHash = N'QA3-hash-1', @TokenHash = N'QA3-sec5-t4', @ExpiresAt = @exp;
INSERT @tok EXEC security.usp_RefreshToken_RotateChecked @OldTokenHash = N'QA3-sec5-t4', @NewTokenHash = N'QA3-sec5-t5', @ExpiresAt = @exp;
IF (SELECT COUNT(*) FROM @tok WHERE SessionStamp = @stamp) <> 2
    RAISERROR('sec5 8: a new session must carry the new stamp', 16, 1);
DELETE @tok;

/* 9. disabled: no refresh, no sign-in */
UPDATE security.[USER] SET IsActive = 0 WHERE UserId = @u;
INSERT @tok EXEC security.usp_RefreshToken_RotateChecked @OldTokenHash = N'QA3-sec5-t5', @NewTokenHash = N'QA3-sec5-t6', @ExpiresAt = @exp;
INSERT @tok EXEC security.usp_RefreshToken_Issue @UserId = @u, @PasswordHash = N'QA3-hash-1', @TokenHash = N'QA3-sec5-t6', @ExpiresAt = @exp;
IF EXISTS (SELECT 1 FROM @tok) OR EXISTS (SELECT 1 FROM security.REFRESH_TOKEN WHERE TokenHash = N'QA3-sec5-t6')
    RAISERROR('sec5 9: a disabled account must neither refresh nor sign in', 16, 1);

/* 10. an unknown user is refused by name, and the caller's transaction is left as it was */
DECLARE @msg NVARCHAR(400);
BEGIN TRY
    INSERT @end EXEC security.usp_User_EndSessions @UserId = -1;
END TRY
BEGIN CATCH
    SET @msg = ERROR_MESSAGE();
END CATCH;
IF ISNULL(@msg, N'') <> N'User not found.' OR @@TRANCOUNT <> 1 OR XACT_STATE() <> 1
    RAISERROR('sec5 10: an unknown user must be refused with "User not found." and leave the transaction usable', 16, 1);

ROLLBACK;
PRINT 'ok sec5_end_sessions';
