/* QA3 payroll (unit E) - REL-1 / ROS-1: nothing before the hire date or after the termination date is deducted (short
   days, the unpaid-holiday line, exit permissions, unpaid leave), so a leaver's net never goes negative; readiness does
   not wait for days outside the employment. REL-5: an employee "removed" (soft-deleted) with attendance in the month is
   still paid for it.
   Runs on a dev database with docs/103_qa3_payroll.sql applied, inside a transaction that is rolled back.
   sqlcmd -I -b -i tests/qa3/payroll/02_employment_window.sql   ->  prints 'ok 02_employment_window' */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
BEGIN TRAN;
DECLARE @fails INT = 0, @Hr INT, @B INT, @S INT, @Basic INT, @Leaver INT, @Late INT, @Removed INT, @Run INT, @a DECIMAL(18,2), @x NVARCHAR(400), @d DATE;
DECLARE @g TABLE (PayrollRunId INT, PayslipCount INT, PayslipsWithWarnings INT);
DECLARE @c TABLE (PayrollRunId INT, PeriodYearMonth CHAR(7), [Status] VARCHAR(12), PrimaryCurrency CHAR(3), RunType VARCHAR(12));
DECLARE @r TABLE (PeriodYearMonth CHAR(7), PeriodStart DATE, PeriodEnd DATE, UnprocessedPunches INT, UnresolvedPinPunches INT, OpenAnomalies INT,
                  PendingCorrections INT, RosteredDaysWithNoRecord INT, UndecidedExitVariances INT, UndecidedAnomalies INT, IsReady BIT);
SET @Hr = (SELECT TOP 1 UserId FROM security.[USER] u WHERE payroll.fn_UserHasRole(u.UserId, N'HR') = 1 OR payroll.fn_UserHasRole(u.UserId, N'Admin') = 1 ORDER BY UserId);
UPDATE core.SETTING SET SettingValue = '26' WHERE SettingKey = 'StandardWorkingDaysPerMonth';
UPDATE hr.APPROVAL_TIER SET MinBasicSalary = NULL, MaxBasicSalary = NULL;
SET @Basic = (SELECT ComponentTypeId FROM hr.COMPONENT_TYPE WHERE SystemCode = 'BASIC');
INSERT INTO hr.BRANCH (Name) VALUES (N'QA3 Pay Window'); SET @B = SCOPE_IDENTITY();
INSERT INTO attendance.SHIFT (Name, StartTime, EndTime, GraceMinutes, CrossesMidnight, BreakMinutes) VALUES (N'QA3 07-15', '07:00', '15:00', NULL, 0, 0);
SET @S = SCOPE_IDENTITY();
INSERT INTO attendance.ROSTER_MONTH (BranchId, MonthDate, [Status]) VALUES (@B, '2099-08-01', 'Approved');
INSERT INTO hr.EMPLOYEE (BranchId, DepartmentId, PositionId, FullName, HireDate, TerminationDate)
SELECT @B, (SELECT TOP 1 DepartmentId FROM hr.DEPARTMENT ORDER BY DepartmentId), (SELECT TOP 1 PositionId FROM hr.POSITION ORDER BY PositionId), v.N, v.H, v.T
FROM (VALUES (N'QA3 Rami Leaver', CAST('2025-01-01' AS DATE), CAST('2099-08-15' AS DATE)), (N'QA3 Nour Late Starter', '2099-08-10', NULL), (N'QA3 Rita Removed', '2025-01-01', NULL)) v(N, H, T);
SELECT @Leaver = MAX(CASE WHEN FullName = N'QA3 Rami Leaver' THEN EmployeeId END), @Late = MAX(CASE WHEN FullName = N'QA3 Nour Late Starter' THEN EmployeeId END),
       @Removed = MAX(CASE WHEN FullName = N'QA3 Rita Removed' THEN EmployeeId END) FROM hr.EMPLOYEE WHERE BranchId = @B;
INSERT INTO hr.EMPLOYEE_BRANCH_HISTORY (EmployeeId, BranchId, EffectiveFrom)
SELECT e.EmployeeId, @B, e.HireDate FROM hr.EMPLOYEE e WHERE e.BranchId = @B AND NOT EXISTS (SELECT 1 FROM hr.EMPLOYEE_BRANCH_HISTORY h WHERE h.EmployeeId = e.EmployeeId);
INSERT INTO hr.SALARY_COMPONENT (EmployeeId, ComponentTypeId, Amount, CurrencyCode, EffectiveFrom)
VALUES (@Leaver, @Basic, 2600, 'USD', '2025-01-01'), (@Late, @Basic, 2600, 'USD', '2099-08-01'), (@Removed, @Basic, 2600, 'USD', '2025-01-01');
/* the approved August roster rosters all three every day; the leaver worked to the 15th and the old rule marked him
   absent after it; the late starter (hire date corrected from the 1st to the 10th) was marked absent before it; the
   removed one worked to the 20th */
SET @d = '2099-08-01';
WHILE @d <= '2099-08-31'
BEGIN
    INSERT INTO attendance.SHIFT_ASSIGNMENT (EmployeeId, ShiftId, WorkDate, IsRestDay) VALUES (@Leaver, @S, @d, 0), (@Late, @S, @d, 0), (@Removed, @S, @d, 0);
    INSERT INTO attendance.ATTENDANCE_RECORD (EmployeeId, WorkDate, [Status], DayFraction, ShortfallMinutes, StandardMinutes, WorkedMinutes, [Source])
    VALUES (@Leaver, @d, CASE WHEN @d <= '2099-08-15' THEN 'Present' ELSE 'Absent' END, CASE WHEN @d <= '2099-08-15' THEN 1 ELSE 0 END, CASE WHEN @d <= '2099-08-15' THEN 0 ELSE 480 END, 480, CASE WHEN @d <= '2099-08-15' THEN 480 ELSE 0 END, 'Device'),
           (@Late,   @d, CASE WHEN @d >= '2099-08-10' THEN 'Present' ELSE 'Absent' END, CASE WHEN @d >= '2099-08-10' THEN 1 ELSE 0 END, CASE WHEN @d >= '2099-08-10' THEN 0 ELSE 480 END, 480, CASE WHEN @d >= '2099-08-10' THEN 480 ELSE 0 END, 'Device');
    IF @d <= '2099-08-20'
        INSERT INTO attendance.ATTENDANCE_RECORD (EmployeeId, WorkDate, [Status], DayFraction, StandardMinutes, WorkedMinutes, [Source]) VALUES (@Removed, @d, 'Present', 1, 480, 480, 'Device');
    SET @d = DATEADD(DAY, 1, @d);
END
/* the removed one's roster after the 20th has no record - readiness would wait for it; she is removed, so it does not */
UPDATE hr.EMPLOYEE SET IsDeleted = 1 WHERE EmployeeId = @Removed;
/* a roster day before the hire date with no record does not hold readiness back either */
DELETE FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @Late AND WorkDate = '2099-08-02';
INSERT INTO @r EXEC attendance.usp_Attendance_PayrollReadiness '2099-08', '2099-09-02';
IF (SELECT RosteredDaysWithNoRecord FROM @r) <> 0
    BEGIN SET @fails += 1; RAISERROR('02: readiness counts a roster day outside the employment as missing.', 16, 1); END

INSERT INTO @c EXEC payroll.usp_PayrollRun_Create @PeriodYearMonth = '2099-08', @CreatedByUserId = @Hr, @Notes = N'QA3 payroll 02', @AsOfDate = '2099-09-02';
SET @Run = (SELECT PayrollRunId FROM @c);
INSERT INTO @g EXEC payroll.usp_PayrollRun_Generate @PayrollRunId = @Run, @ActedByUserId = @Hr, @AsOfDate = '2099-09-02';

/* the leaver: 2600 x 15/31 = 1258.06, nothing deducted after the 15th, net positive (it was -41.94) */
SELECT @a = SUM(CASE WHEN l.Category = 'Deduction' AND l.SourceType IN ('Attendance','Leave','ExitPermission') THEN l.Amount ELSE 0 END),
       @x = CONCAT(MAX(ps.NetUsd), ' net; basic ', SUM(CASE WHEN l.SourceType = 'Salary' THEN l.Amount ELSE 0 END))
FROM payroll.PAYSLIP ps JOIN payroll.PAYSLIP_LINE l ON l.PayslipId = ps.PayslipId WHERE ps.PayrollRunId = @Run AND ps.EmployeeId = @Leaver;
IF @a <> 0 OR (SELECT NetUsd FROM payroll.PAYSLIP WHERE PayrollRunId = @Run AND EmployeeId = @Leaver) <= 0
   OR (SELECT SUM(l.Amount) FROM payroll.PAYSLIP ps JOIN payroll.PAYSLIP_LINE l ON l.PayslipId = ps.PayslipId WHERE ps.PayrollRunId = @Run AND ps.EmployeeId = @Leaver AND l.SourceType = 'Salary') <> 1258.06
    BEGIN SET @fails += 1; RAISERROR('02: the leaver was docked after the termination date: %s', 16, 1, @x); END

/* the late starter: 2600 x 22/31 = 1845.16 and no deduction for the days before the 10th */
IF EXISTS (SELECT 1 FROM payroll.PAYSLIP ps JOIN payroll.PAYSLIP_LINE l ON l.PayslipId = ps.PayslipId WHERE ps.PayrollRunId = @Run AND ps.EmployeeId = @Late AND l.SourceType = 'Attendance')
   OR (SELECT SUM(l.Amount) FROM payroll.PAYSLIP ps JOIN payroll.PAYSLIP_LINE l ON l.PayslipId = ps.PayslipId WHERE ps.PayrollRunId = @Run AND ps.EmployeeId = @Late AND l.SourceType = 'Salary') <> 1845.16
    BEGIN SET @fails += 1; RAISERROR('02: days before the corrected hire date were deducted.', 16, 1); END

/* REL-5: the removed employee worked to the 20th - she is in the run */
IF NOT EXISTS (SELECT 1 FROM payroll.PAYSLIP WHERE PayrollRunId = @Run AND EmployeeId = @Removed)
    BEGIN SET @fails += 1; RAISERROR('02: a soft-deleted employee with attendance in the month has no payslip.', 16, 1); END

ROLLBACK TRAN;
IF @fails = 0 PRINT 'ok 02_employment_window';
