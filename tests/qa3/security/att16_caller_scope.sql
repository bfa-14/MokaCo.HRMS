/* QA3 ATT-16 scenario (docs/105_qa3_security.sql): hr.usp_Scope_CallerEmployees answers what one caller may
   see for a period - script 87's rule. Runs inside BEGIN TRAN ... ROLLBACK on a dev database (rows named
   'QA3 ...'); RAISERRORs on a wrong result, prints 'ok att16_caller_scope' otherwise.
   sqlcmd -I -b -d <db> -i tests/qa3/security/att16_caller_scope.sql */
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
BEGIN TRAN;

DECLARE @dep INT = (SELECT TOP (1) DepartmentId FROM hr.DEPARTMENT ORDER BY DepartmentId);
DECLARE @pos INT = (SELECT TOP (1) PositionId FROM hr.[POSITION] ORDER BY PositionId);
DECLARE @b1 INT, @b2 INT, @uM INT, @uHr INT, @uNone INT, @uE3 INT, @m INT, @e1 INT, @e2 INT, @e3 INT, @e4 INT;

INSERT INTO hr.BRANCH (Name) VALUES (N'QA3 att16 branch 1'); SET @b1 = SCOPE_IDENTITY();
INSERT INTO hr.BRANCH (Name) VALUES (N'QA3 att16 branch 2'); SET @b2 = SCOPE_IDENTITY();

INSERT INTO security.[USER] (Username, PasswordHash, IsActive) VALUES (N'QA3 att16 manager', N'x', 1); SET @uM = SCOPE_IDENTITY();
INSERT INTO security.[USER] (Username, PasswordHash, IsActive) VALUES (N'QA3 att16 hr', N'x', 1);      SET @uHr = SCOPE_IDENTITY();
INSERT INTO security.[USER] (Username, PasswordHash, IsActive) VALUES (N'QA3 att16 nobody', N'x', 1);  SET @uNone = SCOPE_IDENTITY();
INSERT INTO security.[USER] (Username, PasswordHash, IsActive) VALUES (N'QA3 att16 e3', N'x', 1);      SET @uE3 = SCOPE_IDENTITY();
INSERT INTO security.USER_ROLE (UserId, RoleId)
SELECT TOP (1) @uHr, rp.RoleId FROM security.ROLE_PERMISSION rp JOIN security.PERMISSION p ON p.PermissionId = rp.PermissionId WHERE p.Code = 'EMP_VIEW_ALL';
IF @@ROWCOUNT <> 1 RAISERROR('att16 setup: no role holds EMP_VIEW_ALL (script 87)', 16, 1);

INSERT INTO hr.EMPLOYEE (FullName, BranchId, DepartmentId, PositionId, HireDate, UserId) VALUES (N'QA3 att16 manager', @b1, @dep, @pos, '2025-01-01', @uM); SET @m = SCOPE_IDENTITY();
UPDATE hr.BRANCH SET ManagerEmployeeId = @m WHERE BranchId = @b1;
INSERT INTO hr.EMPLOYEE (FullName, BranchId, DepartmentId, PositionId, HireDate) VALUES (N'QA3 att16 e1 in branch 1', @b1, @dep, @pos, '2025-01-01'); SET @e1 = SCOPE_IDENTITY();
INSERT INTO hr.EMPLOYEE (FullName, BranchId, DepartmentId, PositionId, HireDate) VALUES (N'QA3 att16 e2 moved to 2', @b2, @dep, @pos, '2025-01-01'); SET @e2 = SCOPE_IDENTITY();
INSERT INTO hr.EMPLOYEE (FullName, BranchId, DepartmentId, PositionId, HireDate, UserId) VALUES (N'QA3 att16 e3 in branch 2', @b2, @dep, @pos, '2025-01-01', @uE3); SET @e3 = SCOPE_IDENTITY();
INSERT INTO hr.EMPLOYEE (FullName, BranchId, DepartmentId, PositionId, HireDate) VALUES (N'QA3 att16 e4 old day', @b2, @dep, @pos, '2025-01-01'); SET @e4 = SCOPE_IDENTITY();

-- e2 worked a day of August in branch 1 (then moved); e3 only in branch 2; e4 worked in branch 1 in June only
INSERT INTO attendance.ATTENDANCE_RECORD (EmployeeId, WorkDate, [Status], BranchId) VALUES
    (@e2, '2026-08-05', 'Present', @b1), (@e3, '2026-08-05', 'Present', @b2), (@e4, '2026-06-10', 'Present', @b1);

DECLARE @r TABLE (Kind CHAR(1), Id INT);
DECLARE @got NVARCHAR(400), @want NVARCHAR(400);

/* 1. the branch manager in August: themselves, e1 (branch today), e2 (a day of August in branch 1);
      not e3 (branch 2 only), not e4 (branch 1 only in June); manages branch 1 */
INSERT @r EXEC hr.usp_Scope_CallerEmployees @CallerUserId = @uM, @FromDate = '2026-08-01', @ToDate = '2026-08-31';
SELECT @got = STRING_AGG(CONCAT(Kind, ':', CASE Id WHEN @m THEN 'm' WHEN @e1 THEN 'e1' WHEN @e2 THEN 'e2' WHEN @e3 THEN 'e3' WHEN @e4 THEN 'e4' WHEN @b1 THEN 'b1' WHEN @b2 THEN 'b2' ELSE CONCAT('?', Id) END), ',')
                    WITHIN GROUP (ORDER BY Kind, CASE Id WHEN @m THEN 0 WHEN @e1 THEN 1 WHEN @e2 THEN 2 WHEN @e3 THEN 3 WHEN @e4 THEN 4 ELSE 9 END)
FROM @r;
SET @want = N'B:b1,E:m,E:e1,E:e2,S:m';
IF @got IS NULL OR @got <> @want
    RAISERROR('att16 1: manager in August, got [%s], want [%s]', 16, 1, @got, @want);
DELETE @r;

/* 2. the same manager over any day: e4 too (a day in branch 1 in June) */
INSERT @r EXEC hr.usp_Scope_CallerEmployees @CallerUserId = @uM;
IF NOT EXISTS (SELECT 1 FROM @r WHERE Kind = 'E' AND Id = @e4) OR EXISTS (SELECT 1 FROM @r WHERE Kind = 'E' AND Id = @e3)
    RAISERROR('att16 2: over any day the manager sees e4 and still not e3', 16, 1);
DELETE @r;

/* 3. an employee of branch 2 who manages nothing: only themselves */
INSERT @r EXEC hr.usp_Scope_CallerEmployees @CallerUserId = @uE3, @FromDate = '2026-08-01', @ToDate = '2026-08-31';
SELECT @got = STRING_AGG(CONCAT(Kind, ':', CASE Id WHEN @e3 THEN 'e3' ELSE CONCAT('?', Id) END), ',') WITHIN GROUP (ORDER BY Kind) FROM @r;
IF @got IS NULL OR @got <> N'E:e3,S:e3'
    RAISERROR('att16 3: an employee sees only themselves, got [%s]', 16, 1, @got);
DELETE @r;

/* 4. EMP_VIEW_ALL: one 'A' row and nothing else */
INSERT @r EXEC hr.usp_Scope_CallerEmployees @CallerUserId = @uHr, @FromDate = '2026-08-01', @ToDate = '2026-08-31';
IF (SELECT COUNT(*) FROM @r) <> 1 OR NOT EXISTS (SELECT 1 FROM @r WHERE Kind = 'A' AND Id IS NULL)
    RAISERROR('att16 4: EMP_VIEW_ALL must be one A row', 16, 1);
DELETE @r;

/* 5. the system (no caller): everyone */
INSERT @r EXEC hr.usp_Scope_CallerEmployees @CallerUserId = NULL;
IF NOT EXISTS (SELECT 1 FROM @r WHERE Kind = 'A')
    RAISERROR('att16 5: the system sees everyone', 16, 1);
DELETE @r;

/* 6. a login with no employee and no EMP_VIEW_ALL: nothing */
INSERT @r EXEC hr.usp_Scope_CallerEmployees @CallerUserId = @uNone;
IF EXISTS (SELECT 1 FROM @r)
    RAISERROR('att16 6: a login with no employee sees nothing', 16, 1);

ROLLBACK;
PRINT 'ok att16_caller_scope';
