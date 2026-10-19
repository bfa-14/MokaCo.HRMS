/* ============================================================================
   tests/qa3/leave/guards.sql -- QA3 LEV-11 / WF-16, REL-4, LEV-13, LEV-12, LEV-7 / WF-4, convention 4 (docs/99_qa3_leave.sql).
   - the preview counts as create stores: a half day of a fixed-entitlement type is 0.5; it reports the days promised to
     pending requests and whether the balance is enforced;
   - a decision writes ValueBefore = '<standing days>|<discretionary>' on the step it decided, and a partial approval
     (where the chain lets the step adjust) ends the leave on its last granted day;
   - create refuses an inactive type, dates after the employee's termination, a period already paid; the service gate
     counts whole months; decide refuses a paid period and dates after termination, and writes nothing then.
   Runs on a real dev database: each phase is one transaction that is rolled back (a refusal under XACT_ABORT dooms the
   transaction it is caught in, so each phase ends with at most one). Seeded rows start with 'QA3 ', dates are in 2097.
   Prints 'ok guards', or raises the first wrong result. Needs 99.
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
SET QUOTED_IDENTIFIER ON;
GO
IF OBJECT_ID('tempdb..#qa3_fail') IS NOT NULL DROP TABLE #qa3_fail;
CREATE TABLE #qa3_fail (Msg NVARCHAR(4000));
IF OBJECT_ID('tempdb..#qa3_guard_seed') IS NOT NULL DROP PROCEDURE #qa3_guard_seed;
IF OBJECT_ID('tempdb..#qa3_guard_paid') IS NOT NULL DROP PROCEDURE #qa3_guard_paid;
IF OBJECT_ID('tempdb..#qa3_guard_approver') IS NOT NULL DROP PROCEDURE #qa3_guard_approver;
GO
/* 'QA3 Annual' (paid, tier 0: 30 days, 30 granted), 'QA3 Fixed' (70 calendar days), 'QA3 Unpaid', 'QA3 Gone' (inactive),
   'QA3 Gated' (usable after 1 month of service); E1 hired 2020 with a Mon-Fri roster in May-July 2097; E2 hired 15 Jan 2097 */
CREATE PROCEDURE #qa3_guard_seed
    @E1 INT OUTPUT, @E2 INT OUTPUT, @Annual INT OUTPUT, @Fixed INT OUTPUT, @Unpaid INT OUTPUT, @Gone INT OUTPUT, @Gated INT OUTPUT,
    @User INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO hr.BRANCH (Name, IsActive) VALUES (N'QA3 Guard Branch', 1);
    DECLARE @B INT = SCOPE_IDENTITY();
    DECLARE @Dep INT = (SELECT TOP 1 DepartmentId FROM hr.DEPARTMENT ORDER BY DepartmentId);
    DECLARE @Pos INT = (SELECT TOP 1 PositionId FROM hr.[POSITION] ORDER BY PositionId);
    SET @User = (SELECT TOP 1 UserId FROM security.[USER] WHERE IsActive = 1 ORDER BY UserId);
    INSERT INTO attendance.SHIFT (Name, StartTime, EndTime, GraceMinutes, CrossesMidnight, BreakMinutes, IsActive)
    VALUES (N'QA3 Day', '08:00', '16:00', NULL, 0, 30, 1);
    DECLARE @Shift INT = SCOPE_IDENTITY();
    INSERT INTO hr.LEAVE_TYPE (Name, IsPaid, CarryOver, RequiresCertificate, MinServiceMonthsToUse, NoticePreferredDays, FixedEntitlementDays, IsDiscretionary, IsActive)
    VALUES (N'QA3 Annual', 1, 1, 0, 0, 0, NULL, 0, 1), (N'QA3 Fixed', 1, 0, 0, 0, 0, 70, 0, 1),
           (N'QA3 Unpaid', 0, 0, 0, 0, 0, NULL, 0, 1), (N'QA3 Gone', 1, 0, 0, 0, 0, NULL, 0, 0),
           (N'QA3 Gated', 0, 0, 0, 1, 0, NULL, 0, 1);
    SET @Annual = (SELECT LeaveTypeId FROM hr.LEAVE_TYPE WHERE Name = N'QA3 Annual');
    SET @Fixed = (SELECT LeaveTypeId FROM hr.LEAVE_TYPE WHERE Name = N'QA3 Fixed');
    SET @Unpaid = (SELECT LeaveTypeId FROM hr.LEAVE_TYPE WHERE Name = N'QA3 Unpaid');
    SET @Gone = (SELECT LeaveTypeId FROM hr.LEAVE_TYPE WHERE Name = N'QA3 Gone');
    SET @Gated = (SELECT LeaveTypeId FROM hr.LEAVE_TYPE WHERE Name = N'QA3 Gated');
    INSERT INTO hr.LEAVE_ACCRUAL_TIER (LeaveTypeId, MinServiceYears, AnnualDays) VALUES (@Annual, 0, 30);
    INSERT INTO hr.EMPLOYEE (BranchId, DepartmentId, PositionId, FullName, HireDate, TerminationDate, ApprovalTier, PreferredLanguage)
    VALUES (@B, @Dep, @Pos, N'QA3 Guard E1', '2020-01-01', NULL, 5, 'en'), (@B, @Dep, @Pos, N'QA3 Guard E2', '2097-01-15', NULL, 5, 'en');
    SET @E1 = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Guard E1');
    SET @E2 = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Guard E2');
    INSERT INTO hr.LEAVE_LEDGER (EmployeeId, LeaveTypeId, PeriodYearMonth, MovementType, Days, EffectiveDate, Note)
    VALUES (@E1, @Annual, '2097-01', 'Accrual', 30, '2097-01-01', N'QA3 granted');
    DECLARE @d DATE = '2097-05-01';
    WHILE @d <= '2097-07-31'
    BEGIN
        INSERT INTO attendance.SHIFT_ASSIGNMENT (EmployeeId, ShiftId, WorkDate, IsRestDay)
        VALUES (@E1, CASE WHEN DATEDIFF(DAY, '19000101', @d) % 7 < 5 THEN @Shift END, @d, CASE WHEN DATEDIFF(DAY, '19000101', @d) % 7 < 5 THEN 0 ELSE 1 END);
        SET @d = DATEADD(DAY, 1, @d);
    END
END;
GO
/* a month paid for an employee: the month's live Primary run, approved, with a payslip for them */
CREATE PROCEDURE #qa3_guard_paid @Emp INT, @Ym CHAR(7), @User INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Run INT = (SELECT PayrollRunId FROM payroll.PAYROLL_RUN WHERE PeriodYearMonth = @Ym AND RunType = 'Primary' AND [Status] <> 'Cancelled');
    IF @Run IS NULL
    BEGIN
        INSERT INTO payroll.PAYROLL_RUN (PeriodYearMonth, PeriodStart, PeriodEnd, PrimaryCurrency, Notes, CreatedByUserId, RunType, [Status])
        VALUES (@Ym, CAST(@Ym + '-01' AS DATE), EOMONTH(CAST(@Ym + '-01' AS DATE)), 'USD', N'QA3 paid month', @User, 'Primary', 'Approved');
        SET @Run = SCOPE_IDENTITY();
    END
    ELSE UPDATE payroll.PAYROLL_RUN SET [Status] = 'Approved' WHERE PayrollRunId = @Run;
    INSERT INTO payroll.PAYSLIP (PayrollRunId, EmployeeId, EmployeeName) VALUES (@Run, @Emp, N'QA3 paid');
END;
GO
/* who may sign the request's current step (NULL: nobody can, or the request is closed) */
CREATE PROCEDURE #qa3_guard_approver @Rid INT, @Approver INT OUTPUT, @CanAdjust BIT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Step INT, @Def INT;
    SELECT @Step = CurrentStepNo, @Def = WorkflowDefinitionId FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId = @Rid AND [Status] IN ('Pending', 'OnHold');
    DECLARE @Si INT = (SELECT RequestStepInstanceId FROM workflow.REQUEST_STEP_INSTANCE WHERE RequestInstanceId = @Rid AND StepNo = @Step);
    SET @Approver = (SELECT TOP 1 u.UserId FROM security.[USER] u WHERE u.IsActive = 1 AND @Si IS NOT NULL AND workflow.fn_CanUserActOnStep(@Si, u.UserId) = 1 ORDER BY u.UserId);
    SET @CanAdjust = ISNULL((SELECT CanAdjust FROM workflow.WORKFLOW_STEP WHERE WorkflowDefinitionId = @Def AND StepNo = @Step), 0);
END;
GO

/* ---------------- phase 1: the preview, a decision's ValueBefore, a partial approval through the chain ---------------- */
BEGIN TRAN;
BEGIN TRY
    DECLARE @E1 INT, @E2 INT, @Annual INT, @Fixed INT, @Unpaid INT, @Gone INT, @Gated INT, @User INT, @msg NVARCHAR(2000);
    EXEC #qa3_guard_seed @E1 OUTPUT, @E2 OUTPUT, @Annual OUTPUT, @Fixed OUTPUT, @Unpaid OUTPUT, @Gone OUTPUT, @Gated OUTPUT, @User OUTPUT;
    DECLARE @Mon DATE = '2097-05-04';
    WHILE DATEDIFF(DAY, '19000101', @Mon) % 7 <> 0 SET @Mon = DATEADD(DAY, 1, @Mon);
    DECLARE @Tue DATE = DATEADD(DAY, 1, @Mon), @Wed DATE = DATEADD(DAY, 2, @Mon), @Sat DATE = DATEADD(DAY, 5, @Mon), @Sun DATE = DATEADD(DAY, 6, @Mon);
    DECLARE @pv TABLE (CalendarDays INT, WorkingDays DECIMAL(9,1), RestDays INT, Holidays INT, CountsCalendarDays BIT, Balance DECIMAL(18,2),
                       PendingDays DECIMAL(9,1), BalanceEnforced BIT);

    /* the preview of a Mon-Sun week of QA3 Annual: 5 working days, 2 rest days, enforced */
    INSERT INTO @pv EXEC hr.usp_Leave_CountWorkingDays @EmployeeId = @E1, @LeaveTypeId = @Annual, @FromDate = @Mon, @ToDate = @Sun;
    IF NOT EXISTS (SELECT 1 FROM @pv WHERE WorkingDays = 5 AND RestDays = 2 AND BalanceEnforced = 1 AND Balance = 30 AND PendingDays = 0)
        RAISERROR('FAIL guards (preview): a Mon-Sun week of QA3 Annual should be 5 working days, 2 rest days, balance 30, nothing pending, enforced.', 16, 1);
    /* a half day of a fixed-entitlement type on a rest day: 0.5, as create stores it (it showed 1) */
    DELETE FROM @pv;
    INSERT INTO @pv EXEC hr.usp_Leave_CountWorkingDays @EmployeeId = @E1, @LeaveTypeId = @Fixed, @FromDate = @Sat, @ToDate = @Sat, @HalfDay = 'AM';
    IF (SELECT WorkingDays FROM @pv) <> 0.5
        RAISERROR('FAIL guards (preview): a half day of a fixed-entitlement type costs 0.5, as create stores it.', 16, 1);
    /* an unpaid type is not enforced */
    DELETE FROM @pv;
    INSERT INTO @pv EXEC hr.usp_Leave_CountWorkingDays @EmployeeId = @E1, @LeaveTypeId = @Unpaid, @FromDate = @Mon, @ToDate = @Mon;
    IF (SELECT BalanceEnforced FROM @pv) <> 0
        RAISERROR('FAIL guards (preview): the balance of an unpaid type is not enforced.', 16, 1);

    /* raise Mon-Wed of QA3 Annual: 3 days, pending */
    EXEC workflow.usp_LeaveRequest_Create @EmployeeId = @E1, @RaisedByUserId = @User, @LeaveTypeId = @Annual,
         @FromDate = @Mon, @ToDate = @Wed, @Reason = N'QA3 guards phase 1';
    DECLARE @rid INT = (SELECT TOP 1 RequestInstanceId FROM workflow.LEAVE_REQUEST WHERE EmployeeId = @E1 ORDER BY LeaveRequestId DESC);
    IF @rid IS NULL RAISERROR('FAIL guards (phase 1): the request was not created.', 16, 1);
    DECLARE @status VARCHAR(20) = (SELECT [Status] FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId = @rid);
    IF @status IN ('Pending', 'OnHold')
    BEGIN
        /* the preview now counts it as promised */
        DELETE FROM @pv;
        INSERT INTO @pv EXEC hr.usp_Leave_CountWorkingDays @EmployeeId = @E1, @LeaveTypeId = @Annual, @FromDate = @Mon, @ToDate = @Mon;
        IF (SELECT PendingDays FROM @pv) <> 3
            RAISERROR('FAIL guards (preview): the 3 days of the pending request should show as PendingDays.', 16, 1);

        DECLARE @appr INT, @adj BIT, @step INT = (SELECT CurrentStepNo FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId = @rid), @n INT = 0;
        EXEC #qa3_guard_approver @rid, @appr OUTPUT, @adj OUTPUT;
        IF @appr IS NULL PRINT 'guards: note: nobody can sign the first step of the leave chain here; the decision checks are skipped.';
        ELSE
        BEGIN
            DECLARE @grant DECIMAL(9,1) = CASE WHEN @adj = 1 THEN 2 ELSE NULL END;    -- 2 of 3 where the step may adjust
            EXEC workflow.usp_LeaveRequest_Decide @RequestInstanceId = @rid, @ActedByUserId = @appr, @ApprovedDays = @grant,
                 @Comment = N'QA3 decision', @SignedWithPassword = 1;
            IF (SELECT ValueBefore FROM workflow.REQUEST_STEP_INSTANCE WHERE RequestInstanceId = @rid AND StepNo = @step) <> '3.0|0'
            BEGIN
                SET @msg = CONCAT('FAIL guards (LEV-7): the decided step should hold ValueBefore ''3.0|0''; holds ',
                                  ISNULL((SELECT ValueBefore FROM workflow.REQUEST_STEP_INSTANCE WHERE RequestInstanceId = @rid AND StepNo = @step), 'NULL'));
                RAISERROR(@msg, 16, 1);
            END
            /* sign the rest of the chain as it stands */
            WHILE @n < 6 AND EXISTS (SELECT 1 FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId = @rid AND [Status] IN ('Pending', 'OnHold'))
            BEGIN
                EXEC #qa3_guard_approver @rid, @appr OUTPUT, @adj OUTPUT;
                IF @appr IS NULL BREAK;
                EXEC workflow.usp_LeaveRequest_Decide @RequestInstanceId = @rid, @ActedByUserId = @appr,
                     @Comment = N'QA3 decision', @SignedWithPassword = 1;
                SET @n += 1;
            END
            IF (SELECT [Status] FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId = @rid) = 'Approved'
               AND (SELECT ApprovedToDate FROM workflow.LEAVE_REQUEST WHERE RequestInstanceId = @rid) <> CASE WHEN @grant = 2 THEN @Tue ELSE @Wed END
                RAISERROR('FAIL guards (LEV-2): the approved leave does not end on its last granted day.', 16, 1);
        END
    END
    ELSE PRINT 'guards: note: the leave chain approved the request at once here; the decision checks are skipped.';

    /* LEV-12: whole months. E2 (hired 15 Jan 2097) has 1 whole month on 15 February: QA3 Gated (1 month) is accepted */
    EXEC workflow.usp_LeaveRequest_Create @EmployeeId = @E2, @RaisedByUserId = @User, @LeaveTypeId = @Gated,
         @FromDate = '2097-02-16', @ToDate = '2097-02-16', @Reason = N'QA3 one whole month';
    IF NOT EXISTS (SELECT 1 FROM workflow.LEAVE_REQUEST WHERE EmployeeId = @E2)
        RAISERROR('FAIL guards (LEV-12): 1 whole month of service on 16 February should pass a 1-month gate.', 16, 1);
END TRY
BEGIN CATCH
    DECLARE @e NVARCHAR(4000) = ERROR_MESSAGE();
    IF @@TRANCOUNT > 0 ROLLBACK;
    INSERT INTO #qa3_fail VALUES (@e);
    RAISERROR(N'%s', 16, 1, @e);
END CATCH;
IF @@TRANCOUNT > 0 ROLLBACK;
GO

/* ---------------- phases 2-7: one refusal each ---------------- */
IF OBJECT_ID('tempdb..#qa3_refusal') IS NOT NULL DROP PROCEDURE #qa3_refusal;
GO
/* @Case: what to set up and refuse; @Expect: LIKE pattern of the refusal */
CREATE PROCEDURE #qa3_refusal @Case VARCHAR(20), @Expect NVARCHAR(400)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;
    DECLARE @E1 INT, @E2 INT, @Annual INT, @Fixed INT, @Unpaid INT, @Gone INT, @Gated INT, @User INT, @msg NVARCHAR(2000), @err NVARCHAR(2000);
    BEGIN TRAN;
    BEGIN TRY
        EXEC #qa3_guard_seed @E1 OUTPUT, @E2 OUTPUT, @Annual OUTPUT, @Fixed OUTPUT, @Unpaid OUTPUT, @Gone OUTPUT, @Gated OUTPUT, @User OUTPUT;
        DECLARE @rid INT, @appr INT, @adj BIT, @step INT;
        IF @Case IN ('decide-paid', 'decide-term')
        BEGIN
            EXEC workflow.usp_LeaveRequest_Create @EmployeeId = @E1, @RaisedByUserId = @User, @LeaveTypeId = @Unpaid,
                 @FromDate = '2097-07-06', @ToDate = '2097-07-08', @Reason = N'QA3 to decide';
            SET @rid = (SELECT TOP 1 RequestInstanceId FROM workflow.LEAVE_REQUEST WHERE EmployeeId = @E1 ORDER BY LeaveRequestId DESC);
            EXEC #qa3_guard_approver @rid, @appr OUTPUT, @adj OUTPUT;
            IF @appr IS NULL
            BEGIN
                PRINT CONCAT('guards: note: nobody can sign the leave chain here; the ', @Case, ' refusal is not checked.');
                ROLLBACK; RETURN;
            END
            SET @step = (SELECT CurrentStepNo FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId = @rid);
            IF @Case = 'decide-paid' EXEC #qa3_guard_paid @E1, '2097-07', @User;
            ELSE UPDATE hr.EMPLOYEE SET TerminationDate = '2097-07-07' WHERE EmployeeId = @E1;
            BEGIN TRY
                EXEC workflow.usp_LeaveRequest_Decide @RequestInstanceId = @rid, @ActedByUserId = @appr, @Comment = N'QA3 decision', @SignedWithPassword = 1;
            END TRY BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH;
            /* reads still work in a doomed transaction: nothing of the decision may be there */
            IF EXISTS (SELECT 1 FROM workflow.REQUEST_STEP_INSTANCE WHERE RequestInstanceId = @rid AND StepNo = @step AND ([Status] <> 'Pending' OR ValueBefore IS NOT NULL))
               OR EXISTS (SELECT 1 FROM workflow.LEAVE_REQUEST WHERE RequestInstanceId = @rid AND DaysApproved IS NOT NULL)
            BEGIN SET @msg = CONCAT('FAIL guards (', @Case, '): the refused decision wrote something.'); RAISERROR(@msg, 16, 1); END
        END
        ELSE
        BEGIN
            DECLARE @type INT = CASE @Case WHEN 'create-inactive' THEN @Gone WHEN 'create-gate' THEN @Gated ELSE @Unpaid END;
            DECLARE @emp INT = CASE @Case WHEN 'create-gate' THEN @E2 ELSE @E1 END;
            DECLARE @f DATE = CASE @Case WHEN 'create-gate' THEN '2097-02-14' WHEN 'create-paid' THEN '2097-06-08' ELSE '2097-05-11' END;
            IF @Case = 'create-term' UPDATE hr.EMPLOYEE SET TerminationDate = '2097-05-10' WHERE EmployeeId = @E1;
            IF @Case = 'create-paid' EXEC #qa3_guard_paid @E1, '2097-06', @User;
            BEGIN TRY
                EXEC workflow.usp_LeaveRequest_Create @EmployeeId = @emp, @RaisedByUserId = @User, @LeaveTypeId = @type,
                     @FromDate = @f, @ToDate = @f, @Reason = N'QA3 to be refused';
            END TRY BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH;
            IF EXISTS (SELECT 1 FROM workflow.LEAVE_REQUEST WHERE EmployeeId = @emp AND FromDate = @f)
            BEGIN SET @msg = CONCAT('FAIL guards (', @Case, '): the refused request was stored.'); RAISERROR(@msg, 16, 1); END
        END
        IF @err IS NULL OR @err NOT LIKE @Expect
        BEGIN
            SET @msg = CONCAT('FAIL guards (', @Case, '): expected a refusal like "', @Expect, '"; got: ', ISNULL(@err, 'accepted'));
            RAISERROR(@msg, 16, 1);
        END
    END TRY
    BEGIN CATCH
        DECLARE @e NVARCHAR(4000) = ERROR_MESSAGE();
        IF @@TRANCOUNT > 0 ROLLBACK;
        INSERT INTO #qa3_fail VALUES (@e);
        RAISERROR(N'%s', 16, 1, @e);
        RETURN;
    END CATCH;
    IF @@TRANCOUNT > 0 ROLLBACK;
END;
GO
DECLARE @paid NVARCHAR(200) = CONCAT(N'This period is paid ', NCHAR(8212), N' raise a payroll adjustment instead.');
EXEC #qa3_refusal 'create-inactive', N'QA3 Gone leave is no longer offered%';
EXEC #qa3_refusal 'create-term',     N'QA3 Guard E1 leaves on 2097-05-10; leave after that day cannot be taken.';
EXEC #qa3_refusal 'create-paid',     @paid;
EXEC #qa3_refusal 'create-gate',     N'QA3 Gated leave can be used after 1 months of service; this employee will have 0 at the start date.%';
EXEC #qa3_refusal 'decide-paid',     @paid;
EXEC #qa3_refusal 'decide-term',     N'QA3 Guard E1 leaves on 2097-07-07; leave after that day cannot be taken.';
GO

IF EXISTS (SELECT 1 FROM #qa3_fail) RAISERROR('guards: FAILED (see above).', 16, 1);
ELSE PRINT 'ok guards';
DROP PROCEDURE #qa3_refusal;
DROP PROCEDURE #qa3_guard_approver;
DROP PROCEDURE #qa3_guard_paid;
DROP PROCEDURE #qa3_guard_seed;
GO
