/* QA3 workflow scenario (wf_undo_arms): WF-8, ATT-5, ROS-11, WF-16: what each reversal undoes, and which approvals cannot be taken back */
/* Runs on a real dev database (MokaCo_HRMS_Dev) or a stand-in: every phase is ONE transaction that is
   rolled back at the end of its phase (a refusal raised under XACT_ABORT dooms the transaction it is caught in, so a
   phase checks at most one refusal, last); rows are seeded with a 'QA3 ' prefix. A wrong result RAISERRORs (run with sqlcmd -I -b);
   success prints 'ok wf_undo_arms'. Needs docs/101_qa3_workflow.sql (and 99). */
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
/* ---------------- phase 1: ATT-5 + WF-8 - an exit permission is applied at its final approval and un-applied by a retract ---------------- */
BEGIN TRAN;
EXEC #QA3_Seed;
DECLARE @hr1 INT = (SELECT v FROM #ctx WHERE k = 'hr1'), @owner INT = (SELECT v FROM #ctx WHERE k = 'owner'),
        @emp INT = (SELECT v FROM #ctx WHERE k = 'empId'), @uEmp INT = (SELECT v FROM #ctx WHERE k = 'emp'),
        @rHR INT = (SELECT v FROM #ctx WHERE k = 'rHR'), @rOwner INT = (SELECT v FROM #ctx WHERE k = 'rOwner');
DECLARE @def INT, @rid INT, @ep INT, @ok BIT, @what NVARCHAR(400);
EXEC #QA3_Chain 'EXIT_PERMISSION', @rHR, @rOwner, @DefId = @def OUTPUT;
EXEC #QA3_NewRequest 'EXIT_PERMISSION', @emp, @uEmp, @rid OUTPUT;
INSERT INTO workflow.EXIT_PERMISSION (RequestInstanceId, EmployeeId, ExitDate, FromTime, ToTime, RequestedMinutes, ApprovedMinutes, Reason, ConvertToLeave)
VALUES (@rid, @emp, '2097-04-21', '11:00', '12:00', 60, 60, N'QA3 errand', 0);
SET @ep = SCOPE_IDENTITY();
/* the day already has a record (manual, so the day rule leaves its figures alone and only the links are under test) */
INSERT INTO attendance.ATTENDANCE_RECORD (EmployeeId, WorkDate, [Status], IsManual) VALUES (@emp, '2097-04-21', 'Present', 1);
EXEC #QA3_Approve @rid, @hr1;
/* the engine closes it - no typed decide, no nightly job */
DECLARE @r TABLE (RequestInstanceId INT, [Status] VARCHAR(20), CurrentStepNo INT, ClosedReason NVARCHAR(300), Decision VARCHAR(25), SignedAsDeputy BIT, SignedWithPassword BIT);
INSERT INTO @r EXEC workflow.usp_Request_Approve @RequestInstanceId = @rid, @ActedByUserId = @owner, @SignedWithPassword = 1;
SET @ok = CASE WHEN (SELECT [Status] FROM @r) = 'Approved'
                AND EXISTS (SELECT 1 FROM workflow.EXIT_PERMISSION WHERE ExitPermissionId = @ep AND AppliedToAttendanceAt IS NOT NULL)
                AND EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @emp AND WorkDate = '2097-04-21' AND ExitPermissionId = @ep) THEN 1 ELSE 0 END;
EXEC #QA3_Check @ok, N'the final approval applies the exit permission to its day (ATT-5)';
DECLARE @x TABLE (RequestInstanceId INT, [Status] VARCHAR(20), CurrentStepNo INT);
INSERT INTO @x EXEC workflow.usp_Request_RetractLastDecision @RequestInstanceId = @rid, @ActedByUserId = @owner, @Reason = N'QA3 wrong day', @SignedWithPassword = 1;
SET @ok = CASE WHEN EXISTS (SELECT 1 FROM workflow.EXIT_PERMISSION WHERE ExitPermissionId = @ep AND AppliedToAttendanceAt IS NULL)
                AND NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD WHERE ExitPermissionId = @ep) THEN 1 ELSE 0 END;
EXEC #QA3_Check @ok, N'the retract un-applies the exit permission and the day stops pointing at it';
IF @@TRANCOUNT > 0 ROLLBACK;
GO

/* ---------------- phase 2: WF-8 - the overtime minutes stamped on the worked day go with the approval ---------------- */
BEGIN TRAN;
EXEC #QA3_Seed;
DECLARE @hr1 INT = (SELECT v FROM #ctx WHERE k = 'hr1'), @owner INT = (SELECT v FROM #ctx WHERE k = 'owner'),
        @emp INT = (SELECT v FROM #ctx WHERE k = 'empId'), @uEmp INT = (SELECT v FROM #ctx WHERE k = 'emp'),
        @rHR INT = (SELECT v FROM #ctx WHERE k = 'rHR'), @rOwner INT = (SELECT v FROM #ctx WHERE k = 'rOwner');
DECLARE @def INT, @rid INT, @ot INT, @st VARCHAR(20), @ok BIT;
EXEC #QA3_Chain 'OVERTIME', @rHR, @rOwner, @DefId = @def OUTPUT;
EXEC #QA3_NewRequest 'OVERTIME', @emp, @uEmp, @rid OUTPUT;
INSERT INTO workflow.OVERTIME_REQUEST (RequestInstanceId, EmployeeId, WorkDate, RequestedMinutes) VALUES (@rid, @emp, '2097-04-22', 90);
SET @ot = SCOPE_IDENTITY();
INSERT INTO attendance.ATTENDANCE_RECORD (EmployeeId, WorkDate, [Status], IsManual) VALUES (@emp, '2097-04-22', 'Present', 1);
EXEC #QA3_Approve @rid, @hr1;
EXEC #QA3_Approve @rid, @owner, @Status = @st OUTPUT;
SET @ok = CASE WHEN @st = 'Approved'
                AND EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @emp AND WorkDate = '2097-04-22' AND OvertimeRequestId = @ot AND OvertimeApprovedMinutes = 90)
                AND EXISTS (SELECT 1 FROM workflow.OVERTIME_REQUEST WHERE OvertimeRequestId = @ot AND AppliedToAttendanceAt IS NOT NULL) THEN 1 ELSE 0 END;
EXEC #QA3_Check @ok, N'the approved overtime is stamped on its worked day';
DECLARE @x TABLE (RequestInstanceId INT, [Status] VARCHAR(20), CurrentStepNo INT);
INSERT INTO @x EXEC workflow.usp_Request_RetractLastDecision @RequestInstanceId = @rid, @ActedByUserId = @owner, @Reason = N'QA3 not needed', @SignedWithPassword = 1;
SET @ok = CASE WHEN NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD WHERE OvertimeRequestId = @ot)
                AND EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @emp AND WorkDate = '2097-04-22' AND OvertimeApprovedMinutes IS NULL)
                AND EXISTS (SELECT 1 FROM workflow.OVERTIME_REQUEST WHERE OvertimeRequestId = @ot AND AppliedToAttendanceAt IS NULL) THEN 1 ELSE 0 END;
EXEC #QA3_Check @ok, N'the retract takes the approved overtime minutes off the day';
IF @@TRANCOUNT > 0 ROLLBACK;
GO

/* ---------------- phase 3: ROS-11 - a retracted roster approval leaves the month pending (no earlier approval) ---------------- */
BEGIN TRAN;
EXEC #QA3_Seed;
DECLARE @hr1 INT = (SELECT v FROM #ctx WHERE k = 'hr1'), @owner INT = (SELECT v FROM #ctx WHERE k = 'owner'), @branch INT = (SELECT v FROM #ctx WHERE k = 'branch'),
        @emp INT = (SELECT v FROM #ctx WHERE k = 'empId'), @rHR INT = (SELECT v FROM #ctx WHERE k = 'rHR'), @rOwner INT = (SELECT v FROM #ctx WHERE k = 'rOwner');
DECLARE @def INT, @rid INT, @ok BIT, @what NVARCHAR(400);
EXEC #QA3_Chain 'ROSTER_APPROVAL', @rHR, @rOwner, @DefId = @def OUTPUT;
EXEC #QA3_NewRequest 'ROSTER_APPROVAL', @emp, @hr1, @rid OUTPUT;
INSERT INTO workflow.ROSTER_APPROVAL (RequestInstanceId, BranchId, MonthDate) VALUES (@rid, @branch, '2097-05-01');
INSERT INTO attendance.ROSTER_MONTH (BranchId, MonthDate, [Status], RequestInstanceId) VALUES (@branch, '2097-05-01', 'PendingApproval', @rid);
EXEC #QA3_Approve @rid, @hr1;
DECLARE @r TABLE (RequestInstanceId INT, [Status] VARCHAR(20), CurrentStepNo INT, ClosedReason NVARCHAR(300), Decision VARCHAR(25), SignedAsDeputy BIT, SignedWithPassword BIT);
INSERT INTO @r EXEC workflow.usp_Request_Approve @RequestInstanceId = @rid, @ActedByUserId = @owner, @SignedWithPassword = 1;
SET @ok = CASE WHEN EXISTS (SELECT 1 FROM attendance.ROSTER_MONTH WHERE BranchId = @branch AND MonthDate = '2097-05-01' AND [Status] = 'Approved' AND RequestInstanceId = @rid)
                AND EXISTS (SELECT 1 FROM workflow.ROSTER_APPROVAL WHERE RequestInstanceId = @rid AND AppliedAt IS NOT NULL) THEN 1 ELSE 0 END;
EXEC #QA3_Check @ok, N'the roster approval activates the month';
DECLARE @x TABLE (RequestInstanceId INT, [Status] VARCHAR(20), CurrentStepNo INT);
INSERT INTO @x EXEC workflow.usp_Request_RetractLastDecision @RequestInstanceId = @rid, @ActedByUserId = @owner, @Reason = N'QA3 not this version', @SignedWithPassword = 1;
SELECT @what = CONCAT(N'after the retract the month is ', [Status], N', approved at ', ISNULL(CONVERT(VARCHAR(30), ApprovedAt, 126), N'NULL'))
FROM attendance.ROSTER_MONTH WHERE BranchId = @branch AND MonthDate = '2097-05-01';
SET @ok = CASE WHEN EXISTS (SELECT 1 FROM attendance.ROSTER_MONTH WHERE BranchId = @branch AND MonthDate = '2097-05-01' AND [Status] = 'PendingApproval'
                                                                    AND RequestInstanceId = @rid AND ApprovedAt IS NULL)
                AND EXISTS (SELECT 1 FROM workflow.ROSTER_APPROVAL WHERE RequestInstanceId = @rid AND AppliedAt IS NULL) THEN 1 ELSE 0 END;
EXEC #QA3_Check @ok, @what;
IF @@TRANCOUNT > 0 ROLLBACK;
GO

/* ---------------- phase 4: ROS-11 - with an earlier approval standing, the month stays approved on it ---------------- */
BEGIN TRAN;
EXEC #QA3_Seed;
DECLARE @hr1 INT = (SELECT v FROM #ctx WHERE k = 'hr1'), @owner INT = (SELECT v FROM #ctx WHERE k = 'owner'), @branch INT = (SELECT v FROM #ctx WHERE k = 'branch'),
        @emp INT = (SELECT v FROM #ctx WHERE k = 'empId'), @rHR INT = (SELECT v FROM #ctx WHERE k = 'rHR'), @rOwner INT = (SELECT v FROM #ctx WHERE k = 'rOwner');
DECLARE @def INT, @r0 INT, @r1 INT, @ok BIT, @what NVARCHAR(400), @r0At DATETIME2;
EXEC #QA3_Chain 'ROSTER_APPROVAL', @rHR, @rOwner, @DefId = @def OUTPUT;
DECLARE @r TABLE (RequestInstanceId INT, [Status] VARCHAR(20), CurrentStepNo INT, ClosedReason NVARCHAR(300), Decision VARCHAR(25), SignedAsDeputy BIT, SignedWithPassword BIT);
EXEC #QA3_NewRequest 'ROSTER_APPROVAL', @emp, @hr1, @r0 OUTPUT;
INSERT INTO workflow.ROSTER_APPROVAL (RequestInstanceId, BranchId, MonthDate) VALUES (@r0, @branch, '2097-05-01');
EXEC #QA3_Approve @r0, @hr1;
INSERT INTO @r EXEC workflow.usp_Request_Approve @RequestInstanceId = @r0, @ActedByUserId = @owner, @SignedWithPassword = 1;
UPDATE workflow.REQUEST_INSTANCE SET ClosedAt = DATEADD(DAY, -3, ClosedAt) WHERE RequestInstanceId = @r0;
SET @r0At = (SELECT ClosedAt FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId = @r0);
/* the roster changed and went up again (usp_RosterApproval_Create keeps an approved month approved, pointing at the new request) */
EXEC #QA3_NewRequest 'ROSTER_APPROVAL', @emp, @hr1, @r1 OUTPUT;
INSERT INTO workflow.ROSTER_APPROVAL (RequestInstanceId, BranchId, MonthDate) VALUES (@r1, @branch, '2097-05-01');
UPDATE attendance.ROSTER_MONTH SET RequestInstanceId = @r1 WHERE BranchId = @branch AND MonthDate = '2097-05-01';
EXEC #QA3_Approve @r1, @hr1;
INSERT INTO @r EXEC workflow.usp_Request_Approve @RequestInstanceId = @r1, @ActedByUserId = @owner, @SignedWithPassword = 1;
DECLARE @x TABLE (RequestInstanceId INT, [Status] VARCHAR(20), CurrentStepNo INT);
INSERT INTO @x EXEC workflow.usp_Request_RetractLastDecision @RequestInstanceId = @r1, @ActedByUserId = @owner, @Reason = N'QA3 keep the first one', @SignedWithPassword = 1;
SELECT @what = CONCAT(N'after the retract of the re-approval the month is ', [Status], N' (approved at ', ISNULL(CONVERT(VARCHAR(30), ApprovedAt, 126), N'NULL'), N')')
FROM attendance.ROSTER_MONTH WHERE BranchId = @branch AND MonthDate = '2097-05-01';
SET @ok = CASE WHEN EXISTS (SELECT 1 FROM attendance.ROSTER_MONTH WHERE BranchId = @branch AND MonthDate = '2097-05-01' AND [Status] = 'Approved' AND ApprovedAt = @r0At)
                AND EXISTS (SELECT 1 FROM workflow.ROSTER_APPROVAL WHERE RequestInstanceId = @r1 AND AppliedAt IS NULL)
                AND EXISTS (SELECT 1 FROM workflow.ROSTER_APPROVAL WHERE RequestInstanceId = @r0 AND AppliedAt IS NOT NULL) THEN 1 ELSE 0 END;
EXEC #QA3_Check @ok, @what;
IF @@TRANCOUNT > 0 ROLLBACK;
GO

/* ---------------- phase 5: WF-8 - a rejection of any type can be taken back (nothing to undo) ---------------- */
BEGIN TRAN;
EXEC #QA3_Seed;
DECLARE @hr1 INT = (SELECT v FROM #ctx WHERE k = 'hr1'), @owner INT = (SELECT v FROM #ctx WHERE k = 'owner'),
        @emp INT = (SELECT v FROM #ctx WHERE k = 'empId'), @uEmp INT = (SELECT v FROM #ctx WHERE k = 'emp'),
        @rHR INT = (SELECT v FROM #ctx WHERE k = 'rHR'), @rOwner INT = (SELECT v FROM #ctx WHERE k = 'rOwner');
DECLARE @def INT, @rid INT, @ok BIT;
EXEC #QA3_Chain 'SHIFT_SWAP', @rHR, @rOwner, @DefId = @def OUTPUT;
EXEC #QA3_NewRequest 'SHIFT_SWAP', @emp, @uEmp, @rid OUTPUT;
EXEC #QA3_Approve @rid, @hr1;
EXEC #QA3_Reject @rid, @owner;
DECLARE @x TABLE (RequestInstanceId INT, [Status] VARCHAR(20), CurrentStepNo INT);
INSERT INTO @x EXEC workflow.usp_Request_RetractLastDecision @RequestInstanceId = @rid, @ActedByUserId = @owner, @Reason = N'QA3 rejected the wrong one', @SignedWithPassword = 1;
SET @ok = CASE WHEN EXISTS (SELECT 1 FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId = @rid AND [Status] = 'Pending' AND CurrentStepNo = 2) THEN 1 ELSE 0 END;
EXEC #QA3_Check @ok, N'a rejected shift swap is retracted by its rejecter';
IF @@TRANCOUNT > 0 ROLLBACK;
GO

/* ---------------- phase 6: WF-8 - an APPROVED shift swap has no safe undo and is refused with a sentence ---------------- */
BEGIN TRAN;
EXEC #QA3_Seed;
DECLARE @hr1 INT = (SELECT v FROM #ctx WHERE k = 'hr1'), @owner INT = (SELECT v FROM #ctx WHERE k = 'owner'),
        @emp INT = (SELECT v FROM #ctx WHERE k = 'empId'), @uEmp INT = (SELECT v FROM #ctx WHERE k = 'emp'),
        @rHR INT = (SELECT v FROM #ctx WHERE k = 'rHR'), @rOwner INT = (SELECT v FROM #ctx WHERE k = 'rOwner');
DECLARE @def INT, @rid INT, @ok BIT, @err NVARCHAR(400), @what NVARCHAR(400);
EXEC #QA3_Chain 'SHIFT_SWAP', @rHR, @rOwner, @DefId = @def OUTPUT;
EXEC #QA3_NewRequest 'SHIFT_SWAP', @emp, @uEmp, @rid OUTPUT;
EXEC #QA3_Approve @rid, @hr1;
EXEC #QA3_Approve @rid, @owner;
BEGIN TRY EXEC workflow.usp_Request_RetractLastDecision @RequestInstanceId = @rid, @ActedByUserId = @owner, @Reason = N'QA3 undo the swap', @SignedWithPassword = 1; END TRY
BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
SET @what = CONCAT(N'an approved shift swap is not taken back - got: ', ISNULL(@err, N'accepted'));
SET @ok = CASE WHEN @err LIKE N'An approved %cannot be taken back%' AND EXISTS (SELECT 1 FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId = @rid AND [Status] = 'Approved') THEN 1 ELSE 0 END;
EXEC #QA3_Check @ok, @what;
IF @@TRANCOUNT > 0 ROLLBACK;
GO

/* ---------------- phase 7: WF-16 / LEV-11 - an approved leave inside a paid period is not taken back ---------------- */
BEGIN TRAN;
EXEC #QA3_Seed;
DECLARE @hr1 INT = (SELECT v FROM #ctx WHERE k = 'hr1'), @owner INT = (SELECT v FROM #ctx WHERE k = 'owner'),
        @emp INT = (SELECT v FROM #ctx WHERE k = 'empId'), @uEmp INT = (SELECT v FROM #ctx WHERE k = 'emp'),
        @rHR INT = (SELECT v FROM #ctx WHERE k = 'rHR'), @rOwner INT = (SELECT v FROM #ctx WHERE k = 'rOwner');
DECLARE @def INT, @rid INT, @ok BIT, @err NVARCHAR(400), @what NVARCHAR(400), @run INT;
DECLARE @Annual INT = (SELECT TOP 1 LeaveTypeId FROM hr.LEAVE_TYPE ORDER BY CASE WHEN Name = N'Annual' THEN 0 ELSE 1 END, LeaveTypeId);
EXEC #QA3_Chain 'LEAVE_REQUEST', @rHR, @rOwner, @DefId = @def OUTPUT;
EXEC #QA3_NewRequest 'LEAVE_REQUEST', @emp, @uEmp, @rid OUTPUT;
INSERT INTO workflow.LEAVE_REQUEST (RequestInstanceId, EmployeeId, LeaveTypeId, FromDate, ToDate, DaysRequested) VALUES (@rid, @emp, @Annual, '2097-06-09', '2097-06-10', 2);
EXEC #QA3_Approve @rid, @hr1;
EXEC #QA3_Approve @rid, @owner;
/* June 2097 is then paid for this employee: a locked Primary run with their payslip */
INSERT INTO payroll.PAYROLL_RUN (PeriodYearMonth, PeriodStart, PeriodEnd, RunType, [Status], PrimaryCurrency, CreatedByUserId)
VALUES ('2097-06', '2097-06-01', '2097-06-30', 'Primary', 'Approved', 'USD', @hr1);
SET @run = SCOPE_IDENTITY();
INSERT INTO payroll.PAYSLIP (PayrollRunId, EmployeeId, EmployeeName) VALUES (@run, @emp, N'QA3 Employee');
BEGIN TRY EXEC workflow.usp_Request_RetractLastDecision @RequestInstanceId = @rid, @ActedByUserId = @owner, @Reason = N'QA3 after payday', @SignedWithPassword = 1; END TRY
BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
SET @what = CONCAT(N'a leave in a paid period is not taken back - got: ', ISNULL(@err, N'accepted'));
SET @ok = CASE WHEN @err LIKE N'This period is paid%' AND EXISTS (SELECT 1 FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId = @rid AND [Status] = 'Approved') THEN 1 ELSE 0 END;
EXEC #QA3_Check @ok, @what;
IF @@TRANCOUNT > 0 ROLLBACK;
GO
PRINT 'ok wf_undo_arms';
GO
