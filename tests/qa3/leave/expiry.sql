/* ============================================================================
   tests/qa3/leave/expiry.sql -- QA3 LEV-6 (docs/99_qa3_leave.sql): carried-over days expire right.
   - a discretionary grant consumes no carried day (its usage and give-back net to zero);
   - leave dated before the expiry but posted after it is given back by a correcting line; a second run adds nothing;
   - once the expiry month is paid for the employee the expiry is final;
   - a leave over a mid-month expiry date counts only its days up to that date;
   - '02-29' is 28 February in a year without one; a value that is not MM-DD expires nothing and says so (@Problem).
   Runs on a real dev database inside one transaction that is rolled back; seeded rows start with 'QA3 ' and use 2097.
   Prints 'ok expiry', or raises the first wrong result. Needs 99.
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
SET QUOTED_IDENTIFIER ON;
GO
BEGIN TRAN;
BEGIN TRY
    DECLARE @msg NVARCHAR(2000), @p NVARCHAR(300), @got DECIMAL(9,2);
    DECLARE @x TABLE (EmployeesExpired INT, DaysExpired DECIMAL(9,2));
    INSERT INTO hr.BRANCH (Name, IsActive) VALUES (N'QA3 Expiry Branch', 1);
    DECLARE @B INT = SCOPE_IDENTITY();
    DECLARE @Dep INT = (SELECT TOP 1 DepartmentId FROM hr.DEPARTMENT ORDER BY DepartmentId);
    DECLARE @Pos INT = (SELECT TOP 1 PositionId FROM hr.[POSITION] ORDER BY PositionId);
    DECLARE @User INT = (SELECT TOP 1 UserId FROM security.[USER] WHERE IsActive = 1 ORDER BY UserId);
    INSERT INTO hr.LEAVE_TYPE (Name, IsPaid, AccrualPerMonth, CarryOver, RequiresCertificate, MinServiceMonthsToUse, NoticePreferredDays, FixedEntitlementDays, IsDiscretionary, IsActive)
    VALUES (N'QA3 Annual', 1, 0, 1, 0, 0, 0, NULL, 0, 1);
    DECLARE @A INT = SCOPE_IDENTITY();
    INSERT INTO hr.EMPLOYEE (BranchId, DepartmentId, PositionId, FullName, HireDate, TerminationDate, ApprovalTier, PreferredLanguage)
    SELECT @B, @Dep, @Pos, CONCAT(N'QA3 Expiry E', n), '2020-01-01', NULL, 5, 'en' FROM (VALUES (1),(2),(3),(4),(5)) v(n);
    DECLARE @E1 INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Expiry E1'),
            @E2 INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Expiry E2'),
            @E3 INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Expiry E3'),
            @E4 INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Expiry E4'),
            @E5 INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Expiry E5');
    /* everybody carried 5 days into 2097 (E4: 4) and was granted 15 */
    INSERT INTO hr.LEAVE_LEDGER (EmployeeId, LeaveTypeId, PeriodYearMonth, MovementType, Days, EffectiveDate, Note)
    SELECT e.EmployeeId, @A, '2097-01', 'CarryOver', CASE WHEN e.EmployeeId = @E4 THEN 4 ELSE 5 END, '2097-01-01', N'QA3 carried'
    FROM hr.EMPLOYEE e WHERE e.FullName LIKE N'QA3 Expiry E%'
    UNION ALL
    SELECT e.EmployeeId, @A, '2097-01', 'Accrual', 15, '2097-01-01', N'QA3 granted'
    FROM hr.EMPLOYEE e WHERE e.FullName LIKE N'QA3 Expiry E%';
    DECLARE @T INT = (SELECT RequestTypeId FROM workflow.REQUEST_TYPE WHERE Code = 'LEAVE_REQUEST');
    DECLARE @Def INT = (SELECT TOP 1 WorkflowDefinitionId FROM workflow.WORKFLOW_DEFINITION WHERE RequestTypeId = @T
                        ORDER BY CASE WHEN [Status] = 'Active' THEN 0 ELSE 1 END, WorkflowDefinitionId DESC);
    DECLARE @rid INT;

    /* 1. E1: a 3-day DISCRETIONARY leave in February consumes nothing: all 5 carried days expire */
    INSERT INTO workflow.REQUEST_INSTANCE (RequestTypeId, WorkflowDefinitionId, EmployeeId, RaisedByUserId, [Status], Title, ClosedAt)
    VALUES (@T, @Def, @E1, @User, 'Approved', N'QA3 expiry discretionary', SYSUTCDATETIME());
    SET @rid = SCOPE_IDENTITY();
    INSERT INTO workflow.LEAVE_REQUEST (RequestInstanceId, EmployeeId, LeaveTypeId, FromDate, ToDate, DaysRequested, DaysApproved, IsDiscretionary)
    VALUES (@rid, @E1, @A, '2097-02-11', '2097-02-13', 3, 3, 1);
    EXEC hr.usp_LeaveLedger_PostRequest @RequestInstanceId = @rid, @ActorUserId = @User;
    INSERT INTO @x EXEC hr.usp_LeaveCarryOver_Expire @AsOfDate = '2097-04-01', @ExpiresOn = '03-31', @EmployeeId = @E1, @Problem = @p OUTPUT;
    SET @got = (SELECT SUM(Days) FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E1 AND MovementType = 'Expiry');
    IF @got <> -5 BEGIN SET @msg = CONCAT('FAIL expiry (1): a discretionary leave consumes no carried day: -5 expected; got ', ISNULL(CAST(@got AS VARCHAR(20)), 'none')); RAISERROR(@msg, 16, 1); END

    /* 2. E2: nothing used by 31 March -> 5 expire on 1 April; a half day dated 20 March is posted on 3 April (an exit
          permission converted at the period close) -> the 5 April run gives it back; a third run adds nothing */
    DELETE FROM @x;
    INSERT INTO @x EXEC hr.usp_LeaveCarryOver_Expire @AsOfDate = '2097-04-01', @ExpiresOn = '03-31', @EmployeeId = @E2, @Problem = @p OUTPUT;
    INSERT INTO hr.LEAVE_LEDGER (EmployeeId, LeaveTypeId, PeriodYearMonth, MovementType, Days, EffectiveDate, Note, SourceType, SourceRef)
    VALUES (@E2, @A, '2097-03', 'Usage', -0.5, '2097-03-20', N'QA3 exit permission converted to leave', 'ExitPermission', -1);
    DELETE FROM @x;
    INSERT INTO @x EXEC hr.usp_LeaveCarryOver_Expire @AsOfDate = '2097-04-05', @ExpiresOn = '03-31', @EmployeeId = @E2, @Problem = @p OUTPUT;
    IF (SELECT DaysExpired FROM @x) <> -0.5 RAISERROR('FAIL expiry (2): the run after the late posting should report -0.5 (half a day given back).', 16, 1);
    DELETE FROM @x;
    INSERT INTO @x EXEC hr.usp_LeaveCarryOver_Expire @AsOfDate = '2097-04-06', @ExpiresOn = '03-31', @EmployeeId = @E2, @Problem = @p OUTPUT;
    SET @got = (SELECT SUM(Days) FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E2 AND MovementType = 'Expiry');
    IF @got <> -4.5 OR (SELECT COUNT(*) FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E2 AND MovementType = 'Expiry') <> 2
    BEGIN
        SET @msg = CONCAT('FAIL expiry (2): 5 expired then 0.5 given back = -4.5 in two lines; got ', ISNULL(CAST(@got AS VARCHAR(20)), 'none'), ' in ',
                          (SELECT COUNT(*) FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E2 AND MovementType = 'Expiry'), ' line(s)');
        RAISERROR(@msg, 16, 1);
    END

    /* 3. E5: the same late half day, but March is already paid for E5: the expiry stays final */
    DELETE FROM @x;
    INSERT INTO @x EXEC hr.usp_LeaveCarryOver_Expire @AsOfDate = '2097-04-01', @ExpiresOn = '03-31', @EmployeeId = @E5, @Problem = @p OUTPUT;
    DECLARE @Run INT = (SELECT PayrollRunId FROM payroll.PAYROLL_RUN WHERE PeriodYearMonth = '2097-03' AND RunType = 'Primary' AND [Status] <> 'Cancelled');
    IF @Run IS NULL
    BEGIN
        INSERT INTO payroll.PAYROLL_RUN (PeriodYearMonth, PeriodStart, PeriodEnd, PrimaryCurrency, Notes, CreatedByUserId, RunType, [Status])
        VALUES ('2097-03', '2097-03-01', '2097-03-31', 'USD', N'QA3 paid March', @User, 'Primary', 'Approved');
        SET @Run = SCOPE_IDENTITY();
    END
    ELSE UPDATE payroll.PAYROLL_RUN SET [Status] = 'Approved' WHERE PayrollRunId = @Run;
    INSERT INTO payroll.PAYSLIP (PayrollRunId, EmployeeId, EmployeeName) VALUES (@Run, @E5, N'QA3 Expiry E5');
    INSERT INTO hr.LEAVE_LEDGER (EmployeeId, LeaveTypeId, PeriodYearMonth, MovementType, Days, EffectiveDate, Note, SourceType, SourceRef)
    VALUES (@E5, @A, '2097-03', 'Usage', -0.5, '2097-03-20', N'QA3 exit permission converted to leave', 'ExitPermission', -2);
    DELETE FROM @x;
    INSERT INTO @x EXEC hr.usp_LeaveCarryOver_Expire @AsOfDate = '2097-04-05', @ExpiresOn = '03-31', @EmployeeId = @E5, @Problem = @p OUTPUT;
    IF (SELECT SUM(Days) FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E5 AND MovementType = 'Expiry') <> -5
        RAISERROR('FAIL expiry (3): the expiry month is paid for E5, the expiry must stay -5.', 16, 1);

    /* 4. E3: expiry 03-15; a 5-day leave 13-17 March (no roster: every day a working day) used 3 carried days by the 15th:
          2 expire (a monthly usage row dated the 13th used to count all 5) */
    INSERT INTO workflow.REQUEST_INSTANCE (RequestTypeId, WorkflowDefinitionId, EmployeeId, RaisedByUserId, [Status], Title, ClosedAt)
    VALUES (@T, @Def, @E3, @User, 'Approved', N'QA3 expiry mid-month', SYSUTCDATETIME());
    SET @rid = SCOPE_IDENTITY();
    INSERT INTO workflow.LEAVE_REQUEST (RequestInstanceId, EmployeeId, LeaveTypeId, FromDate, ToDate, DaysRequested, DaysApproved, IsDiscretionary)
    VALUES (@rid, @E3, @A, '2097-03-13', '2097-03-17', 5, 5, 0);
    EXEC hr.usp_LeaveLedger_PostRequest @RequestInstanceId = @rid, @ActorUserId = @User;
    DELETE FROM @x;
    INSERT INTO @x EXEC hr.usp_LeaveCarryOver_Expire @AsOfDate = '2097-03-20', @ExpiresOn = '03-15', @EmployeeId = @E3, @Problem = @p OUTPUT;
    SET @got = (SELECT SUM(Days) FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E3 AND MovementType = 'Expiry');
    IF @got <> -2 OR (SELECT MIN(EffectiveDate) FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E3 AND MovementType = 'Expiry') <> '2097-03-15'
    BEGIN SET @msg = CONCAT('FAIL expiry (4): a mid-month expiry counts the days up to it: -2 on 2097-03-15 expected; got ', ISNULL(CAST(@got AS VARCHAR(20)), 'none')); RAISERROR(@msg, 16, 1); END

    /* 5. E4: '02-29' in 2097 (no 29 February) is 28 February */
    DELETE FROM @x;
    INSERT INTO @x EXEC hr.usp_LeaveCarryOver_Expire @AsOfDate = '2097-03-01', @ExpiresOn = '02-29', @EmployeeId = @E4, @Problem = @p OUTPUT;
    IF NOT EXISTS (SELECT 1 FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E4 AND MovementType = 'Expiry' AND Days = -4 AND EffectiveDate = '2097-02-28')
        RAISERROR('FAIL expiry (5): 02-29 in a year without it should expire on 28 February.', 16, 1);

    /* 6. a value that is not MM-DD expires nothing and says why */
    DECLARE @rows INT = (SELECT COUNT(*) FROM hr.LEAVE_LEDGER WHERE MovementType = 'Expiry' AND EmployeeId IN (@E1, @E2, @E3, @E4, @E5));
    DELETE FROM @x;
    INSERT INTO @x EXEC hr.usp_LeaveCarryOver_Expire @AsOfDate = '2097-12-31', @ExpiresOn = '13-45', @Problem = @p OUTPUT;
    IF @p IS NULL OR @p NOT LIKE N'%"13-45" is not a MM-DD date%' OR (SELECT EmployeesExpired FROM @x) <> 0
        RAISERROR('FAIL expiry (6): ''13-45'' must expire nothing and explain itself in @Problem.', 16, 1);
    DELETE FROM @x;
    INSERT INTO @x EXEC hr.usp_LeaveCarryOver_Expire @AsOfDate = '2097-12-31', @ExpiresOn = '3-31', @Problem = @p OUTPUT;
    IF @p IS NULL OR (SELECT COUNT(*) FROM hr.LEAVE_LEDGER WHERE MovementType = 'Expiry' AND EmployeeId IN (@E1, @E2, @E3, @E4, @E5)) <> @rows
        RAISERROR('FAIL expiry (6): ''3-31'' is not MM-DD: nothing expires.', 16, 1);

    PRINT 'ok expiry';
END TRY
BEGIN CATCH
    DECLARE @e NVARCHAR(4000) = ERROR_MESSAGE();
    IF @@TRANCOUNT > 0 ROLLBACK;
    RAISERROR(N'%s', 16, 1, @e);
END CATCH;
IF @@TRANCOUNT > 0 ROLLBACK;
GO
