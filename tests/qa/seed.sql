/* ============================================================================
   tests/qa/seed.sql — creates the isolated QA test set (everything prefixed "QA ").
   Month under test M = 2026-08 (previous full month at the time of writing).
   Run with:  sqlcmd -S localhost -U sa -C -I -d MokaCo_HRMS -i seed.sql
   Re-runnable: run cleanup.sql first (run.sh does).
   Nothing here modifies real rows except two settings that are snapshotted and
   restored by cleanup.sql (BookingNotifyEmail is redirected to a .invalid mailbox
   so the QA staff-alert e-mails cannot reach the real staff mailbox).
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO
/* ---- 0. QA helper objects (dropped by cleanup.sql) ------------------------- */
IF OBJECT_ID('dbo.QA_STATE') IS NULL
    CREATE TABLE dbo.QA_STATE ([Key] NVARCHAR(100) NOT NULL PRIMARY KEY, [Value] NVARCHAR(400) NULL);
IF OBJECT_ID('dbo.QA_RESULT') IS NULL
    CREATE TABLE dbo.QA_RESULT (Seq INT IDENTITY(1,1) PRIMARY KEY, Id NVARCHAR(20), [Case] NVARCHAR(300),
                                Expected NVARCHAR(600), Actual NVARCHAR(600), Pass BIT, LoggedAt DATETIME2 DEFAULT SYSUTCDATETIME());
GO
CREATE OR ALTER PROCEDURE dbo.QA_Check
    @Id NVARCHAR(20), @Case NVARCHAR(300), @Expected NVARCHAR(600), @Actual NVARCHAR(600), @Pass BIT
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO dbo.QA_RESULT (Id, [Case], Expected, Actual, Pass) VALUES (@Id, @Case, @Expected, @Actual, @Pass);
    PRINT CONCAT(CASE WHEN @Pass = 1 THEN 'PASS' ELSE 'FAIL' END, ' | ', @Id, ' | ', @Case,
                 ' | expected=', ISNULL(@Expected, 'NULL'), ' | actual=', ISNULL(@Actual, 'NULL'));
END;
GO
CREATE OR ALTER PROCEDURE dbo.QA_Note @Text NVARCHAR(MAX)
AS BEGIN SET NOCOUNT ON; PRINT CONCAT('NOTE | ', @Text); END;
GO

/* ---- 1. baseline counts of the real data (compared again after cleanup) ---- */
DELETE FROM dbo.QA_STATE;
INSERT INTO dbo.QA_STATE ([Key], [Value])
SELECT 'baseline.' + s.name + '.' + t.name, CAST(SUM(p.rows) AS NVARCHAR(50))
FROM sys.tables t JOIN sys.schemas s ON s.schema_id = t.schema_id
JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0,1)
WHERE t.name NOT LIKE 'QA[_]%'
GROUP BY s.name, t.name;
INSERT INTO dbo.QA_STATE VALUES ('baseline.nonqa.shift_assignment_checksum',
    CAST((SELECT CHECKSUM_AGG(CHECKSUM(EmployeeId, ShiftId, WorkDate, IsRestDay)) FROM attendance.SHIFT_ASSIGNMENT) AS NVARCHAR(50)));
INSERT INTO dbo.QA_STATE VALUES ('setting.BookingNotifyEmail', (SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'BookingNotifyEmail'));
INSERT INTO dbo.QA_STATE VALUES ('setting.MachinePullEnabled', (SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'MachinePullEnabled'));
INSERT INTO dbo.QA_STATE VALUES ('month', '2026-08');
GO

/* ---- 2. e-mail redirect (restored by cleanup.sql) --------------------------- */
UPDATE core.SETTING SET SettingValue = 'qa-staff-alert@example.invalid' WHERE SettingKey = 'BookingNotifyEmail';
GO

/* ---- 3. users (password for every QA user: QaPass!2026) ------------------- */
DECLARE @Hash NVARCHAR(300) = N'argon2id$v=19$m=19456,t=2,p=1$gPUm+x9SuWEj/PO/NW85BQ==$DFe+U8/hoFEcLRGN3iaELEtCnDIujaW/xU5GSSDOd5E=';
INSERT INTO security.[USER] (Username, PasswordHash, IsActive)
VALUES (N'qa.owner', @Hash, 1), (N'qa.hr', @Hash, 1), (N'qa.manager', @Hash, 1),
       (N'qa.ops', @Hash, 1), (N'qa.e1', @Hash, 1), (N'qa.e5', @Hash, 1);
INSERT INTO security.USER_ROLE (UserId, RoleId, AssignedAt)
SELECT u.UserId, r.RoleId, SYSUTCDATETIME()
FROM security.[USER] u
JOIN security.[ROLE] r ON r.Name = CASE u.Username
        WHEN N'qa.owner' THEN N'Owner' WHEN N'qa.hr' THEN N'HR' WHEN N'qa.manager' THEN N'Manager'
        WHEN N'qa.ops' THEN N'OperationsManager' ELSE N'Employee' END
WHERE u.Username LIKE N'qa.%';
GO

/* ---- 4. branch + employees ------------------------------------------------ */
INSERT INTO hr.BRANCH (Name, IsActive) VALUES (N'QA Branch', 1);
DECLARE @B INT = (SELECT BranchId FROM hr.BRANCH WHERE Name = N'QA Branch');
DECLARE @Dep INT = (SELECT TOP 1 DepartmentId FROM hr.DEPARTMENT WHERE Name = N'Operations');
DECLARE @PosB INT = (SELECT TOP 1 PositionId FROM hr.POSITION WHERE Title = N'Barista');
DECLARE @PosM INT = (SELECT TOP 1 PositionId FROM hr.POSITION WHERE Title = N'Branch Manager');
DECLARE @PosH INT = (SELECT TOP 1 PositionId FROM hr.POSITION WHERE Title = N'HR Officer');
DECLARE @U TABLE (Username NVARCHAR(100), UserId INT);
INSERT INTO @U SELECT Username, UserId FROM security.[USER] WHERE Username LIKE N'qa.%';

/* tier 3 employees must not report to a tier-4 manager (hierarchy trigger), so ReportsTo is NULL for them */
INSERT INTO hr.EMPLOYEE (UserId, BranchId, DepartmentId, PositionId, FullName, HireDate, TerminationDate, ApprovalTier, Email, PreferredLanguage)
VALUES ((SELECT UserId FROM @U WHERE Username = N'qa.manager'), @B, @Dep, @PosM, N'QA Manager', '2023-01-01', NULL, 4, NULL, 'en'),
       ((SELECT UserId FROM @U WHERE Username = N'qa.hr'),      @B, @Dep, @PosH, N'QA HR Officer', '2022-01-01', NULL, 3, NULL, 'en'),
       ((SELECT UserId FROM @U WHERE Username = N'qa.e1'),      @B, @Dep, @PosB, N'QA E1', '2020-01-01', NULL, 3, NULL, 'en'),
       (NULL, @B, @Dep, @PosB, N'QA E2', '2026-08-15', NULL, 5, NULL, 'en'),
       (NULL, @B, @Dep, @PosB, N'QA E3', '2024-01-01', NULL, 5, NULL, 'en'),
       (NULL, @B, @Dep, @PosB, N'QA E4', '2024-01-01', NULL, 5, NULL, 'en'),
       ((SELECT UserId FROM @U WHERE Username = N'qa.e5'),      @B, @Dep, @PosB, N'QA E5', '2024-01-01', NULL, 5, NULL, 'en'),
       (NULL, @B, @Dep, @PosB, N'QA E6', '2024-01-01', NULL, 5, NULL, 'en'),
       (NULL, @B, @Dep, @PosB, N'QA E7', '2024-01-01', '2026-08-20', 5, NULL, 'en'),
       (NULL, @B, @Dep, @PosB, N'QA E8', '2026-07-10', NULL, 5, NULL, 'en'),
       (NULL, @B, @Dep, @PosB, N'QA E9', '2020-06-01', NULL, 3, NULL, 'en');

DECLARE @Mgr INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA Manager');
UPDATE hr.EMPLOYEE SET ReportsToEmployeeId = @Mgr WHERE FullName IN (N'QA E2', N'QA E3', N'QA E4', N'QA E5', N'QA E6', N'QA E7', N'QA E8');
UPDATE hr.BRANCH SET ManagerEmployeeId = @Mgr WHERE BranchId = @B;

/* salary components (tier ranges: tier3 3000-4000, tier4 2000-3000, tier5 1000-2000 USD) */
DECLARE @CtBasic INT = (SELECT ComponentTypeId FROM hr.COMPONENT_TYPE WHERE Name = N'Basic Salary');
DECLARE @CtTrans INT = (SELECT ComponentTypeId FROM hr.COMPONENT_TYPE WHERE Name = N'Transport Allowance');
INSERT INTO hr.SALARY_COMPONENT (EmployeeId, ComponentTypeId, Amount, CurrencyCode, EffectiveFrom)
SELECT e.EmployeeId, @CtBasic,
       CASE e.FullName WHEN N'QA Manager' THEN 2500 WHEN N'QA HR Officer' THEN 3000
                       WHEN N'QA E1' THEN 3500 WHEN N'QA E9' THEN 3500 WHEN N'QA E2' THEN 1500 ELSE 1200 END,
       'USD', '2026-01-01'
FROM hr.EMPLOYEE e WHERE e.FullName LIKE N'QA %';
INSERT INTO hr.SALARY_COMPONENT (EmployeeId, ComponentTypeId, Amount, CurrencyCode, EffectiveFrom)
SELECT e.EmployeeId, @CtTrans, 6000000, 'LBP', '2026-01-01'
FROM hr.EMPLOYEE e WHERE e.FullName IN (N'QA E1', N'QA E9');
GO

/* ---- 5. device + enrolments --------------------------------------------- */
DECLARE @B INT = (SELECT BranchId FROM hr.BRANCH WHERE Name = N'QA Branch');
INSERT INTO attendance.DEVICE (SerialNumber, BranchId, IsActive, [Name], PullIp, PullPort, PullCommKey, PullEnabled)
VALUES ('QA-DEVICE-001', @B, 1, N'QA Device', '127.0.0.1', 43700, 0, 0);
DECLARE @D INT = (SELECT DeviceId FROM attendance.DEVICE WHERE SerialNumber = 'QA-DEVICE-001');
INSERT INTO attendance.EMPLOYEE_DEVICE (EmployeeId, DeviceId, EnrollPin)
SELECT e.EmployeeId, @D, 'QA' + RIGHT(e.FullName, 1)
FROM hr.EMPLOYEE e WHERE e.FullName LIKE N'QA E[1-9]';
GO

/* ---- 6. roster for M through the real generator procs --------------------- */
DECLARE @Morning INT = (SELECT ShiftId FROM attendance.SHIFT WHERE Name = N'Morning');
DECLARE @Evening INT = (SELECT ShiftId FROM attendance.SHIFT WHERE Name = N'Evening');
DECLARE @E TABLE (Name NVARCHAR(50), Id INT);
INSERT INTO @E SELECT FullName, EmployeeId FROM hr.EMPLOYEE WHERE FullName LIKE N'QA %';
DECLARE @id INT;
/* Mon-Sat with Sunday rest */
SELECT @id = Id FROM @E WHERE Name = N'QA E1'; EXEC attendance.usp_ShiftAssignment_GenerateRange @id, '2026-08-01', '2026-08-31', @Morning, '1111110', 0;
SELECT @id = Id FROM @E WHERE Name = N'QA E2'; EXEC attendance.usp_ShiftAssignment_GenerateRange @id, '2026-08-15', '2026-08-31', @Morning, '1111110', 0;
SELECT @id = Id FROM @E WHERE Name = N'QA E3'; EXEC attendance.usp_ShiftAssignment_GenerateRange @id, '2026-08-01', '2026-08-31', @Evening, '1111110', 0;
SELECT @id = Id FROM @E WHERE Name = N'QA E4'; EXEC attendance.usp_ShiftAssignment_GenerateRange @id, '2026-08-01', '2026-08-31', @Morning, '1111100', 0;  -- Sat + Sun rest
SELECT @id = Id FROM @E WHERE Name = N'QA E5'; EXEC attendance.usp_ShiftAssignment_GenerateRange @id, '2026-08-01', '2026-08-31', @Morning, '1111110', 0;
SELECT @id = Id FROM @E WHERE Name = N'QA E6'; EXEC attendance.usp_ShiftAssignment_GenerateRange @id, '2026-08-01', '2026-08-31', @Morning, '1111110', 0;
SELECT @id = Id FROM @E WHERE Name = N'QA E7'; EXEC attendance.usp_ShiftAssignment_GenerateRange @id, '2026-08-01', '2026-08-20', @Morning, '1111110', 0;
SELECT @id = Id FROM @E WHERE Name = N'QA E9'; EXEC attendance.usp_ShiftAssignment_GenerateRange @id, '2026-08-01', '2026-08-31', @Morning, '1111110', 0;
/* one-off: E4 works the Evening shift on Wed 2026-08-12 (used by R5 to show how copy-period treats exceptions) */
SELECT @id = Id FROM @E WHERE Name = N'QA E4'; EXEC attendance.usp_ShiftAssignment_Upsert @id, '2026-08-12', @Evening, 0;
GO

/* ---- 7. punches (RAW_DEVICE_LOG, Source = 'QA') ---------------------------
   Times are wall-clock (the processor compares PunchTimeUtc with WorkDate+StartTime
   with no time-zone conversion, so "Utc" columns hold local time in this system).
   Normal Morning day = 07:00 in / 16:00 out. Normal Evening day = 16:00 in / 01:00 out next day.
   --------------------------------------------------------------------------- */
DECLARE @D INT = (SELECT DeviceId FROM attendance.DEVICE WHERE SerialNumber = 'QA-DEVICE-001');
DECLARE @Morning INT = (SELECT ShiftId FROM attendance.SHIFT WHERE Name = N'Morning');
DECLARE @Evening INT = (SELECT ShiftId FROM attendance.SHIFT WHERE Name = N'Evening');

IF OBJECT_ID('tempdb..#p') IS NOT NULL DROP TABLE #p;
CREATE TABLE #p (EmployeeId INT, PunchTime DATETIME2(0), PunchType SMALLINT);

/* exceptions: employee-days that do NOT get the standard pair */
IF OBJECT_ID('tempdb..#ex') IS NOT NULL DROP TABLE #ex;
CREATE TABLE #ex (EmployeeId INT, WorkDate DATE);
DECLARE @E1 INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA E1');
DECLARE @E3 INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA E3');
DECLARE @E4 INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA E4');
DECLARE @E5 INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA E5');
DECLARE @E6 INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA E6');
INSERT INTO #ex VALUES
 (@E1,'2026-08-04'),(@E1,'2026-08-05'),(@E1,'2026-08-06'),(@E1,'2026-08-07'),(@E1,'2026-08-08'),
 (@E1,'2026-08-10'),(@E1,'2026-08-11'),(@E1,'2026-08-12'),(@E1,'2026-08-13'),
 (@E3,'2026-08-03'),
 (@E5,'2026-08-17'),(@E5,'2026-08-18'),(@E5,'2026-08-19'),(@E5,'2026-08-24'),
 (@E6,'2026-08-10'),(@E6,'2026-08-11');

/* standard pairs for every rostered working day not in the exception list */
INSERT INTO #p (EmployeeId, PunchTime, PunchType)
SELECT sa.EmployeeId, DATEADD(MINUTE, 7*60, CAST(sa.WorkDate AS DATETIME2(0))), 0
FROM attendance.SHIFT_ASSIGNMENT sa JOIN hr.EMPLOYEE e ON e.EmployeeId = sa.EmployeeId AND e.FullName LIKE N'QA E%'
WHERE sa.ShiftId = @Morning AND sa.IsRestDay = 0 AND sa.WorkDate BETWEEN '2026-08-01' AND '2026-08-31'
  AND NOT EXISTS (SELECT 1 FROM #ex x WHERE x.EmployeeId = sa.EmployeeId AND x.WorkDate = sa.WorkDate)
UNION ALL
SELECT sa.EmployeeId, DATEADD(MINUTE, 16*60, CAST(sa.WorkDate AS DATETIME2(0))), 1
FROM attendance.SHIFT_ASSIGNMENT sa JOIN hr.EMPLOYEE e ON e.EmployeeId = sa.EmployeeId AND e.FullName LIKE N'QA E%'
WHERE sa.ShiftId = @Morning AND sa.IsRestDay = 0 AND sa.WorkDate BETWEEN '2026-08-01' AND '2026-08-31'
  AND NOT EXISTS (SELECT 1 FROM #ex x WHERE x.EmployeeId = sa.EmployeeId AND x.WorkDate = sa.WorkDate)
UNION ALL
SELECT sa.EmployeeId, DATEADD(MINUTE, 16*60, CAST(sa.WorkDate AS DATETIME2(0))), 0
FROM attendance.SHIFT_ASSIGNMENT sa JOIN hr.EMPLOYEE e ON e.EmployeeId = sa.EmployeeId AND e.FullName LIKE N'QA E%'
WHERE sa.ShiftId = @Evening AND sa.IsRestDay = 0 AND sa.WorkDate BETWEEN '2026-08-01' AND '2026-08-31'
  AND NOT EXISTS (SELECT 1 FROM #ex x WHERE x.EmployeeId = sa.EmployeeId AND x.WorkDate = sa.WorkDate)
UNION ALL
SELECT sa.EmployeeId, DATEADD(MINUTE, 25*60, CAST(sa.WorkDate AS DATETIME2(0))), 1     -- 01:00 next day
FROM attendance.SHIFT_ASSIGNMENT sa JOIN hr.EMPLOYEE e ON e.EmployeeId = sa.EmployeeId AND e.FullName LIKE N'QA E%'
WHERE sa.ShiftId = @Evening AND sa.IsRestDay = 0 AND sa.WorkDate BETWEEN '2026-08-01' AND '2026-08-31'
  AND NOT EXISTS (SELECT 1 FROM #ex x WHERE x.EmployeeId = sa.EmployeeId AND x.WorkDate = sa.WorkDate);

/* scenario punches */
INSERT INTO #p VALUES
 (@E1, '2026-08-02 08:00', 0), (@E1, '2026-08-02 12:00', 1),             -- R2: punch on a Sunday rest day
 (@E1, '2026-08-04 07:12', 0), (@E1, '2026-08-04 16:00', 1),             -- A2: 12 min after start, grace 10
 (@E1, '2026-08-05 07:08', 0), (@E1, '2026-08-05 16:00', 1),             -- A3: inside grace
 (@E1, '2026-08-06 07:00', 0), (@E1, '2026-08-06 14:45', 1),             -- A4: out 75 min early
 /* 2026-08-07: A5 no punches */
 (@E1, '2026-08-08 07:00', 0), (@E1, '2026-08-08 10:00', 1),             -- A4b: 75-minute mid-day exit
 (@E1, '2026-08-08 11:15', 0), (@E1, '2026-08-08 16:00', 1),
 (@E1, '2026-08-10 07:00', 0),                                           -- A6: in only
 (@E1, '2026-08-11 07:00', 0), (@E1, '2026-08-11 07:00:30', 0), (@E1, '2026-08-11 16:00', 1), -- A7: press within debounce window
 (@E1, '2026-08-12 06:40', 0), (@E1, '2026-08-12 16:00', 1),             -- A9: early in
 (@E1, '2026-08-13 07:00', 0), (@E1, '2026-08-13 15:05', 1),             -- A11: left 55 min early, exit permission 60 min
 (@E3, '2026-08-03 16:05', 0), (@E3, '2026-08-04 01:10', 1),             -- A8: overnight
 (@E4, '2026-08-08 07:00', 0), (@E4, '2026-08-08 12:00', 1),             -- R2: E4 punch on Saturday rest day
 (@E5, '2026-08-18 07:00', 0), (@E5, '2026-08-18 09:00', 1);             -- A10: accidental punch on a leave day

INSERT INTO attendance.RAW_DEVICE_LOG (DeviceId, EnrollPin, EmployeeId, PunchTimeUtc, PunchType, [Source], DedupHash)
SELECT @D, ed.EnrollPin, p.EmployeeId, p.PunchTime, p.PunchType, 'QA',
       CONVERT(VARCHAR(64), HASHBYTES('SHA2_256', CONVERT(VARCHAR(200),
           CONCAT(@D, '|', ed.EnrollPin, '|', FORMAT(p.PunchTime, 'yyyy-MM-dd\THH:mm:ss.fffffff'), '|', p.PunchType))), 2)
FROM #p p
JOIN attendance.EMPLOYEE_DEVICE ed ON ed.EmployeeId = p.EmployeeId AND ed.DeviceId = @D;
INSERT INTO dbo.QA_STATE VALUES ('seed.punches', CAST(@@ROWCOUNT AS NVARCHAR(20)));
GO

/* ---- 8. booking test fixtures: a QA room with its own discount and add-on --- */
DECLARE @Room TABLE (RoomId INT, Code VARCHAR(30), Name NVARCHAR(80), NameAr NVARCHAR(80), Seats INT, MinPersons INT,
    PricePerHour DECIMAL(10,2), CurrencyCode CHAR(3), DepositPercent DECIMAL(5,2), MinHours INT, MaxHours INT,
    [Description] NVARCHAR(300), Features NVARCHAR(300), PolicyText NVARCHAR(1000), PhotoKey VARCHAR(100), SortOrder INT, IsActive BIT);
INSERT INTO @Room EXEC booking.usp_Room_Upsert @RoomId = NULL, @Code = 'qa-room', @Name = N'QA Room', @Seats = 6,
     @MinPersons = 1, @PricePerHour = 20, @CurrencyCode = 'USD', @DepositPercent = 50, @SortOrder = 99, @IsActive = 1;
DECLARE @R INT = (SELECT RoomId FROM booking.ROOM WHERE Code = 'qa-room');
DECLARE @d TINYINT = 1;
WHILE @d <= 7 BEGIN EXEC booking.usp_Room_SetHours @R, @d, '09:00', '01:00', 0; SET @d += 1; END   -- opens 09:00, closes 01:00 next day
EXEC booking.usp_RoomDiscount_Upsert @DiscountId = NULL, @RoomId = @R, @MinHours = 3, @DiscountPercent = 10, @IsActive = 1;
EXEC booking.usp_RoomAddon_Upsert @RoomId = @R, @Name = N'QA Platter', @PriceType = 'Fixed', @Price = 15;
INSERT INTO dbo.QA_STATE VALUES ('room.id', CAST(@R AS NVARCHAR(10)));
GO
/* ---- 9. leave year 2026 for the QA employees (real employees already have theirs; the proc skips them) ----
   Part of the fixture so that balances exist when the leave requests are approved; cases/03 re-runs it for L1. */
DECLARE @hr INT = (SELECT UserId FROM security.[USER] WHERE Username = N'qa.hr');
DECLARE @o TABLE (LeaveTypeName NVARCHAR(60), EmployeesOpened INT, DaysGranted DECIMAL(9,2), ProratedEmployees INT, DaysCarriedOver DECIMAL(9,2), DaysExpired DECIMAL(9,2));
INSERT INTO @o EXEC hr.usp_LeaveYear_Open @Year = 2026, @ActedByUserId = @hr;
SELECT 'LeaveYear_Open (seed)' AS what, LeaveTypeName, EmployeesOpened, DaysGranted, ProratedEmployees FROM @o;
GO
PRINT 'SEED DONE';
SELECT 'QA employees' AS what, COUNT(*) AS n FROM hr.EMPLOYEE WHERE FullName LIKE N'QA %'
UNION ALL SELECT 'QA roster rows', COUNT(*) FROM attendance.SHIFT_ASSIGNMENT sa JOIN hr.EMPLOYEE e ON e.EmployeeId = sa.EmployeeId WHERE e.FullName LIKE N'QA %'
UNION ALL SELECT 'QA punches', COUNT(*) FROM attendance.RAW_DEVICE_LOG WHERE [Source] = 'QA';
GO
