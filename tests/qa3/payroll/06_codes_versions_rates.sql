/* QA3 payroll (unit E) - configuration payroll depends on:
   PAY-10 / REL-7  payroll finds its component types by SYSTEM CODE (a renamed basic still pays); a system type cannot be
           renamed, deactivated or deleted through the procedures; Generate refuses when a system type is missing;
   PAY-9   one NSSF / tax version per scheme per month - the one in force at the period end; a new version closes the
           previous one the day before it starts; an earlier one is refused;
   item 2 / CON-9  a rate of 1/89,500 survives the column and the procedure; zero and a second rate for the same day are
           refused; REL-11 a Draft run re-reads the rates as of the period end at every Generate, a Review run keeps its
           snapshot, a currency with no rate on file is refused (never converted to NULL);
   suspicions  tips are one line per distribution (SourceId = that distribution); an unpaid public holiday costs a day only
           in an APPROVED roster month; (script 100's precedence) a public holiday on a rest day that is worked earns the
           holiday premium and an unpaid one on a rest day is never deducted;
   PAY-12  PAYROLL_VIEW / REPORT_VIEW are held by every role holding PAYROLL_RUN or PAYROLL_APPROVE / ATTENDANCE_VIEW.
   Runs on a dev database with docs/103_qa3_payroll.sql applied, in transactions that are rolled back.
   sqlcmd -I -b -i tests/qa3/payroll/06_codes_versions_rates.sql   ->  prints 'ok 06_codes_versions_rates' */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
GO
CREATE PROCEDURE #qa3_06_emp @Name NVARCHAR(100), @B INT, @Basic DECIMAL(18,2), @E INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @BasicType INT = (SELECT ComponentTypeId FROM hr.COMPONENT_TYPE WHERE SystemCode = 'BASIC');
    UPDATE core.SETTING SET SettingValue = v.V FROM core.SETTING s JOIN (VALUES ('StandardWorkingDaysPerMonth','26'), ('StandardWorkDayHours','8'),
        ('TaxFamilyDeductionAnnualUsd','0'), ('PayrollPrimaryCurrency','USD'), ('HolidayWorkRate','2.0')) v(K, V) ON v.K = s.SettingKey;
    UPDATE hr.APPROVAL_TIER SET MinBasicSalary = NULL, MaxBasicSalary = NULL;
    INSERT INTO hr.EMPLOYEE (BranchId, DepartmentId, PositionId, FullName, HireDate)
    VALUES (@B, (SELECT TOP 1 DepartmentId FROM hr.DEPARTMENT ORDER BY DepartmentId), (SELECT TOP 1 PositionId FROM hr.POSITION ORDER BY PositionId), @Name, '2024-01-01');
    SET @E = SCOPE_IDENTITY();
    IF NOT EXISTS (SELECT 1 FROM hr.EMPLOYEE_BRANCH_HISTORY WHERE EmployeeId = @E) INSERT INTO hr.EMPLOYEE_BRANCH_HISTORY (EmployeeId, BranchId, EffectiveFrom) VALUES (@E, @B, '2024-01-01');
    INSERT INTO hr.SALARY_COMPONENT (EmployeeId, ComponentTypeId, Amount, CurrencyCode, EffectiveFrom) VALUES (@E, @BasicType, @Basic, 'USD', '2024-01-01');
END
GO
DECLARE @fails INT = 0, @Hr INT, @B INT, @B2 INT, @E INT, @E2 INT, @Run INT, @Rid INT, @Ot INT, @Basic INT, @Tips INT, @Transport INT, @RT INT, @WD INT, @Ri INT, @Td1 INT, @Td2 INT,
        @msg NVARCHAR(2048), @msg2 NVARCHAR(2048), @msg3 NVARCHAR(2048), @x NVARCHAR(400), @a DECIMAL(18,2), @n INT, @rate DECIMAL(28,12);
DECLARE @g TABLE (PayrollRunId INT, PayslipCount INT, PayslipsWithWarnings INT);
DECLARE @c TABLE (PayrollRunId INT, PeriodYearMonth CHAR(7), [Status] VARCHAR(12), PrimaryCurrency CHAR(3), RunType VARCHAR(12));
DECLARE @id TABLE (Id INT);
SET @Hr = (SELECT TOP 1 UserId FROM security.[USER] u WHERE payroll.fn_UserHasRole(u.UserId, N'HR') = 1 OR payroll.fn_UserHasRole(u.UserId, N'Admin') = 1 ORDER BY UserId);
SELECT TOP 1 @WD = WorkflowDefinitionId, @RT = RequestTypeId FROM workflow.WORKFLOW_DEFINITION ORDER BY WorkflowDefinitionId;
DECLARE @col SYSNAME = CASE WHEN COL_LENGTH('hr.NSSF_RATE', 'Scheme') IS NOT NULL THEN N'Scheme' ELSE N'SchemeName' END, @sql NVARCHAR(MAX);

/* ======== A. PAY-10: the codes ======== */
BEGIN TRAN;
INSERT INTO hr.BRANCH (Name) VALUES (N'QA3 Pay Codes'); SET @B = SCOPE_IDENTITY();
EXEC #qa3_06_emp N'QA3 Nour Codes', @B, 2600, @E OUTPUT;
SELECT @Ot = MAX(CASE WHEN SystemCode = 'OVERTIME' THEN ComponentTypeId END), @Basic = MAX(CASE WHEN SystemCode = 'BASIC' THEN ComponentTypeId END)
FROM hr.COMPONENT_TYPE;
SELECT @msg = NULL, @msg2 = NULL, @msg3 = NULL;
BEGIN TRY EXEC hr.usp_ComponentType_Update @ComponentTypeId = @Ot, @Name = N'Overtime pay', @Category = 'Earning', @Sign = 1; END TRY BEGIN CATCH SET @msg = ERROR_MESSAGE(); END CATCH;
BEGIN TRY EXEC hr.usp_ComponentType_SetActive @ComponentTypeId = @Ot, @IsActive = 0; END TRY BEGIN CATCH SET @msg2 = ERROR_MESSAGE(); END CATCH;
BEGIN TRY EXEC hr.usp_ComponentType_Delete @ComponentTypeId = @Ot; END TRY BEGIN CATCH SET @msg3 = ERROR_MESSAGE(); END CATCH;
IF @msg NOT LIKE N'%is a system component type%renamed%' OR @msg2 NOT LIKE N'%cannot be deactivated%' OR @msg3 NOT LIKE N'%cannot be deleted%'
   OR @msg IS NULL OR @msg2 IS NULL OR @msg3 IS NULL OR NOT EXISTS (SELECT 1 FROM hr.COMPONENT_TYPE WHERE ComponentTypeId = @Ot AND IsActive = 1)
    BEGIN SET @fails += 1; RAISERROR('06 A: a system type was renamed, deactivated or deleted (%s | %s | %s).', 16, 1, @msg, @msg2, @msg3); END
/* renamed behind the procedures' back: payroll still finds the basic by its code */
UPDATE hr.COMPONENT_TYPE SET Name = N'QA3 Monthly salary' WHERE ComponentTypeId = @Basic;
INSERT INTO @c EXEC payroll.usp_PayrollRun_Create @PeriodYearMonth = '2099-03', @CreatedByUserId = @Hr, @Notes = N'QA3 payroll 06', @AsOfDate = '2099-04-02';
SET @Run = (SELECT PayrollRunId FROM @c); DELETE FROM @c;
INSERT INTO @g EXEC payroll.usp_PayrollRun_Generate @PayrollRunId = @Run, @ActedByUserId = @Hr, @AsOfDate = '2099-04-02';
IF NOT EXISTS (SELECT 1 FROM payroll.PAYSLIP_LINE l JOIN payroll.PAYSLIP ps ON ps.PayslipId = l.PayslipId
               WHERE ps.PayrollRunId = @Run AND ps.EmployeeId = @E AND l.ComponentTypeId = @Basic AND l.Amount = 2600 AND l.ComponentName = N'QA3 Monthly salary')
    BEGIN SET @fails += 1; RAISERROR('06 A: the renamed basic was not paid.', 16, 1); END
/* a system type that lost its code: Generate refuses (LAST: the refusal leaves the transaction uncommittable) */
UPDATE hr.COMPONENT_TYPE SET SystemCode = NULL WHERE SystemCode = 'TIPS';
SET @msg = NULL;
BEGIN TRY EXEC payroll.usp_PayrollRun_Generate @PayrollRunId = @Run, @ActedByUserId = @Hr, @AsOfDate = '2099-04-02'; END TRY BEGIN CATCH SET @msg = ERROR_MESSAGE(); END CATCH;
IF @msg IS NULL OR @msg NOT LIKE N'%TIPS%'
    BEGIN SET @fails += 1; RAISERROR('06 A: Generate ran without the TIPS type (%s).', 16, 1, @msg); END
ROLLBACK TRAN;

/* ======== B. PAY-9: NSSF 3 % from January, 4 % from 16 March; tax 5 % from January, 10 % from 16 March ======== */
BEGIN TRAN;
INSERT INTO hr.BRANCH (Name) VALUES (N'QA3 Pay Versions'); SET @B = SCOPE_IDENTITY();
EXEC #qa3_06_emp N'QA3 Nour Versions', @B, 4000, @E OUTPUT;
UPDATE hr.NSSF_RATE SET EffectiveTo = '2098-12-31' WHERE EffectiveTo IS NULL OR EffectiveTo > '2098-12-31';
UPDATE hr.TAX_BRACKET SET EffectiveTo = '2098-12-31' WHERE EffectiveTo IS NULL OR EffectiveTo > '2098-12-31';
SET @sql = N'INSERT INTO hr.NSSF_RATE (' + QUOTENAME(@col) + N', EmployeeRate, EmployerRate, IsCeilinged, CeilingAmount, EffectiveFrom) VALUES (N''QA3 scheme'', 0.03, 0.08, 1, 2500, ''2099-01-01'');';
EXEC sys.sp_executesql @sql;
SET @sql = N'INSERT INTO hr.NSSF_RATE (' + QUOTENAME(@col) + N', EmployeeRate, EmployerRate, IsCeilinged, CeilingAmount, EffectiveFrom) VALUES (N''QA3 scheme'', 0.04, 0.08, 1, 2500, ''2099-03-16'');';
EXEC sys.sp_executesql @sql;
INSERT INTO hr.TAX_BRACKET (MinAnnual, MaxAnnual, Rate, CurrencyCode, EffectiveFrom) VALUES (0, NULL, 0.05, 'USD', '2099-01-01');
INSERT INTO hr.TAX_BRACKET (MinAnnual, MaxAnnual, Rate, CurrencyCode, EffectiveFrom) VALUES (0, NULL, 0.10, 'USD', '2099-03-16');
SET @sql = N'SELECT @d = MAX(CASE WHEN EmployeeRate = 0.03 THEN EffectiveTo END) FROM hr.NSSF_RATE WHERE ' + QUOTENAME(@col) + N' = N''QA3 scheme'';';
DECLARE @nssfTo DATE; EXEC sys.sp_executesql @sql, N'@d DATE OUTPUT', @d = @nssfTo OUTPUT;
IF @nssfTo <> '2099-03-15' OR (SELECT EffectiveTo FROM hr.TAX_BRACKET WHERE EffectiveFrom = '2099-01-01' AND Rate = 0.05) <> '2099-03-15'
    BEGIN SET @fails += 1; RAISERROR('06 B: a new version did not close the previous one the day before it starts.', 16, 1); END
INSERT INTO @c EXEC payroll.usp_PayrollRun_Create @PeriodYearMonth = '2099-03', @CreatedByUserId = @Hr, @Notes = N'QA3 payroll 06', @AsOfDate = '2099-04-02';
SET @Run = (SELECT PayrollRunId FROM @c); DELETE FROM @c;
INSERT INTO @g EXEC payroll.usp_PayrollRun_Generate @PayrollRunId = @Run, @ActedByUserId = @Hr, @AsOfDate = '2099-04-02';
/* March: the versions in force on the 31st only - NSSF 4 % x 2500 = 100.00 (one line), tax 10 % x (4000 - 100) = 390.00 */
SELECT @x = CONCAT('NSSF ', SUM(CASE WHEN c.SystemCode = 'NSSF_EMPLOYEE' THEN l.Amount END), ' in ', SUM(CASE WHEN c.SystemCode = 'NSSF_EMPLOYEE' THEN 1 END),
                   ' line(s), tax ', SUM(CASE WHEN c.SystemCode = 'INCOME_TAX' THEN l.Amount END), ' in ', SUM(CASE WHEN c.SystemCode = 'INCOME_TAX' THEN 1 END), ' line(s)')
FROM payroll.PAYSLIP_LINE l JOIN payroll.PAYSLIP ps ON ps.PayslipId = l.PayslipId JOIN hr.COMPONENT_TYPE c ON c.ComponentTypeId = l.ComponentTypeId
WHERE ps.PayrollRunId = @Run AND ps.EmployeeId = @E;
IF @x <> 'NSSF 100.00 in 1 line(s), tax 390.00 in 1 line(s)'
    BEGIN SET @fails += 1; RAISERROR('06 B: March did not use the versions in force on the 31st only: %s.', 16, 1, @x); END
/* an older version is refused (LAST: a trigger's refusal leaves the transaction uncommittable) */
SELECT @msg = NULL, @msg2 = NULL;
SET @sql = N'INSERT INTO hr.NSSF_RATE (' + QUOTENAME(@col) + N', EmployeeRate, EmployerRate, IsCeilinged, CeilingAmount, EffectiveFrom) VALUES (N''QA3 scheme'', 0.02, 0.08, 1, 2500, ''2099-02-01'');';
BEGIN TRY EXEC sys.sp_executesql @sql; END TRY BEGIN CATCH SET @msg = ERROR_MESSAGE(); END CATCH;
IF @msg IS NULL OR @msg NOT LIKE N'%A new version must start after the latest one%'
    BEGIN SET @fails += 1; RAISERROR('06 B: an NSSF version older than the latest was accepted (%s).', 16, 1, @msg); END
IF @@TRANCOUNT > 0 ROLLBACK TRAN;

/* ======== C. item 2 / CON-9 / REL-11: rates ======== */
BEGIN TRAN;
UPDATE core.SETTING SET SettingValue = 'QA3R' WHERE SettingKey = 'PayrollRateType';
INSERT INTO @id EXEC core.usp_ExchangeRate_Add @FromCurrency = 'LBP', @ToCurrency = 'USD', @RateType = 'QA3R', @EffectiveDate = '2099-01-01', @Rate = 0.000011173184357542;
SET @Rid = (SELECT Id FROM @id); DELETE FROM @id;
IF (SELECT Rate FROM core.EXCHANGE_RATE WHERE ExchangeRateId = @Rid) <> 0.000011173184
    BEGIN SET @fails += 1; RAISERROR('06 C: 1/89,500 did not survive.', 16, 1); END
SELECT @msg = NULL, @msg2 = NULL;
BEGIN TRY EXEC core.usp_ExchangeRate_Add @FromCurrency = 'LBP', @ToCurrency = 'USD', @RateType = 'QA3R', @EffectiveDate = '2099-01-01', @Rate = 0.00001; END TRY BEGIN CATCH SET @msg = ERROR_MESSAGE(); END CATCH;
BEGIN TRY EXEC core.usp_ExchangeRate_Add @FromCurrency = 'LBP', @ToCurrency = 'USD', @RateType = 'QA3R', @EffectiveDate = '2099-02-01', @Rate = 0; END TRY BEGIN CATCH SET @msg2 = ERROR_MESSAGE(); END CATCH;
IF @msg IS NULL OR @msg NOT LIKE N'%already exists. Edit that rate instead%' OR @msg2 IS NULL OR @msg2 NOT LIKE N'%above zero%'
    BEGIN SET @fails += 1; RAISERROR('06 C: a second rate for the day or a zero rate was accepted (%s | %s).', 16, 1, @msg, @msg2); END
INSERT INTO hr.BRANCH (Name) VALUES (N'QA3 Pay Rates'); SET @B = SCOPE_IDENTITY();
EXEC #qa3_06_emp N'QA3 Nour Rates', @B, 1300, @E OUTPUT;
INSERT INTO hr.COMPONENT_TYPE (Name, Category, [Sign], IsStanding, IsBasicSalary, IsActive) VALUES (N'QA3 Transport', 'Earning', 1, 1, 0, 1); SET @Transport = SCOPE_IDENTITY();
INSERT INTO hr.SALARY_COMPONENT (EmployeeId, ComponentTypeId, Amount, CurrencyCode, EffectiveFrom) VALUES (@E, @Transport, 6000000, 'LBP', '2024-01-01');
INSERT INTO @c EXEC payroll.usp_PayrollRun_Create @PeriodYearMonth = '2099-03', @CreatedByUserId = @Hr, @Notes = N'QA3 payroll 06', @AsOfDate = '2099-03-05';
SET @Run = (SELECT PayrollRunId FROM @c); DELETE FROM @c;
INSERT INTO @g EXEC payroll.usp_PayrollRun_Generate @PayrollRunId = @Run, @ActedByUserId = @Hr, @AsOfDate = '2099-04-02';
SET @a = payroll.fn_ToPrimary(@Run, 6000000, 'LBP');
IF @a <> 67.04 BEGIN SET @fails += 1; SET @x = CAST(@a AS NVARCHAR(30)); RAISERROR('06 C: 6,000,000 LBP at 1/89,500 is %s, not 67.04.', 16, 1, @x); END
/* a new rate published for the 31st after the run was created: a Draft run re-reads it at Generate */
INSERT INTO @id EXEC core.usp_ExchangeRate_Add @FromCurrency = 'LBP', @ToCurrency = 'USD', @RateType = 'QA3R', @EffectiveDate = '2099-03-31', @Rate = 0.00001;
SET @Rid = (SELECT Id FROM @id); DELETE FROM @id;
INSERT INTO @g EXEC payroll.usp_PayrollRun_Generate @PayrollRunId = @Run, @ActedByUserId = @Hr, @AsOfDate = '2099-04-02';
SET @a = payroll.fn_ToPrimary(@Run, 6000000, 'LBP');
IF @a <> 60.00 BEGIN SET @fails += 1; SET @x = CAST(@a AS NVARCHAR(30)); RAISERROR('06 C: the Draft run did not re-read the rate of the 31st (%s, not 60.00).', 16, 1, @x); END
/* in Review the snapshot is frozen: a corrected figure does not move it */
UPDATE payroll.PAYROLL_RUN SET [Status] = 'Review' WHERE PayrollRunId = @Run;
DECLARE @set TABLE (ExchangeRateId INT, FromCurrency CHAR(3), ToCurrency CHAR(3), RateType VARCHAR(20), EffectiveDate DATE, Rate DECIMAL(28,12));
INSERT INTO @set EXEC core.usp_ExchangeRate_SetRate @ExchangeRateId = @Rid, @Rate = 0.00002;
INSERT INTO @g EXEC payroll.usp_PayrollRun_Generate @PayrollRunId = @Run, @ActedByUserId = @Hr, @AsOfDate = '2099-04-02';
SET @a = payroll.fn_ToPrimary(@Run, 6000000, 'LBP');
IF @a <> 60.00 BEGIN SET @fails += 1; SET @x = CAST(@a AS NVARCHAR(30)); RAISERROR('06 C: the Review run''s rates moved (%s, not 60.00).', 16, 1, @x); END
/* back to Draft with no LBP rate on file any more: Generate refuses (LAST: it rolls the whole transaction back) */
UPDATE payroll.PAYROLL_RUN SET [Status] = 'Draft' WHERE PayrollRunId = @Run;
DELETE FROM core.EXCHANGE_RATE WHERE RateType = 'QA3R';
SET @msg = NULL;
BEGIN TRY EXEC payroll.usp_PayrollRun_Generate @PayrollRunId = @Run, @ActedByUserId = @Hr, @AsOfDate = '2099-04-02'; END TRY BEGIN CATCH SET @msg = ERROR_MESSAGE(); END CATCH;
IF @msg IS NULL OR @msg NOT LIKE N'No LBP rate of type QA3R is on file for 2099-03 (on or before 2099-03-31)%'
    BEGIN SET @fails += 1; RAISERROR('06 C: a currency with no rate was not refused (%s).', 16, 1, @msg); END
IF @@TRANCOUNT > 0 ROLLBACK TRAN;

/* ======== D. tips per distribution; unpaid holidays; holiday on a rest day; permissions ======== */
BEGIN TRAN;
INSERT INTO hr.BRANCH (Name) VALUES (N'QA3 Pay Draft roster'); SET @B = SCOPE_IDENTITY();
INSERT INTO hr.BRANCH (Name) VALUES (N'QA3 Pay Approved roster'); SET @B2 = SCOPE_IDENTITY();
EXEC #qa3_06_emp N'QA3 Nour Draft', @B, 2600, @E OUTPUT;
EXEC #qa3_06_emp N'QA3 Nour Approved', @B2, 2600, @E2 OUTPUT;
/* two finalized tip distributions in March */
INSERT INTO workflow.REQUEST_INSTANCE (RequestTypeId, WorkflowDefinitionId, EmployeeId, RaisedByUserId, [Status], Title) VALUES (@RT, @WD, @E, @Hr, 'Approved', N'QA3 tips 5th');
SET @Ri = SCOPE_IDENTITY();
INSERT INTO workflow.TIP_DISTRIBUTION (RequestInstanceId, BranchId, ShiftDate, FinalizedAt) VALUES (@Ri, @B, '2099-03-05', SYSUTCDATETIME()); SET @Td1 = SCOPE_IDENTITY();
INSERT INTO workflow.REQUEST_INSTANCE (RequestTypeId, WorkflowDefinitionId, EmployeeId, RaisedByUserId, [Status], Title) VALUES (@RT, @WD, @E, @Hr, 'Approved', N'QA3 tips 20th');
SET @Ri = SCOPE_IDENTITY();
INSERT INTO workflow.TIP_DISTRIBUTION (RequestInstanceId, BranchId, ShiftDate, FinalizedAt) VALUES (@Ri, @B, '2099-03-20', SYSUTCDATETIME()); SET @Td2 = SCOPE_IDENTITY();
INSERT INTO workflow.TIP_DISTRIBUTION_LINE (TipDistributionId, EmployeeId, CurrencyCode, Amount) VALUES (@Td1, @E, 'USD', 50), (@Td2, @E, 'USD', 70);
/* an unpaid public holiday on Tuesday 10 March, both rostered to work it; a paid one on 17 March, @E2's rest day, worked */
INSERT INTO core.HOLIDAY (HolidayDate, Name, IsPaid) VALUES ('2099-03-10', N'QA3 unpaid holiday', 0), ('2099-03-17', N'QA3 paid holiday', 1);
INSERT INTO attendance.SHIFT_ASSIGNMENT (EmployeeId, ShiftId, WorkDate, IsRestDay)
VALUES (@E, (SELECT MIN(ShiftId) FROM attendance.SHIFT), '2099-03-10', 0), (@E2, (SELECT MIN(ShiftId) FROM attendance.SHIFT), '2099-03-10', 0), (@E2, NULL, '2099-03-17', 1);
INSERT INTO attendance.ROSTER_MONTH (BranchId, MonthDate, [Status]) VALUES (@B, '2099-03-01', 'Draft');
INSERT INTO attendance.ROSTER_MONTH (BranchId, MonthDate, [Status], ApprovedAt) VALUES (@B2, '2099-03-01', 'Approved', SYSUTCDATETIME());
INSERT INTO attendance.ATTENDANCE_RECORD (EmployeeId, WorkDate, [Status], DayFraction, StandardMinutes, WorkedMinutes, [Source])
VALUES (@E2, '2099-03-10', 'Holiday', 1, 480, 0, 'Device'), (@E2, '2099-03-17', 'Holiday', 1, 0, 240, 'Device');
INSERT INTO @c EXEC payroll.usp_PayrollRun_Create @PeriodYearMonth = '2099-03', @CreatedByUserId = @Hr, @Notes = N'QA3 payroll 06', @AsOfDate = '2099-04-02';
SET @Run = (SELECT PayrollRunId FROM @c); DELETE FROM @c;
INSERT INTO @g EXEC payroll.usp_PayrollRun_Generate @PayrollRunId = @Run, @ActedByUserId = @Hr, @AsOfDate = '2099-04-02';
SELECT @x = STRING_AGG(CONCAT(l.SourceId, ':', l.Amount, ':', l.Note), '|') WITHIN GROUP (ORDER BY l.SourceId)
FROM payroll.PAYSLIP_LINE l JOIN payroll.PAYSLIP ps ON ps.PayslipId = l.PayslipId
WHERE ps.PayrollRunId = @Run AND ps.EmployeeId = @E AND l.SourceType = 'Tip';
IF @x <> CONCAT(@Td1, ':50.00:Tips of 2099-03-05|', @Td2, ':70.00:Tips of 2099-03-20')
    BEGIN SET @fails += 1; RAISERROR('06 D: tips are not one line per distribution (%s).', 16, 1, @x); END
/* the unpaid holiday costs a day in the approved roster month only (100.00); the paid holiday worked on a rest day earns
   240 / 480 x 100 x (2.0 - 1) = 50.00 */
SELECT @x = CONCAT('draft ', ISNULL(SUM(CASE WHEN ps.EmployeeId = @E AND c.SystemCode = 'ABSENCE' THEN l.Amount END), 0),
                   ', approved ', ISNULL(SUM(CASE WHEN ps.EmployeeId = @E2 AND c.SystemCode = 'ABSENCE' THEN l.Amount END), 0),
                   ', holiday work ', ISNULL(SUM(CASE WHEN ps.EmployeeId = @E2 AND c.SystemCode = 'HOLIDAY_WORK' THEN l.Amount END), 0))
FROM payroll.PAYSLIP_LINE l JOIN payroll.PAYSLIP ps ON ps.PayslipId = l.PayslipId JOIN hr.COMPONENT_TYPE c ON c.ComponentTypeId = l.ComponentTypeId
WHERE ps.PayrollRunId = @Run;
IF @x <> 'draft 0.00, approved 100.00, holiday work 50.00'
    BEGIN SET @fails += 1; RAISERROR('06 D: holidays: %s.', 16, 1, @x); END
/* PAY-12: the seeded permissions */
SET @n = (SELECT COUNT(DISTINCT rp.RoleId) FROM security.ROLE_PERMISSION rp JOIN security.PERMISSION p ON p.PermissionId = rp.PermissionId
          WHERE (p.Code IN ('PAYROLL_RUN', 'PAYROLL_APPROVE')
                 AND NOT EXISTS (SELECT 1 FROM security.ROLE_PERMISSION x JOIN security.PERMISSION px ON px.PermissionId = x.PermissionId
                                 WHERE x.RoleId = rp.RoleId AND px.Code = 'PAYROLL_VIEW'))
             OR (p.Code = 'ATTENDANCE_VIEW'
                 AND NOT EXISTS (SELECT 1 FROM security.ROLE_PERMISSION x JOIN security.PERMISSION px ON px.PermissionId = x.PermissionId
                                 WHERE x.RoleId = rp.RoleId AND px.Code = 'REPORT_VIEW')));
IF @n <> 0 BEGIN SET @fails += 1; RAISERROR('06 D: %d role(s) can run payroll or see attendance without PAYROLL_VIEW / REPORT_VIEW.', 16, 1, @n); END
ROLLBACK TRAN;

IF @fails = 0 PRINT 'ok 06_codes_versions_rates';
GO
DROP PROCEDURE #qa3_06_emp;
