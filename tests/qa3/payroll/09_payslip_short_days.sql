/* QA3 payroll - script 109: the days behind a payslip's "N day(s) short" line. The per-day list (payroll.fn_ShortDayList)
   is the same rule as the total the payslip deducts (payroll.fn_ShortDays), and payroll.usp_Payslip_ShortDays lists, for
   one payslip, exactly the days its line counted: same total, same number of dates, within the run's period up to the
   day it counted to. A payslip without the line lists nothing.
   Runs on a dev database with docs/103 and docs/109 applied, inside a transaction that is rolled back.
   sqlcmd -I -b -i tests/qa3/payroll/09_payslip_short_days.sql   ->  prints 'ok 09_payslip_short_days' */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
BEGIN TRAN;
DECLARE @fails INT = 0, @Hr INT, @B INT, @S INT, @Basic INT, @Short INT, @Full INT, @Run INT, @d DATE, @x NVARCHAR(400);
DECLARE @g TABLE (PayrollRunId INT, PayslipCount INT, PayslipsWithWarnings INT);
DECLARE @c TABLE (PayrollRunId INT, PeriodYearMonth CHAR(7), [Status] VARCHAR(12), PrimaryCurrency CHAR(3), RunType VARCHAR(12));
DECLARE @days TABLE (WorkDate DATE, [Status] VARCHAR(20), FirstInUtc DATETIME2, LastOutUtc DATETIME2, WorkedMinutes INT, StandardMinutes INT,
                     ShortfallMinutes INT, LateMinutes INT, DayFraction DECIMAL(9,4), MissingDays DECIMAL(9,4), CountedFrom DATE, CountedUpTo DATE,
                     LineQuantity DECIMAL(18,4));
SET @Hr = (SELECT TOP 1 UserId FROM security.[USER] u WHERE payroll.fn_UserHasRole(u.UserId, N'HR') = 1 OR payroll.fn_UserHasRole(u.UserId, N'Admin') = 1 ORDER BY UserId);
UPDATE core.SETTING SET SettingValue = '26' WHERE SettingKey = 'StandardWorkingDaysPerMonth';
UPDATE hr.APPROVAL_TIER SET MinBasicSalary = NULL, MaxBasicSalary = NULL;
SET @Basic = (SELECT ComponentTypeId FROM hr.COMPONENT_TYPE WHERE SystemCode = 'BASIC');
INSERT INTO hr.BRANCH (Name) VALUES (N'QA3 Short Days'); SET @B = SCOPE_IDENTITY();
INSERT INTO attendance.SHIFT (Name, StartTime, EndTime, GraceMinutes, CrossesMidnight, BreakMinutes) VALUES (N'QA3 SD 08-16', '08:00', '16:00', NULL, 0, 0);
SET @S = SCOPE_IDENTITY();
INSERT INTO attendance.ROSTER_MONTH (BranchId, MonthDate, [Status]) VALUES (@B, '2099-09-01', 'Approved');
INSERT INTO hr.EMPLOYEE (BranchId, DepartmentId, PositionId, FullName, HireDate)
SELECT @B, (SELECT TOP 1 DepartmentId FROM hr.DEPARTMENT ORDER BY DepartmentId), (SELECT TOP 1 PositionId FROM hr.POSITION ORDER BY PositionId), v.N, '2025-01-01'
FROM (VALUES (N'QA3 SD Short'), (N'QA3 SD Full')) v(N);
SELECT @Short = MAX(CASE WHEN FullName = N'QA3 SD Short' THEN EmployeeId END), @Full = MAX(CASE WHEN FullName = N'QA3 SD Full' THEN EmployeeId END)
FROM hr.EMPLOYEE WHERE BranchId = @B;
INSERT INTO hr.EMPLOYEE_BRANCH_HISTORY (EmployeeId, BranchId, EffectiveFrom)
SELECT e.EmployeeId, @B, e.HireDate FROM hr.EMPLOYEE e WHERE e.BranchId = @B AND NOT EXISTS (SELECT 1 FROM hr.EMPLOYEE_BRANCH_HISTORY h WHERE h.EmployeeId = e.EmployeeId);
INSERT INTO hr.SALARY_COMPONENT (EmployeeId, ComponentTypeId, Amount, CurrencyCode, EffectiveFrom) VALUES (@Short, @Basic, 2600, 'USD', '2025-01-01'), (@Full, @Basic, 2600, 'USD', '2025-01-01');

/* September 2099, both rostered every day. The short one: absent on the 3rd and the 17th, 2 hours short on the 9th,
   30 minutes short on the 22nd, on leave on the 25th (never short), a rest day on the 28th (never short); the rest full. */
SET @d = '2099-09-01';
WHILE @d <= '2099-09-30'
BEGIN
    INSERT INTO attendance.SHIFT_ASSIGNMENT (EmployeeId, ShiftId, WorkDate, IsRestDay)
    VALUES (@Short, CASE WHEN @d = '2099-09-28' THEN NULL ELSE @S END, @d, CASE WHEN @d = '2099-09-28' THEN 1 ELSE 0 END), (@Full, @S, @d, 0);
    INSERT INTO attendance.ATTENDANCE_RECORD (EmployeeId, WorkDate, [Status], DayFraction, ShortfallMinutes, StandardMinutes, WorkedMinutes, [Source])
    VALUES (@Short, @d,
            CASE WHEN @d IN ('2099-09-03', '2099-09-17') THEN 'Absent' WHEN @d = '2099-09-25' THEN 'Leave' WHEN @d = '2099-09-28' THEN 'RestDay' ELSE 'Present' END,
            CASE WHEN @d IN ('2099-09-03', '2099-09-17') THEN 0 WHEN @d = '2099-09-09' THEN 0.75 WHEN @d = '2099-09-22' THEN 0.9375
                 WHEN @d IN ('2099-09-25', '2099-09-28') THEN NULL ELSE 1 END,
            CASE WHEN @d IN ('2099-09-03', '2099-09-17') THEN 480 WHEN @d = '2099-09-09' THEN 120 WHEN @d = '2099-09-22' THEN 30 ELSE 0 END,
            480,
            CASE WHEN @d IN ('2099-09-03', '2099-09-17', '2099-09-25', '2099-09-28') THEN 0 WHEN @d = '2099-09-09' THEN 360 WHEN @d = '2099-09-22' THEN 450 ELSE 480 END,
            'Device'),
           (@Full, @d, 'Present', 1, 0, 480, 480, 'Device');
    SET @d = DATEADD(DAY, 1, @d);
END

/* 1. the per-day list adds up to the total, employee by employee, over the whole month (every employee of the database) */
IF EXISTS (
    SELECT 1
    FROM payroll.fn_ShortDays('2099-09-01', '2099-09-30') t
    FULL JOIN (SELECT EmployeeId, SUM(MissingDays) AS MissingDays, COUNT(*) AS DaysAffected
               FROM payroll.fn_ShortDayList('2099-09-01', '2099-09-30') GROUP BY EmployeeId) l ON l.EmployeeId = t.EmployeeId
    WHERE t.EmployeeId IS NULL OR l.EmployeeId IS NULL OR ABS(t.MissingDays - l.MissingDays) > 0.000001 OR t.DaysAffected <> l.DaysAffected)
    BEGIN SET @fails += 1; RAISERROR('09: fn_ShortDayList does not add up to fn_ShortDays.', 16, 1); END

/* 2. the payslip: 2 absences + 0.25 + 0.0625 = 2.3125 days across 4 dates */
INSERT INTO @c EXEC payroll.usp_PayrollRun_Create @PeriodYearMonth = '2099-09', @CreatedByUserId = @Hr, @Notes = N'QA3 payroll 09', @AsOfDate = '2099-10-02';
SET @Run = (SELECT PayrollRunId FROM @c);
INSERT INTO @g EXEC payroll.usp_PayrollRun_Generate @PayrollRunId = @Run, @ActedByUserId = @Hr, @AsOfDate = '2099-10-02';
DECLARE @PsShort INT = (SELECT PayslipId FROM payroll.PAYSLIP WHERE PayrollRunId = @Run AND EmployeeId = @Short);
DECLARE @PsFull INT = (SELECT PayslipId FROM payroll.PAYSLIP WHERE PayrollRunId = @Run AND EmployeeId = @Full);
INSERT INTO @days EXEC payroll.usp_Payslip_ShortDays @PayslipId = @PsShort;
SELECT @x = CONCAT(COUNT(*), ' rows, ', SUM(MissingDays), ' days, line ', MAX(LineQuantity), ', up to ', MAX(CountedUpTo),
                   ', dates ', STRING_AGG(CONVERT(CHAR(10), WorkDate, 23), ' ')) FROM @days;
IF (SELECT COUNT(*) FROM @days) <> 4
   OR (SELECT SUM(MissingDays) FROM @days) <> 2.3125
   OR EXISTS (SELECT 1 FROM @days WHERE WorkDate NOT IN ('2099-09-03', '2099-09-09', '2099-09-17', '2099-09-22'))
   OR (SELECT MAX(CountedFrom) FROM @days) <> '2099-09-01' OR (SELECT MAX(CountedUpTo) FROM @days) <> '2099-09-30'
    BEGIN SET @fails += 1; RAISERROR('09: the payslip lists the wrong days: %s', 16, 1, @x); END
/* the same total and the same dates as the line itself */
IF NOT EXISTS (SELECT 1 FROM payroll.PAYSLIP_LINE pl JOIN hr.COMPONENT_TYPE ct ON ct.ComponentTypeId = pl.ComponentTypeId
               WHERE pl.PayslipId = @PsShort AND ct.SystemCode = 'LATE' AND pl.SourceType = 'Attendance'
                 AND ROUND(pl.Quantity, 2) = ROUND((SELECT SUM(MissingDays) FROM @days), 2) AND pl.Note LIKE N'% across 4 date(s)')
    BEGIN SET @fails += 1; RAISERROR('09: the list and the payslip line disagree: %s', 16, 1, @x); END

/* 3. a payslip with no short-days line lists nothing */
DELETE FROM @days;
INSERT INTO @days EXEC payroll.usp_Payslip_ShortDays @PayslipId = @PsFull;
IF EXISTS (SELECT 1 FROM @days) BEGIN SET @fails += 1; RAISERROR('09: a payslip without short days lists some.', 16, 1); END

/* 4. a run that counted only to the 15th (generated on the 16th) lists only the days up to the 15th */
UPDATE payroll.PAYROLL_RUN SET GeneratedUpTo = '2099-09-15' WHERE PayrollRunId = @Run;
DELETE FROM @days;
INSERT INTO @days EXEC payroll.usp_Payslip_ShortDays @PayslipId = @PsShort;
IF (SELECT COUNT(*) FROM @days) <> 2 OR (SELECT MAX(WorkDate) FROM @days) <> '2099-09-09'
    BEGIN SET @fails += 1; RAISERROR('09: the list ignores the day the run counted to.', 16, 1); END

/* 5. an unknown payslip lists nothing (no error) */
DELETE FROM @days;
INSERT INTO @days EXEC payroll.usp_Payslip_ShortDays @PayslipId = -1;
IF EXISTS (SELECT 1 FROM @days) BEGIN SET @fails += 1; RAISERROR('09: an unknown payslip lists days.', 16, 1); END

ROLLBACK TRAN;
IF @fails = 0 PRINT 'ok 09_payslip_short_days';
