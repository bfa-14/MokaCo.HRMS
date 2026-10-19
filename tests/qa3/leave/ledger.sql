/* ============================================================================
   tests/qa3/leave/ledger.sql -- QA3 LEV-9 (delete), LEV-14 / CON-8 (balances), ATT-15 (@Quiet), LEV-11 (manual usage)
   (docs/99_qa3_leave.sql).
   - only a manual adjustment can be deleted, and the ledger read says which rows (CanDelete); every other row is refused
     with a sentence naming what keeps it;
   - hr.usp_LeaveLedger_PostMovement @Quiet = 1 posts without a result set; a manual Usage in a paid period is refused;
   - hr.usp_LeaveBalance_Get returns Adjusted and every row adds up: Remaining = Accrued + CarriedOver - Used + Adjusted.
   Runs on a real dev database: each phase is one transaction that is rolled back; seeded rows start with 'QA3 '.
   Prints 'ok ledger', or raises the first wrong result. Needs 99.
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
SET QUOTED_IDENTIFIER ON;
GO
IF OBJECT_ID('tempdb..#qa3_fail') IS NOT NULL DROP TABLE #qa3_fail;
CREATE TABLE #qa3_fail (Msg NVARCHAR(4000));
IF OBJECT_ID('tempdb..#qa3_ledger_seed') IS NOT NULL DROP PROCEDURE #qa3_ledger_seed;
GO
/* one employee with one row of every kind: manual accrual and adjustment, a posted leave, a year opening, an exit
   permission's conversion, an expiry */
CREATE PROCEDURE #qa3_ledger_seed @E INT OUTPUT, @A INT OUTPUT, @User INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO hr.BRANCH (Name, IsActive) VALUES (N'QA3 Ledger Branch', 1);
    DECLARE @B INT = SCOPE_IDENTITY();
    DECLARE @Dep INT = (SELECT TOP 1 DepartmentId FROM hr.DEPARTMENT ORDER BY DepartmentId);
    DECLARE @Pos INT = (SELECT TOP 1 PositionId FROM hr.[POSITION] ORDER BY PositionId);
    SET @User = (SELECT TOP 1 UserId FROM security.[USER] WHERE IsActive = 1 ORDER BY UserId);
    INSERT INTO hr.LEAVE_TYPE (Name, IsPaid, AccrualPerMonth, CarryOver, RequiresCertificate, MinServiceMonthsToUse, NoticePreferredDays, FixedEntitlementDays, IsDiscretionary, IsActive)
    VALUES (N'QA3 Annual', 1, 0, 1, 0, 0, 0, NULL, 0, 1);
    SET @A = SCOPE_IDENTITY();
    INSERT INTO hr.EMPLOYEE (BranchId, DepartmentId, PositionId, FullName, HireDate, TerminationDate, ApprovalTier, PreferredLanguage)
    VALUES (@B, @Dep, @Pos, N'QA3 Ledger E1', '2020-01-01', NULL, 5, 'en');
    SET @E = SCOPE_IDENTITY();
    DECLARE @sink TABLE (LeaveLedgerId INT);
    INSERT INTO @sink EXEC hr.usp_LeaveLedger_PostMovement @EmployeeId = @E, @LeaveTypeId = @A, @MovementType = 'Accrual', @Days = 10,
         @EffectiveDate = '2097-01-01', @Note = N'QA3 manual accrual', @CreatedBy = @User;
    INSERT INTO @sink EXEC hr.usp_LeaveLedger_PostMovement @EmployeeId = @E, @LeaveTypeId = @A, @MovementType = 'Adjustment', @Days = 2,
         @EffectiveDate = '2097-02-01', @Note = N'QA3 manual adjustment', @CreatedBy = @User;
    INSERT INTO hr.LEAVE_LEDGER (EmployeeId, LeaveTypeId, PeriodYearMonth, MovementType, Days, EffectiveDate, Note, SourceType, SourceRef)
    VALUES (@E, @A, '2097-01', 'CarryOver', 3, '2097-01-01', N'Carried over from 2096.', 'LeaveYear', 2097),
           (@E, @A, '2097-03', 'Usage', -0.5, '2097-03-20', N'QA3 exit permission converted to leave', 'ExitPermission', -1),
           (@E, @A, '2097-03', 'Expiry', -1, '2097-03-31', N'QA3 expiry', NULL, NULL);
    DECLARE @T INT = (SELECT RequestTypeId FROM workflow.REQUEST_TYPE WHERE Code = 'LEAVE_REQUEST');
    DECLARE @Def INT = (SELECT TOP 1 WorkflowDefinitionId FROM workflow.WORKFLOW_DEFINITION WHERE RequestTypeId = @T
                        ORDER BY CASE WHEN [Status] = 'Active' THEN 0 ELSE 1 END, WorkflowDefinitionId DESC);
    INSERT INTO workflow.REQUEST_INSTANCE (RequestTypeId, WorkflowDefinitionId, EmployeeId, RaisedByUserId, [Status], Title, ClosedAt)
    VALUES (@T, @Def, @E, @User, 'Approved', N'QA3 ledger leave', SYSUTCDATETIME());
    DECLARE @rid INT = SCOPE_IDENTITY();
    INSERT INTO workflow.LEAVE_REQUEST (RequestInstanceId, EmployeeId, LeaveTypeId, FromDate, ToDate, DaysRequested, DaysApproved, IsDiscretionary)
    VALUES (@rid, @E, @A, '2097-04-06', '2097-04-07', 2, 2, 1);                          -- discretionary: usage + give-back
    EXEC hr.usp_LeaveLedger_PostRequest @RequestInstanceId = @rid, @ActorUserId = @User;
END;
GO

/* ---------------- phase 1: CanDelete, the one deletable row, @Quiet, the balance rows ---------------- */
BEGIN TRAN;
BEGIN TRY
    DECLARE @E INT, @A INT, @User INT, @msg NVARCHAR(2000);
    EXEC #qa3_ledger_seed @E OUTPUT, @A OUTPUT, @User OUTPUT;
    DECLARE @rows TABLE (LeaveLedgerId INT, EmployeeId INT, LeaveTypeId INT, PeriodYearMonth CHAR(7), MovementType VARCHAR(20), LeaveRequestId INT,
                         Days DECIMAL(6,2), EffectiveDate DATE, Note NVARCHAR(200), CreatedAt DATETIME2, SourceType VARCHAR(30), CanDelete BIT);
    INSERT INTO @rows EXEC hr.usp_LeaveLedger_GetByEmployee @EmployeeId = @E;
    IF (SELECT COUNT(*) FROM @rows WHERE CanDelete = 1) <> 1
       OR NOT EXISTS (SELECT 1 FROM @rows WHERE CanDelete = 1 AND MovementType = 'Adjustment' AND Note = N'QA3 manual adjustment')
    BEGIN
        SET @msg = CONCAT('FAIL ledger (CanDelete): only the manual adjustment may be deleted; CanDelete on: ',
                          (SELECT STRING_AGG(CONCAT(MovementType, ' ', Days), ', ') FROM @rows WHERE CanDelete = 1));
        RAISERROR(@msg, 16, 1);
    END
    DECLARE @id INT = (SELECT LeaveLedgerId FROM @rows WHERE CanDelete = 1);
    EXEC hr.usp_LeaveLedger_Delete @LeaveLedgerId = @id;
    IF EXISTS (SELECT 1 FROM hr.LEAVE_LEDGER WHERE LeaveLedgerId = @id) RAISERROR('FAIL ledger (delete): the manual adjustment was not deleted.', 16, 1);

    /* @Quiet = 1: posted, no result set */
    DECLARE @sink TABLE (LeaveLedgerId INT);
    DECLARE @n INT = (SELECT COUNT(*) FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E);
    INSERT INTO @sink EXEC hr.usp_LeaveLedger_PostMovement @EmployeeId = @E, @LeaveTypeId = @A, @MovementType = 'Adjustment', @Days = -1,
         @EffectiveDate = '2097-05-01', @Note = N'QA3 quiet', @CreatedBy = @User, @Quiet = 1;
    IF EXISTS (SELECT 1 FROM @sink) OR (SELECT COUNT(*) FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E) <> @n + 1
        RAISERROR('FAIL ledger (@Quiet): a quiet post must write the row and return no result set.', 16, 1);
    INSERT INTO @sink EXEC hr.usp_LeaveLedger_PostMovement @EmployeeId = @E, @LeaveTypeId = @A, @MovementType = 'Adjustment', @Days = 1,
         @EffectiveDate = '2097-05-02', @Note = N'QA3 loud', @CreatedBy = @User;
    IF (SELECT COUNT(*) FROM @sink) <> 1 RAISERROR('FAIL ledger (@Quiet): a normal post returns the new id.', 16, 1);

    /* LEV-14: Adjusted is there and every row adds up */
    DECLARE @bal TABLE (EmployeeId INT, LeaveTypeId INT, PeriodYearMonth CHAR(7), Accrued DECIMAL(9,2), CarriedOver DECIMAL(9,2), Used DECIMAL(9,2),
                        Adjusted DECIMAL(9,2), Remaining DECIMAL(9,2));
    INSERT INTO @bal EXEC hr.usp_LeaveBalance_Get @EmployeeId = @E;
    IF EXISTS (SELECT 1 FROM @bal WHERE Accrued + CarriedOver - Used + Adjusted <> Remaining)
       OR (SELECT SUM(Adjusted) FROM @bal) <> (SELECT SUM(Days) FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E AND MovementType IN ('Adjustment', 'Expiry'))
       OR (SELECT SUM(Adjusted) FROM @bal) = 0
        RAISERROR('FAIL ledger (LEV-14): the balance rows must carry Adjusted and add up.', 16, 1);
END TRY
BEGIN CATCH
    DECLARE @failMsg NVARCHAR(4000) = ERROR_MESSAGE();
    IF @@TRANCOUNT > 0 ROLLBACK;
    INSERT INTO #qa3_fail VALUES (@failMsg);
    RAISERROR(N'%s', 16, 1, @failMsg);
END CATCH;
IF @@TRANCOUNT > 0 ROLLBACK;
GO

/* ---------------- phases 2-7: one refusal each ---------------- */
IF OBJECT_ID('tempdb..#qa3_ledger_refusal') IS NOT NULL DROP PROCEDURE #qa3_ledger_refusal;
GO
CREATE PROCEDURE #qa3_ledger_refusal @Case VARCHAR(20), @Expect NVARCHAR(400)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;
    DECLARE @E INT, @A INT, @User INT, @msg NVARCHAR(2000), @err NVARCHAR(2000), @id INT;
    BEGIN TRAN;
    BEGIN TRY
        EXEC #qa3_ledger_seed @E OUTPUT, @A OUTPUT, @User OUTPUT;
        IF @Case = 'manual-usage-paid'
        BEGIN
            DECLARE @Run INT = (SELECT PayrollRunId FROM payroll.PAYROLL_RUN WHERE PeriodYearMonth = '2097-06' AND RunType = 'Primary' AND [Status] <> 'Cancelled');
            IF @Run IS NULL
            BEGIN
                INSERT INTO payroll.PAYROLL_RUN (PeriodYearMonth, PeriodStart, PeriodEnd, PrimaryCurrency, Notes, CreatedByUserId, RunType, [Status])
                VALUES ('2097-06', '2097-06-01', '2097-06-30', 'USD', N'QA3 paid June', @User, 'Primary', 'Approved');
                SET @Run = SCOPE_IDENTITY();
            END
            ELSE UPDATE payroll.PAYROLL_RUN SET [Status] = 'Approved' WHERE PayrollRunId = @Run;
            INSERT INTO payroll.PAYSLIP (PayrollRunId, EmployeeId, EmployeeName) VALUES (@Run, @E, N'QA3 Ledger E1');
            DECLARE @sink TABLE (LeaveLedgerId INT);
            BEGIN TRY
                INSERT INTO @sink EXEC hr.usp_LeaveLedger_PostMovement @EmployeeId = @E, @LeaveTypeId = @A, @MovementType = 'Usage', @Days = 1,
                     @EffectiveDate = '2097-06-10', @Note = N'QA3 manual usage in a paid month', @CreatedBy = @User;
            END TRY BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH;
            IF EXISTS (SELECT 1 FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E AND EffectiveDate = '2097-06-10')
                RAISERROR('FAIL ledger (manual-usage-paid): the refused movement was stored.', 16, 1);
        END
        ELSE
        BEGIN
            SET @id = (SELECT TOP 1 LeaveLedgerId FROM hr.LEAVE_LEDGER
                       WHERE EmployeeId = @E
                         AND ((@Case = 'leave-row' AND LeaveRequestId IS NOT NULL)
                           OR (@Case = 'year-row' AND SourceType = 'LeaveYear')
                           OR (@Case = 'exit-row' AND SourceType = 'ExitPermission')
                           OR (@Case = 'expiry-row' AND MovementType = 'Expiry')
                           OR (@Case = 'manual-accrual' AND MovementType = 'Accrual')));
            BEGIN TRY EXEC hr.usp_LeaveLedger_Delete @LeaveLedgerId = @id; END TRY BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH;
            IF NOT EXISTS (SELECT 1 FROM hr.LEAVE_LEDGER WHERE LeaveLedgerId = @id)
            BEGIN SET @msg = CONCAT('FAIL ledger (', @Case, '): the row was deleted.'); RAISERROR(@msg, 16, 1); END
        END
        IF @err IS NULL OR @err NOT LIKE @Expect
        BEGIN
            SET @msg = CONCAT('FAIL ledger (', @Case, '): expected a refusal like "', @Expect, '"; got: ', ISNULL(@err, 'accepted'));
            RAISERROR(@msg, 16, 1);
        END
    END TRY
    BEGIN CATCH
        DECLARE @failMsg NVARCHAR(4000) = ERROR_MESSAGE();
        IF @@TRANCOUNT > 0 ROLLBACK;
        INSERT INTO #qa3_fail VALUES (@failMsg);
        RAISERROR(N'%s', 16, 1, @failMsg);
        RETURN;
    END CATCH;
    IF @@TRANCOUNT > 0 ROLLBACK;
END;
GO
DECLARE @paid NVARCHAR(200) = CONCAT(N'This period is paid ', NCHAR(8212), N' raise a payroll adjustment instead.');
EXEC #qa3_ledger_refusal 'leave-row',         N'This movement belongs to an approved leave request%retract or reopen it instead.';
EXEC #qa3_ledger_refusal 'year-row',          N'This movement was written when the leave year was opened%undo the year opening instead.';
EXEC #qa3_ledger_refusal 'exit-row',          N'This movement converts exit-permission time to leave%';
EXEC #qa3_ledger_refusal 'expiry-row',        N'This movement is the carry-over expiry%';
EXEC #qa3_ledger_refusal 'manual-accrual',    N'Only a manual adjustment can be deleted%';
EXEC #qa3_ledger_refusal 'manual-usage-paid', @paid;
GO

IF EXISTS (SELECT 1 FROM #qa3_fail) RAISERROR('ledger: FAILED (see above).', 16, 1);
ELSE PRINT 'ok ledger';
DROP PROCEDURE #qa3_ledger_refusal;
DROP PROCEDURE #qa3_ledger_seed;
GO
