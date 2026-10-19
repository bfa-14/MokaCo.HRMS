/* QA3 workflow scenario (wf_reopen_rules): WF-14 and WF-6: who reopens what, and what a reopen re-checks */
/* Runs on a real dev database (MokaCo_HRMS_Dev) or a stand-in: every phase is ONE transaction that is
   rolled back at the end of its phase (a refusal raised under XACT_ABORT dooms the transaction it is caught in, so a
   phase checks at most one refusal, last); rows are seeded with a 'QA3 ' prefix. A wrong result RAISERRORs (run with sqlcmd -I -b);
   success prints 'ok wf_reopen_rules'. Needs docs/101_qa3_workflow.sql (and 99). */
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
/* ---------------- phase 1: WF-14 - each half of the GM + Owner reopen is password-signed ---------------- */
BEGIN TRAN;
EXEC #QA3_Seed;
DECLARE @hr1 INT = (SELECT v FROM #ctx WHERE k = 'hr1'), @owner INT = (SELECT v FROM #ctx WHERE k = 'owner'), @gm INT = (SELECT v FROM #ctx WHERE k = 'gm'),
        @emp INT = (SELECT v FROM #ctx WHERE k = 'empId'), @uEmp INT = (SELECT v FROM #ctx WHERE k = 'emp'),
        @rHR INT = (SELECT v FROM #ctx WHERE k = 'rHR'), @rOwner INT = (SELECT v FROM #ctx WHERE k = 'rOwner');
DECLARE @def INT, @rid INT, @st VARCHAR(20), @err NVARCHAR(400), @ok BIT, @what NVARCHAR(400);
EXEC #QA3_Chain 'OVERTIME', @rHR, @rOwner, @DefId = @def OUTPUT;
EXEC #QA3_NewRequest 'OVERTIME', @emp, @uEmp, @rid OUTPUT;
INSERT INTO workflow.OVERTIME_REQUEST (RequestInstanceId, EmployeeId, WorkDate, RequestedMinutes) VALUES (@rid, @emp, '2097-04-07', 60);
EXEC #QA3_Approve @rid, @hr1;
EXEC #QA3_Reject @rid, @owner;
BEGIN TRY EXEC workflow.usp_Request_Reopen @RequestInstanceId = @rid, @ActedByUserId = @gm, @Reason = N'QA3 wrong information'; END TRY
BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
SET @what = CONCAT(N'an unsigned half of a reopen is refused - got: ', ISNULL(@err, N'accepted'));
SET @ok = CASE WHEN @err LIKE N'%must be signed with your password%' AND NOT EXISTS (SELECT 1 FROM workflow.REQUEST_REVERSAL WHERE RequestInstanceId = @rid) THEN 1 ELSE 0 END;
EXEC #QA3_Check @ok, @what;
IF @@TRANCOUNT > 0 ROLLBACK;
GO

/* ---------------- phase 2: WF-14 - a request nobody signed (approved automatically) is refused at the FIRST half ---------------- */
BEGIN TRAN;
EXEC #QA3_Seed;
DECLARE @gm INT = (SELECT v FROM #ctx WHERE k = 'gm'), @emp INT = (SELECT v FROM #ctx WHERE k = 'empId'), @uEmp INT = (SELECT v FROM #ctx WHERE k = 'emp'),
        @rHR INT = (SELECT v FROM #ctx WHERE k = 'rHR'), @rOwner INT = (SELECT v FROM #ctx WHERE k = 'rOwner');
DECLARE @def INT, @rid INT, @err NVARCHAR(400), @ok BIT, @what NVARCHAR(400);
EXEC #QA3_Chain 'OVERTIME', @rHR, @rOwner, @DefId = @def OUTPUT;
EXEC #QA3_NewRequest 'OVERTIME', @emp, @uEmp, @rid OUTPUT;
INSERT INTO workflow.OVERTIME_REQUEST (RequestInstanceId, EmployeeId, WorkDate, RequestedMinutes) VALUES (@rid, @emp, '2097-04-07', 60);
UPDATE workflow.REQUEST_STEP_INSTANCE SET [Status] = 'Skipped', SkipReason = N'QA3 every step skipped' WHERE RequestInstanceId = @rid;
UPDATE workflow.REQUEST_INSTANCE SET [Status] = 'Approved', CurrentStepNo = NULL, ClosedAt = SYSUTCDATETIME(),
       ClosedReason = N'Approved automatically: every step was skipped.' WHERE RequestInstanceId = @rid;
BEGIN TRY EXEC workflow.usp_Request_Reopen @RequestInstanceId = @rid, @ActedByUserId = @gm, @Reason = N'QA3 should have been checked', @SignedWithPassword = 1; END TRY
BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
SET @what = CONCAT(N'no half-signed dead end: a request with no standing decision is refused at the first half - got: ', ISNULL(@err, N'accepted'));
SET @ok = CASE WHEN @err LIKE N'There is no decision to reverse%' AND NOT EXISTS (SELECT 1 FROM workflow.REQUEST_REVERSAL WHERE RequestInstanceId = @rid) THEN 1 ELSE 0 END;
EXEC #QA3_Check @ok, @what;
IF @@TRANCOUNT > 0 ROLLBACK;
GO

/* ---------------- phase 3: WF-14 - HR alone does not reopen a REJECTED request ---------------- */
BEGIN TRAN;
EXEC #QA3_Seed;
DECLARE @hr1 INT = (SELECT v FROM #ctx WHERE k = 'hr1'), @hr2 INT = (SELECT v FROM #ctx WHERE k = 'hr2'), @owner INT = (SELECT v FROM #ctx WHERE k = 'owner'),
        @emp INT = (SELECT v FROM #ctx WHERE k = 'empId'), @uEmp INT = (SELECT v FROM #ctx WHERE k = 'emp'),
        @rHR INT = (SELECT v FROM #ctx WHERE k = 'rHR'), @rOwner INT = (SELECT v FROM #ctx WHERE k = 'rOwner');
DECLARE @def INT, @rid INT, @err NVARCHAR(400), @ok BIT, @what NVARCHAR(400);
EXEC #QA3_Chain 'OVERTIME', @rHR, @rOwner, @DefId = @def OUTPUT;
EXEC #QA3_NewRequest 'OVERTIME', @emp, @uEmp, @rid OUTPUT;
INSERT INTO workflow.OVERTIME_REQUEST (RequestInstanceId, EmployeeId, WorkDate, RequestedMinutes) VALUES (@rid, @emp, '2097-04-07', 60);
EXEC #QA3_Approve @rid, @hr1;
EXEC #QA3_Reject @rid, @owner;
BEGIN TRY EXEC workflow.usp_Request_ReopenClosed @RequestInstanceId = @rid, @ActedByUserId = @hr2, @Reason = N'QA3 HR reopens'; END TRY
BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
SET @what = CONCAT(N'HR''s single-signature reopen refuses a rejected request - got: ', ISNULL(@err, N'accepted'));
SET @ok = CASE WHEN @err LIKE N'A rejected request is reopened by the General Manager and the Owner%'
                AND EXISTS (SELECT 1 FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId = @rid AND [Status] = 'Rejected') THEN 1 ELSE 0 END;
EXEC #QA3_Check @ok, @what;
IF @@TRANCOUNT > 0 ROLLBACK;
GO

/* ---------------- phase 4: WF-14 - HR reopens a CANCELLED request at the step still waiting, unsigning nothing ---------------- */
BEGIN TRAN;
EXEC #QA3_Seed;
DECLARE @hr1 INT = (SELECT v FROM #ctx WHERE k = 'hr1'), @hr2 INT = (SELECT v FROM #ctx WHERE k = 'hr2'),
        @emp INT = (SELECT v FROM #ctx WHERE k = 'empId'), @uEmp INT = (SELECT v FROM #ctx WHERE k = 'emp'),
        @rHR INT = (SELECT v FROM #ctx WHERE k = 'rHR'), @rOwner INT = (SELECT v FROM #ctx WHERE k = 'rOwner');
DECLARE @def INT, @rid INT, @ok BIT;
EXEC #QA3_Chain 'OVERTIME', @rHR, @rOwner, @DefId = @def OUTPUT;
EXEC #QA3_NewRequest 'OVERTIME', @emp, @uEmp, @rid OUTPUT;
INSERT INTO workflow.OVERTIME_REQUEST (RequestInstanceId, EmployeeId, WorkDate, RequestedMinutes) VALUES (@rid, @emp, '2097-04-07', 60);
EXEC #QA3_Approve @rid, @hr1;
UPDATE workflow.REQUEST_INSTANCE SET [Status] = 'Cancelled', CurrentStepNo = NULL, ClosedAt = SYSUTCDATETIME(), ClosedReason = N'QA3 cancelled' WHERE RequestInstanceId = @rid;
DECLARE @x TABLE (RequestInstanceId INT, [Status] VARCHAR(20), CurrentStepNo INT);
INSERT INTO @x EXEC workflow.usp_Request_ReopenClosed @RequestInstanceId = @rid, @ActedByUserId = @hr2, @Reason = N'QA3 cancelled by mistake';
SET @ok = CASE WHEN (SELECT [Status] FROM @x) = 'Pending' AND (SELECT CurrentStepNo FROM @x) = 2
                AND EXISTS (SELECT 1 FROM workflow.REQUEST_STEP_INSTANCE WHERE RequestInstanceId = @rid AND StepNo = 1 AND [Status] = 'Approved')
                AND EXISTS (SELECT 1 FROM workflow.WORKFLOW_SIGNATURE WHERE RequestInstanceId = @rid AND [Action] = 'Reopened') THEN 1 ELSE 0 END;
EXEC #QA3_Check @ok, N'HR reopens a cancelled request at step 2, keeping step 1''s approval';
IF @@TRANCOUNT > 0 ROLLBACK;
GO

/* ---------------- phase 5: WF-6 - a rejected leave is not reopened over the same dates approved since ---------------- */
BEGIN TRAN;
EXEC #QA3_Seed;
DECLARE @hr1 INT = (SELECT v FROM #ctx WHERE k = 'hr1'), @owner INT = (SELECT v FROM #ctx WHERE k = 'owner'), @gm INT = (SELECT v FROM #ctx WHERE k = 'gm'),
        @emp INT = (SELECT v FROM #ctx WHERE k = 'empId'), @uEmp INT = (SELECT v FROM #ctx WHERE k = 'emp'),
        @rHR INT = (SELECT v FROM #ctx WHERE k = 'rHR'), @rOwner INT = (SELECT v FROM #ctx WHERE k = 'rOwner');
DECLARE @def INT, @A INT, @B INT, @err NVARCHAR(400), @ok BIT, @what NVARCHAR(400);
DECLARE @Annual INT = (SELECT TOP 1 LeaveTypeId FROM hr.LEAVE_TYPE ORDER BY CASE WHEN Name = N'Annual' THEN 0 ELSE 1 END, LeaveTypeId);
EXEC #QA3_Chain 'LEAVE_REQUEST', @rHR, @rOwner, @DefId = @def OUTPUT;
EXEC #QA3_NewRequest 'LEAVE_REQUEST', @emp, @uEmp, @A OUTPUT;
INSERT INTO workflow.LEAVE_REQUEST (RequestInstanceId, EmployeeId, LeaveTypeId, FromDate, ToDate, DaysRequested) VALUES (@A, @emp, @Annual, '2097-04-01', '2097-04-02', 2);
EXEC #QA3_Approve @A, @hr1;
EXEC #QA3_Reject @A, @owner;
EXEC #QA3_NewRequest 'LEAVE_REQUEST', @emp, @uEmp, @B OUTPUT;
INSERT INTO workflow.LEAVE_REQUEST (RequestInstanceId, EmployeeId, LeaveTypeId, FromDate, ToDate, DaysRequested) VALUES (@B, @emp, @Annual, '2097-04-02', '2097-04-03', 2);
EXEC #QA3_Approve @B, @hr1;
EXEC #QA3_Approve @B, @owner;
BEGIN TRY EXEC workflow.usp_Request_Reopen @RequestInstanceId = @A, @ActedByUserId = @gm, @Reason = N'QA3 rejected on wrong information', @SignedWithPassword = 1; END TRY
BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
SET @what = CONCAT(N'the reopen re-checks the leave overlap at the first half - got: ', ISNULL(@err, N'accepted'));
SET @ok = CASE WHEN @err LIKE N'These dates overlap leave request #%(Approved)%' AND NOT EXISTS (SELECT 1 FROM workflow.REQUEST_REVERSAL WHERE RequestInstanceId = @A) THEN 1 ELSE 0 END;
EXEC #QA3_Check @ok, @what;
IF @@TRANCOUNT > 0 ROLLBACK;
GO

/* ---------------- phase 6: WF-6 - and at the SECOND half, for what was raised between the two signatures ---------------- */
BEGIN TRAN;
EXEC #QA3_Seed;
DECLARE @hr1 INT = (SELECT v FROM #ctx WHERE k = 'hr1'), @owner INT = (SELECT v FROM #ctx WHERE k = 'owner'), @gm INT = (SELECT v FROM #ctx WHERE k = 'gm'),
        @emp INT = (SELECT v FROM #ctx WHERE k = 'empId'), @uEmp INT = (SELECT v FROM #ctx WHERE k = 'emp'),
        @rHR INT = (SELECT v FROM #ctx WHERE k = 'rHR'), @rOwner INT = (SELECT v FROM #ctx WHERE k = 'rOwner');
DECLARE @def INT, @A INT, @B INT, @err NVARCHAR(400), @ok BIT, @what NVARCHAR(400);
EXEC #QA3_Chain 'OVERTIME', @rHR, @rOwner, @DefId = @def OUTPUT;
EXEC #QA3_NewRequest 'OVERTIME', @emp, @uEmp, @A OUTPUT;
INSERT INTO workflow.OVERTIME_REQUEST (RequestInstanceId, EmployeeId, WorkDate, RequestedMinutes) VALUES (@A, @emp, '2097-04-07', 60);
EXEC #QA3_Approve @A, @hr1;
EXEC #QA3_Reject @A, @owner;
DECLARE @half TABLE ([State] VARCHAR(20), FirstSignRole NVARCHAR(30));
INSERT INTO @half EXEC workflow.usp_Request_Reopen @RequestInstanceId = @A, @ActedByUserId = @gm, @Reason = N'QA3 wrong information', @SignedWithPassword = 1;
/* meanwhile another overtime request for the same date */
EXEC #QA3_NewRequest 'OVERTIME', @emp, @uEmp, @B OUTPUT;
INSERT INTO workflow.OVERTIME_REQUEST (RequestInstanceId, EmployeeId, WorkDate, RequestedMinutes) VALUES (@B, @emp, '2097-04-07', 90);
BEGIN TRY EXEC workflow.usp_Request_Reopen @RequestInstanceId = @A, @ActedByUserId = @owner, @Reason = NULL, @SignedWithPassword = 1; END TRY
BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
SET @what = CONCAT(N'the second half re-checks one overtime per date - got: ', ISNULL(@err, N'accepted'));
SET @ok = CASE WHEN (SELECT [State] FROM @half) = 'AwaitingSecond' AND @err LIKE N'An overtime request already exists for this employee on that date%'
                AND EXISTS (SELECT 1 FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId = @A AND [Status] = 'Rejected') THEN 1 ELSE 0 END;
EXEC #QA3_Check @ok, @what;
IF @@TRANCOUNT > 0 ROLLBACK;
GO

/* ---------------- phase 7: WF-6 - overlapping exit-permission windows ---------------- */
BEGIN TRAN;
EXEC #QA3_Seed;
DECLARE @hr1 INT = (SELECT v FROM #ctx WHERE k = 'hr1'), @owner INT = (SELECT v FROM #ctx WHERE k = 'owner'), @gm INT = (SELECT v FROM #ctx WHERE k = 'gm'),
        @emp INT = (SELECT v FROM #ctx WHERE k = 'empId'), @uEmp INT = (SELECT v FROM #ctx WHERE k = 'emp'),
        @rHR INT = (SELECT v FROM #ctx WHERE k = 'rHR'), @rOwner INT = (SELECT v FROM #ctx WHERE k = 'rOwner');
DECLARE @def INT, @A INT, @B INT, @err NVARCHAR(400), @ok BIT, @what NVARCHAR(400);
EXEC #QA3_Chain 'EXIT_PERMISSION', @rHR, @rOwner, @DefId = @def OUTPUT;
EXEC #QA3_NewRequest 'EXIT_PERMISSION', @emp, @uEmp, @A OUTPUT;
INSERT INTO workflow.EXIT_PERMISSION (RequestInstanceId, EmployeeId, ExitDate, FromTime, ToTime, RequestedMinutes, ApprovedMinutes, Reason, ConvertToLeave)
VALUES (@A, @emp, '2097-04-08', '11:00', '12:00', 60, 60, N'QA3 first', 0);
EXEC #QA3_Approve @A, @hr1;
EXEC #QA3_Reject @A, @owner;
EXEC #QA3_NewRequest 'EXIT_PERMISSION', @emp, @uEmp, @B OUTPUT;
INSERT INTO workflow.EXIT_PERMISSION (RequestInstanceId, EmployeeId, ExitDate, FromTime, ToTime, RequestedMinutes, ApprovedMinutes, Reason, ConvertToLeave)
VALUES (@B, @emp, '2097-04-08', '11:30', '12:30', 60, 60, N'QA3 second', 0);
BEGIN TRY EXEC workflow.usp_Request_Reopen @RequestInstanceId = @A, @ActedByUserId = @owner, @Reason = N'QA3 look again', @SignedWithPassword = 1; END TRY
BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
SET @what = CONCAT(N'the reopen re-checks overlapping exit windows - got: ', ISNULL(@err, N'accepted'));
SET @ok = CASE WHEN @err LIKE N'This employee already has a pending or approved exit permission that overlaps those times%' THEN 1 ELSE 0 END;
EXEC #QA3_Check @ok, @what;
IF @@TRANCOUNT > 0 ROLLBACK;
GO

/* ---------------- phase 8: WF-6 - one open roster request per branch-month ---------------- */
BEGIN TRAN;
EXEC #QA3_Seed;
DECLARE @hr1 INT = (SELECT v FROM #ctx WHERE k = 'hr1'), @owner INT = (SELECT v FROM #ctx WHERE k = 'owner'), @gm INT = (SELECT v FROM #ctx WHERE k = 'gm'),
        @emp INT = (SELECT v FROM #ctx WHERE k = 'empId'), @uEmp INT = (SELECT v FROM #ctx WHERE k = 'emp'), @branch INT = (SELECT v FROM #ctx WHERE k = 'branch'),
        @rHR INT = (SELECT v FROM #ctx WHERE k = 'rHR'), @rOwner INT = (SELECT v FROM #ctx WHERE k = 'rOwner');
DECLARE @def INT, @A INT, @B INT, @err NVARCHAR(400), @ok BIT, @what NVARCHAR(400);
EXEC #QA3_Chain 'ROSTER_APPROVAL', @rHR, @rOwner, @DefId = @def OUTPUT;
EXEC #QA3_NewRequest 'ROSTER_APPROVAL', @emp, @hr1, @A OUTPUT;
INSERT INTO workflow.ROSTER_APPROVAL (RequestInstanceId, BranchId, MonthDate) VALUES (@A, @branch, '2097-04-01');
EXEC #QA3_Approve @A, @hr1;
EXEC #QA3_Reject @A, @owner;
EXEC #QA3_NewRequest 'ROSTER_APPROVAL', @emp, @hr1, @B OUTPUT;
INSERT INTO workflow.ROSTER_APPROVAL (RequestInstanceId, BranchId, MonthDate) VALUES (@B, @branch, '2097-04-01');
BEGIN TRY EXEC workflow.usp_Request_Reopen @RequestInstanceId = @A, @ActedByUserId = @gm, @Reason = N'QA3 the old roster', @SignedWithPassword = 1; END TRY
BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
SET @what = CONCAT(N'the reopen re-checks one open roster request per branch-month - got: ', ISNULL(@err, N'accepted'));
SET @ok = CASE WHEN @err LIKE N'This roster is already waiting for approval (request #%' THEN 1 ELSE 0 END;
EXEC #QA3_Check @ok, @what;
IF @@TRANCOUNT > 0 ROLLBACK;
GO

/* ---------------- phase 9: WF-6 - HR's reopen of a cancelled leave re-checks the overlap too ---------------- */
BEGIN TRAN;
EXEC #QA3_Seed;
DECLARE @hr1 INT = (SELECT v FROM #ctx WHERE k = 'hr1'), @hr2 INT = (SELECT v FROM #ctx WHERE k = 'hr2'), @owner INT = (SELECT v FROM #ctx WHERE k = 'owner'),
        @emp INT = (SELECT v FROM #ctx WHERE k = 'empId'), @uEmp INT = (SELECT v FROM #ctx WHERE k = 'emp'),
        @rHR INT = (SELECT v FROM #ctx WHERE k = 'rHR'), @rOwner INT = (SELECT v FROM #ctx WHERE k = 'rOwner');
DECLARE @def INT, @A INT, @B INT, @err NVARCHAR(400), @ok BIT, @what NVARCHAR(400);
DECLARE @Annual INT = (SELECT TOP 1 LeaveTypeId FROM hr.LEAVE_TYPE ORDER BY CASE WHEN Name = N'Annual' THEN 0 ELSE 1 END, LeaveTypeId);
EXEC #QA3_Chain 'LEAVE_REQUEST', @rHR, @rOwner, @DefId = @def OUTPUT;
EXEC #QA3_NewRequest 'LEAVE_REQUEST', @emp, @uEmp, @A OUTPUT;
INSERT INTO workflow.LEAVE_REQUEST (RequestInstanceId, EmployeeId, LeaveTypeId, FromDate, ToDate, DaysRequested) VALUES (@A, @emp, @Annual, '2097-04-14', '2097-04-15', 2);
UPDATE workflow.REQUEST_INSTANCE SET [Status] = 'Cancelled', CurrentStepNo = NULL, ClosedAt = SYSUTCDATETIME(), ClosedReason = N'QA3 cancelled' WHERE RequestInstanceId = @A;
EXEC #QA3_NewRequest 'LEAVE_REQUEST', @emp, @uEmp, @B OUTPUT;
INSERT INTO workflow.LEAVE_REQUEST (RequestInstanceId, EmployeeId, LeaveTypeId, FromDate, ToDate, DaysRequested) VALUES (@B, @emp, @Annual, '2097-04-15', '2097-04-15', 1);
BEGIN TRY EXEC workflow.usp_Request_ReopenClosed @RequestInstanceId = @A, @ActedByUserId = @hr2, @Reason = N'QA3 cancelled by mistake'; END TRY
BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
SET @what = CONCAT(N'HR''s reopen of a cancelled leave re-checks the overlap - got: ', ISNULL(@err, N'accepted'));
SET @ok = CASE WHEN @err LIKE N'These dates overlap leave request #%(Pending)%'
                AND EXISTS (SELECT 1 FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId = @A AND [Status] = 'Cancelled') THEN 1 ELSE 0 END;
EXEC #QA3_Check @ok, @what;
IF @@TRANCOUNT > 0 ROLLBACK;
GO
PRINT 'ok wf_reopen_rules';
GO
