/* QA3 item 10 scenario (docs/105_qa3_security.sql): a right signature password clears the login failure count
   (security.usp_User_ClearLoginFailures) without stamping LastLoginAt. Runs inside BEGIN TRAN ... ROLLBACK on a dev
   database (rows named 'QA3 ...'); RAISERRORs on a wrong result, prints 'ok item10_clear_failures' otherwise.
   sqlcmd -I -b -d <db> -i tests/qa3/security/item10_clear_failures.sql */
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
BEGIN TRAN;

DECLARE @u INT, @last DATETIME2 = '2026-01-02T03:04:05';
INSERT INTO security.[USER] (Username, PasswordHash, IsActive, FailedLoginAttempts, LockoutEnd, LastLoginAt)
VALUES (N'QA3 item10 user', N'x', 1, 4, DATEADD(MINUTE, -1, SYSUTCDATETIME()), @last);
SET @u = SCOPE_IDENTITY();

EXEC security.usp_User_ClearLoginFailures @UserId = @u;
IF NOT EXISTS (SELECT 1 FROM security.[USER] WHERE UserId = @u AND FailedLoginAttempts = 0 AND LockoutEnd IS NULL AND LastLoginAt = @last)
    RAISERROR('item10 1: the count and the lockout must be cleared, LastLoginAt left as it was', 16, 1);

EXEC security.usp_User_ClearLoginFailures @UserId = -1;     -- nobody: nothing happens, nothing raised

ROLLBACK;
PRINT 'ok item10_clear_failures';
