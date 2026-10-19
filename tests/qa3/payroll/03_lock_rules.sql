/* QA3 payroll (unit E) - when a run may be locked:
   PAY-4  readiness is asked again by Generate and Approve (an anomaly recorded after the run was generated refuses both);
   PAY-3  a primary is not locked before its last day is over unless the Owner asks for an EARLY LOCK;
   PAY-5 / REL-3 / ATT-11  an expense held by an earlier open run is left to it; two open months never both recover the
          same advance (the later one goes stale when the earlier is locked); Approve refuses a run whose inputs changed
          after it was generated (an advance and an unpaid leave taken back) and names them;
   PAY-11 the second approval of a run changes nothing.
   Runs on a dev database with docs/103_qa3_payroll.sql applied. Each part is a transaction that is rolled back; its
   refusal checks come LAST because the payroll procedures SET XACT_ABORT ON, so a refusal caught in TRY leaves the
   transaction uncommittable (reads, and so further refusals, still work).
   sqlcmd -I -b -i tests/qa3/payroll/03_lock_rules.sql   ->  prints 'ok 03_lock_rules' */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
GO
CREATE PROCEDURE #qa3_03_setup @Name NVARCHAR(100), @E INT OUTPUT, @Hr INT OUTPUT, @Owner INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @B INT, @Basic INT = (SELECT ComponentTypeId FROM hr.COMPONENT_TYPE WHERE SystemCode = 'BASIC');
    SET @Hr = (SELECT TOP 1 UserId FROM security.[USER] u WHERE payroll.fn_UserHasRole(u.UserId, N'HR') = 1 OR payroll.fn_UserHasRole(u.UserId, N'Admin') = 1 ORDER BY UserId);
    SET @Owner = (SELECT TOP 1 UserId FROM security.[USER] u WHERE payroll.fn_UserHasRole(u.UserId, N'Owner') = 1 ORDER BY UserId);
    UPDATE core.SETTING SET SettingValue = '26' WHERE SettingKey = 'StandardWorkingDaysPerMonth';
    UPDATE hr.APPROVAL_TIER SET MinBasicSalary = NULL, MaxBasicSalary = NULL;
    INSERT INTO hr.BRANCH (Name) VALUES (CONCAT(N'QA3 Pay Lock ', @Name)); SET @B = SCOPE_IDENTITY();
    INSERT INTO hr.EMPLOYEE (BranchId, DepartmentId, PositionId, FullName, HireDate)
    VALUES (@B, (SELECT TOP 1 DepartmentId FROM hr.DEPARTMENT ORDER BY DepartmentId), (SELECT TOP 1 PositionId FROM hr.POSITION ORDER BY PositionId), @Name, '2025-01-01');
    SET @E = SCOPE_IDENTITY();
    IF NOT EXISTS (SELECT 1 FROM hr.EMPLOYEE_BRANCH_HISTORY WHERE EmployeeId = @E) INSERT INTO hr.EMPLOYEE_BRANCH_HISTORY (EmployeeId, BranchId, EffectiveFrom) VALUES (@E, @B, '2025-01-01');
    INSERT INTO hr.SALARY_COMPONENT (EmployeeId, ComponentTypeId, Amount, CurrencyCode, EffectiveFrom) VALUES (@E, @Basic, 2600, 'USD', '2025-01-01');
END
GO
DECLARE @fails INT = 0, @Hr INT, @Owner INT, @E INT, @Aug INT, @Sep INT, @Oct INT, @Ri INT, @RiLeave INT, @Adv INT, @Unpaid INT, @RT INT, @WD INT, @msg NVARCHAR(2048), @msg2 NVARCHAR(2048), @msg3 NVARCHAR(2048);
DECLARE @g TABLE (PayrollRunId INT, PayslipCount INT, PayslipsWithWarnings INT);
DECLARE @c TABLE (PayrollRunId INT, PeriodYearMonth CHAR(7), [Status] VARCHAR(12), PrimaryCurrency CHAR(3), RunType VARCHAR(12));
DECLARE @ap TABLE (PayrollRunId INT, [Status] VARCHAR(12), LockedAt DATETIME2);
SELECT TOP 1 @WD = WorkflowDefinitionId, @RT = RequestTypeId FROM workflow.WORKFLOW_DEFINITION ORDER BY WorkflowDefinitionId;

/* ======== A. PAY-4 and PAY-3: an anomaly recorded after Generate; an approval on the last day ======== */
BEGIN TRAN;
EXEC #qa3_03_setup N'QA3 Hadi Ready', @E OUTPUT, @Hr OUTPUT, @Owner OUTPUT;
INSERT INTO @c EXEC payroll.usp_PayrollRun_Create @PeriodYearMonth = '2099-08', @CreatedByUserId = @Hr, @Notes = N'QA3 payroll 03', @AsOfDate = '2099-08-02';
SET @Aug = (SELECT PayrollRunId FROM @c); DELETE FROM @c;
INSERT INTO @g EXEC payroll.usp_PayrollRun_Generate @PayrollRunId = @Aug, @ActedByUserId = @Hr, @AsOfDate = '2099-09-02';
UPDATE payroll.PAYROLL_RUN SET [Status] = 'Review' WHERE PayrollRunId = @Aug;          -- what usp_PayrollRun_SendToReview does
INSERT INTO attendance.ATTENDANCE_RECORD (EmployeeId, WorkDate, [Status], DayFraction, StandardMinutes, WorkedMinutes, [Source]) VALUES (@E, '2099-08-10', 'Present', 1, 480, 480, 'Device');
INSERT INTO attendance.ATTENDANCE_ANOMALY (AttendanceId, EmployeeId, WorkDate, [Type]) VALUES (SCOPE_IDENTITY(), @E, '2099-08-10', 'LateArrival');
SELECT @msg = NULL, @msg2 = NULL, @msg3 = NULL;
BEGIN TRY EXEC payroll.usp_PayrollRun_Approve @PayrollRunId = @Aug, @ActedByUserId = @Owner, @AsOfDate = '2099-09-03'; END TRY BEGIN CATCH SET @msg = ERROR_MESSAGE(); END CATCH;
BEGIN TRY EXEC payroll.usp_PayrollRun_Generate @PayrollRunId = @Aug, @ActedByUserId = @Hr, @AsOfDate = '2099-09-03'; END TRY BEGIN CATCH SET @msg2 = ERROR_MESSAGE(); END CATCH;
BEGIN TRY EXEC payroll.usp_PayrollRun_Approve @PayrollRunId = @Aug, @ActedByUserId = @Owner, @AsOfDate = '2099-08-31'; END TRY BEGIN CATCH SET @msg3 = ERROR_MESSAGE(); END CATCH;
IF @msg IS NULL OR @msg NOT LIKE N'Attendance for 2099-08 has 1 undecided anomaly up to 2099-08-31%'
    BEGIN SET @fails += 1; RAISERROR('03 A: Approve did not ask readiness again (%s).', 16, 1, @msg); END
IF @msg2 IS NULL OR @msg2 <> @msg
    BEGIN SET @fails += 1; RAISERROR('03 A: Generate did not ask readiness again with the same sentence (%s).', 16, 1, @msg2); END
IF @msg3 IS NULL OR @msg3 NOT LIKE N'The period 2099-08 runs until 2099-08-31; it can be locked from 2099-09-01. Locking it now is an EARLY LOCK%'
    BEGIN SET @fails += 1; RAISERROR('03 A: August was locked before its last day was over (%s).', 16, 1, @msg3); END
ROLLBACK TRAN;

/* ======== B. PAY-3 with the Owner's choice: an early lock is recorded as such ======== */
BEGIN TRAN;
EXEC #qa3_03_setup N'QA3 Hadi Early', @E OUTPUT, @Hr OUTPUT, @Owner OUTPUT;
INSERT INTO @c EXEC payroll.usp_PayrollRun_Create @PeriodYearMonth = '2099-08', @CreatedByUserId = @Hr, @Notes = N'QA3 payroll 03', @AsOfDate = '2099-08-02';
SET @Aug = (SELECT PayrollRunId FROM @c); DELETE FROM @c;
INSERT INTO @g EXEC payroll.usp_PayrollRun_Generate @PayrollRunId = @Aug, @ActedByUserId = @Hr, @AsOfDate = '2099-08-31';
UPDATE payroll.PAYROLL_RUN SET [Status] = 'Review' WHERE PayrollRunId = @Aug;
INSERT INTO @ap EXEC payroll.usp_PayrollRun_Approve @PayrollRunId = @Aug, @ActedByUserId = @Owner, @AllowEarlyLock = 1, @AsOfDate = '2099-08-31';
IF NOT EXISTS (SELECT 1 FROM payroll.PAYROLL_RUN WHERE PayrollRunId = @Aug AND [Status] = 'Approved' AND LockedEarly = 1 AND GeneratedUpTo = '2099-08-30')
   OR NOT EXISTS (SELECT 1 FROM payroll.PAYROLL_RUN_EVENT WHERE PayrollRunId = @Aug AND [Action] = 'Approved' AND Detail LIKE N'%EARLY LOCK%')
    BEGIN SET @fails += 1; RAISERROR('03 B: the Owner''s early lock is not recorded as one.', 16, 1); END
ROLLBACK TRAN;

/* ======== C. PAY-5: September is generated while August waits for the Owner ======== */
BEGIN TRAN;
EXEC #qa3_03_setup N'QA3 Hadi Stale', @E OUTPUT, @Hr OUTPUT, @Owner OUTPUT;
/* an expense of 100 (August) and an advance of 300 recovered at 300 a month from August, both approved */
INSERT INTO workflow.REQUEST_INSTANCE (RequestTypeId, WorkflowDefinitionId, EmployeeId, RaisedByUserId, [Status], Title) VALUES (@RT, @WD, @E, @Hr, 'Approved', N'QA3 expense');
SET @Ri = SCOPE_IDENTITY();
INSERT INTO workflow.EXPENSE_REIMBURSEMENT (RequestInstanceId, EmployeeId, ExpenseDate, Category, Amount, CurrencyCode) VALUES (@Ri, @E, '2099-08-20', N'QA3 Taxi', 100, 'USD');
INSERT INTO payroll.SALARY_ADVANCE (EmployeeId, Amount, CurrencyCode, AdvanceDate, MonthlyDeduction, RemainingAmount, FirstDeductionPeriod, Reason, CreatedByUserId)
VALUES (@E, 300, 'USD', '2099-08-05', 300, 300, '2099-08', N'QA3 advance', @Hr);
INSERT INTO @c EXEC payroll.usp_PayrollRun_Create @PeriodYearMonth = '2099-08', @CreatedByUserId = @Hr, @Notes = N'QA3 payroll 03', @AsOfDate = '2099-08-02';
SET @Aug = (SELECT PayrollRunId FROM @c); DELETE FROM @c;
INSERT INTO @g EXEC payroll.usp_PayrollRun_Generate @PayrollRunId = @Aug, @ActedByUserId = @Hr, @AsOfDate = '2099-09-02';
UPDATE payroll.PAYROLL_RUN SET [Status] = 'Review' WHERE PayrollRunId = @Aug;
INSERT INTO @c EXEC payroll.usp_PayrollRun_Create @PeriodYearMonth = '2099-09', @CreatedByUserId = @Hr, @Notes = N'QA3 payroll 03', @AsOfDate = '2099-09-02';
SET @Sep = (SELECT PayrollRunId FROM @c); DELETE FROM @c;
INSERT INTO @g EXEC payroll.usp_PayrollRun_Generate @PayrollRunId = @Sep, @ActedByUserId = @Hr, @AsOfDate = '2099-10-02';
/* the expense is August's (its open run holds it); the advance is recovered by both open months - for now */
IF EXISTS (SELECT 1 FROM payroll.PAYSLIP_LINE l JOIN payroll.PAYSLIP ps ON ps.PayslipId = l.PayslipId WHERE ps.PayrollRunId = @Sep AND l.SourceType = 'Expense')
   OR NOT EXISTS (SELECT 1 FROM payroll.PAYSLIP_LINE l JOIN payroll.PAYSLIP ps ON ps.PayslipId = l.PayslipId WHERE ps.PayrollRunId = @Aug AND l.SourceType = 'Expense')
    BEGIN SET @fails += 1; RAISERROR('03 C: the expense held by the open August run is paid by September as well.', 16, 1); END
UPDATE payroll.PAYROLL_RUN SET [Status] = 'Review' WHERE PayrollRunId = @Sep;
INSERT INTO @ap EXEC payroll.usp_PayrollRun_Approve @PayrollRunId = @Aug, @ActedByUserId = @Owner, @AsOfDate = '2099-10-03';
/* August's lock recovered the advance: September (generated before) now reads as out of date, on the advance only */
IF (SELECT STRING_AGG(CONCAT(EmployeeName, N': ', Source), N'; ') FROM payroll.fn_RunStaleness(@Sep)) <> N'QA3 Hadi Stale: Advances'
    BEGIN SET @fails += 1; SET @msg = (SELECT STRING_AGG(CONCAT(EmployeeName, N': ', Source), N'; ') FROM payroll.fn_RunStaleness(@Sep)); RAISERROR('03 C: September should be stale on the advance only (%s).', 16, 1, @msg); END
INSERT INTO @g EXEC payroll.usp_PayrollRun_Generate @PayrollRunId = @Sep, @ActedByUserId = @Hr, @AsOfDate = '2099-10-03';
INSERT INTO @ap EXEC payroll.usp_PayrollRun_Approve @PayrollRunId = @Sep, @ActedByUserId = @Owner, @AsOfDate = '2099-10-03';
IF (SELECT RemainingAmount FROM payroll.SALARY_ADVANCE WHERE EmployeeId = @E) <> 0
   OR (SELECT COUNT(*) FROM payroll.PAYSLIP_LINE l JOIN payroll.PAYSLIP ps ON ps.PayslipId = l.PayslipId WHERE ps.EmployeeId = @E AND l.SourceType IN ('Expense','Advance')) <> 2
    BEGIN SET @fails += 1; RAISERROR('03 C: the expense or the advance was paid / recovered twice.', 16, 1); END
/* PAY-11: a second approval is refused and changes nothing */
SET @msg = NULL;
BEGIN TRY EXEC payroll.usp_PayrollRun_Approve @PayrollRunId = @Aug, @ActedByUserId = @Owner, @AsOfDate = '2099-10-03'; END TRY BEGIN CATCH SET @msg = ERROR_MESSAGE(); END CATCH;
IF @msg IS NULL OR @msg <> N'This run is already approved and locked.' OR (SELECT COUNT(*) FROM payroll.PAYROLL_RUN_EVENT WHERE PayrollRunId = @Aug AND [Action] = 'Approved') <> 1
    BEGIN SET @fails += 1; RAISERROR('03 C: a second approval was not refused cleanly (%s).', 16, 1, @msg); END
ROLLBACK TRAN;

/* ======== D. PAY-5 (t12): after Generate an advance and an unpaid leave are taken back - Approve names both ======== */
BEGIN TRAN;
EXEC #qa3_03_setup N'QA3 Hadi Taken Back', @E OUTPUT, @Hr OUTPUT, @Owner OUTPUT;
INSERT INTO hr.LEAVE_TYPE (Name, IsPaid) VALUES (N'QA3 Unpaid', 0); SET @Unpaid = SCOPE_IDENTITY();
INSERT INTO workflow.REQUEST_INSTANCE (RequestTypeId, WorkflowDefinitionId, EmployeeId, RaisedByUserId, [Status], Title) VALUES (@RT, @WD, @E, @Hr, 'Approved', N'QA3 leave');
SET @RiLeave = SCOPE_IDENTITY();
INSERT INTO workflow.LEAVE_REQUEST (RequestInstanceId, EmployeeId, LeaveTypeId, FromDate, ToDate, DaysRequested, ApprovedToDate) VALUES (@RiLeave, @E, @Unpaid, '2099-10-19', '2099-10-21', 3, '2099-10-21');
INSERT INTO payroll.SALARY_ADVANCE (EmployeeId, Amount, CurrencyCode, AdvanceDate, MonthlyDeduction, RemainingAmount, FirstDeductionPeriod, Reason, CreatedByUserId)
VALUES (@E, 300, 'USD', '2099-10-05', 300, 300, '2099-10', N'QA3 advance 2', @Hr);
SET @Adv = SCOPE_IDENTITY();
INSERT INTO @c EXEC payroll.usp_PayrollRun_Create @PeriodYearMonth = '2099-10', @CreatedByUserId = @Hr, @Notes = N'QA3 payroll 03', @AsOfDate = '2099-10-02';
SET @Oct = (SELECT PayrollRunId FROM @c); DELETE FROM @c;
INSERT INTO @g EXEC payroll.usp_PayrollRun_Generate @PayrollRunId = @Oct, @ActedByUserId = @Hr, @AsOfDate = '2099-11-02';
IF NOT EXISTS (SELECT 1 FROM payroll.PAYSLIP_LINE l JOIN payroll.PAYSLIP ps ON ps.PayslipId = l.PayslipId WHERE ps.PayrollRunId = @Oct AND l.SourceType = 'Advance')
   OR NOT EXISTS (SELECT 1 FROM payroll.PAYSLIP_LINE l JOIN payroll.PAYSLIP ps ON ps.PayslipId = l.PayslipId WHERE ps.PayrollRunId = @Oct AND l.SourceType = 'Leave')
    BEGIN SET @fails += 1; RAISERROR('03 D: the October payslip should recover the advance and deduct the unpaid leave.', 16, 1); END
UPDATE payroll.PAYROLL_RUN SET [Status] = 'Review' WHERE PayrollRunId = @Oct;
DELETE FROM payroll.SALARY_ADVANCE WHERE SalaryAdvanceId = @Adv;                                       -- the advance approval taken back
UPDATE workflow.REQUEST_INSTANCE SET [Status] = 'Pending' WHERE RequestInstanceId = @RiLeave;        -- the leave approval taken back
SET @msg = NULL;
BEGIN TRY EXEC payroll.usp_PayrollRun_Approve @PayrollRunId = @Oct, @ActedByUserId = @Owner, @AsOfDate = '2099-11-02'; END TRY BEGIN CATCH SET @msg = ERROR_MESSAGE(); END CATCH;
IF @msg IS NULL OR @msg <> N'This run is out of date: what 1 payslip(s) were computed from changed after it was generated (QA3 Hadi Taken Back: Advances, Leave). Regenerate the run, check it, then approve it.'
    BEGIN SET @fails += 1; RAISERROR('03 D: a run whose advance and leave were taken back was not refused (%s).', 16, 1, @msg); END
ROLLBACK TRAN;

IF @fails = 0 PRINT 'ok 03_lock_rules';
GO
DROP PROCEDURE #qa3_03_setup;
