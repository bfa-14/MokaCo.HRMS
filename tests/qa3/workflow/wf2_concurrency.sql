/* QA3 workflow scenario (wf2_concurrency): WF-2: decisions under lock - the single-session half (the two-session races are manual, below) */
/* Runs on a real dev database (MokaCo_HRMS_Dev) or a stand-in: every phase is ONE transaction that is
   rolled back at the end of its phase (a refusal raised under XACT_ABORT dooms the transaction it is caught in, so a
   phase checks at most one refusal, last); rows are seeded with a 'QA3 ' prefix. A wrong result RAISERRORs (run with sqlcmd -I -b);
   success prints 'ok wf2_concurrency'. Needs docs/101_qa3_workflow.sql (and 99). */
SET NOCOUNT ON; SET XACT_ABORT OFF; SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON;
GO
IF OBJECT_ID('tempdb..#ctx') IS NOT NULL DROP TABLE #ctx;
CREATE TABLE #ctx (k VARCHAR(40) PRIMARY KEY, v INT);
GO
/* ---- helpers for this session only (temporary procedures) ---- */
IF OBJECT_ID('tempdb..#QA3_Check') IS NOT NULL DROP PROCEDURE #QA3_Check;
IF OBJECT_ID('tempdb..#QA3_Chain') IS NOT NULL DROP PROCEDURE #QA3_Chain;
IF OBJECT_ID('tempdb..#QA3_NewRequest') IS NOT NULL DROP PROCEDURE #QA3_NewRequest;
IF OBJECT_ID('tempdb..#QA3_Approve') IS NOT NULL DROP PROCEDURE #QA3_Approve;
GO
/* a wrong result stops the scenario with its sentence (sqlcmd -b); the open transaction dies with the session */
CREATE PROCEDURE #QA3_Check @Ok BIT, @What NVARCHAR(400) AS
BEGIN
    IF ISNULL(@Ok, 0) = 0 BEGIN RAISERROR(N'QA3 FAILED: %s', 16, 1, @What); RETURN 1; END
    RETURN 0;
END;
GO
/* a fresh ACTIVE chain for a type (the type's other active chains of that population retire inside the transaction):
   one or two Role steps, optionally adjustable */
CREATE PROCEDURE #QA3_Chain @Code VARCHAR(30), @Role1 INT, @Role2 INT = NULL, @Adjust1 BIT = 0, @Adjust2 BIT = 0,
                            @Tier INT = NULL, @DefId INT OUTPUT AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM workflow.REQUEST_TYPE WHERE Code = @Code)
        INSERT INTO workflow.REQUEST_TYPE (Code, Name) VALUES (@Code, CONCAT(N'QA3 ', @Code));
    DECLARE @T INT = (SELECT RequestTypeId FROM workflow.REQUEST_TYPE WHERE Code = @Code);
    UPDATE workflow.REQUEST_TYPE SET IsActive = 1 WHERE RequestTypeId = @T;
    UPDATE workflow.WORKFLOW_DEFINITION SET [Status] = 'Retired'
    WHERE RequestTypeId = @T AND [Status] = 'Active' AND ISNULL(MinRequesterTier, -1) = ISNULL(@Tier, -1);
    INSERT INTO workflow.WORKFLOW_DEFINITION (RequestTypeId, [Version], [Status], MinRequesterTier)
    VALUES (@T, ISNULL((SELECT MAX([Version]) FROM workflow.WORKFLOW_DEFINITION WHERE RequestTypeId = @T), 0) + 1, 'Active', @Tier);
    SET @DefId = SCOPE_IDENTITY();
    INSERT INTO workflow.WORKFLOW_STEP (WorkflowDefinitionId, StepNo, Name, ApproverType, ApproverRoleId, CanAdjust)
    VALUES (@DefId, 1, N'QA3 step 1', 'Role', @Role1, @Adjust1);
    IF @Role2 IS NOT NULL
        INSERT INTO workflow.WORKFLOW_STEP (WorkflowDefinitionId, StepNo, Name, ApproverType, ApproverRoleId, CanAdjust)
        VALUES (@DefId, 2, N'QA3 step 2', 'Role', @Role2, @Adjust2);
END;
GO
/* a request on the type's active default chain, standing on step 1 (usp_Request_Submit's materialised chain) */
CREATE PROCEDURE #QA3_NewRequest @Code VARCHAR(30), @EmployeeId INT, @RaisedBy INT, @Rid INT OUTPUT AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @T INT, @D INT;
    SELECT TOP 1 @T = t.RequestTypeId, @D = d.WorkflowDefinitionId
    FROM workflow.REQUEST_TYPE t
    JOIN workflow.WORKFLOW_DEFINITION d ON d.RequestTypeId = t.RequestTypeId AND d.[Status] = 'Active'
    WHERE t.Code = @Code
    ORDER BY CASE WHEN d.MinRequesterTier IS NULL THEN 0 ELSE 1 END, d.[Version] DESC;
    INSERT INTO workflow.REQUEST_INSTANCE (RequestTypeId, WorkflowDefinitionId, EmployeeId, RaisedByUserId, [Status], CurrentStepNo, Title)
    VALUES (@T, @D, @EmployeeId, @RaisedBy, 'Pending', 1, CONCAT(N'QA3 ', @Code));
    SET @Rid = SCOPE_IDENTITY();
    INSERT INTO workflow.REQUEST_STEP_INSTANCE (RequestInstanceId, StepNo, Name, ApproverType, ApproverRoleId, [Status])
    SELECT @Rid, s.StepNo, s.Name, s.ApproverType, s.ApproverRoleId, 'Pending'
    FROM workflow.WORKFLOW_STEP s WHERE s.WorkflowDefinitionId = @D;
    INSERT INTO workflow.WORKFLOW_SIGNATURE (RequestInstanceId, StepNo, [Action], ActedByUserId) VALUES (@Rid, NULL, 'Submitted', @RaisedBy);
END;
GO
/* what a typed _Decide does: the engine under INSERT...EXEC, then the effects when the request closed approved */
CREATE PROCEDURE #QA3_Approve @Rid INT, @User INT, @Comment NVARCHAR(1000) = NULL, @ChangeSummary NVARCHAR(300) = NULL,
                              @Status VARCHAR(20) = NULL OUTPUT AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @r TABLE (RequestInstanceId INT, [Status] VARCHAR(20), CurrentStepNo INT, ClosedReason NVARCHAR(300),
                      Decision VARCHAR(25), SignedAsDeputy BIT, SignedWithPassword BIT);
    INSERT INTO @r EXEC workflow.usp_Request_Approve @RequestInstanceId = @Rid, @ActedByUserId = @User,
         @Comment = @Comment, @ChangeSummary = @ChangeSummary, @SignedWithPassword = 1;
    SET @Status = (SELECT TOP 1 [Status] FROM @r);
    IF @Status = 'Approved'
        EXEC workflow.usp_Request_ApplyApprovalEffects @RequestInstanceId = @Rid, @ActorUserId = @User;
END;
GO
/* what the base usp_Request_Reject commits for a rejection that ends the request (its live body is not in the repo) */
IF OBJECT_ID('tempdb..#QA3_Reject') IS NOT NULL DROP PROCEDURE #QA3_Reject;
GO
CREATE PROCEDURE #QA3_Reject @Rid INT, @User INT AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Step INT = (SELECT CurrentStepNo FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId = @Rid);
    UPDATE workflow.REQUEST_STEP_INSTANCE SET [Status] = 'Rejected', Decision = 'Rejected', ActedByUserId = @User, ActedAt = SYSUTCDATETIME(), Comment = N'QA3 no'
    WHERE RequestInstanceId = @Rid AND StepNo = @Step;
    INSERT INTO workflow.WORKFLOW_SIGNATURE (RequestInstanceId, StepNo, [Action], ActedByUserId, Comment) VALUES (@Rid, @Step, 'Rejected', @User, N'QA3 no');
    UPDATE workflow.REQUEST_INSTANCE SET [Status] = 'Rejected', CurrentStepNo = NULL, ClosedAt = SYSUTCDATETIME(), ClosedReason = N'QA3 no'
    WHERE RequestInstanceId = @Rid;
END;
GO
/* the people of every phase: QA3 users with the HR / Owner / General Manager roles and two employees
   (called inside each phase's transaction, so it all rolls back with it) */
IF OBJECT_ID('tempdb..#QA3_Seed') IS NOT NULL DROP PROCEDURE #QA3_Seed;
GO
CREATE PROCEDURE #QA3_Seed AS
BEGIN
    SET NOCOUNT ON;
    DELETE FROM #ctx;
    DECLARE @Pw NVARCHAR(200) = N'QA3 not a password hash';
    INSERT INTO security.[USER] (Username, PasswordHash, IsActive)
    VALUES (N'QA3 hr1', @Pw, 1), (N'QA3 hr2', @Pw, 1), (N'QA3 owner', @Pw, 1), (N'QA3 gm', @Pw, 1), (N'QA3 emp', @Pw, 1), (N'QA3 mgr', @Pw, 1);
    DECLARE @rHR INT = (SELECT RoleId FROM security.[ROLE] WHERE Name = N'HR'),
            @rOwner INT = (SELECT RoleId FROM security.[ROLE] WHERE Name = N'Owner'),
            @rGM INT = (SELECT TOP 1 RoleId FROM security.[ROLE] WHERE Name IN (N'General Manager', N'GeneralManager') ORDER BY RoleId);
    IF @rHR IS NULL OR @rOwner IS NULL OR @rGM IS NULL
    BEGIN RAISERROR(N'QA3 seed: the roles HR, Owner and General Manager must exist.', 16, 1); RETURN 1; END
    INSERT INTO security.USER_ROLE (UserId, RoleId)
    SELECT u.UserId, CASE u.Username WHEN N'QA3 owner' THEN @rOwner WHEN N'QA3 gm' THEN @rGM ELSE @rHR END
    FROM security.[USER] u WHERE u.Username IN (N'QA3 hr1', N'QA3 hr2', N'QA3 owner', N'QA3 gm');
    DECLARE @Branch INT = (SELECT TOP 1 BranchId FROM hr.BRANCH ORDER BY BranchId),
            @Dept INT = (SELECT TOP 1 DepartmentId FROM hr.DEPARTMENT ORDER BY DepartmentId),
            @Pos INT = (SELECT TOP 1 PositionId FROM hr.[POSITION] ORDER BY PositionId);
    INSERT INTO hr.EMPLOYEE (UserId, BranchId, DepartmentId, PositionId, FullName, HireDate, Email)
    SELECT UserId, @Branch, @Dept, @Pos, N'QA3 Employee', '2020-01-01', N'qa3.employee@example.invalid' FROM security.[USER] WHERE Username = N'QA3 emp';
    INSERT INTO hr.EMPLOYEE (UserId, BranchId, DepartmentId, PositionId, FullName, HireDate, Email)
    SELECT UserId, @Branch, @Dept, @Pos, N'QA3 Second', '2020-01-01', N'qa3.second@example.invalid' FROM security.[USER] WHERE Username = N'QA3 mgr';
    INSERT INTO #ctx (k, v)
    SELECT REPLACE(Username, N'QA3 ', N''), UserId FROM security.[USER] WHERE Username LIKE N'QA3 %'
    UNION ALL SELECT 'empId', EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Employee'
    UNION ALL SELECT 'emp2Id', EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Second'
    UNION ALL SELECT 'rHR', @rHR UNION ALL SELECT 'rOwner', @rOwner UNION ALL SELECT 'rGM', @rGM UNION ALL SELECT 'branch', @Branch;
    RETURN 0;
END;
GO
/* for the leave phases: a leave chain of HR then the Owner, both may adjust (every other active leave chain retires
   inside the phase's transaction). An unpaid type (no balance to seed) and a Mon-Fri roster for one week of June 2097. */
IF OBJECT_ID('tempdb..#QA3_LeaveSetup') IS NOT NULL DROP PROCEDURE #QA3_LeaveSetup;
GO
CREATE PROCEDURE #QA3_LeaveSetup @LeaveTypeId INT OUTPUT, @Mon DATE OUTPUT AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @emp INT = (SELECT v FROM #ctx WHERE k = 'empId'), @rHR INT = (SELECT v FROM #ctx WHERE k = 'rHR'),
            @rOwner INT = (SELECT v FROM #ctx WHERE k = 'rOwner'), @def INT;
    UPDATE workflow.WORKFLOW_DEFINITION SET [Status] = 'Retired'
    WHERE [Status] = 'Active' AND RequestTypeId = (SELECT RequestTypeId FROM workflow.REQUEST_TYPE WHERE Code = 'LEAVE_REQUEST');
    EXEC #QA3_Chain 'LEAVE_REQUEST', @rHR, @rOwner, 1, 1, NULL, @def OUTPUT;
    INSERT INTO attendance.SHIFT (Name, StartTime, EndTime, GraceMinutes, CrossesMidnight, BreakMinutes, IsActive)
    VALUES (N'QA3 WF4 Day', '08:00', '16:00', NULL, 0, 30, 1);
    DECLARE @Shift INT = SCOPE_IDENTITY();
    INSERT INTO hr.LEAVE_TYPE (Name, IsPaid, AccrualPerMonth, CarryOver, RequiresCertificate, MinServiceMonthsToUse, NoticePreferredDays,
                               FixedEntitlementDays, IsDiscretionary, IsActive)
    VALUES (N'QA3 WF4 Unpaid', 0, 0, 0, 0, 0, 0, NULL, 0, 1);
    SET @LeaveTypeId = SCOPE_IDENTITY();
    SET @Mon = '2097-06-01';
    WHILE DATEDIFF(DAY, '19000101', @Mon) % 7 <> 0 SET @Mon = DATEADD(DAY, 1, @Mon);      -- a Monday
    INSERT INTO attendance.SHIFT_ASSIGNMENT (EmployeeId, ShiftId, WorkDate, IsRestDay)
    SELECT @emp, CASE WHEN v.n < 5 THEN @Shift END, DATEADD(DAY, v.n, @Mon), CASE WHEN v.n < 5 THEN 0 ELSE 1 END
    FROM (VALUES (0), (1), (2), (3), (4), (5), (6)) v(n);
END;
GO
/* MANUAL TWO-SESSION CHECKS (run on a stand-in, never on live data; each needs three sqlcmd sessions started together):
   A. Two HR users approve the SAME step (exit permission, HR -> Owner, request R on step 1).
        session 0: BEGIN TRAN; UPDATE security.USER_ROLE SET RoleId = RoleId WHERE UserId = <hr2>; WAITFOR DELAY '00:00:05'; COMMIT;
        session B (start 1 s later):  EXEC workflow.usp_Request_Approve @RequestInstanceId = R, @ActedByUserId = <hr2>, @ExpectedStepNo = 1;
        session A (0.3 s after B):    EXEC workflow.usp_Request_Approve @RequestInstanceId = R, @ActedByUserId = <hr1>, @ExpectedStepNo = 1;
      Expected: one of them approves step 1; the other is refused "This step was decided a moment ago - reload." (with
      @ExpectedStepNo) or "You are not the approver for this step." (without); step 1 carries ONE 'Approved' signature.
      Before 101 both succeeded and step 1 had two signatures.
   B. The requester cancels while the Owner's final approval is in flight (salary advance, HR signed step 1).
        session 0: hold the Owner's USER_ROLE row for 5 s (as in A);
        session B: INSERT...EXEC workflow.usp_Request_Approve (Owner, signed) then usp_Request_ApplyApprovalEffects when Approved;
        session A (1 s later): the cancel's UPDATE ... WHERE [Status] = 'Pending'.
      Expected: the cancel waits for the approval's lock and then updates 0 rows; the request is Approved with ONE
      advance. Before 101 the cancel committed first and the approval then overwrote it: Approved after Cancelled.
   (The scripted versions used for QA3 are race32.sh / race33.sh in the unit's scratchpad.) */

/* ---------------- phase 1: the step the caller decided is no longer the current one ---------------- */
BEGIN TRAN;
EXEC #QA3_Seed;
DECLARE @hr1 INT = (SELECT v FROM #ctx WHERE k = 'hr1'), @hr2 INT = (SELECT v FROM #ctx WHERE k = 'hr2'),
        @emp INT = (SELECT v FROM #ctx WHERE k = 'empId'), @uEmp INT = (SELECT v FROM #ctx WHERE k = 'emp'),
        @rHR INT = (SELECT v FROM #ctx WHERE k = 'rHR');
DECLARE @def INT, @rid INT, @ok BIT, @err NVARCHAR(400), @what NVARCHAR(400);
EXEC #QA3_Chain 'EXIT_PERMISSION', @rHR, @rHR, @DefId = @def OUTPUT;           -- HR at both steps: the dangerous chain
EXEC #QA3_NewRequest 'EXIT_PERMISSION', @emp, @uEmp, @rid OUTPUT;
EXEC #QA3_Approve @rid, @hr1;                                                   -- hr1 decided step 1 a moment ago
DECLARE @r TABLE (RequestInstanceId INT, [Status] VARCHAR(20), CurrentStepNo INT, ClosedReason NVARCHAR(300), Decision VARCHAR(25), SignedAsDeputy BIT, SignedWithPassword BIT);
BEGIN TRY INSERT INTO @r EXEC workflow.usp_Request_Approve @RequestInstanceId = @rid, @ActedByUserId = @hr2, @ExpectedStepNo = 1, @SignedWithPassword = 1; END TRY
BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
SET @what = CONCAT(N'hr2''s click on step 1 does not approve step 2 - got: ', ISNULL(@err, N'accepted'));
SET @ok = CASE WHEN @err = N'This step was decided a moment ago ' + NCHAR(8212) + N' reload.'
                AND EXISTS (SELECT 1 FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId = @rid AND [Status] = 'Pending' AND CurrentStepNo = 2)
                AND NOT EXISTS (SELECT 1 FROM workflow.REQUEST_STEP_INSTANCE WHERE RequestInstanceId = @rid AND StepNo = 2 AND [Status] <> 'Pending') THEN 1 ELSE 0 END;
EXEC #QA3_Check @ok, @what;
IF @@TRANCOUNT > 0 ROLLBACK;
GO

/* ---------------- phase 2: a request closed a moment ago says so; one closed long ago says it is closed ---------------- */
BEGIN TRAN;
EXEC #QA3_Seed;
DECLARE @hr1 INT = (SELECT v FROM #ctx WHERE k = 'hr1'), @emp INT = (SELECT v FROM #ctx WHERE k = 'empId'), @uEmp INT = (SELECT v FROM #ctx WHERE k = 'emp'),
        @rHR INT = (SELECT v FROM #ctx WHERE k = 'rHR'), @rOwner INT = (SELECT v FROM #ctx WHERE k = 'rOwner');
DECLARE @def INT, @rid INT, @ok BIT, @err NVARCHAR(400), @what NVARCHAR(400);
EXEC #QA3_Chain 'EXIT_PERMISSION', @rHR, @rOwner, @DefId = @def OUTPUT;
EXEC #QA3_NewRequest 'EXIT_PERMISSION', @emp, @uEmp, @rid OUTPUT;
UPDATE workflow.REQUEST_INSTANCE SET [Status] = 'Cancelled', CurrentStepNo = NULL, ClosedAt = DATEADD(HOUR, -5, SYSUTCDATETIME()) WHERE RequestInstanceId = @rid;
DECLARE @r TABLE (RequestInstanceId INT, [Status] VARCHAR(20), CurrentStepNo INT, ClosedReason NVARCHAR(300), Decision VARCHAR(25), SignedAsDeputy BIT, SignedWithPassword BIT);
BEGIN TRY INSERT INTO @r EXEC workflow.usp_Request_Approve @RequestInstanceId = @rid, @ActedByUserId = @hr1, @SignedWithPassword = 1; END TRY
BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
SET @what = CONCAT(N'a request closed hours ago is "already closed" - got: ', ISNULL(@err, N'accepted'));
SET @ok = CASE WHEN @err = N'This request is already closed.' THEN 1 ELSE 0 END;
EXEC #QA3_Check @ok, @what;
IF @@TRANCOUNT > 0 ROLLBACK;
GO
BEGIN TRAN;
EXEC #QA3_Seed;
DECLARE @hr1 INT = (SELECT v FROM #ctx WHERE k = 'hr1'), @emp INT = (SELECT v FROM #ctx WHERE k = 'empId'), @uEmp INT = (SELECT v FROM #ctx WHERE k = 'emp'),
        @rHR INT = (SELECT v FROM #ctx WHERE k = 'rHR'), @rOwner INT = (SELECT v FROM #ctx WHERE k = 'rOwner');
DECLARE @def INT, @rid INT, @ok BIT, @err NVARCHAR(400), @what NVARCHAR(400);
EXEC #QA3_Chain 'EXIT_PERMISSION', @rHR, @rOwner, @DefId = @def OUTPUT;
EXEC #QA3_NewRequest 'EXIT_PERMISSION', @emp, @uEmp, @rid OUTPUT;
UPDATE workflow.REQUEST_INSTANCE SET [Status] = 'Cancelled', CurrentStepNo = NULL, ClosedAt = SYSUTCDATETIME() WHERE RequestInstanceId = @rid;
DECLARE @r TABLE (RequestInstanceId INT, [Status] VARCHAR(20), CurrentStepNo INT, ClosedReason NVARCHAR(300), Decision VARCHAR(25), SignedAsDeputy BIT, SignedWithPassword BIT);
BEGIN TRY INSERT INTO @r EXEC workflow.usp_Request_Approve @RequestInstanceId = @rid, @ActedByUserId = @hr1, @SignedWithPassword = 1; END TRY
BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
SET @what = CONCAT(N'a request cancelled a moment ago is reported as decided a moment ago - got: ', ISNULL(@err, N'accepted'));
SET @ok = CASE WHEN @err = N'This step was decided a moment ago ' + NCHAR(8212) + N' reload.' THEN 1 ELSE 0 END;
EXEC #QA3_Check @ok, @what;
IF @@TRANCOUNT > 0 ROLLBACK;
GO

/* ---------------- phase 3: every deciding procedure locks the request row before it reads it ---------------- */
DECLARE @missing NVARCHAR(400) = (
    SELECT STRING_AGG(o.name, N', ')
    FROM sys.objects o JOIN sys.sql_modules m ON m.object_id = o.object_id
    WHERE SCHEMA_NAME(o.schema_id) = 'workflow'
      AND o.name IN ('usp_Request_Approve', 'usp_Request_RetractLastDecision', 'usp_Request_Reopen', 'usp_Request_ReopenClosed',
                     'usp_Request_WithdrawDecision', 'usp_Request_MoveToVersion')
      AND m.definition NOT LIKE N'%FROM workflow.REQUEST_INSTANCE%WITH (UPDLOCK, ROWLOCK)%');
IF @missing IS NOT NULL RAISERROR(N'QA3 FAILED: these decisions read the request without locking it: %s', 16, 1, @missing);
GO
PRINT 'ok wf2_concurrency';
GO
