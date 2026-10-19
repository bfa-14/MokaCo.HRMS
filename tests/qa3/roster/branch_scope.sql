/* ============================================================================
   tests/qa3/roster/branch_scope.sql -- QA3 ROS-14, WF-7 (docs/102_qa3_roster.sql).
   A branch manager without EMP_VIEW_ALL changes and reads only the roster of the branches they manage (by the
   employee's branch of the day): set day, delete, generate, copy, apply patterns, clear, the month's status, the
   leave overlay, re-derive and submitting the month all refuse another branch with the auto-roster's sentence; HR
   (EMP_VIEW_ALL) may do all of it. A roster month submitted by somebody of another branch is signed at the
   branch-manager step by the ROSTER branch's manager, and stays raised by the submitter.
   Runs on a real dev database: everything inside one transaction that is rolled back; seeded rows start with 'QA3 '
   (users 'qa3.scope.*'). Uses next month. Prints 'ok branch_scope', or raises the first wrong result. Needs 99-102.
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
SET QUOTED_IDENTIFIER ON;
BEGIN TRAN;
BEGIN TRY
    DECLARE @msg NVARCHAR(2000), @err NVARCHAR(2000), @n INT;
    DECLARE @NotYours NVARCHAR(200) = N'You can only plan rosters for the branches you manage.';
    DECLARE @Today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE);
    DECLARE @CM DATE = DATEFROMPARTS(YEAR(@Today), MONTH(@Today), 1);
    DECLARE @NM DATE = DATEADD(MONTH, 1, @CM), @NMEnd DATE = EOMONTH(DATEADD(MONTH, 1, @CM));
    DECLARE @Day DATE = DATEADD(DAY, 9, @NM);
    DECLARE @Dep INT = (SELECT TOP 1 DepartmentId FROM hr.DEPARTMENT ORDER BY DepartmentId);
    DECLARE @Pos INT = (SELECT TOP 1 PositionId FROM hr.[POSITION] ORDER BY PositionId);

    INSERT INTO hr.BRANCH (Name, IsActive) VALUES (N'QA3 Scope Branch A', 1);
    DECLARE @BA INT = SCOPE_IDENTITY();
    INSERT INTO hr.BRANCH (Name, IsActive) VALUES (N'QA3 Scope Branch B', 1);
    DECLARE @BB INT = SCOPE_IDENTITY();
    INSERT INTO security.[USER] (Username, PasswordHash, IsActive)
    VALUES (N'qa3.scope.mgra', N'x', 1), (N'qa3.scope.mgrb', N'x', 1), (N'qa3.scope.hr', N'x', 1);
    DECLARE @UMgrA INT = (SELECT UserId FROM security.[USER] WHERE Username = N'qa3.scope.mgra');
    DECLARE @UMgrB INT = (SELECT UserId FROM security.[USER] WHERE Username = N'qa3.scope.mgrb');
    DECLARE @UHr   INT = (SELECT UserId FROM security.[USER] WHERE Username = N'qa3.scope.hr');
    INSERT INTO security.[ROLE] (Name) VALUES (N'QA3 Scope HR');
    DECLARE @RoleHr INT = SCOPE_IDENTITY();
    INSERT INTO security.ROLE_PERMISSION (RoleId, PermissionId) SELECT @RoleHr, PermissionId FROM security.PERMISSION WHERE Code = 'EMP_VIEW_ALL';
    INSERT INTO security.USER_ROLE (UserId, RoleId) VALUES (@UHr, @RoleHr);
    INSERT INTO hr.EMPLOYEE (UserId, BranchId, DepartmentId, PositionId, FullName, HireDate)
    VALUES (@UMgrA, @BA, @Dep, @Pos, N'QA3 Scope Manager A', '2020-01-01'),
           (@UMgrB, @BB, @Dep, @Pos, N'QA3 Scope Manager B', '2020-01-01'),
           (@UHr,   @BA, @Dep, @Pos, N'QA3 Scope HR Officer', '2020-01-01'),
           (NULL,   @BA, @Dep, @Pos, N'QA3 Scope Staff A', '2020-01-01'),
           (NULL,   @BB, @Dep, @Pos, N'QA3 Scope Staff B', '2020-01-01');
    DECLARE @MgrA INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Scope Manager A');
    DECLARE @MgrB INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Scope Manager B');
    DECLARE @HrE  INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Scope HR Officer');
    DECLARE @SA   INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Scope Staff A');
    DECLARE @SB   INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Scope Staff B');
    UPDATE hr.BRANCH SET ManagerEmployeeId = @MgrA WHERE BranchId = @BA;
    UPDATE hr.BRANCH SET ManagerEmployeeId = @MgrB WHERE BranchId = @BB;
    INSERT INTO attendance.SHIFT (Name, StartTime, EndTime, GraceMinutes, CrossesMidnight, BreakMinutes, IsActive)
    VALUES (N'QA3 Scope Day', '08:00', '16:00', NULL, 0, 30, 1);
    DECLARE @Sh INT = SCOPE_IDENTITY();

    /* staff B's current month (the source of a copy), a pattern, and one day of next month */
    DECLARE @d DATE = @CM;
    WHILE @d <= EOMONTH(@CM)
    BEGIN
        INSERT INTO attendance.SHIFT_ASSIGNMENT (EmployeeId, ShiftId, WorkDate, IsRestDay) VALUES (@SB, @Sh, @d, 0);
        SET @d = DATEADD(DAY, 1, @d);
    END
    INSERT INTO attendance.EMPLOYEE_SHIFT_PATTERN (EmployeeId, DayOfWeek, ShiftId, IsRestDay, IsActive)
    SELECT @SB, v.Dow, @Sh, 0, 1 FROM (VALUES (1), (2), (3), (4), (5), (6), (7)) v(Dow);
    INSERT INTO attendance.SHIFT_ASSIGNMENT (EmployeeId, ShiftId, WorkDate, IsRestDay) VALUES (@SB, @Sh, @Day, 0);
    DECLARE @RowB INT = SCOPE_IDENTITY();
    DECLARE @NMy INT = YEAR(@NM), @NMm INT = MONTH(@NM);
    DECLARE @src CHAR(7) = CONVERT(CHAR(7), @CM, 120), @tgt CHAR(7) = CONVERT(CHAR(7), @NM, 120);

    /* ---- manager A, on branch A: allowed ---- */
    DECLARE @ok TABLE (Id INT);
    INSERT INTO @ok EXEC attendance.usp_ShiftAssignment_Upsert @EmployeeId = @SA, @WorkDate = @Day, @ShiftId = @Sh, @IsRestDay = 0, @CallerUserId = @UMgrA;
    IF NOT EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId = @SA AND WorkDate = @Day)
        RAISERROR('FAIL branch_scope: the manager of branch A could not set a day of their own branch.', 16, 1);

    /* ---- manager A, on branch B: every door refuses with the sentence ---- */
    DECLARE @door VARCHAR(40);
    DECLARE @doors TABLE (Door VARCHAR(40), Err NVARCHAR(2000));
    SET @err = NULL; BEGIN TRY EXEC attendance.usp_ShiftAssignment_Upsert @EmployeeId = @SB, @WorkDate = @Day, @ShiftId = NULL, @IsRestDay = 1, @CallerUserId = @UMgrA; END TRY BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH;
    INSERT INTO @doors VALUES ('set day', @err);
    SET @err = NULL; BEGIN TRY EXEC attendance.usp_ShiftAssignment_Delete @ShiftAssignmentId = @RowB, @CallerUserId = @UMgrA; END TRY BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH;
    INSERT INTO @doors VALUES ('delete', @err);
    SET @err = NULL; BEGIN TRY EXEC attendance.usp_ShiftAssignment_GenerateRange @EmployeeId = @SB, @FromDate = @NM, @ToDate = @NMEnd, @ShiftId = @Sh, @Weekdays = '1111100', @Overwrite = 0, @CallerUserId = @UMgrA; END TRY BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH;
    INSERT INTO @doors VALUES ('generate', @err);
    SET @err = NULL; BEGIN TRY EXEC attendance.usp_ShiftAssignment_CopyPeriod @SourceYearMonth = @src, @TargetYearMonth = @tgt, @EmployeeId = NULL, @Overwrite = 0, @BranchId = @BB, @CallerUserId = @UMgrA; END TRY BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH;
    INSERT INTO @doors VALUES ('copy', @err);
    SET @err = NULL; BEGIN TRY EXEC attendance.usp_ShiftAssignment_ApplyPatternForMonth @YearMonth = @tgt, @EmployeeId = NULL, @Overwrite = 0, @BranchId = @BB, @CallerUserId = @UMgrA; END TRY BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH;
    INSERT INTO @doors VALUES ('apply patterns', @err);
    SET @err = NULL; BEGIN TRY EXEC attendance.usp_RosterMonth_Get @BranchId = @BB, @MonthDate = @NM, @CallerUserId = @UMgrA; END TRY BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH;
    INSERT INTO @doors VALUES ('month status', @err);
    SET @err = NULL; BEGIN TRY EXEC attendance.usp_Roster_RederiveMonth @BranchId = @BB, @Year = @NMy, @Month = @NMm, @CallerUserId = @UMgrA; END TRY BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH;
    INSERT INTO @doors VALUES ('re-derive', @err);
    IF @@TRANCOUNT = 0 RAISERROR('FAIL branch_scope: a refusal rolled the test back.', 16, 1);
    SELECT TOP 1 @door = Door, @err = Err FROM @doors WHERE Err IS NULL OR Err <> @NotYours ORDER BY Door;
    IF @door IS NOT NULL
    BEGIN SET @msg = CONCAT('FAIL branch_scope: manager A on branch B, ', @door, ': expected "', @NotYours, '", got ', ISNULL(@err, 'no refusal')); RAISERROR(@msg, 16, 1); END
    IF EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId = @SB AND WorkDate >= @NM AND ShiftAssignmentId <> @RowB)
        RAISERROR('FAIL branch_scope: a refused writer still wrote branch B''s roster.', 16, 1);

    /* ---- the leave overlay is scoped the same way ---- */
    DECLARE @LT INT = (SELECT RequestTypeId FROM workflow.REQUEST_TYPE WHERE Code = 'LEAVE_REQUEST');
    DECLARE @LDef INT = (SELECT TOP 1 WorkflowDefinitionId FROM workflow.WORKFLOW_DEFINITION WHERE RequestTypeId = @LT
                         ORDER BY CASE WHEN [Status] = 'Active' THEN 0 ELSE 1 END, WorkflowDefinitionId DESC);
    DECLARE @Annual INT = (SELECT TOP 1 LeaveTypeId FROM hr.LEAVE_TYPE ORDER BY CASE WHEN Name = N'Annual' THEN 0 ELSE 1 END, LeaveTypeId);
    INSERT INTO workflow.REQUEST_INSTANCE (RequestTypeId, WorkflowDefinitionId, EmployeeId, RaisedByUserId, [Status], Title, ClosedAt)
    VALUES (@LT, @LDef, @SB, @UHr, 'Approved', N'QA3 scope leave', SYSUTCDATETIME());
    INSERT INTO workflow.LEAVE_REQUEST (RequestInstanceId, EmployeeId, LeaveTypeId, FromDate, ToDate, DaysRequested, IsDiscretionary)
    VALUES (SCOPE_IDENTITY(), @SB, @Annual, @Day, @Day, 1, 0);
    DECLARE @lv TABLE (EmployeeId INT, [Date] DATE, DaysOnLeave DECIMAL(6,2));
    INSERT INTO @lv EXEC attendance.usp_Roster_GetLeaveDays @FromDate = @NM, @ToDate = @NMEnd, @BranchId = NULL, @CallerUserId = @UMgrA;
    IF EXISTS (SELECT 1 FROM @lv WHERE EmployeeId = @SB)
        RAISERROR('FAIL branch_scope: manager A sees branch B''s leave days.', 16, 1);
    DELETE FROM @lv;
    INSERT INTO @lv EXEC attendance.usp_Roster_GetLeaveDays @FromDate = @NM, @ToDate = @NMEnd, @BranchId = @BB, @CallerUserId = @UHr;
    IF NOT EXISTS (SELECT 1 FROM @lv WHERE EmployeeId = @SB AND [Date] = @Day AND DaysOnLeave = 1)
        RAISERROR('FAIL branch_scope: HR does not see branch B''s leave day.', 16, 1);

    /* ---- HR (EMP_VIEW_ALL): allowed on branch B ---- */
    DELETE FROM @ok;
    DECLARE @Day2 DATE = DATEADD(DAY, 1, @Day);
    INSERT INTO @ok EXEC attendance.usp_ShiftAssignment_Upsert @EmployeeId = @SB, @WorkDate = @Day2, @ShiftId = @Sh, @IsRestDay = 0, @CallerUserId = @UHr;
    IF NOT EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId = @SB AND WorkDate = @Day2)
        RAISERROR('FAIL branch_scope: HR could not set a day of branch B.', 16, 1);

    /* ---- WF-7: HR (branch A) submits branch B's month: branch B's manager signs, HR raised it ---- */
    IF EXISTS (SELECT 1 FROM workflow.REQUEST_TYPE rt JOIN workflow.WORKFLOW_DEFINITION d ON d.RequestTypeId = rt.RequestTypeId AND d.[Status] = 'Active'
               WHERE rt.Code = 'ROSTER_APPROVAL' AND rt.IsActive = 1)
    BEGIN
        /* (its one result set is not captured: it captures the engine's own, and INSERT...EXEC cannot be nested) */
        EXEC workflow.usp_RosterApproval_Create @EmployeeId = @HrE, @RaisedByUserId = @UHr, @BranchId = @BB, @MonthDate = @NM;
        IF @@TRANCOUNT = 0 RAISERROR('FAIL branch_scope: submitting rolled the test back.', 16, 1);
        DECLARE @Rid INT = (SELECT MAX(RequestInstanceId) FROM workflow.ROSTER_APPROVAL WHERE BranchId = @BB AND MonthDate = @NM);
        IF @Rid IS NULL OR NOT EXISTS (SELECT 1 FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId = @Rid AND RaisedByUserId = @UHr AND EmployeeId = @HrE)
            RAISERROR('FAIL branch_scope (WF-7): the request must stay raised by HR and filed against HR.', 16, 1);
        IF EXISTS (SELECT 1 FROM workflow.REQUEST_STEP_INSTANCE si
                   WHERE si.RequestInstanceId = @Rid AND si.ApproverType = 'BranchManager' AND ISNULL(si.ResolvedUserId, -1) <> @UMgrB)
        BEGIN
            SELECT @msg = CONCAT('FAIL branch_scope (WF-7): the branch-manager step must go to branch B''s manager (user ', @UMgrB, '); got user ',
                                 ISNULL(CAST((SELECT TOP 1 ResolvedUserId FROM workflow.REQUEST_STEP_INSTANCE
                                              WHERE RequestInstanceId = @Rid AND ApproverType = 'BranchManager') AS VARCHAR(12)), 'nobody'));
            RAISERROR(@msg, 16, 1);
        END
        IF EXISTS (SELECT 1 FROM workflow.REQUEST_STEP_INSTANCE si
                   WHERE si.RequestInstanceId = @Rid AND si.ApproverType = 'BranchManager' AND si.[Status] <> 'Pending')
            RAISERROR('FAIL branch_scope (WF-7): branch B''s manager has a step to sign - it must be pending.', 16, 1);
        IF NOT EXISTS (SELECT 1 FROM workflow.REQUEST_STEP_INSTANCE WHERE RequestInstanceId = @Rid AND ApproverType = 'BranchManager')
            PRINT 'note branch_scope: the ROSTER_APPROVAL chain on this database has no branch-manager step - WF-7 routing not exercised.';
    END
    ELSE PRINT 'note branch_scope: no active ROSTER_APPROVAL chain on this database - WF-7 not exercised.';

    ROLLBACK;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    DECLARE @failure NVARCHAR(4000) = ERROR_MESSAGE();
    RAISERROR(@failure, 16, 1);
END CATCH;
GO

/* Clear and Submit run with XACT_ABORT ON (as before 102): their refusal, caught here, leaves the test's transaction
   uncommittable - so each is checked last, in a transaction of its own, before anything is written. */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
SET QUOTED_IDENTIFIER ON;
DECLARE @door INT = 1;
WHILE @door <= 2
BEGIN
    BEGIN TRAN;
    BEGIN TRY
        DECLARE @msg NVARCHAR(2000), @err NVARCHAR(2000) = NULL;
        DECLARE @Today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE);
        DECLARE @NM DATE = DATEADD(MONTH, 1, DATEFROMPARTS(YEAR(@Today), MONTH(@Today), 1));
        DECLARE @NMy INT = YEAR(@NM), @NMm INT = MONTH(@NM);
        DECLARE @Dep INT = (SELECT TOP 1 DepartmentId FROM hr.DEPARTMENT ORDER BY DepartmentId);
        DECLARE @Pos INT = (SELECT TOP 1 PositionId FROM hr.[POSITION] ORDER BY PositionId);
        INSERT INTO hr.BRANCH (Name, IsActive) VALUES (N'QA3 Scope Branch A', 1);
        DECLARE @BA INT = SCOPE_IDENTITY();
        INSERT INTO hr.BRANCH (Name, IsActive) VALUES (N'QA3 Scope Branch B', 1);
        DECLARE @BB INT = SCOPE_IDENTITY();
        INSERT INTO security.[USER] (Username, PasswordHash, IsActive) VALUES (N'qa3.scope.mgra', N'x', 1);
        DECLARE @UMgrA INT = SCOPE_IDENTITY();
        INSERT INTO hr.EMPLOYEE (UserId, BranchId, DepartmentId, PositionId, FullName, HireDate)
        VALUES (@UMgrA, @BA, @Dep, @Pos, N'QA3 Scope Manager A', '2020-01-01'), (NULL, @BB, @Dep, @Pos, N'QA3 Scope Staff B', '2020-01-01');
        DECLARE @MgrA INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Scope Manager A');
        DECLARE @SB INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Scope Staff B');
        UPDATE hr.BRANCH SET ManagerEmployeeId = @MgrA WHERE BranchId = @BA;
        INSERT INTO attendance.SHIFT_ASSIGNMENT (EmployeeId, ShiftId, WorkDate, IsRestDay) VALUES (@SB, NULL, @NM, 1);
        IF @door = 1
            BEGIN TRY EXEC attendance.usp_Roster_Clear @BranchId = @BB, @Year = @NMy, @Month = @NMm, @UserId = @UMgrA; END TRY BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH;
        ELSE
            BEGIN TRY EXEC workflow.usp_RosterApproval_Create @EmployeeId = @MgrA, @RaisedByUserId = @UMgrA, @BranchId = @BB, @MonthDate = @NM; END TRY BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH;
        IF ISNULL(@err, N'') <> N'You can only plan rosters for the branches you manage.'
        BEGIN
            SET @msg = CONCAT('FAIL branch_scope: manager A on branch B, ', CASE @door WHEN 1 THEN 'clear' ELSE 'submit' END,
                              ': expected the scope refusal, got ', ISNULL(@err, 'no refusal'));
            RAISERROR(@msg, 16, 1);
        END
        IF @@TRANCOUNT > 0 ROLLBACK;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        DECLARE @failure NVARCHAR(4000) = ERROR_MESSAGE();
        RAISERROR(@failure, 16, 1);
        RETURN;
    END CATCH;
    SET @door = @door + 1;
END
PRINT 'ok branch_scope';
