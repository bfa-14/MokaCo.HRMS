/* QA3 payroll (unit E) - the handoff 7.5 worked check, exact; a raise added without closing the old row (PAY-6 / REL-2);
   unpaid deductions capped at the basic (QA3 decision); the hour rate on StandardWorkDayHours (PAY-14); the branch of
   the period on the payslip (PAY-15).
   Runs on a dev database with docs/103_qa3_payroll.sql applied, inside a transaction that is rolled back; months of 2099,
   the procedures' clock injected; its own NSSF / tax / rate / settings so the figures do not depend on the database.
   sqlcmd -I -b -i tests/qa3/payroll/01_worked_check_and_salary.sql   ->  prints 'ok 01_worked_check_and_salary' */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
BEGIN TRAN;
DECLARE @fails INT = 0, @Hr INT, @Owner INT, @B INT, @B2 INT, @Basic INT, @Transport INT, @E1 INT, @E2 INT, @E3 INT, @E4 INT, @Run INT, @a DECIMAL(18,2), @x NVARCHAR(400);
DECLARE @g TABLE (PayrollRunId INT, PayslipCount INT, PayslipsWithWarnings INT);
DECLARE @c TABLE (PayrollRunId INT, PeriodYearMonth CHAR(7), [Status] VARCHAR(12), PrimaryCurrency CHAR(3), RunType VARCHAR(12));
/* ---- the configuration of the handoff's worked check, for 2099 only (rolled back) ---- */
SET @Hr = (SELECT TOP 1 UserId FROM security.[USER] u WHERE payroll.fn_UserHasRole(u.UserId, N'HR') = 1 OR payroll.fn_UserHasRole(u.UserId, N'Admin') = 1 ORDER BY UserId);
SET @Owner = (SELECT TOP 1 UserId FROM security.[USER] u WHERE payroll.fn_UserHasRole(u.UserId, N'Owner') = 1 ORDER BY UserId);
UPDATE core.SETTING SET SettingValue = v.V FROM core.SETTING s JOIN (VALUES ('StandardWorkingDaysPerMonth','26'), ('StandardWorkDayHours','8'), ('NssfCeilingUsd','2500'),
    ('TaxFamilyDeductionAnnualUsd','0'), ('PayrollPrimaryCurrency','USD'), ('PayrollRateType','QA3'), ('LeavePayoutOnTermination','1'), ('HolidayWorkRate','2.0')) v(K, V) ON v.K = s.SettingKey;
UPDATE hr.APPROVAL_TIER SET MinBasicSalary = NULL, MaxBasicSalary = NULL;
INSERT INTO core.EXCHANGE_RATE (FromCurrency, ToCurrency, RateType, EffectiveDate, Rate) VALUES ('USD', 'LBP', 'QA3', '2099-01-01', 90000);
UPDATE hr.NSSF_RATE SET EffectiveTo = '2098-12-31' WHERE EffectiveTo IS NULL OR EffectiveTo > '2098-12-31';
DECLARE @col SYSNAME = CASE WHEN COL_LENGTH('hr.NSSF_RATE', 'Scheme') IS NOT NULL THEN N'Scheme' ELSE N'SchemeName' END;
DECLARE @ins NVARCHAR(MAX) = N'INSERT INTO hr.NSSF_RATE (' + QUOTENAME(@col) + N', EmployeeRate, EmployerRate, IsCeilinged, CeilingAmount, EffectiveFrom) VALUES
    (N''QA3 Sickness'', 0.03, 0.08, 1, 2500, ''2099-01-01''), (N''QA3 Family'', 0, 0.06, 1, 2500, ''2099-01-01''), (N''QA3 End of service'', 0, 0.085, 0, NULL, ''2099-01-01'');';
EXEC sys.sp_executesql @ins;
INSERT INTO hr.TAX_BRACKET (MinAnnual, MaxAnnual, Rate, CurrencyCode, EffectiveFrom) VALUES (0, 6000, 0.02, 'USD', '2099-01-01'), (6000, 15000, 0.04, 'USD', '2099-01-01'),
    (15000, 30000, 0.07, 'USD', '2099-01-01'), (30000, 60000, 0.11, 'USD', '2099-01-01'), (60000, 120000, 0.15, 'USD', '2099-01-01'), (120000, NULL, 0.20, 'USD', '2099-01-01');
INSERT INTO hr.BRANCH (Name) VALUES (N'QA3 Pay Branch'); SET @B = SCOPE_IDENTITY();
INSERT INTO hr.BRANCH (Name) VALUES (N'QA3 Pay Branch Two'); SET @B2 = SCOPE_IDENTITY();
SET @Basic = (SELECT ComponentTypeId FROM hr.COMPONENT_TYPE WHERE SystemCode = 'BASIC');
INSERT INTO hr.COMPONENT_TYPE (Name, Category, [Sign], IsStanding, IsBasicSalary, IsActive) VALUES (N'QA3 Transport', 'Earning', 1, 1, 0, 1); SET @Transport = SCOPE_IDENTITY();
INSERT INTO hr.EMPLOYEE (BranchId, DepartmentId, PositionId, FullName, HireDate)
SELECT @B, (SELECT TOP 1 DepartmentId FROM hr.DEPARTMENT ORDER BY DepartmentId), (SELECT TOP 1 PositionId FROM hr.POSITION ORDER BY PositionId), v.N, '2020-01-01'
FROM (VALUES (N'QA3 Worked check'), (N'QA3 Raise'), (N'QA3 Unpaid month'), (N'QA3 Moved')) v(N);
SELECT @E1 = MAX(CASE WHEN FullName = N'QA3 Worked check' THEN EmployeeId END), @E2 = MAX(CASE WHEN FullName = N'QA3 Raise' THEN EmployeeId END),
       @E3 = MAX(CASE WHEN FullName = N'QA3 Unpaid month' THEN EmployeeId END), @E4 = MAX(CASE WHEN FullName = N'QA3 Moved' THEN EmployeeId END)
FROM hr.EMPLOYEE WHERE FullName LIKE N'QA3 %' AND BranchId = @B;
INSERT INTO hr.EMPLOYEE_BRANCH_HISTORY (EmployeeId, BranchId, EffectiveFrom)
SELECT e.EmployeeId, @B, '2020-01-01' FROM hr.EMPLOYEE e WHERE e.EmployeeId IN (@E1, @E2, @E3, @E4)
  AND NOT EXISTS (SELECT 1 FROM hr.EMPLOYEE_BRANCH_HISTORY h WHERE h.EmployeeId = e.EmployeeId);
INSERT INTO hr.EMPLOYEE_BRANCH_HISTORY (EmployeeId, BranchId, EffectiveFrom) VALUES (@E4, @B2, '2099-03-20');   -- moved on the 20th
INSERT INTO hr.SALARY_COMPONENT (EmployeeId, ComponentTypeId, Amount, CurrencyCode, EffectiveFrom) VALUES
    (@E1, @Basic, 3500, 'USD', '2020-01-01'), (@E1, @Transport, 6000000, 'LBP', '2020-01-01'),
    (@E2, @Basic, 1500, 'USD', '2020-01-01'),
    (@E2, @Basic, 1800, 'USD', '2099-03-16'),            -- the raise, added the old raw way: the 1500 row was never closed
    (@E3, @Basic, 2600, 'USD', '2020-01-01'), (@E4, @Basic, 2080, 'USD', '2020-01-01');
/* E3 takes the whole of March unpaid: with no roster every one of the 31 days counts - 31 x 100 = 3100 against a 2600 basic */
DECLARE @RT INT, @WD INT, @Ri INT, @Unpaid INT;
SELECT TOP 1 @WD = WorkflowDefinitionId, @RT = RequestTypeId FROM workflow.WORKFLOW_DEFINITION ORDER BY WorkflowDefinitionId;
INSERT INTO hr.LEAVE_TYPE (Name, IsPaid) VALUES (N'QA3 Unpaid', 0); SET @Unpaid = SCOPE_IDENTITY();
INSERT INTO workflow.REQUEST_INSTANCE (RequestTypeId, WorkflowDefinitionId, EmployeeId, RaisedByUserId, [Status], Title) VALUES (@RT, @WD, @E3, @Hr, 'Approved', N'QA3 unpaid month');
SET @Ri = SCOPE_IDENTITY();
INSERT INTO workflow.LEAVE_REQUEST (RequestInstanceId, EmployeeId, LeaveTypeId, FromDate, ToDate, DaysRequested, DaysApproved, ApprovedToDate, PaidSnapshot)
VALUES (@Ri, @E3, @Unpaid, '2099-03-01', '2099-03-31', 31, 31, '2099-03-31', 0);
/* E4 works 120 approved overtime minutes on the 10th */
INSERT INTO workflow.REQUEST_INSTANCE (RequestTypeId, WorkflowDefinitionId, EmployeeId, RaisedByUserId, [Status], Title) VALUES (@RT, @WD, @E4, @Hr, 'Approved', N'QA3 overtime');
SET @Ri = SCOPE_IDENTITY();
INSERT INTO workflow.OVERTIME_REQUEST (RequestInstanceId, EmployeeId, WorkDate, RequestedMinutes, ApprovedMinutes, RateMultiplier) VALUES (@Ri, @E4, '2099-03-10', 120, 120, 1.5);
INSERT INTO attendance.ATTENDANCE_RECORD (EmployeeId, WorkDate, [Status], DayFraction, StandardMinutes, WorkedMinutes, OvertimeMinutes, [Source])
VALUES (@E4, '2099-03-10', 'Present', 1, 480, 600, 120, 'Manual');
UPDATE core.SETTING SET SettingValue = '10' WHERE SettingKey = 'StandardWorkDayHours';        -- PAY-14: the hour rate follows this key

/* ---- the run ---- */
INSERT INTO @c EXEC payroll.usp_PayrollRun_Create @PeriodYearMonth = '2099-03', @CreatedByUserId = @Hr, @Notes = N'QA3 payroll 01', @AsOfDate = '2099-04-02';
SET @Run = (SELECT PayrollRunId FROM @c);
INSERT INTO @g EXEC payroll.usp_PayrollRun_Generate @PayrollRunId = @Run, @ActedByUserId = @Hr, @AsOfDate = '2099-04-02';

/* the worked check (handoff 7.5): base 3566.67; employee NSSF 75.00; employer 2500 x 14 % + base x 8.5 % = 653.17;
   tax ((3566.67 - 75) x 12 = 41900.04 -> 120 + 360 + 1050 + 1309.00) / 12 = 236.58; net 3188.42 USD + 6,000,000 LBP */
SELECT @x = CONCAT('NSSF ', SUM(CASE WHEN c.SystemCode = 'NSSF_EMPLOYEE' THEN l.Amount END), ' / employer ', SUM(CASE WHEN c.SystemCode = 'NSSF_EMPLOYER' THEN l.Amount END),
                   ' / tax ', SUM(CASE WHEN c.SystemCode = 'INCOME_TAX' THEN l.Amount END), ' / net ', MAX(ps.NetUsd), ' USD + ', MAX(ps.NetLbp), ' LBP / comparable ', MAX(ps.NetPrimary))
FROM payroll.PAYSLIP ps JOIN payroll.PAYSLIP_LINE l ON l.PayslipId = ps.PayslipId LEFT JOIN hr.COMPONENT_TYPE c ON c.ComponentTypeId = l.ComponentTypeId
WHERE ps.PayrollRunId = @Run AND ps.EmployeeId = @E1;
IF @x <> 'NSSF 75.00 / employer 653.17 / tax 236.58 / net 3188.42 USD + 6000000.00 LBP / comparable 3255.09'
    BEGIN SET @fails += 1; RAISERROR('01: the worked check moved: %s', 16, 1, @x); END

/* PAY-6: 1500 x 15/31 + 1800 x 16/31, never both in full */
SET @a = (SELECT SUM(l.Amount) FROM payroll.PAYSLIP ps JOIN payroll.PAYSLIP_LINE l ON l.PayslipId = ps.PayslipId WHERE ps.PayrollRunId = @Run AND ps.EmployeeId = @E2 AND l.SourceType = 'Salary');
IF @a <> ROUND(1500.0 * 15 / 31, 2) + ROUND(1800.0 * 16 / 31, 2)
    BEGIN SET @x = CAST(@a AS NVARCHAR(30)); SET @fails += 1; RAISERROR('01: the raise from the 16th paid %s, not 725.81 + 929.03.', 16, 1, @x); END

/* the cap: 31 unpaid working days x 100 = 3100 would exceed the 2600 basic - the deduction stops at the basic, net 0 */
SELECT @a = SUM(l.Amount), @x = MAX(l.Note) FROM payroll.PAYSLIP ps JOIN payroll.PAYSLIP_LINE l ON l.PayslipId = ps.PayslipId
WHERE ps.PayrollRunId = @Run AND ps.EmployeeId = @E3 AND l.SourceType = 'Leave';
IF @a <> 2600 OR @x NOT LIKE N'%capped%' OR (SELECT NetUsd FROM payroll.PAYSLIP WHERE PayrollRunId = @Run AND EmployeeId = @E3) <> 0
    BEGIN SET @x = CONCAT(@a, ' ', @x); SET @fails += 1; RAISERROR('01: the unpaid month was not capped at the basic: %s', 16, 1, @x); END

/* PAY-14: hour rate = 2080 / 26 / 10 (StandardWorkDayHours) = 8.00; 120 min x 1.5 = 24.00. PAY-15: the branch on the 31st */
SET @a = (SELECT SUM(l.Amount) FROM payroll.PAYSLIP ps JOIN payroll.PAYSLIP_LINE l ON l.PayslipId = ps.PayslipId WHERE ps.PayrollRunId = @Run AND ps.EmployeeId = @E4 AND l.SourceType = 'Overtime');
IF @a <> 24.00 BEGIN SET @x = CAST(@a AS NVARCHAR(30)); SET @fails += 1; RAISERROR('01: overtime paid %s, not 24.00 at StandardWorkDayHours 10.', 16, 1, @x); END
IF (SELECT BranchName FROM payroll.PAYSLIP WHERE PayrollRunId = @Run AND EmployeeId = @E4) <> N'QA3 Pay Branch Two'
    BEGIN SET @fails += 1; RAISERROR('01: the payslip does not carry the branch of the period.', 16, 1); END

ROLLBACK TRAN;
IF @fails = 0 PRINT 'ok 01_worked_check_and_salary';
