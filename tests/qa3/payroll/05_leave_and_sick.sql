/* QA3 payroll (unit E) - leave on the payslip:
   PAY-8   unpaid leave is the APPROVED span (ISNULL(ApprovedToDate, ToDate): a partial approval keeps the first days) and the
           type as approved (ISNULL(PaidSnapshot, IsPaid): flipping the type later never re-prices it); a short day after the
           approved span is judged from attendance like any other day;
   LEV-17  the payslip's paid / unpaid leave days are WORKING days of the approved span (a rest day costs nothing, a half
           day is 0.5);
   LEV-16 / LEV-13 / PAY-13  sick pay tiers: the days of every TIERED type (a type with LEAVE_PAY_TIER rows, whatever its
           name) are numbered day by day across the year, so a leave crossing a month end costs each month its own days;
           the tier is chosen by WHOLE years of service (hired 31 Dec 2097: one whole year in January 2099, not two).
   Runs on a dev database with docs/103_qa3_payroll.sql applied, in transactions that are rolled back.
   sqlcmd -I -b -i tests/qa3/payroll/05_leave_and_sick.sql   ->  prints 'ok 05_leave_and_sick' */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
GO
CREATE PROCEDURE #qa3_05_emp @Name NVARCHAR(100), @Hire DATE, @E INT OUTPUT, @B INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @BasicType INT = (SELECT ComponentTypeId FROM hr.COMPONENT_TYPE WHERE SystemCode = 'BASIC');
    UPDATE core.SETTING SET SettingValue = '26' WHERE SettingKey = 'StandardWorkingDaysPerMonth';
    UPDATE core.SETTING SET SettingValue = '0' WHERE SettingKey = 'LeaveCountsRestDays';
    UPDATE hr.APPROVAL_TIER SET MinBasicSalary = NULL, MaxBasicSalary = NULL;
    INSERT INTO hr.BRANCH (Name) VALUES (CONCAT(N'QA3 Pay Leave ', @Name)); SET @B = SCOPE_IDENTITY();
    INSERT INTO hr.EMPLOYEE (BranchId, DepartmentId, PositionId, FullName, HireDate)
    VALUES (@B, (SELECT TOP 1 DepartmentId FROM hr.DEPARTMENT ORDER BY DepartmentId), (SELECT TOP 1 PositionId FROM hr.POSITION ORDER BY PositionId), @Name, @Hire);
    SET @E = SCOPE_IDENTITY();
    IF NOT EXISTS (SELECT 1 FROM hr.EMPLOYEE_BRANCH_HISTORY WHERE EmployeeId = @E) INSERT INTO hr.EMPLOYEE_BRANCH_HISTORY (EmployeeId, BranchId, EffectiveFrom) VALUES (@E, @B, @Hire);
    INSERT INTO hr.SALARY_COMPONENT (EmployeeId, ComponentTypeId, Amount, CurrencyCode, EffectiveFrom) VALUES (@E, @BasicType, 2600, 'USD', @Hire);
END
GO
/* an approved leave request */
CREATE PROCEDURE #qa3_05_leave @E INT, @Type INT, @From DATE, @To DATE, @ApprovedTo DATE, @PaidSnapshot BIT, @HalfDay CHAR(2) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Hr INT = (SELECT TOP 1 UserId FROM security.[USER] u WHERE payroll.fn_UserHasRole(u.UserId, N'HR') = 1 OR payroll.fn_UserHasRole(u.UserId, N'Admin') = 1 ORDER BY UserId);
    DECLARE @WD INT, @RT INT, @Ri INT;
    SELECT TOP 1 @WD = WorkflowDefinitionId, @RT = RequestTypeId FROM workflow.WORKFLOW_DEFINITION ORDER BY WorkflowDefinitionId;
    INSERT INTO workflow.REQUEST_INSTANCE (RequestTypeId, WorkflowDefinitionId, EmployeeId, RaisedByUserId, [Status], Title) VALUES (@RT, @WD, @E, @Hr, 'Approved', N'QA3 leave');
    SET @Ri = SCOPE_IDENTITY();
    INSERT INTO workflow.LEAVE_REQUEST (RequestInstanceId, EmployeeId, LeaveTypeId, FromDate, ToDate, DaysRequested, DaysApproved, HalfDay, ApprovedToDate, PaidSnapshot)
    VALUES (@Ri, @E, @Type, @From, @To, DATEDIFF(DAY, @From, @To) + 1, DATEDIFF(DAY, @From, ISNULL(@ApprovedTo, @To)) + 1, @HalfDay, @ApprovedTo, @PaidSnapshot);
END
GO
CREATE PROCEDURE #qa3_05_run @Period CHAR(7), @AsOf DATE, @Run INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Hr INT = (SELECT TOP 1 UserId FROM security.[USER] u WHERE payroll.fn_UserHasRole(u.UserId, N'HR') = 1 OR payroll.fn_UserHasRole(u.UserId, N'Admin') = 1 ORDER BY UserId);
    DECLARE @c TABLE (PayrollRunId INT, PeriodYearMonth CHAR(7), [Status] VARCHAR(12), PrimaryCurrency CHAR(3), RunType VARCHAR(12));
    DECLARE @g TABLE (PayrollRunId INT, PayslipCount INT, PayslipsWithWarnings INT);
    INSERT INTO @c EXEC payroll.usp_PayrollRun_Create @PeriodYearMonth = @Period, @CreatedByUserId = @Hr, @Notes = N'QA3 payroll 05', @AsOfDate = @AsOf;
    SET @Run = (SELECT PayrollRunId FROM @c);
    INSERT INTO @g EXEC payroll.usp_PayrollRun_Generate @PayrollRunId = @Run, @ActedByUserId = @Hr, @AsOfDate = @AsOf;
END
GO
DECLARE @fails INT = 0, @E INT, @B INT, @Run INT, @Jan INT, @Feb INT, @Unpaid INT, @Flip INT, @Flip2 INT, @Sick INT, @x NVARCHAR(400),
        @unpaidAmt DECIMAL(18,2), @shortAmt DECIMAL(18,2), @hdrUnpaid DECIMAL(6,2), @hdrPaid DECIMAL(6,2), @janAbs DECIMAL(18,2), @febAbs DECIMAL(18,2);

/* ======== A. PAY-8 / LEV-17 in March 2099: a rest day on the 11th (roster approved), an absence on the 15th ======== */
BEGIN TRAN;
EXEC #qa3_05_emp N'QA3 Leila Leave', '2024-01-01', @E OUTPUT, @B OUTPUT;
INSERT INTO hr.LEAVE_TYPE (Name, IsPaid) VALUES (N'QA3 Unpaid', 0); SET @Unpaid = SCOPE_IDENTITY();
INSERT INTO hr.LEAVE_TYPE (Name, IsPaid) VALUES (N'QA3 Paid then unpaid', 1); SET @Flip = SCOPE_IDENTITY();
INSERT INTO hr.LEAVE_TYPE (Name, IsPaid) VALUES (N'QA3 Unpaid then paid', 0); SET @Flip2 = SCOPE_IDENTITY();
INSERT INTO attendance.SHIFT_ASSIGNMENT (EmployeeId, ShiftId, WorkDate, IsRestDay) VALUES (@E, NULL, '2099-03-11', 1), (@E, (SELECT MIN(ShiftId) FROM attendance.SHIFT), '2099-03-15', 0);
INSERT INTO attendance.ROSTER_MONTH (BranchId, MonthDate, [Status], ApprovedAt) VALUES (@B, '2099-03-01', 'Approved', SYSUTCDATETIME());
INSERT INTO attendance.ATTENDANCE_RECORD (EmployeeId, WorkDate, [Status], DayFraction, StandardMinutes, WorkedMinutes, [Source])
VALUES (@E, '2099-03-11', 'RestDay', 1, 0, 0, 'Device'), (@E, '2099-03-15', 'Absent', 0, 480, 0, 'Device');
/* requested 10-20 March, approved up to the 12th: the 10th and the 12th cost (the 11th is a rest day) */
EXEC #qa3_05_leave @E, @Unpaid, '2099-03-10', '2099-03-20', '2099-03-12', 0;
/* approved while its type was paid; the type was made unpaid afterwards: still paid */
EXEC #qa3_05_leave @E, @Flip, '2099-03-24', '2099-03-25', NULL, 1;
UPDATE hr.LEAVE_TYPE SET IsPaid = 0 WHERE LeaveTypeId = @Flip;
/* approved while its type was unpaid (half a day); the type was made paid afterwards: still unpaid */
EXEC #qa3_05_leave @E, @Flip2, '2099-03-27', '2099-03-27', NULL, 0, 'AM';
UPDATE hr.LEAVE_TYPE SET IsPaid = 1 WHERE LeaveTypeId = @Flip2;
EXEC #qa3_05_run '2099-03', '2099-04-02', @Run OUTPUT;
SELECT @unpaidAmt = ISNULL(SUM(CASE WHEN c.SystemCode = 'UNPAID_LEAVE' THEN l.Amount END), 0),
       @shortAmt = ISNULL(SUM(CASE WHEN c.SystemCode = 'LATE' THEN l.Amount END), 0)
FROM payroll.PAYSLIP_LINE l JOIN payroll.PAYSLIP ps ON ps.PayslipId = l.PayslipId JOIN hr.COMPONENT_TYPE c ON c.ComponentTypeId = l.ComponentTypeId
WHERE ps.PayrollRunId = @Run AND ps.EmployeeId = @E;
SELECT @hdrUnpaid = UnpaidLeaveDays, @hdrPaid = PaidLeaveDays FROM payroll.PAYSLIP WHERE PayrollRunId = @Run AND EmployeeId = @E;
IF @unpaidAmt <> 250 OR @shortAmt <> 100 OR @hdrUnpaid <> 2.5 OR @hdrPaid <> 2
BEGIN
    SET @fails += 1;
    SET @x = CONCAT('unpaid leave ', @unpaidAmt, ' (expected 250), short days ', @shortAmt, ' (expected 100), header unpaid ', @hdrUnpaid, ' (2.5), paid ', @hdrPaid, ' (2)');
    RAISERROR('05 A: %s.', 16, 1, @x);
END
ROLLBACK TRAN;

/* ======== B. LEV-16 / LEV-13 / PAY-13: a tiered sick type (not named 'Sick'); hired 31 Dec 2097 = one whole year ======== */
BEGIN TRAN;
EXEC #qa3_05_emp N'QA3 Leila Sick', '2097-12-31', @E OUTPUT, @B OUTPUT;
INSERT INTO hr.LEAVE_TYPE (Name, IsPaid) VALUES (N'QA3 Illness', 1); SET @Sick = SCOPE_IDENTITY();
INSERT INTO hr.LEAVE_PAY_TIER (LeaveTypeId, MinServiceYears, FullPayDays, HalfPayDays) VALUES (@Sick, 0, 15, 15), (@Sick, 2, 30, 30);
/* days 1-20 (5-24 Jan): 16-20 at half pay = 2.5 days; days 21-32 (28 Jan - 8 Feb): 21-24 in January (half: 2 days),
   25-30 in February (half: 3 days) and 31-32 (beyond the tier: 2 days) */
EXEC #qa3_05_leave @E, @Sick, '2099-01-05', '2099-01-24', NULL, 1;
EXEC #qa3_05_leave @E, @Sick, '2099-01-28', '2099-02-08', NULL, 1;
EXEC #qa3_05_run '2099-01', '2099-02-15', @Jan OUTPUT;
EXEC #qa3_05_run '2099-02', '2099-03-02', @Feb OUTPUT;
SELECT @janAbs = ISNULL(SUM(CASE WHEN ps.PayrollRunId = @Jan THEN l.Amount END), 0), @febAbs = ISNULL(SUM(CASE WHEN ps.PayrollRunId = @Feb THEN l.Amount END), 0)
FROM payroll.PAYSLIP_LINE l JOIN payroll.PAYSLIP ps ON ps.PayslipId = l.PayslipId JOIN hr.COMPONENT_TYPE c ON c.ComponentTypeId = l.ComponentTypeId AND c.SystemCode = 'ABSENCE'
WHERE ps.EmployeeId = @E;
IF @janAbs <> 450 OR @febAbs <> 500
    BEGIN SET @fails += 1; SET @x = CONCAT('January ', @janAbs, ' (expected 450), February ', @febAbs, ' (expected 500)'); RAISERROR('05 B: sick pay tiers: %s.', 16, 1, @x); END
ROLLBACK TRAN;

IF @fails = 0 PRINT 'ok 05_leave_and_sick';
GO
DROP PROCEDURE #qa3_05_emp; DROP PROCEDURE #qa3_05_leave; DROP PROCEDURE #qa3_05_run;
