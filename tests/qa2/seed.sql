/* ============================================================================
   tests/qa2/seed.sql — the isolated QA2 scenario set (everything prefixed "QA2 ").

   Month under test M = the PREVIOUS month (computed, Beirut clock) and kept in dbo.QA2_STATE('month').
   Two branches, twelve employees, four shifts (break 30, grace NULL = the tolerance setting):
     QA2 Morning 07:00-15:00 · QA2 Evening 15:00-23:00 · QA2 Overnight 22:00-06:00 · QA2 Part 08:00-12:00 (break 0)
     E1  morning            the same-day attendance combinations (A1)
     E2  evening            holiday work, swap partner
     E3  overnight          month end, DST nights (last Sunday of March / of October, seeded explicitly)
     E4  part-timer, 4 h    unrostered day, rehire scenario (inside the payroll transaction)
     E5  hired the 12th, terminated the 20th of M
     E6  terminated the 20th of M with unused leave
     E7  USD basic 2000 + LBP allowance 27,000,000
     E8  basic 1500 -> 1800 from the 16th of M
     E9  approved salary advance whose instalment is larger than the net
     E10 hired last year: carry-over
     E11 the leave cases
     E12 transferred from branch 1 to branch 2 on the 16th of M
   Re-runnable: run cleanup.sql first (run.sh does). Nothing here modifies a real row.
   Apply with sqlcmd -C -I.
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/* ---- 0. helper objects (dropped by cleanup.sql) ---------------------------- */
IF OBJECT_ID('dbo.QA2_STATE') IS NULL
    CREATE TABLE dbo.QA2_STATE ([Key] NVARCHAR(100) NOT NULL PRIMARY KEY, [Value] NVARCHAR(400) NULL);
IF OBJECT_ID('dbo.QA2_RESULT') IS NULL
    CREATE TABLE dbo.QA2_RESULT (Seq INT IDENTITY(1,1) PRIMARY KEY, Id NVARCHAR(20), [Case] NVARCHAR(400),
                                 Expected NVARCHAR(700), Actual NVARCHAR(700), Pass BIT, LoggedAt DATETIME2 DEFAULT SYSUTCDATETIME());
/* which date a case plays on: working days are taken from the roster, never from a weekday literal */
IF OBJECT_ID('dbo.QA2_DAY') IS NULL
    CREATE TABLE dbo.QA2_DAY (CaseId NVARCHAR(20) NOT NULL PRIMARY KEY, EmployeeId INT NOT NULL, WorkDate DATE NOT NULL);
GO
CREATE OR ALTER PROCEDURE dbo.QA2_Check
    @Id NVARCHAR(20), @Case NVARCHAR(400), @Expected NVARCHAR(700), @Actual NVARCHAR(700), @Pass BIT
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO dbo.QA2_RESULT (Id, [Case], Expected, Actual, Pass) VALUES (@Id, @Case, @Expected, @Actual, ISNULL(@Pass, 0));
    PRINT CONCAT(CASE WHEN @Pass = 1 THEN 'PASS' ELSE 'FAIL' END, ' | ', @Id, ' | ', @Case,
                 ' | expected=', ISNULL(@Expected, 'NULL'), ' | actual=', ISNULL(@Actual, 'NULL'));
END;
GO
CREATE OR ALTER PROCEDURE dbo.QA2_Note @Text NVARCHAR(MAX)
AS BEGIN SET NOCOUNT ON; PRINT CONCAT('NOTE | ', @Text); END;
GO
/* lookups the case files use instead of repeating the same SELECTs */
CREATE OR ALTER FUNCTION dbo.QA2_Emp (@Name NVARCHAR(50)) RETURNS INT
AS BEGIN RETURN (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA2 ' + @Name); END;
GO
CREATE OR ALTER FUNCTION dbo.QA2_User (@Username NVARCHAR(50)) RETURNS INT
AS BEGIN RETURN (SELECT UserId FROM security.[USER] WHERE Username = N'qa2.' + @Username); END;
GO
CREATE OR ALTER FUNCTION dbo.QA2_Date (@CaseId NVARCHAR(20)) RETURNS DATE
AS BEGIN RETURN (SELECT WorkDate FROM dbo.QA2_DAY WHERE CaseId = @CaseId); END;
GO
/* a wall-clock moment on a case's date: QA2_At('A1a', '07:25') ; +1 day for the morning after an overnight shift */
CREATE OR ALTER FUNCTION dbo.QA2_At (@CaseId NVARCHAR(20), @Time TIME(0), @PlusDays INT) RETURNS DATETIME2(0)
AS BEGIN
    RETURN DATEADD(SECOND, DATEDIFF(SECOND, CAST('00:00' AS TIME(0)), @Time),
                   CAST(DATEADD(DAY, ISNULL(@PlusDays, 0), (SELECT WorkDate FROM dbo.QA2_DAY WHERE CaseId = @CaseId)) AS DATETIME2(0)));
END;
GO
/* the latest request of a kind raised for an employee (the typed _Create procedures answer with a result set that
   cannot be captured by INSERT-EXEC — they already use one inside) */
CREATE OR ALTER FUNCTION dbo.QA2_LastRequest (@EmployeeId INT) RETURNS INT
AS BEGIN RETURN (SELECT MAX(RequestInstanceId) FROM workflow.REQUEST_INSTANCE WHERE EmployeeId = @EmployeeId); END;
GO
/* one raw punch for a QA2 employee, exactly as a terminal would have pushed it (wall clock, Source 'QA2') */
CREATE OR ALTER PROCEDURE dbo.QA2_Punch @EmployeeId INT, @PunchTime DATETIME2(0), @PunchType SMALLINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @D INT = (SELECT DeviceId FROM attendance.DEVICE WHERE SerialNumber = 'QA2-DEVICE-001');
    DECLARE @Pin VARCHAR(30) = (SELECT EnrollPin FROM attendance.EMPLOYEE_DEVICE WHERE EmployeeId = @EmployeeId AND DeviceId = @D);
    INSERT INTO attendance.RAW_DEVICE_LOG (DeviceId, EnrollPin, EmployeeId, PunchTimeUtc, PunchType, [Source], DedupHash)
    VALUES (@D, @Pin, @EmployeeId, @PunchTime, @PunchType, 'QA2',
            CONVERT(VARCHAR(64), HASHBYTES('SHA2_256', CONVERT(VARCHAR(200),
                CONCAT(@D, '|', @Pin, '|', FORMAT(@PunchTime, 'yyyy-MM-dd\THH:mm:ss.fffffff'), '|', @PunchType))), 2));
END;
GO
/* Walks a request through its whole approval chain as the QA2 approvers (manager -> HR -> owner), through the
   TYPED decide procedure of its kind — the same procedures the API calls once it has checked the password.
   A user who is not the approver of the current step is refused by the procedure; that refusal is swallowed and
   the next user is tried. Runs OUTSIDE any transaction (a caught refusal would doom one). */
CREATE OR ALTER PROCEDURE dbo.QA2_Approve
    @RequestInstanceId INT, @Kind VARCHAR(20),          -- Leave | Exit | Overtime | Swap | Advance | Generic
    @Minutes INT = NULL, @Amount DECIMAL(18,2) = NULL, @Discretionary BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @users TABLE (Seq INT IDENTITY(1,1), UserId INT);
    INSERT INTO @users (UserId)
    SELECT UserId FROM security.[USER] WHERE Username IN (N'qa2.manager', N'qa2.hr', N'qa2.owner')
    ORDER BY CASE Username WHEN N'qa2.manager' THEN 1 WHEN N'qa2.hr' THEN 2 ELSE 3 END;
    DECLARE @round INT = 0, @i INT, @u INT, @status VARCHAR(20);
    DECLARE @sink TABLE (c1 SQL_VARIANT NULL);
    WHILE @round < 6
    BEGIN
        SET @status = (SELECT [Status] FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId = @RequestInstanceId);
        IF @status IS NULL OR @status NOT IN ('Pending', 'OnHold') BREAK;
        SET @i = 1;
        WHILE @i <= 3
        BEGIN
            SET @u = (SELECT UserId FROM @users WHERE Seq = @i);
            BEGIN TRY
                IF @Kind = 'Leave'
                    EXEC workflow.usp_LeaveRequest_Decide @RequestInstanceId = @RequestInstanceId, @ActedByUserId = @u,
                         @Comment = N'QA2 approval', @SignedWithPassword = 1, @MakeDiscretionary = @Discretionary;
                ELSE IF @Kind = 'Exit'
                    EXEC workflow.usp_ExitPermission_Decide @RequestInstanceId = @RequestInstanceId, @ActedByUserId = @u,
                         @ApprovedMinutes = @Minutes, @Comment = N'QA2 approval', @SignedWithPassword = 1;
                ELSE IF @Kind = 'Overtime'
                    EXEC workflow.usp_Overtime_Decide @RequestInstanceId = @RequestInstanceId, @ActedByUserId = @u,
                         @ApprovedMinutes = @Minutes, @Comment = N'QA2 approval', @SignedWithPassword = 1;
                ELSE IF @Kind = 'Swap'
                    EXEC workflow.usp_ShiftSwap_Decide @RequestInstanceId = @RequestInstanceId, @ActedByUserId = @u,
                         @Comment = N'QA2 approval', @SignedWithPassword = 1;
                ELSE IF @Kind = 'Advance'
                    EXEC workflow.usp_SalaryAdvance_Decide @RequestInstanceId = @RequestInstanceId, @ActedByUserId = @u,
                         @ApprovedAmount = @Amount, @Comment = N'QA2 approval', @SignedWithPassword = 1;
                ELSE
                    EXEC workflow.usp_Request_Approve @RequestInstanceId = @RequestInstanceId, @ActedByUserId = @u,
                         @Comment = N'QA2 approval', @SignedWithPassword = 1;
            END TRY
            BEGIN CATCH
                IF @@TRANCOUNT > 0 ROLLBACK TRAN;       -- not this user's step (or a rule refused it): try the next
            END CATCH;
            SET @status = (SELECT [Status] FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId = @RequestInstanceId);
            IF @status NOT IN ('Pending', 'OnHold') BREAK;
            SET @i += 1;
        END
        SET @round += 1;
    END
END;
GO

/* An APPROVED overtime request for a date of the month under test. Overtime is pre-approval by rule ("must be approved
   before it is worked" — usp_Overtime_Create refuses a past date), and M is in the past, so the request is raised and
   approved through the real procedures for a FUTURE date and its WorkDate is then moved to the case date: the state a
   request raised in time would be in. Only this QA2 row is touched. */
CREATE OR ALTER PROCEDURE dbo.QA2_ApprovedOvertime @EmployeeId INT, @WorkDate DATE, @Minutes INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Hr INT = dbo.QA2_User(N'hr');
    DECLARE @future DATE = DATEADD(DAY, 30, CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE));
    WHILE EXISTS (SELECT 1 FROM workflow.OVERTIME_REQUEST WHERE EmployeeId = @EmployeeId AND WorkDate = @future) SET @future = DATEADD(DAY, 1, @future);
    EXEC workflow.usp_Overtime_Create @EmployeeId = @EmployeeId, @RaisedByUserId = @Hr, @WorkDate = @future, @RequestedMinutes = @Minutes, @Reason = N'QA2 overtime';
    DECLARE @rid INT = (SELECT MAX(RequestInstanceId) FROM workflow.OVERTIME_REQUEST WHERE EmployeeId = @EmployeeId AND WorkDate = @future);
    EXEC dbo.QA2_Approve @rid, 'Overtime', @Minutes = @Minutes;
    UPDATE workflow.OVERTIME_REQUEST SET WorkDate = @WorkDate WHERE RequestInstanceId = @rid;
END;
GO

/* Derives every QA2 employee-day that has an unprocessed punch — and ONLY those: the real processor
   (usp_Attendance_ProcessRawLogs with no date) would also sweep up real unprocessed punches, which the suite must
   never touch. Same writer (usp_Attendance_ComputeDay), same attribution rule, same "mark what was consumed". */
CREATE OR ALTER PROCEDURE dbo.QA2_Process
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @day TABLE (EmployeeId INT, WorkDate DATE, PRIMARY KEY (EmployeeId, WorkDate));
    INSERT INTO @day
    SELECT DISTINCT r.EmployeeId, attendance.fn_AttributedWorkDate(r.EmployeeId, r.PunchTimeUtc)
    FROM attendance.RAW_DEVICE_LOG r JOIN hr.EMPLOYEE e ON e.EmployeeId = r.EmployeeId AND e.FullName LIKE N'QA2 %'
    WHERE r.IsProcessed = 0;
    DECLARE @e INT, @d DATE;
    DECLARE pc CURSOR LOCAL FAST_FORWARD FOR SELECT EmployeeId, WorkDate FROM @day ORDER BY WorkDate, EmployeeId;
    OPEN pc; FETCH NEXT FROM pc INTO @e, @d;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @e, @WorkDate = @d;
        FETCH NEXT FROM pc INTO @e, @d;
    END
    CLOSE pc; DEALLOCATE pc;
    UPDATE r SET r.IsProcessed = 1
    FROM attendance.RAW_DEVICE_LOG r
    JOIN @day d ON d.EmployeeId = r.EmployeeId AND d.WorkDate = attendance.fn_AttributedWorkDate(r.EmployeeId, r.PunchTimeUtc)
    WHERE r.IsProcessed = 0;
END;
GO

/* ---- 1. baseline of the real data (compared again after cleanup) ----------- */
DELETE FROM dbo.QA2_STATE; DELETE FROM dbo.QA2_DAY;
INSERT INTO dbo.QA2_STATE ([Key], [Value])
SELECT 'baseline.' + s.name + '.' + t.name, CAST(SUM(p.rows) AS NVARCHAR(50))
FROM sys.tables t JOIN sys.schemas s ON s.schema_id = t.schema_id
JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0,1)
WHERE t.name NOT LIKE 'QA2[_]%' AND t.name NOT LIKE 'QA[_]%'
GROUP BY s.name, t.name;
INSERT INTO dbo.QA2_STATE VALUES ('baseline.nonqa.shift_assignment_checksum',
    CAST((SELECT CHECKSUM_AGG(CHECKSUM(EmployeeId, ShiftId, WorkDate, IsRestDay)) FROM attendance.SHIFT_ASSIGNMENT) AS NVARCHAR(50)));
INSERT INTO dbo.QA2_STATE VALUES ('baseline.nonqa.attendance_checksum',
    CAST((SELECT CHECKSUM_AGG(CHECKSUM(EmployeeId, WorkDate, [Status], WorkedMinutes, DayFraction)) FROM attendance.ATTENDANCE_RECORD) AS NVARCHAR(50)));
INSERT INTO dbo.QA2_STATE VALUES ('baseline.nonqa.ledger_checksum',
    CAST((SELECT CHECKSUM_AGG(CHECKSUM(EmployeeId, LeaveTypeId, MovementType, Days, EffectiveDate)) FROM hr.LEAVE_LEDGER) AS NVARCHAR(50)));
DECLARE @Today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE);
DECLARE @M DATE = DATEFROMPARTS(YEAR(DATEADD(MONTH, -1, @Today)), MONTH(DATEADD(MONTH, -1, @Today)), 1);
INSERT INTO dbo.QA2_STATE VALUES ('month', CONVERT(CHAR(7), @M, 23));
/* the DST nights: the Saturday before the last Sunday of March (this year, or last year if still ahead) and of October (last one already past) */
DECLARE @y INT = YEAR(@Today), @mar DATE, @oct DATE;
SET @mar = DATEFROMPARTS(@y, 3, 31); WHILE DATEDIFF(DAY, '19000107', @mar) % 7 <> 0 SET @mar = DATEADD(DAY, -1, @mar);   -- a Sunday
IF @mar >= @Today BEGIN SET @mar = DATEFROMPARTS(@y - 1, 3, 31); WHILE DATEDIFF(DAY, '19000107', @mar) % 7 <> 0 SET @mar = DATEADD(DAY, -1, @mar); END
SET @oct = DATEFROMPARTS(@y, 10, 31); WHILE DATEDIFF(DAY, '19000107', @oct) % 7 <> 0 SET @oct = DATEADD(DAY, -1, @oct);
IF @oct >= @Today BEGIN SET @oct = DATEFROMPARTS(@y - 1, 10, 31); WHILE DATEDIFF(DAY, '19000107', @oct) % 7 <> 0 SET @oct = DATEADD(DAY, -1, @oct); END
INSERT INTO dbo.QA2_STATE VALUES ('dst.spring.sunday', CONVERT(CHAR(10), @mar, 23)), ('dst.autumn.sunday', CONVERT(CHAR(10), @oct, 23));
GO

/* ---- 2. users (password for every QA2 user: QaPass!2026, the same Argon2 hash as suite 1) ---- */
DECLARE @Hash NVARCHAR(300) = N'argon2id$v=19$m=19456,t=2,p=1$gPUm+x9SuWEj/PO/NW85BQ==$DFe+U8/hoFEcLRGN3iaELEtCnDIujaW/xU5GSSDOd5E=';
INSERT INTO security.[USER] (Username, PasswordHash, IsActive)
VALUES (N'qa2.owner', @Hash, 1), (N'qa2.hr', @Hash, 1), (N'qa2.manager', @Hash, 1), (N'qa2.e1', @Hash, 1), (N'qa2.e11', @Hash, 1);
INSERT INTO security.USER_ROLE (UserId, RoleId, AssignedAt)
SELECT u.UserId, r.RoleId, SYSUTCDATETIME()
FROM security.[USER] u
JOIN security.[ROLE] r ON r.Name = CASE u.Username WHEN N'qa2.owner' THEN N'Owner' WHEN N'qa2.hr' THEN N'HR'
                                                   WHEN N'qa2.manager' THEN N'Manager' ELSE N'Employee' END
WHERE u.Username LIKE N'qa2.%';
GO

/* ---- 3. branches, shifts, employees, salaries ------------------------------ */
DECLARE @M DATE = CAST((SELECT [Value] FROM dbo.QA2_STATE WHERE [Key] = 'month') + '-01' AS DATE);
INSERT INTO hr.BRANCH (Name, IsActive) VALUES (N'QA2 Branch 1', 1), (N'QA2 Branch 2', 1);
DECLARE @B1 INT = (SELECT BranchId FROM hr.BRANCH WHERE Name = N'QA2 Branch 1');
DECLARE @B2 INT = (SELECT BranchId FROM hr.BRANCH WHERE Name = N'QA2 Branch 2');
INSERT INTO attendance.SHIFT (Name, StartTime, EndTime, GraceMinutes, CrossesMidnight, BreakMinutes, IsActive)
VALUES (N'QA2 Morning',   '07:00', '15:00', NULL, 0, 30, 1),
       (N'QA2 Evening',   '15:00', '23:00', NULL, 0, 30, 1),
       (N'QA2 Overnight', '22:00', '06:00', NULL, 1, 30, 1),
       (N'QA2 Part',      '08:00', '12:00', NULL, 0, 0,  1);
DECLARE @Dep INT = (SELECT TOP 1 DepartmentId FROM hr.DEPARTMENT WHERE Name = N'Operations');
IF @Dep IS NULL SET @Dep = (SELECT TOP 1 DepartmentId FROM hr.DEPARTMENT ORDER BY DepartmentId);
DECLARE @PosB INT = ISNULL((SELECT TOP 1 PositionId FROM hr.POSITION WHERE Title = N'Barista'), (SELECT TOP 1 PositionId FROM hr.POSITION ORDER BY PositionId));
DECLARE @PosM INT = ISNULL((SELECT TOP 1 PositionId FROM hr.POSITION WHERE Title = N'Branch Manager'), @PosB);
DECLARE @PosH INT = ISNULL((SELECT TOP 1 PositionId FROM hr.POSITION WHERE Title = N'HR Officer'), @PosB);
DECLARE @U TABLE (Username NVARCHAR(100), UserId INT);
INSERT INTO @U SELECT Username, UserId FROM security.[USER] WHERE Username LIKE N'qa2.%';
DECLARE @LastYear DATE = DATEFROMPARTS(YEAR(@M) - 1, 3, 1);
INSERT INTO hr.EMPLOYEE (UserId, BranchId, DepartmentId, PositionId, FullName, HireDate, TerminationDate, ApprovalTier, Email, PreferredLanguage)
VALUES ((SELECT UserId FROM @U WHERE Username = N'qa2.manager'), @B1, @Dep, @PosM, N'QA2 Manager',    '2023-01-01', NULL, 4, NULL, 'en'),
       ((SELECT UserId FROM @U WHERE Username = N'qa2.hr'),      @B1, @Dep, @PosH, N'QA2 HR Officer', '2022-01-01', NULL, 3, NULL, 'en'),
       ((SELECT UserId FROM @U WHERE Username = N'qa2.e1'),      @B1, @Dep, @PosB, N'QA2 E1',  '2024-01-01', NULL, 5, NULL, 'en'),
       (NULL, @B1, @Dep, @PosB, N'QA2 E2',  '2024-01-01', NULL, 5, NULL, 'en'),
       (NULL, @B1, @Dep, @PosB, N'QA2 E3',  '2024-01-01', NULL, 5, NULL, 'en'),
       (NULL, @B1, @Dep, @PosB, N'QA2 E4',  '2024-01-01', NULL, 5, NULL, 'en'),
       (NULL, @B1, @Dep, @PosB, N'QA2 E5',  DATEADD(DAY, 11, @M), DATEADD(DAY, 19, @M), 5, NULL, 'en'),   -- hired the 12th, terminated the 20th
       (NULL, @B1, @Dep, @PosB, N'QA2 E6',  '2024-01-01', DATEADD(DAY, 19, @M), 5, NULL, 'en'),           -- terminated the 20th
       (NULL, @B1, @Dep, @PosB, N'QA2 E7',  '2024-01-01', NULL, 5, NULL, 'en'),
       (NULL, @B1, @Dep, @PosB, N'QA2 E8',  '2024-01-01', NULL, 5, NULL, 'en'),
       (NULL, @B1, @Dep, @PosB, N'QA2 E9',  '2024-01-01', NULL, 5, NULL, 'en'),
       (NULL, @B1, @Dep, @PosB, N'QA2 E10', @LastYear,    NULL, 5, NULL, 'en'),                           -- hired last year
       ((SELECT UserId FROM @U WHERE Username = N'qa2.e11'),     @B1, @Dep, @PosB, N'QA2 E11', '2024-01-01', NULL, 5, NULL, 'en'),
       (NULL, @B1, @Dep, @PosB, N'QA2 E12', '2024-01-01', NULL, 5, NULL, 'en');                           -- transferred to branch 2 on the 16th (case A4c)
DECLARE @Mgr INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA2 Manager');
UPDATE hr.EMPLOYEE SET ReportsToEmployeeId = @Mgr WHERE FullName LIKE N'QA2 E%';
UPDATE hr.BRANCH SET ManagerEmployeeId = @Mgr WHERE BranchId IN (@B1, @B2);

DECLARE @CtBasic INT = (SELECT ComponentTypeId FROM hr.COMPONENT_TYPE WHERE Name = N'Basic Salary');
DECLARE @CtTrans INT = (SELECT ComponentTypeId FROM hr.COMPONENT_TYPE WHERE Name = N'Transport Allowance');
INSERT INTO hr.SALARY_COMPONENT (EmployeeId, ComponentTypeId, Amount, CurrencyCode, EffectiveFrom, EffectiveTo)
SELECT e.EmployeeId, @CtBasic,
       CASE e.FullName WHEN N'QA2 Manager' THEN 2500 WHEN N'QA2 HR Officer' THEN 3000
                       WHEN N'QA2 E7' THEN 2000 WHEN N'QA2 E8' THEN 1500 WHEN N'QA2 E9' THEN 1000 ELSE 1300 END,
       'USD', '2024-01-01',
       CASE WHEN e.FullName = N'QA2 E8' THEN DATEADD(DAY, 14, @M) END          -- E8: 1500 until the 15th …
FROM hr.EMPLOYEE e WHERE e.FullName LIKE N'QA2 %';
INSERT INTO hr.SALARY_COMPONENT (EmployeeId, ComponentTypeId, Amount, CurrencyCode, EffectiveFrom)
SELECT EmployeeId, @CtBasic, 1800, 'USD', DATEADD(DAY, 15, @M) FROM hr.EMPLOYEE WHERE FullName = N'QA2 E8';   -- … 1800 from the 16th
INSERT INTO hr.SALARY_COMPONENT (EmployeeId, ComponentTypeId, Amount, CurrencyCode, EffectiveFrom)
SELECT EmployeeId, @CtTrans, 27000000, 'LBP', '2024-01-01' FROM hr.EMPLOYEE WHERE FullName = N'QA2 E7';
GO

/* ---- 4. device + enrolments ------------------------------------------------ */
DECLARE @B1 INT = (SELECT BranchId FROM hr.BRANCH WHERE Name = N'QA2 Branch 1');
INSERT INTO attendance.DEVICE (SerialNumber, BranchId, IsActive, [Name], PullIp, PullPort, PullCommKey, PullEnabled)
VALUES ('QA2-DEVICE-001', @B1, 1, N'QA2 Device', '127.0.0.1', 43701, 0, 0);
DECLARE @D INT = (SELECT DeviceId FROM attendance.DEVICE WHERE SerialNumber = 'QA2-DEVICE-001');
INSERT INTO attendance.EMPLOYEE_DEVICE (EmployeeId, DeviceId, EnrollPin)
SELECT e.EmployeeId, @D, 'Q2' + REPLACE(e.FullName, N'QA2 E', '')
FROM hr.EMPLOYEE e WHERE e.FullName LIKE N'QA2 E%';
GO

/* ---- 5. rosters through the real generator: Mon-Sat, Sunday rest ------------
   M and M+1 for everybody; the two DST weeks for E3. E4 (part-timer) works Mon-Fri only and has NO row at
   all on Saturdays: that is the "unrostered day". E5 / E6 only while employed. The ROSTER_MONTH headers are
   written Approved directly — the approval chain itself is suite 1's subject (R3); A4 exercises the rest. */
DECLARE @M DATE = CAST((SELECT [Value] FROM dbo.QA2_STATE WHERE [Key] = 'month') + '-01' AS DATE);
DECLARE @MEnd DATE = EOMONTH(@M), @N DATE = DATEADD(MONTH, 1, @M), @NEnd DATE = EOMONTH(DATEADD(MONTH, 1, @M));
DECLARE @Spring DATE = CAST((SELECT [Value] FROM dbo.QA2_STATE WHERE [Key] = 'dst.spring.sunday') AS DATE);
DECLARE @Autumn DATE = CAST((SELECT [Value] FROM dbo.QA2_STATE WHERE [Key] = 'dst.autumn.sunday') AS DATE);
DECLARE @Morning INT = (SELECT ShiftId FROM attendance.SHIFT WHERE Name = N'QA2 Morning');
DECLARE @Evening INT = (SELECT ShiftId FROM attendance.SHIFT WHERE Name = N'QA2 Evening');
DECLARE @Night   INT = (SELECT ShiftId FROM attendance.SHIFT WHERE Name = N'QA2 Overnight');
DECLARE @Part    INT = (SELECT ShiftId FROM attendance.SHIFT WHERE Name = N'QA2 Part');
DECLARE @emp TABLE (Name NVARCHAR(50), Id INT, ShiftId INT, Mask CHAR(7), FromD DATE, ToD DATE);
INSERT INTO @emp
SELECT e.FullName, e.EmployeeId,
       CASE e.FullName WHEN N'QA2 E2' THEN @Evening WHEN N'QA2 E3' THEN @Night WHEN N'QA2 E4' THEN @Part ELSE @Morning END,
       CASE e.FullName WHEN N'QA2 E4' THEN '1111100' WHEN N'QA2 E3' THEN '1111111' ELSE '1111110' END,   -- E3 works every night: month end and the DST nights must not depend on a weekday
       CASE WHEN e.HireDate > @M THEN e.HireDate ELSE @M END,
       CASE WHEN e.TerminationDate IS NOT NULL THEN e.TerminationDate ELSE @NEnd END
FROM hr.EMPLOYEE e WHERE e.FullName LIKE N'QA2 E%';
DECLARE @id INT, @s INT, @mask CHAR(7), @f DATE, @t DATE;
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT Id, ShiftId, Mask, FromD, ToD FROM @emp;
OPEN c; FETCH NEXT FROM c INTO @id, @s, @mask, @f, @t;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC attendance.usp_ShiftAssignment_GenerateRange @id, @f, @t, @s, @mask, 0;
    FETCH NEXT FROM c INTO @id, @s, @mask, @f, @t;
END
CLOSE c; DEALLOCATE c;
/* E4's Saturdays: GenerateRange writes a rest-day row for a masked-out day; the unrostered day needs NO row */
DELETE sa FROM attendance.SHIFT_ASSIGNMENT sa
WHERE sa.EmployeeId = (SELECT Id FROM @emp WHERE Name = N'QA2 E4') AND DATEDIFF(DAY, '19000106', sa.WorkDate) % 7 = 0;   -- Saturdays
/* the DST weeks for E3 (overnight): Thursday..Monday around each change */
SELECT @id = Id FROM @emp WHERE Name = N'QA2 E3';
SET @f = DATEADD(DAY, -3, @Spring); SET @t = DATEADD(DAY, 1, @Spring); EXEC attendance.usp_ShiftAssignment_GenerateRange @id, @f, @t, @Night, '1111111', 0;
SET @f = DATEADD(DAY, -3, @Autumn); SET @t = DATEADD(DAY, 1, @Autumn); EXEC attendance.usp_ShiftAssignment_GenerateRange @id, @f, @t, @Night, '1111111', 0;
/* the last night of M-1 (case A2d: on leave that night; the 01:00 punch falls on the 1st of M) */
SET @f = DATEADD(DAY, -1, @M); EXEC attendance.usp_ShiftAssignment_GenerateRange @id, @f, @f, @Night, '1111111', 0;
INSERT INTO attendance.ROSTER_MONTH (BranchId, MonthDate, [Status], ApprovedAt)
SELECT b.BranchId, m.MonthDate, 'Approved', SYSUTCDATETIME()
FROM hr.BRANCH b
CROSS JOIN (SELECT @M AS MonthDate UNION SELECT @N UNION SELECT DATEADD(MONTH, -1, @M)
            UNION SELECT DATEFROMPARTS(YEAR(@Spring), MONTH(@Spring), 1) UNION SELECT DATEFROMPARTS(YEAR(DATEADD(DAY,-3,@Spring)), MONTH(DATEADD(DAY,-3,@Spring)), 1)
            UNION SELECT DATEFROMPARTS(YEAR(@Autumn), MONTH(@Autumn), 1) UNION SELECT DATEFROMPARTS(YEAR(DATEADD(DAY,1,@Autumn)), MONTH(DATEADD(DAY,1,@Autumn)), 1)) m
WHERE b.Name LIKE N'QA2 Branch %'
  AND NOT EXISTS (SELECT 1 FROM attendance.ROSTER_MONTH x WHERE x.BranchId = b.BranchId AND x.MonthDate = m.MonthDate);
GO

/* ---- 6. which date each case plays on ---------------------------------------
   E1's A1 cases take E1's working days of M in order, from the 2nd one; the rest day cases take E1's first two
   rest days. Fixed calendar positions (12th, 16th, 20th, month end) are stated where the rule itself is about them. */
DECLARE @M DATE = CAST((SELECT [Value] FROM dbo.QA2_STATE WHERE [Key] = 'month') + '-01' AS DATE);
DECLARE @E1 INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA2 E1');
;WITH w AS (SELECT sa.WorkDate, ROW_NUMBER() OVER (ORDER BY sa.WorkDate) AS n
            FROM attendance.SHIFT_ASSIGNMENT sa WHERE sa.EmployeeId = @E1 AND sa.IsRestDay = 0 AND sa.WorkDate BETWEEN @M AND EOMONTH(@M))
INSERT INTO dbo.QA2_DAY (CaseId, EmployeeId, WorkDate)
SELECT v.CaseId, @E1, w.WorkDate
FROM (VALUES ('A1a',2),('A1b',3),('A1c',4),('A1d',5),('A1e',6),('A1f',7),('A1j1',8),('A1j2',9),('A1k',10),('A1m',11),('A1n',12),('A1h',13)) v(CaseId, n)
JOIN w ON w.n = v.n;
;WITH r AS (SELECT sa.WorkDate, ROW_NUMBER() OVER (ORDER BY sa.WorkDate) AS n
            FROM attendance.SHIFT_ASSIGNMENT sa WHERE sa.EmployeeId = @E1 AND sa.IsRestDay = 1 AND sa.WorkDate BETWEEN @M AND EOMONTH(@M))
INSERT INTO dbo.QA2_DAY (CaseId, EmployeeId, WorkDate)
SELECT v.CaseId, @E1, r.WorkDate FROM (VALUES ('A1g1',1),('A1g2',2)) v(CaseId, n) JOIN r ON r.n = v.n;
/* the unrostered day: E4's first Saturday of M (no SHIFT_ASSIGNMENT row at all) */
DECLARE @E4 INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA2 E4');
DECLARE @sat DATE = @M; WHILE DATEDIFF(DAY, '19000106', @sat) % 7 <> 0 SET @sat = DATEADD(DAY, 1, @sat);
INSERT INTO dbo.QA2_DAY VALUES ('A1i', @E4, @sat);
/* the unknown device user plays on E4's 2nd working day: its punches arrive under a PIN nobody is enrolled with */
INSERT INTO dbo.QA2_DAY
SELECT 'A1o', @E4, x.WorkDate FROM (SELECT sa.WorkDate, ROW_NUMBER() OVER (ORDER BY sa.WorkDate) n FROM attendance.SHIFT_ASSIGNMENT sa
                                    WHERE sa.EmployeeId = @E4 AND sa.IsRestDay = 0 AND sa.WorkDate BETWEEN @M AND EOMONTH(@M)) x WHERE x.n = 2;
/* E3 (overnight): early-in / early-out on the 5th night, the month-end night, and the two DST nights (the Saturday before each change) */
DECLARE @E3 INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA2 E3');
INSERT INTO dbo.QA2_DAY VALUES
    ('A2c', @E3, DATEADD(DAY, 4, @M)),
    ('A2d', @E3, DATEADD(DAY, -1, @M)),
    ('A2b1', @E3, DATEADD(DAY, -1, CAST((SELECT [Value] FROM dbo.QA2_STATE WHERE [Key] = 'dst.spring.sunday') AS DATE))),
    ('A2b2', @E3, DATEADD(DAY, -1, CAST((SELECT [Value] FROM dbo.QA2_STATE WHERE [Key] = 'dst.autumn.sunday') AS DATE)));
GO

/* ---- 7. punches: a standard pair (start -> end) on every rostered working day of M and of the elapsed part of
        M+1 that no case owns; the case punches are written by the case files themselves ---- */
DECLARE @M DATE = CAST((SELECT [Value] FROM dbo.QA2_STATE WHERE [Key] = 'month') + '-01' AS DATE);
DECLARE @Today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE);
DECLARE @D INT = (SELECT DeviceId FROM attendance.DEVICE WHERE SerialNumber = 'QA2-DEVICE-001');
IF OBJECT_ID('tempdb..#p') IS NOT NULL DROP TABLE #p;
CREATE TABLE #p (EmployeeId INT, PunchTime DATETIME2(0), PunchType SMALLINT);
INSERT INTO #p (EmployeeId, PunchTime, PunchType)
SELECT sa.EmployeeId, DATEADD(MINUTE, DATEDIFF(MINUTE, 0, s.StartTime), CAST(sa.WorkDate AS DATETIME2(0))), 0
FROM attendance.SHIFT_ASSIGNMENT sa
JOIN attendance.SHIFT s ON s.ShiftId = sa.ShiftId
JOIN hr.EMPLOYEE e ON e.EmployeeId = sa.EmployeeId AND e.FullName LIKE N'QA2 E%'
WHERE sa.IsRestDay = 0 AND sa.WorkDate >= @M AND sa.WorkDate < @Today
  AND NOT EXISTS (SELECT 1 FROM dbo.QA2_DAY d WHERE d.EmployeeId = sa.EmployeeId AND d.WorkDate = sa.WorkDate)
UNION ALL
SELECT sa.EmployeeId, DATEADD(MINUTE, DATEDIFF(MINUTE, 0, s.EndTime) + CASE WHEN s.CrossesMidnight = 1 THEN 1440 ELSE 0 END, CAST(sa.WorkDate AS DATETIME2(0))), 1
FROM attendance.SHIFT_ASSIGNMENT sa
JOIN attendance.SHIFT s ON s.ShiftId = sa.ShiftId
JOIN hr.EMPLOYEE e ON e.EmployeeId = sa.EmployeeId AND e.FullName LIKE N'QA2 E%'
WHERE sa.IsRestDay = 0 AND sa.WorkDate >= @M AND sa.WorkDate < @Today
  AND NOT EXISTS (SELECT 1 FROM dbo.QA2_DAY d WHERE d.EmployeeId = sa.EmployeeId AND d.WorkDate = sa.WorkDate);
INSERT INTO attendance.RAW_DEVICE_LOG (DeviceId, EnrollPin, EmployeeId, PunchTimeUtc, PunchType, [Source], DedupHash)
SELECT @D, ed.EnrollPin, p.EmployeeId, p.PunchTime, p.PunchType, 'QA2',
       CONVERT(VARCHAR(64), HASHBYTES('SHA2_256', CONVERT(VARCHAR(200),
           CONCAT(@D, '|', ed.EnrollPin, '|', FORMAT(p.PunchTime, 'yyyy-MM-dd\THH:mm:ss.fffffff'), '|', p.PunchType))), 2)
FROM #p p
JOIN attendance.EMPLOYEE_DEVICE ed ON ed.EmployeeId = p.EmployeeId AND ed.DeviceId = @D;
INSERT INTO dbo.QA2_STATE VALUES ('seed.punches', CAST(@@ROWCOUNT AS NVARCHAR(20)));
GO

/* ---- 8. leave year of M for the QA2 employees (the real ones already have theirs; the procedure skips them) ---- */
DECLARE @M DATE = CAST((SELECT [Value] FROM dbo.QA2_STATE WHERE [Key] = 'month') + '-01' AS DATE);
DECLARE @hr INT = (SELECT UserId FROM security.[USER] WHERE Username = N'qa2.hr'), @yr INT = YEAR(@M);
DECLARE @o TABLE (LeaveTypeName NVARCHAR(60), EmployeesOpened INT, DaysGranted DECIMAL(9,2), ProratedEmployees INT, DaysCarriedOver DECIMAL(9,2), DaysExpired DECIMAL(9,2));
INSERT INTO @o EXEC hr.usp_LeaveYear_Open @Year = @yr, @ActedByUserId = @hr;
GO
PRINT 'QA2 SEED DONE';
SELECT 'QA2 employees' AS what, COUNT(*) AS n FROM hr.EMPLOYEE WHERE FullName LIKE N'QA2 %'
UNION ALL SELECT 'QA2 roster rows', COUNT(*) FROM attendance.SHIFT_ASSIGNMENT sa JOIN hr.EMPLOYEE e ON e.EmployeeId = sa.EmployeeId WHERE e.FullName LIKE N'QA2 %'
UNION ALL SELECT 'QA2 punches', COUNT(*) FROM attendance.RAW_DEVICE_LOG WHERE [Source] = 'QA2';
GO
