/* ============================================================================
   EMPLOYEE <-> USER LINKING
   MokaCo_HRMS   (run after workflow_prereqs.sql)
   ----------------------------------------------------------------------------
   hr.EMPLOYEE.UserId has existed since the HR schema, but nothing could SET it
   from the application, and nothing stopped two employees claiming the same
   login. Both matter now that the workflow resolves people by account:

     - an employee with no login cannot raise a request
     - a BRANCH MANAGER with no login cannot approve anything, so every
       branch-manager step on their branch skips itself
     - two employees sharing one account would make "whose request is this"
       ambiguous, and the engine would resolve approvers to the wrong person

   ADDS: a filtered unique index (one account, one employee - but any number of
         employees may have none), and four procedures.
   ============================================================================ */
USE MokaCo_HRMS;
GO

/* REQUIRED: this script adds a FILTERED index on hr.EMPLOYEE, and any procedure that
   modifies that table must be created with QUOTED_IDENTIFIER (and ANSI_NULLS) ON, or its
   UPDATE fails at runtime with "SET options have incorrect settings". A stored procedure
   captures these at creation time, so they are set here explicitly — never rely on the
   client default (sqlcmd, for one, defaults QUOTED_IDENTIFIER OFF). */
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

DROP PROCEDURE IF EXISTS hr.usp_Employee_UnlinkUser;
DROP PROCEDURE IF EXISTS hr.usp_Employee_LinkUser;
DROP PROCEDURE IF EXISTS hr.usp_User_GetUnlinked;
DROP PROCEDURE IF EXISTS hr.usp_Employee_GetLoginStatus;
GO

/* One user account belongs to at most ONE employee. FILTERED so that the many
   employees with no account yet do not collide with each other on NULL. */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UQ_Employee_UserId')
    CREATE UNIQUE INDEX UQ_Employee_UserId
        ON hr.EMPLOYEE (UserId) WHERE UserId IS NOT NULL;
GO

/* Every employee with their login state - the list the linking screen shows.
   HasLogin drives the column; IsBranchManager is here because an unlinked branch
   manager is not a cosmetic problem, it silently disables an approval step. */
CREATE PROCEDURE hr.usp_Employee_GetLoginStatus
    @OnlyMissing BIT = 0            -- 1 = just the ones who still need an account
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        e.EmployeeId, e.FullName,
        e.BranchId, b.Name AS BranchName,
        p.Title AS PositionName,
        e.UserId, u.Username, u.IsActive AS UserIsActive,
        CAST(CASE WHEN e.UserId IS NULL THEN 0 ELSE 1 END AS BIT) AS HasLogin,
        CAST(CASE WHEN b.ManagerEmployeeId = e.EmployeeId THEN 1 ELSE 0 END AS BIT) AS IsBranchManager,
        /* the case that quietly breaks approvals */
        CASE WHEN b.ManagerEmployeeId = e.EmployeeId AND e.UserId IS NULL
             THEN N'Manages this branch but has no login, so branch-manager approvals will be skipped.'
             WHEN b.ManagerEmployeeId = e.EmployeeId AND u.IsActive = 0
             THEN N'Manages this branch but the account is disabled, so branch-manager approvals will be skipped.'
             ELSE NULL END AS Warning
    FROM hr.EMPLOYEE e
    JOIN hr.BRANCH b        ON b.BranchId = e.BranchId
    LEFT JOIN hr.[POSITION] p ON p.PositionId = e.PositionId
    LEFT JOIN security.[USER] u ON u.UserId = e.UserId
    WHERE e.IsDeleted = 0
      AND (@OnlyMissing = 0 OR e.UserId IS NULL)
    ORDER BY b.Name, e.FullName;
END;
GO

/* Accounts not yet claimed by any employee - what the "link to" picker offers.
   Excludes accounts already linked, so the same login cannot be chosen twice. */
CREATE PROCEDURE hr.usp_User_GetUnlinked
AS
BEGIN
    SET NOCOUNT ON;
    SELECT u.UserId, u.Username, u.IsActive
    FROM security.[USER] u
    WHERE NOT EXISTS (SELECT 1 FROM hr.EMPLOYEE e
                      WHERE e.UserId = u.UserId AND e.IsDeleted = 0)
    ORDER BY u.Username;
END;
GO

/* Link an employee to an existing account.

   Refuses rather than reassigns when the account already belongs to someone else:
   silently moving a login between employees would rewrite who raised past
   requests. Unlink the other employee first, deliberately.

   Replacing an employee's OWN existing link is allowed - that is a correction. */
CREATE PROCEDURE hr.usp_Employee_LinkUser
    @EmployeeId INT,
    @UserId     INT,
    @ActedBy    INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM hr.EMPLOYEE WHERE EmployeeId = @EmployeeId AND IsDeleted = 0)
    BEGIN RAISERROR('Employee not found.', 16, 1); RETURN; END

    IF NOT EXISTS (SELECT 1 FROM security.[USER] WHERE UserId = @UserId)
    BEGIN RAISERROR('User account not found.', 16, 1); RETURN; END

    DECLARE @TakenBy NVARCHAR(150) = (
        SELECT TOP 1 e.FullName FROM hr.EMPLOYEE e
        WHERE e.UserId = @UserId AND e.EmployeeId <> @EmployeeId AND e.IsDeleted = 0);

    IF @TakenBy IS NOT NULL
    BEGIN
        RAISERROR('That account is already linked to %s. Unlink it from them first.', 16, 1, @TakenBy);
        RETURN;
    END

    UPDATE hr.EMPLOYEE SET UserId = @UserId WHERE EmployeeId = @EmployeeId;

    SELECT e.EmployeeId, e.FullName, e.UserId, u.Username, u.IsActive AS UserIsActive,
           CASE WHEN u.IsActive = 0
                THEN N'Linked, but this account is disabled - they cannot sign in or approve until it is enabled.'
                ELSE NULL END AS Warning
    FROM hr.EMPLOYEE e
    JOIN security.[USER] u ON u.UserId = e.UserId
    WHERE e.EmployeeId = @EmployeeId;
END;
GO

/* Break the link. Returns what this costs, so the UI can warn BEFORE it happens:
   an unlinked employee cannot raise requests, and an unlinked branch manager
   disables an approval step for their whole branch.

   Their PAST requests are untouched - REQUEST_INSTANCE stores the employee and the
   acting user directly, so history never depends on this link still existing. */
CREATE PROCEDURE hr.usp_Employee_UnlinkUser
    @EmployeeId INT,
    @ActedBy    INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @IsMgr BIT = 0, @Pending INT = 0;

    SELECT @IsMgr = CASE WHEN b.ManagerEmployeeId = e.EmployeeId THEN 1 ELSE 0 END
    FROM hr.EMPLOYEE e JOIN hr.BRANCH b ON b.BranchId = e.BranchId
    WHERE e.EmployeeId = @EmployeeId;

    /* requests currently waiting on this person's signature */
    SELECT @Pending = COUNT(*)
    FROM workflow.REQUEST_INSTANCE r
    JOIN workflow.REQUEST_STEP_INSTANCE si
      ON si.RequestInstanceId = r.RequestInstanceId AND si.StepNo = r.CurrentStepNo
    JOIN hr.EMPLOYEE e ON e.UserId = si.ResolvedUserId
    WHERE r.[Status] = 'Pending' AND si.[Status] = 'Pending' AND e.EmployeeId = @EmployeeId;

    UPDATE hr.EMPLOYEE SET UserId = NULL WHERE EmployeeId = @EmployeeId;

    SELECT @EmployeeId AS EmployeeId,
           @IsMgr      AS WasBranchManager,
           @Pending    AS RequestsLeftWaiting,
           CASE WHEN @IsMgr = 1
                THEN N'This employee manages a branch. Branch-manager approvals for that branch will now be skipped until they are linked again or another manager is set.'
                WHEN @Pending > 0
                THEN N'Requests were waiting on this person. They can no longer sign them.'
                ELSE NULL END AS Warning;
END;
GO

/* ---- who still needs attention ---- */
SELECT 'Employees with no login'      AS Issue, COUNT(*) AS [Count]
FROM hr.EMPLOYEE WHERE UserId IS NULL AND IsDeleted = 0
UNION ALL
SELECT 'Branch managers with no login', COUNT(*)
FROM hr.BRANCH b JOIN hr.EMPLOYEE e ON e.EmployeeId = b.ManagerEmployeeId
WHERE e.UserId IS NULL AND e.IsDeleted = 0
UNION ALL
SELECT 'Unclaimed user accounts', COUNT(*)
FROM security.[USER] u
WHERE NOT EXISTS (SELECT 1 FROM hr.EMPLOYEE e WHERE e.UserId = u.UserId AND e.IsDeleted = 0);
GO
