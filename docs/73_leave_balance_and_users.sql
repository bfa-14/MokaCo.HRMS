/* ============================================================================
   73_leave_balance_and_users.sql
   · hr.usp_Leave_GetBalanceByYear — per leave type for one leave year, read
     from hr.vw_LEAVE_BALANCE: LeaveType, Entitlement, CarriedOver, Used,
     Adjusted, Remaining, Year. Two result sets: (1) YearOpened, Year;
     (2) the rows — EMPTY when the year was never opened for the employee
     ("opened" = the Accrual row hr.usp_LeaveYear_Open posts in 'YYYY-01').
   · security.usp_User_GetAll — the users grid: two result sets, users (with
     the linked employee) and their roles.
   · security.usp_User_SetRoles — replace-all of a user's roles from a comma
     list; refuses an unknown user or role, and refuses to leave the system
     with no active Admin.
   Every refusal is RAISERROR(msg,16,1) + RETURN (ROLLBACK inside a tran).
   Idempotent. Run with sqlcmd -I.
   ============================================================================ */
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ---- 1. Leave balance for a year --------------------------------------------- */
CREATE OR ALTER PROCEDURE hr.usp_Leave_GetBalanceByYear
    @EmployeeId INT, @Year INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Year = ISNULL(@Year, YEAR(GETDATE()));
    DECLARE @From CHAR(7) = CONCAT(@Year, '-01'), @To CHAR(7) = CONCAT(@Year, '-12');

    DECLARE @Opened BIT = CASE WHEN EXISTS (
        SELECT 1 FROM hr.LEAVE_LEDGER
        WHERE EmployeeId = @EmployeeId AND PeriodYearMonth = @From
          AND MovementType = 'Accrual' AND Note LIKE N'Annual entitlement%') THEN 1 ELSE 0 END;

    SELECT @Opened AS YearOpened, @Year AS [Year];

    SELECT lt.LeaveTypeId,
           lt.Name                                   AS LeaveType,
           lt.IsPaid,
           CAST(ISNULL(SUM(b.Accrued),     0) AS DECIMAL(7,2)) AS Entitlement,
           CAST(ISNULL(SUM(b.CarriedOver), 0) AS DECIMAL(7,2)) AS CarriedOver,
           CAST(ISNULL(SUM(b.Used),        0) AS DECIMAL(7,2)) AS Used,
           CAST(ISNULL(SUM(b.Adjusted),    0) AS DECIMAL(7,2)) AS Adjusted,
           CAST(ISNULL(SUM(b.Remaining),   0) AS DECIMAL(7,2)) AS Remaining,
           @Year                                     AS [Year]
    FROM hr.LEAVE_TYPE lt
    LEFT JOIN hr.vw_LEAVE_BALANCE b
           ON b.LeaveTypeId = lt.LeaveTypeId AND b.EmployeeId = @EmployeeId
          AND b.PeriodYearMonth BETWEEN @From AND @To
    WHERE @Opened = 1
      AND (lt.IsActive = 1 OR b.LeaveTypeId IS NOT NULL)   -- inactive types only when they carry movements
    GROUP BY lt.LeaveTypeId, lt.Name, lt.IsPaid
    ORDER BY lt.Name;
END;
GO

/* ---- 2. Users grid ----------------------------------------------------------- */
CREATE OR ALTER PROCEDURE security.usp_User_GetAll
AS
BEGIN
    SET NOCOUNT ON;
    SELECT u.UserId, u.Username, u.IsActive, u.LastLoginAt,
           e.EmployeeId, e.FullName AS EmployeeName
    FROM security.[USER] u
    OUTER APPLY (SELECT TOP 1 x.EmployeeId, x.FullName
                 FROM hr.EMPLOYEE x WHERE x.UserId = u.UserId AND x.IsDeleted = 0
                 ORDER BY x.EmployeeId) e
    ORDER BY u.Username;

    SELECT ur.UserId, r.RoleId, r.Name
    FROM security.USER_ROLE ur
    JOIN security.[ROLE] r ON r.RoleId = ur.RoleId
    ORDER BY ur.UserId, r.Name;
END;
GO

/* ---- 3. Replace a user's roles ------------------------------------------------ */
CREATE OR ALTER PROCEDURE security.usp_User_SetRoles
    @UserId INT, @RoleIds NVARCHAR(MAX), @AssignedBy INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM security.[USER] WHERE UserId = @UserId)
    BEGIN RAISERROR('User not found.', 16, 1); RETURN; END

    DECLARE @wanted TABLE (RoleId INT PRIMARY KEY);
    INSERT INTO @wanted (RoleId)
    SELECT DISTINCT TRY_CAST(LTRIM(RTRIM(value)) AS INT)
    FROM STRING_SPLIT(ISNULL(@RoleIds, N''), ',')
    WHERE LTRIM(RTRIM(value)) <> '' AND TRY_CAST(LTRIM(RTRIM(value)) AS INT) IS NOT NULL;

    DECLARE @Unknown INT = (SELECT TOP 1 w.RoleId FROM @wanted w
                            WHERE NOT EXISTS (SELECT 1 FROM security.[ROLE] r WHERE r.RoleId = w.RoleId));
    IF @Unknown IS NOT NULL
    BEGIN RAISERROR('Role #%d does not exist.', 16, 1, @Unknown); RETURN; END

    /* never leave the system without an active administrator */
    DECLARE @AdminRoleId INT = (SELECT TOP 1 RoleId FROM security.[ROLE] WHERE Name = N'Admin' ORDER BY RoleId);
    IF @AdminRoleId IS NOT NULL
       AND EXISTS (SELECT 1 FROM security.USER_ROLE WHERE UserId = @UserId AND RoleId = @AdminRoleId)
       AND NOT EXISTS (SELECT 1 FROM @wanted WHERE RoleId = @AdminRoleId)
       AND NOT EXISTS (SELECT 1 FROM security.USER_ROLE ur
                       JOIN security.[USER] u ON u.UserId = ur.UserId
                       WHERE ur.RoleId = @AdminRoleId AND ur.UserId <> @UserId AND u.IsActive = 1)
    BEGIN RAISERROR('At least one active user must keep the Admin role.', 16, 1); RETURN; END

    BEGIN TRAN;
        DELETE ur FROM security.USER_ROLE ur
        WHERE ur.UserId = @UserId AND NOT EXISTS (SELECT 1 FROM @wanted w WHERE w.RoleId = ur.RoleId);

        INSERT INTO security.USER_ROLE (UserId, RoleId, AssignedAt, AssignedBy)
        SELECT @UserId, w.RoleId, SYSUTCDATETIME(), @AssignedBy
        FROM @wanted w
        WHERE NOT EXISTS (SELECT 1 FROM security.USER_ROLE ur WHERE ur.UserId = @UserId AND ur.RoleId = w.RoleId);
    COMMIT;

    SELECT r.RoleId, r.Name
    FROM security.USER_ROLE ur
    JOIN security.[ROLE] r ON r.RoleId = ur.RoleId
    WHERE ur.UserId = @UserId
    ORDER BY r.Name;
END;
GO
