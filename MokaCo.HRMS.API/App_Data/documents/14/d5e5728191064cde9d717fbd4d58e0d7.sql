/* ============================================================================
   SECURITY - stored procedures  (SQL Server 2025)
   ----------------------------------------------------------------------------
   ONLY the security-critical / multi-step operations are procedures. Plain CRUD
   (list/create/edit users, roles, permissions, assignments) stays as inline
   Dapper SQL in the repositories.

   Assumes the `security` schema and its tables already exist in MokaCo_HRMS.
   Lockout policy used below: 5 failed attempts -> 15-minute lockout (tune freely).
   ============================================================================ */
USE MokaCo_HRMS;
GO

/* ----------------------------------------------------------------------------
   1) usp_User_GetForLogin
   Fetch the row the login flow needs (hash + lockout state) by username.
   The API compares the password hash and checks IsActive / LockoutEnd itself.
   Returns 0 or 1 row.
   Dapper: QuerySingleOrDefaultAsync<UserLogin>("security.usp_User_GetForLogin",
           new { Username }, commandType: CommandType.StoredProcedure)
---------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE security.usp_User_GetForLogin
    @Username NVARCHAR(100)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT UserId, Username, PasswordHash, IsActive,
           FailedLoginAttempts, LockoutEnd
    FROM security.[USER]
    WHERE Username = @Username;
END;
GO

/* ----------------------------------------------------------------------------
   2) usp_User_RegisterLoginSuccess
   Call after a correct password: clear failed attempts + lockout, stamp login.
   Dapper: ExecuteAsync(..., new { UserId })
---------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE security.usp_User_RegisterLoginSuccess
    @UserId INT
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE security.[USER]
    SET FailedLoginAttempts = 0,
        LockoutEnd          = NULL,
        LastLoginAt         = SYSUTCDATETIME()
    WHERE UserId = @UserId;
END;
GO

/* ----------------------------------------------------------------------------
   3) usp_User_RegisterLoginFailure
   Call after a wrong password: increment attempts; lock for @LockoutMinutes once
   @MaxAttempts is reached. Returns the new attempt count + resulting LockoutEnd
   so the API can tell the user "account locked".
   Dapper: QuerySingleAsync<LoginFailureResult>(...)
---------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE security.usp_User_RegisterLoginFailure
    @UserId          INT,
    @MaxAttempts     INT = 5,
    @LockoutMinutes  INT = 15
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE security.[USER]
    SET FailedLoginAttempts = FailedLoginAttempts + 1,
        LockoutEnd = CASE
                        WHEN FailedLoginAttempts + 1 >= @MaxAttempts
                        THEN DATEADD(MINUTE, @LockoutMinutes, SYSUTCDATETIME())
                        ELSE LockoutEnd
                     END
    WHERE UserId = @UserId;

    SELECT FailedLoginAttempts, LockoutEnd
    FROM security.[USER]
    WHERE UserId = @UserId;
END;
GO

/* ----------------------------------------------------------------------------
   4) usp_User_GetPermissions
   The role -> permission set for a user, used to build the JWT / authorize every
   request. DISTINCT because two roles may grant the same permission.
   Dapper: QueryAsync<PermissionDto>(..., new { UserId })
---------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE security.usp_User_GetPermissions
    @UserId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT DISTINCT p.Code, p.Module
    FROM security.USER_ROLE ur
    JOIN security.ROLE_PERMISSION rp ON rp.RoleId = ur.RoleId
    JOIN security.PERMISSION p       ON p.PermissionId = rp.PermissionId
    WHERE ur.UserId = @UserId;
END;
GO

/* ----------------------------------------------------------------------------
   5) usp_RefreshToken_Rotate
   Exchange a valid, unexpired, unrevoked refresh token for a new one, atomically:
   validate old -> revoke old (link to new) -> insert new. All in one transaction
   so a crash can't leave two live tokens or none.
   Returns the new RefreshTokenId + UserId on success; returns NO rows if the old
   token is invalid/expired/revoked (the API treats that as 401).
   Pass HASHES, never raw tokens. The API generates the raw token + its hash.
   Dapper: QuerySingleOrDefaultAsync<RotateResult>(...)
---------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE security.usp_RefreshToken_Rotate
    @OldTokenHash NVARCHAR(256),
    @NewTokenHash NVARCHAR(256),
    @ExpiresAt    DATETIME2,
    @CreatedByIp  VARCHAR(45) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRAN;

    DECLARE @UserId INT;

    -- Lock the row while we validate + rotate
    SELECT @UserId = UserId
    FROM security.REFRESH_TOKEN WITH (UPDLOCK, ROWLOCK)
    WHERE TokenHash = @OldTokenHash
      AND RevokedAt IS NULL
      AND ExpiresAt > SYSUTCDATETIME();

    IF @UserId IS NULL
    BEGIN
        ROLLBACK TRAN;      -- invalid/expired/revoked -> no rows returned
        RETURN;
    END

    -- Revoke the old token and point it at its replacement
    UPDATE security.REFRESH_TOKEN
    SET RevokedAt      = SYSUTCDATETIME(),
        ReplacedByHash = @NewTokenHash
    WHERE TokenHash = @OldTokenHash;

    -- Issue the new token
    INSERT INTO security.REFRESH_TOKEN (UserId, TokenHash, ExpiresAt, CreatedByIp)
    VALUES (@UserId, @NewTokenHash, @ExpiresAt, @CreatedByIp);

    DECLARE @NewId BIGINT = SCOPE_IDENTITY();

    COMMIT TRAN;

    SELECT @NewId AS RefreshTokenId, @UserId AS UserId;
END;
GO

/* ----------------------------------------------------------------------------
   6) usp_RefreshToken_Revoke
   Logout / revoke a single session by its token hash. Idempotent: revoking an
   already-revoked or missing token simply affects 0 rows.
   Dapper: ExecuteAsync(..., new { TokenHash })
---------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE security.usp_RefreshToken_Revoke
    @TokenHash NVARCHAR(256)
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE security.REFRESH_TOKEN
    SET RevokedAt = SYSUTCDATETIME()
    WHERE TokenHash = @TokenHash
      AND RevokedAt IS NULL;
END;
GO

/* ============================================================================
   SMOKE TEST (safe to run after the seed data is present)
   ============================================================================ */
-- 1) Login lookup for sara
EXEC security.usp_User_GetForLogin @Username = N'sara.hr';

-- 2) sara's permission set
EXEC security.usp_User_GetPermissions @UserId = 2;

-- 3) Simulate a wrong password for joe (id 6), then a success
EXEC security.usp_User_RegisterLoginFailure @UserId = 6;
EXEC security.usp_User_RegisterLoginSuccess @UserId = 6;

-- 4) Revoke sara's seeded session
EXEC security.usp_RefreshToken_Revoke @TokenHash = N'HASH_refresh_sara_session1';
GO
