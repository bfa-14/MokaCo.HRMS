/* QA3 payroll (unit E) - what is settled when someone leaves, and that it is settled ONCE:
   PAY-2   a separation prepared after the leaving month was locked is paid by the next open primary (a settlement-only
           payslip), stamped with the payslip that paid it (SEPARATION.PaidInPayslipId) and never paid again;
   LEV-8 / REL-14  the leave balance on termination is the ledger AS OF the termination date (usage dated after it does not
           count); it is not paid when the separation pays the leave; the payslip that pays it - the payout line or the
           separation's unused leave - settles it in the ledger at the lock, so moving the termination date never pays it
           twice; a termination recorded after its month was locked gets its payout from the next open primary; an earlier
           open primary that holds a payout keeps it.
   Runs on a dev database with docs/103_qa3_payroll.sql applied, in transactions that are rolled back.
   sqlcmd -I -b -i tests/qa3/payroll/04_settlements.sql   ->  prints 'ok 04_settlements' */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
GO
CREATE PROCEDURE #qa3_04_emp @Name NVARCHAR(100), @Basic DECIMAL(18,2), @Term DATE, @Opening DECIMAL(9,2), @E INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @B INT, @BasicType INT = (SELECT ComponentTypeId FROM hr.COMPONENT_TYPE WHERE SystemCode = 'BASIC');
    DECLARE @Annual INT = (SELECT TOP 1 lt.LeaveTypeId FROM hr.LEAVE_TYPE lt WHERE lt.IsPaid = 1 AND EXISTS (SELECT 1 FROM hr.LEAVE_ACCRUAL_TIER t WHERE t.LeaveTypeId = lt.LeaveTypeId) ORDER BY lt.LeaveTypeId);
    UPDATE core.SETTING SET SettingValue = '26' WHERE SettingKey = 'StandardWorkingDaysPerMonth';
    UPDATE core.SETTING SET SettingValue = '1' WHERE SettingKey = 'LeavePayoutOnTermination';
    UPDATE hr.APPROVAL_TIER SET MinBasicSalary = NULL, MaxBasicSalary = NULL;
    SET @B = (SELECT BranchId FROM hr.BRANCH WHERE Name = N'QA3 Pay Settle');
    IF @B IS NULL BEGIN INSERT INTO hr.BRANCH (Name) VALUES (N'QA3 Pay Settle'); SET @B = SCOPE_IDENTITY(); END
    INSERT INTO hr.EMPLOYEE (BranchId, DepartmentId, PositionId, FullName, HireDate, TerminationDate)
    VALUES (@B, (SELECT TOP 1 DepartmentId FROM hr.DEPARTMENT ORDER BY DepartmentId), (SELECT TOP 1 PositionId FROM hr.POSITION ORDER BY PositionId), @Name, '2024-01-01', @Term);
    SET @E = SCOPE_IDENTITY();
    IF NOT EXISTS (SELECT 1 FROM hr.EMPLOYEE_BRANCH_HISTORY WHERE EmployeeId = @E) INSERT INTO hr.EMPLOYEE_BRANCH_HISTORY (EmployeeId, BranchId, EffectiveFrom) VALUES (@E, @B, '2024-01-01');
    INSERT INTO hr.SALARY_COMPONENT (EmployeeId, ComponentTypeId, Amount, CurrencyCode, EffectiveFrom) VALUES (@E, @BasicType, @Basic, 'USD', '2024-01-01');
    IF @Opening <> 0
        INSERT INTO hr.LEAVE_LEDGER (EmployeeId, LeaveTypeId, PeriodYearMonth, MovementType, Days, EffectiveDate, Note)
        VALUES (@E, @Annual, '2099-01', 'Adjustment', @Opening, '2099-01-01', N'QA3 opening');
END
GO
/* a primary run of @Period, created and generated as of @AsOf and sent to review */
CREATE PROCEDURE #qa3_04_run @Period CHAR(7), @AsOf DATE, @Run INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Hr INT = (SELECT TOP 1 UserId FROM security.[USER] u WHERE payroll.fn_UserHasRole(u.UserId, N'HR') = 1 OR payroll.fn_UserHasRole(u.UserId, N'Admin') = 1 ORDER BY UserId);
    DECLARE @c TABLE (PayrollRunId INT, PeriodYearMonth CHAR(7), [Status] VARCHAR(12), PrimaryCurrency CHAR(3), RunType VARCHAR(12));
    DECLARE @g TABLE (PayrollRunId INT, PayslipCount INT, PayslipsWithWarnings INT);
    INSERT INTO @c EXEC payroll.usp_PayrollRun_Create @PeriodYearMonth = @Period, @CreatedByUserId = @Hr, @Notes = N'QA3 payroll 04', @AsOfDate = @AsOf;
    SET @Run = (SELECT PayrollRunId FROM @c);
    INSERT INTO @g EXEC payroll.usp_PayrollRun_Generate @PayrollRunId = @Run, @ActedByUserId = @Hr, @AsOfDate = @AsOf;
    UPDATE payroll.PAYROLL_RUN SET [Status] = 'Review' WHERE PayrollRunId = @Run;          -- what usp_PayrollRun_SendToReview does
END
GO
CREATE PROCEDURE #qa3_04_approve @Run INT, @AsOf DATE
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Owner INT = (SELECT TOP 1 UserId FROM security.[USER] u WHERE payroll.fn_UserHasRole(u.UserId, N'Owner') = 1 ORDER BY UserId);
    DECLARE @ap TABLE (PayrollRunId INT, [Status] VARCHAR(12), LockedAt DATETIME2);
    INSERT INTO @ap EXEC payroll.usp_PayrollRun_Approve @PayrollRunId = @Run, @ActedByUserId = @Owner, @AsOfDate = @AsOf;
END
GO
/* what one employee's payslip of a run holds, by system code */
CREATE PROCEDURE #qa3_04_lines @Run INT, @E INT, @Basic DECIMAL(18,2) OUTPUT, @Indemnity DECIMAL(18,2) OUTPUT, @Unused DECIMAL(18,2) OUTPUT,
                               @Payout DECIMAL(18,2) OUTPUT, @Deduction DECIMAL(18,2) OUTPUT, @Lines INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT @Basic = ISNULL(SUM(CASE WHEN c.SystemCode = 'BASIC' THEN l.Amount END), 0),
           @Indemnity = ISNULL(SUM(CASE WHEN c.SystemCode = 'INDEMNITY' THEN l.Amount END), 0),
           @Unused = ISNULL(SUM(CASE WHEN c.SystemCode = 'UNUSED_LEAVE' THEN l.Amount END), 0),
           @Payout = ISNULL(SUM(CASE WHEN c.SystemCode = 'LEAVE_PAYOUT' THEN l.Amount END), 0),
           @Deduction = ISNULL(SUM(CASE WHEN c.SystemCode = 'LEAVE_DEDUCTION' THEN l.Amount END), 0),
           @Lines = COUNT(l.PayslipLineId)
    FROM payroll.PAYSLIP ps
    LEFT JOIN payroll.PAYSLIP_LINE l ON l.PayslipId = ps.PayslipId
    LEFT JOIN hr.COMPONENT_TYPE c ON c.ComponentTypeId = l.ComponentTypeId
    WHERE ps.PayrollRunId = @Run AND ps.EmployeeId = @E;
END
GO
DECLARE @fails INT = 0, @E INT, @Apr INT, @May INT, @Jun INT, @Ri INT, @RT INT, @WD INT, @Hr INT, @ps INT, @x NVARCHAR(400),
        @basic DECIMAL(18,2), @ind DECIMAL(18,2), @unused DECIMAL(18,2), @payout DECIMAL(18,2), @ded DECIMAL(18,2), @n INT;
SELECT TOP 1 @WD = WorkflowDefinitionId, @RT = RequestTypeId FROM workflow.WORKFLOW_DEFINITION ORDER BY WorkflowDefinitionId;
SET @Hr = (SELECT TOP 1 UserId FROM security.[USER] u WHERE payroll.fn_UserHasRole(u.UserId, N'HR') = 1 OR payroll.fn_UserHasRole(u.UserId, N'Admin') = 1 ORDER BY UserId);

/* ======== A. PAY-2: the separation is prepared after April was locked; it pays the unused leave itself ======== */
BEGIN TRAN;
EXEC #qa3_04_emp N'QA3 Rami Settled', 1300, NULL, 4, @E OUTPUT;
EXEC #qa3_04_run '2099-04', '2099-05-02', @Apr OUTPUT;
EXEC #qa3_04_approve @Apr, '2099-05-02';
UPDATE hr.EMPLOYEE SET TerminationDate = '2099-04-25' WHERE EmployeeId = @E;
INSERT INTO workflow.REQUEST_INSTANCE (RequestTypeId, WorkflowDefinitionId, EmployeeId, RaisedByUserId, [Status], Title) VALUES (@RT, @WD, @E, @Hr, 'Approved', N'QA3 separation');
SET @Ri = SCOPE_IDENTITY();
INSERT INTO workflow.SEPARATION (RequestInstanceId, EmployeeId, SeparationType, LastWorkingDate, CurrencyCode, ServiceYears, UnusedLeaveDays, UnusedLeaveAmount, IndemnityAmount, PreparedAt)
VALUES (@Ri, @E, 'Resignation', '2099-04-25', 'USD', 5.3, 4, 200, 4000, SYSUTCDATETIME());
EXEC #qa3_04_run '2099-05', '2099-06-02', @May OUTPUT;
EXEC #qa3_04_lines @May, @E, @basic OUTPUT, @ind OUTPUT, @unused OUTPUT, @payout OUTPUT, @ded OUTPUT, @n OUTPUT;
IF @ind <> 4000 OR @unused <> 200 OR @basic <> 0 OR @payout <> 0 OR @ded <> 0 OR @n <> 2
BEGIN
    SET @fails += 1; SET @x = CONCAT('indemnity ', @ind, ', unused leave ', @unused, ', basic ', @basic, ', payout ', @payout, ', lines ', @n);
    RAISERROR('04 A: May should pay the settlement only (4000 + 200; no basic, no second leave payout): %s.', 16, 1, @x);
END
SET @ps = (SELECT PayslipId FROM payroll.PAYSLIP WHERE PayrollRunId = @May AND EmployeeId = @E);
IF NOT EXISTS (SELECT 1 FROM payroll.PAYSLIP WHERE PayslipId = @ps AND Notes LIKE N'%settlement%')
    BEGIN SET @fails += 1; RAISERROR('04 A: the settlement-only payslip does not say so.', 16, 1); END
EXEC #qa3_04_approve @May, '2099-06-02';
IF NOT EXISTS (SELECT 1 FROM workflow.SEPARATION WHERE RequestInstanceId = @Ri AND PaidInPayslipId = @ps)
    BEGIN SET @fails += 1; RAISERROR('04 A: the separation is not stamped with the payslip that paid it.', 16, 1); END
IF (SELECT SUM(Days) FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E) <> 0
   OR NOT EXISTS (SELECT 1 FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E AND SourceType = 'TerminationPayout' AND SourceRef = @ps AND Days = -4 AND EffectiveDate = '2099-04-25')
    BEGIN SET @fails += 1; RAISERROR('04 A: the leave the separation paid is not settled in the ledger.', 16, 1); END
EXEC #qa3_04_run '2099-06', '2099-07-02', @Jun OUTPUT;
IF EXISTS (SELECT 1 FROM payroll.PAYSLIP WHERE PayrollRunId = @Jun AND EmployeeId = @E)
    BEGIN SET @fails += 1; RAISERROR('04 A: June pays the leaver again.', 16, 1); END
ROLLBACK TRAN;

/* ======== B. LEV-8 / REL-14: the payout is the balance as of the termination; the lock settles it; moving the
            termination date into May pays nothing more (and May's basic is the 5 days of May) ======== */
BEGIN TRAN;
EXEC #qa3_04_emp N'QA3 Rami Payout', 2600, '2099-04-30', 6, @E OUTPUT;
INSERT INTO hr.LEAVE_LEDGER (EmployeeId, LeaveTypeId, PeriodYearMonth, MovementType, Days, EffectiveDate, Note)
SELECT @E, LeaveTypeId, '2099-05', 'Usage', -2, '2099-05-03', N'QA3 usage after leaving' FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E;
EXEC #qa3_04_run '2099-04', '2099-05-02', @Apr OUTPUT;
EXEC #qa3_04_lines @Apr, @E, @basic OUTPUT, @ind OUTPUT, @unused OUTPUT, @payout OUTPUT, @ded OUTPUT, @n OUTPUT;
IF @payout <> 600 OR @basic <> 2600
    BEGIN SET @fails += 1; SET @x = CONCAT('payout ', @payout, ', basic ', @basic); RAISERROR('04 B: April should pay 6 days x 100 (the May usage does not count) and the full basic: %s.', 16, 1, @x); END
EXEC #qa3_04_approve @Apr, '2099-05-02';
SET @ps = (SELECT PayslipId FROM payroll.PAYSLIP WHERE PayrollRunId = @Apr AND EmployeeId = @E);
IF NOT EXISTS (SELECT 1 FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E AND SourceType = 'TerminationPayout' AND SourceRef = @ps AND Days = -6 AND EffectiveDate = '2099-04-30')
    BEGIN SET @fails += 1; RAISERROR('04 B: the payout is not settled in the ledger at the lock.', 16, 1); END
UPDATE hr.EMPLOYEE SET TerminationDate = '2099-05-05' WHERE EmployeeId = @E;
EXEC #qa3_04_run '2099-05', '2099-06-02', @May OUTPUT;
EXEC #qa3_04_lines @May, @E, @basic OUTPUT, @ind OUTPUT, @unused OUTPUT, @payout OUTPUT, @ded OUTPUT, @n OUTPUT;
IF @payout <> 0 OR @ded <> 0 OR @basic <> 419.35
    BEGIN SET @fails += 1; SET @x = CONCAT('payout ', @payout, ', deduction ', @ded, ', basic ', @basic); RAISERROR('04 B: the moved termination paid or recovered the leave again: %s.', 16, 1, @x); END
ROLLBACK TRAN;

/* ======== C. PAY-2 / LEV-8: the termination is recorded after April was locked; May pays the payout (settlement only) ===== */
BEGIN TRAN;
EXEC #qa3_04_emp N'QA3 Rami Late', 2600, NULL, 3, @E OUTPUT;
EXEC #qa3_04_run '2099-04', '2099-05-02', @Apr OUTPUT;
EXEC #qa3_04_approve @Apr, '2099-05-02';
UPDATE hr.EMPLOYEE SET TerminationDate = '2099-04-20' WHERE EmployeeId = @E;
EXEC #qa3_04_run '2099-05', '2099-06-02', @May OUTPUT;
EXEC #qa3_04_lines @May, @E, @basic OUTPUT, @ind OUTPUT, @unused OUTPUT, @payout OUTPUT, @ded OUTPUT, @n OUTPUT;
IF @payout <> 300 OR @basic <> 0 OR @n <> 1
    BEGIN SET @fails += 1; SET @x = CONCAT('payout ', @payout, ', basic ', @basic, ', lines ', @n); RAISERROR('04 C: May should pay the 3 days left on leaving, and nothing else: %s.', 16, 1, @x); END
EXEC #qa3_04_approve @May, '2099-06-02';
EXEC #qa3_04_run '2099-06', '2099-07-02', @Jun OUTPUT;
IF EXISTS (SELECT 1 FROM payroll.PAYSLIP WHERE PayrollRunId = @Jun AND EmployeeId = @E) OR (SELECT SUM(Days) FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E) <> 0
    BEGIN SET @fails += 1; RAISERROR('04 C: the payout was not settled once.', 16, 1); END
ROLLBACK TRAN;

/* ======== D. an EARLIER open primary holds the payout: May, generated while April waits, leaves it to April ======== */
BEGIN TRAN;
EXEC #qa3_04_emp N'QA3 Rami Held', 2600, '2099-04-30', 2, @E OUTPUT;
EXEC #qa3_04_run '2099-04', '2099-05-02', @Apr OUTPUT;
EXEC #qa3_04_run '2099-05', '2099-06-02', @May OUTPUT;
EXEC #qa3_04_lines @May, @E, @basic OUTPUT, @ind OUTPUT, @unused OUTPUT, @payout OUTPUT, @ded OUTPUT, @n OUTPUT;
IF @payout <> 0 OR EXISTS (SELECT 1 FROM payroll.PAYSLIP WHERE PayrollRunId = @May AND EmployeeId = @E)
    BEGIN SET @fails += 1; RAISERROR('04 D: May pays the payout April holds.', 16, 1); END
EXEC #qa3_04_lines @Apr, @E, @basic OUTPUT, @ind OUTPUT, @unused OUTPUT, @payout OUTPUT, @ded OUTPUT, @n OUTPUT;
IF @payout <> 200
    BEGIN SET @fails += 1; RAISERROR('04 D: April lost its payout.', 16, 1); END
ROLLBACK TRAN;

IF @fails = 0 PRINT 'ok 04_settlements';
GO
DROP PROCEDURE #qa3_04_emp; DROP PROCEDURE #qa3_04_run; DROP PROCEDURE #qa3_04_approve; DROP PROCEDURE #qa3_04_lines;
