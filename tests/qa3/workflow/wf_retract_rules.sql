/* QA3 workflow scenario (wf_retract_rules): WF-5, WF-13, WF-4 / LEV-7, WF-15, CON-1: retract and withdraw rules */
/* Runs on a real dev database (MokaCo_HRMS_Dev) or a stand-in: every phase is ONE transaction that is
   rolled back at the end of its phase (a refusal raised under XACT_ABORT dooms the transaction it is caught in, so a
   phase checks at most one refusal, last); rows are seeded with a 'QA3 ' prefix. A wrong result RAISERRORs (run with sqlcmd -I -b);
   success prints 'ok wf_retract_rules'. Needs docs/101_qa3_workflow.sql (and 99). */
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
/* ---------------- phase 1: WF-13 - a decision signed at 00:30 Beirut today is "same day" (it is yesterday in UTC) ---------------- */
BEGIN TRAN;
EXEC #QA3_Seed;
DECLARE @hr1 INT = (SELECT v FROM #ctx WHERE k = 'hr1'), @owner INT = (SELECT v FROM #ctx WHERE k = 'owner'),
        @emp INT = (SELECT v FROM #ctx WHERE k = 'empId'), @uEmp INT = (SELECT v FROM #ctx WHERE k = 'emp'),
        @rHR INT = (SELECT v FROM #ctx WHERE k = 'rHR'), @rOwner INT = (SELECT v FROM #ctx WHERE k = 'rOwner');
DECLARE @def INT, @rid INT, @st VARCHAR(20), @err NVARCHAR(400), @ok BIT, @what NVARCHAR(400);
DECLARE @BeirutToday DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE);
DECLARE @SignedUtc DATETIME2 = CAST((DATEADD(MINUTE, 30, CAST(@BeirutToday AS DATETIME2)) AT TIME ZONE 'Middle East Standard Time') AT TIME ZONE 'UTC' AS DATETIME2);
EXEC #QA3_Chain 'EXIT_PERMISSION', @rHR, @rOwner, @DefId = @def OUTPUT;
EXEC #QA3_NewRequest 'EXIT_PERMISSION', @emp, @uEmp, @rid OUTPUT;
INSERT INTO workflow.EXIT_PERMISSION (RequestInstanceId, EmployeeId, ExitDate, FromTime, ToTime, RequestedMinutes, ApprovedMinutes, Reason, ConvertToLeave)
VALUES (@rid, @emp, '2097-03-05', '11:00', '12:00', 60, 60, N'QA3 errand', 0);
EXEC #QA3_Approve @rid, @hr1;
EXEC #QA3_Approve @rid, @owner, @Status = @st OUTPUT;
UPDATE workflow.WORKFLOW_SIGNATURE SET ActedAt = CASE WHEN StepNo = 2 THEN @SignedUtc ELSE DATEADD(MINUTE, -30, @SignedUtc) END
WHERE RequestInstanceId = @rid AND StepNo IS NOT NULL;
DECLARE @x TABLE (RequestInstanceId INT, [Status] VARCHAR(20), CurrentStepNo INT);
INSERT INTO @x EXEC workflow.usp_Request_RetractLastDecision @RequestInstanceId = @rid, @ActedByUserId = @owner, @Reason = N'QA3 signed the wrong one', @SignedWithPassword = 1;
SET @ok = CASE WHEN EXISTS (SELECT 1 FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId = @rid AND [Status] = 'Pending' AND CurrentStepNo = 2) THEN 1 ELSE 0 END;
EXEC #QA3_Check @ok, N'a decision signed early today in Beirut (yesterday in UTC) can still be retracted';
IF @@TRANCOUNT > 0 ROLLBACK;
GO

/* ---------------- phase 2: WF-13 - one signed late yesterday in Beirut cannot ---------------- */
BEGIN TRAN;
EXEC #QA3_Seed;
DECLARE @hr1 INT = (SELECT v FROM #ctx WHERE k = 'hr1'), @owner INT = (SELECT v FROM #ctx WHERE k = 'owner'),
        @emp INT = (SELECT v FROM #ctx WHERE k = 'empId'), @uEmp INT = (SELECT v FROM #ctx WHERE k = 'emp'),
        @rHR INT = (SELECT v FROM #ctx WHERE k = 'rHR'), @rOwner INT = (SELECT v FROM #ctx WHERE k = 'rOwner');
DECLARE @def INT, @rid INT, @st VARCHAR(20), @err NVARCHAR(400), @ok BIT, @what NVARCHAR(400);
DECLARE @BeirutToday DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE);
DECLARE @SignedUtc DATETIME2 = CAST((DATEADD(MINUTE, -30, CAST(@BeirutToday AS DATETIME2)) AT TIME ZONE 'Middle East Standard Time') AT TIME ZONE 'UTC' AS DATETIME2);
EXEC #QA3_Chain 'EXIT_PERMISSION', @rHR, @rOwner, @DefId = @def OUTPUT;
EXEC #QA3_NewRequest 'EXIT_PERMISSION', @emp, @uEmp, @rid OUTPUT;
INSERT INTO workflow.EXIT_PERMISSION (RequestInstanceId, EmployeeId, ExitDate, FromTime, ToTime, RequestedMinutes, ApprovedMinutes, Reason, ConvertToLeave)
VALUES (@rid, @emp, '2097-03-05', '11:00', '12:00', 60, 60, N'QA3 errand', 0);
EXEC #QA3_Approve @rid, @hr1;
EXEC #QA3_Approve @rid, @owner, @Status = @st OUTPUT;
UPDATE workflow.WORKFLOW_SIGNATURE SET ActedAt = CASE WHEN StepNo = 2 THEN @SignedUtc ELSE DATEADD(MINUTE, -30, @SignedUtc) END
WHERE RequestInstanceId = @rid AND StepNo IS NOT NULL;
BEGIN TRY EXEC workflow.usp_Request_RetractLastDecision @RequestInstanceId = @rid, @ActedByUserId = @owner, @Reason = N'QA3 too late', @SignedWithPassword = 1; END TRY
BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
SET @what = CONCAT(N'a decision from yesterday (Beirut) is not retracted - got: ', ISNULL(@err, N'accepted'));
SET @ok = CASE WHEN @err LIKE N'Same-day only%' AND EXISTS (SELECT 1 FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId = @rid AND [Status] = 'Approved') THEN 1 ELSE 0 END;
EXEC #QA3_Check @ok, @what;
IF @@TRANCOUNT > 0 ROLLBACK;
GO

/* ---------------- phase 3: WF-5 - a cancelled request is not brought back by a retract ---------------- */
BEGIN TRAN;
EXEC #QA3_Seed;
DECLARE @hr1 INT = (SELECT v FROM #ctx WHERE k = 'hr1'), @emp INT = (SELECT v FROM #ctx WHERE k = 'empId'), @uEmp INT = (SELECT v FROM #ctx WHERE k = 'emp'),
        @rHR INT = (SELECT v FROM #ctx WHERE k = 'rHR'), @rOwner INT = (SELECT v FROM #ctx WHERE k = 'rOwner');
DECLARE @def INT, @rid INT, @err NVARCHAR(400), @ok BIT, @what NVARCHAR(400);
EXEC #QA3_Chain 'EXIT_PERMISSION', @rHR, @rOwner, @DefId = @def OUTPUT;
EXEC #QA3_NewRequest 'EXIT_PERMISSION', @emp, @uEmp, @rid OUTPUT;
INSERT INTO workflow.EXIT_PERMISSION (RequestInstanceId, EmployeeId, ExitDate, FromTime, ToTime, RequestedMinutes, ApprovedMinutes, Reason, ConvertToLeave)
VALUES (@rid, @emp, '2097-03-05', '11:00', '12:00', 60, 60, N'QA3 errand', 0);
EXEC #QA3_Approve @rid, @hr1;
/* the employee cancels (what usp_Request_Cancel commits) */
UPDATE workflow.REQUEST_INSTANCE SET [Status] = 'Cancelled', CurrentStepNo = NULL, ClosedAt = SYSUTCDATETIME(), ClosedReason = N'QA3 called off' WHERE RequestInstanceId = @rid;
BEGIN TRY EXEC workflow.usp_Request_RetractLastDecision @RequestInstanceId = @rid, @ActedByUserId = @hr1, @Reason = N'QA3 look again'; END TRY
BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
SET @what = CONCAT(N'a retract does not re-open a cancelled request - got: ', ISNULL(@err, N'accepted'));
SET @ok = CASE WHEN @err LIKE N'This request was cancelled%' AND EXISTS (SELECT 1 FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId = @rid AND [Status] = 'Cancelled') THEN 1 ELSE 0 END;
EXEC #QA3_Check @ok, @what;
IF @@TRANCOUNT > 0 ROLLBACK;
GO

/* ---------------- phase 4: WF-5 - a request still open is changed by withdrawing, not by a retract ---------------- */
BEGIN TRAN;
EXEC #QA3_Seed;
DECLARE @hr1 INT = (SELECT v FROM #ctx WHERE k = 'hr1'), @emp INT = (SELECT v FROM #ctx WHERE k = 'empId'), @uEmp INT = (SELECT v FROM #ctx WHERE k = 'emp'),
        @rHR INT = (SELECT v FROM #ctx WHERE k = 'rHR'), @rOwner INT = (SELECT v FROM #ctx WHERE k = 'rOwner');
DECLARE @def INT, @rid INT, @err NVARCHAR(400), @ok BIT, @what NVARCHAR(400);
EXEC #QA3_Chain 'EXIT_PERMISSION', @rHR, @rOwner, @DefId = @def OUTPUT;
EXEC #QA3_NewRequest 'EXIT_PERMISSION', @emp, @uEmp, @rid OUTPUT;
INSERT INTO workflow.EXIT_PERMISSION (RequestInstanceId, EmployeeId, ExitDate, FromTime, ToTime, RequestedMinutes, ApprovedMinutes, Reason, ConvertToLeave)
VALUES (@rid, @emp, '2097-03-05', '11:00', '12:00', 60, 60, N'QA3 errand', 0);
EXEC #QA3_Approve @rid, @hr1;
BEGIN TRY EXEC workflow.usp_Request_RetractLastDecision @RequestInstanceId = @rid, @ActedByUserId = @hr1, @Reason = N'QA3 not yet'; END TRY
BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
SET @what = CONCAT(N'a retract on an open request points to Change decision - got: ', ISNULL(@err, N'accepted'));
SET @ok = CASE WHEN @err LIKE N'This request is still open%' AND EXISTS (SELECT 1 FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId = @rid AND [Status] = 'Pending' AND CurrentStepNo = 2) THEN 1 ELSE 0 END;
EXEC #QA3_Check @ok, @what;
IF @@TRANCOUNT > 0 ROLLBACK;
GO

/* ---------------- phase 5: WF-4 / LEV-7 / WF-15 - a retracted leave approval puts back the days, the flag, the ledger,
                    ApprovedToDate and the closing mail ---------------- */
BEGIN TRAN;
EXEC #QA3_Seed;
DECLARE @hr1 INT = (SELECT v FROM #ctx WHERE k = 'hr1'), @owner INT = (SELECT v FROM #ctx WHERE k = 'owner'),
        @emp INT = (SELECT v FROM #ctx WHERE k = 'empId'), @uEmp INT = (SELECT v FROM #ctx WHERE k = 'emp'),
        @rHR INT = (SELECT v FROM #ctx WHERE k = 'rHR'), @rOwner INT = (SELECT v FROM #ctx WHERE k = 'rOwner');
DECLARE @def INT, @rid INT, @st VARCHAR(20), @ok BIT, @what NVARCHAR(400), @lr INT;
DECLARE @Annual INT = (SELECT TOP 1 LeaveTypeId FROM hr.LEAVE_TYPE ORDER BY CASE WHEN Name = N'Annual' THEN 0 ELSE 1 END, LeaveTypeId);
EXEC #QA3_Chain 'LEAVE_REQUEST', @rHR, @rOwner, @Adjust2 = 1, @DefId = @def OUTPUT;
EXEC #QA3_NewRequest 'LEAVE_REQUEST', @emp, @uEmp, @rid OUTPUT;
INSERT INTO workflow.LEAVE_REQUEST (RequestInstanceId, EmployeeId, LeaveTypeId, FromDate, ToDate, DaysRequested)
VALUES (@rid, @emp, @Annual, '2097-03-04', '2097-03-08', 5);
SET @lr = SCOPE_IDENTITY();
EXEC #QA3_Approve @rid, @hr1;
/* the Owner grants 3 of 5 as discretionary: what unit D's decide writes (ValueBefore = the standing figure and flag),
   then the engine, then the figure and the posting (ApprovedToDate = the last day the ledger allocated) */
UPDATE workflow.REQUEST_STEP_INSTANCE SET ValueBefore = N'5.0|0' WHERE RequestInstanceId = @rid AND StepNo = 2;
EXEC #QA3_Approve @rid, @owner, @Comment = N'QA3 three days, given back', @ChangeSummary = N'Days: 5 -> 3', @Status = @st OUTPUT;
UPDATE workflow.LEAVE_REQUEST SET DaysApproved = 3, IsDiscretionary = 1 WHERE RequestInstanceId = @rid;
UPDATE workflow.LEAVE_REQUEST SET AppliedToLedgerAt = NULL WHERE RequestInstanceId = @rid;
DELETE FROM hr.LEAVE_LEDGER WHERE LeaveRequestId = @lr;
EXEC hr.usp_LeaveLedger_PostRequest @RequestInstanceId = @rid, @ActorUserId = @owner;
UPDATE workflow.LEAVE_REQUEST SET ApprovedToDate = '2097-03-06' WHERE RequestInstanceId = @rid;
INSERT INTO core.EMAIL_OUTBOX (ToAddress, [Subject], Body, RequestInstanceId) VALUES (N'qa3.employee@example.invalid', N'QA3 approved', N'QA3', @rid);
SET @ok = CASE WHEN @st = 'Approved' AND EXISTS (SELECT 1 FROM hr.LEAVE_LEDGER WHERE LeaveRequestId = @lr AND MovementType = 'Usage')
                AND EXISTS (SELECT 1 FROM hr.LEAVE_LEDGER WHERE LeaveRequestId = @lr AND MovementType = 'Adjustment') THEN 1 ELSE 0 END;
EXEC #QA3_Check @ok, N'the discretionary partial approval is posted (usage and give-back)';
DECLARE @x TABLE (RequestInstanceId INT, [Status] VARCHAR(20), CurrentStepNo INT);
INSERT INTO @x EXEC workflow.usp_Request_RetractLastDecision @RequestInstanceId = @rid, @ActedByUserId = @owner, @Reason = N'QA3 misread the roster', @SignedWithPassword = 1;
SELECT @what = CONCAT(N'after the retract: days ', DaysApproved, N', discretionary ', CAST(IsDiscretionary AS INT), N', ApprovedToDate ', ISNULL(CONVERT(CHAR(10), ApprovedToDate, 23), N'NULL'),
                      N', ledger rows ', (SELECT COUNT(*) FROM hr.LEAVE_LEDGER WHERE LeaveRequestId = @lr),
                      N', outbox rows ', (SELECT COUNT(*) FROM core.EMAIL_OUTBOX WHERE RequestInstanceId = @rid))
FROM workflow.LEAVE_REQUEST WHERE RequestInstanceId = @rid;
SET @ok = CASE WHEN EXISTS (SELECT 1 FROM workflow.LEAVE_REQUEST WHERE RequestInstanceId = @rid AND DaysApproved = 5 AND IsDiscretionary = 0
                                                                     AND ApprovedToDate IS NULL AND AppliedToLedgerAt IS NULL)
                AND NOT EXISTS (SELECT 1 FROM hr.LEAVE_LEDGER WHERE LeaveRequestId = @lr)
                AND NOT EXISTS (SELECT 1 FROM core.EMAIL_OUTBOX WHERE RequestInstanceId = @rid)
                AND EXISTS (SELECT 1 FROM workflow.REQUEST_STEP_INSTANCE WHERE RequestInstanceId = @rid AND StepNo = 2 AND [Status] = 'Pending' AND ValueBefore IS NULL)
               THEN 1 ELSE 0 END;
EXEC #QA3_Check @ok, @what;
IF @@TRANCOUNT > 0 ROLLBACK;
GO

/* ---------------- phase 6: WF-4 + CON-1 - withdrawing a cut on an exit permission puts the minutes back,
                    and the typed withdrawal returns ONE result set (the permission) ---------------- */
BEGIN TRAN;
EXEC #QA3_Seed;
DECLARE @hr1 INT = (SELECT v FROM #ctx WHERE k = 'hr1'), @emp INT = (SELECT v FROM #ctx WHERE k = 'empId'), @uEmp INT = (SELECT v FROM #ctx WHERE k = 'emp'),
        @rHR INT = (SELECT v FROM #ctx WHERE k = 'rHR'), @rOwner INT = (SELECT v FROM #ctx WHERE k = 'rOwner');
DECLARE @def INT, @rid INT, @ok BIT, @what NVARCHAR(400);
EXEC #QA3_Chain 'EXIT_PERMISSION', @rHR, @rOwner, @Adjust1 = 1, @DefId = @def OUTPUT;
EXEC #QA3_NewRequest 'EXIT_PERMISSION', @emp, @uEmp, @rid OUTPUT;
INSERT INTO workflow.EXIT_PERMISSION (RequestInstanceId, EmployeeId, ExitDate, FromTime, ToTime, RequestedMinutes, ApprovedMinutes, Reason, ConvertToLeave)
VALUES (@rid, @emp, '2097-03-05', '11:00', '14:00', 180, 180, N'QA3 family matter', 0);
/* what usp_ExitPermission_Decide does when HR cuts 180 to 120: the figure, ValueBefore, then the engine */
UPDATE workflow.EXIT_PERMISSION SET ApprovedMinutes = 120 WHERE RequestInstanceId = @rid;
UPDATE workflow.REQUEST_STEP_INSTANCE SET ValueBefore = N'180' WHERE RequestInstanceId = @rid AND StepNo = 1;
EXEC #QA3_Approve @rid, @hr1, @Comment = N'QA3 two hours is enough', @ChangeSummary = N'Minutes away: 180 -> 120';
/* (it runs the engine under INSERT...EXEC, so it cannot itself be captured that way: its one result set goes to the client) */
EXEC workflow.usp_ExitPermission_WithdrawDecision @RequestInstanceId = @rid, @StepNo = 1, @ActedByUserId = @hr1,
     @Reason = N'QA3 misread the date', @SignedWithPassword = 1;
SELECT @what = CONCAT(N'the withdrawal puts the minutes back to 180 and hands step 1 back - got minutes ', ApprovedMinutes) FROM workflow.EXIT_PERMISSION WHERE RequestInstanceId = @rid;
SET @ok = CASE WHEN EXISTS (SELECT 1 FROM workflow.EXIT_PERMISSION WHERE RequestInstanceId = @rid AND ApprovedMinutes = 180)
                AND EXISTS (SELECT 1 FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId = @rid AND [Status] = 'Pending' AND CurrentStepNo = 1)
                AND EXISTS (SELECT 1 FROM workflow.WORKFLOW_SIGNATURE WHERE RequestInstanceId = @rid AND [Action] = 'Withdrawn') THEN 1 ELSE 0 END;
EXEC #QA3_Check @ok, @what;
/* CON-1: its FIRST result set is the permission (the API reads one row of it), no longer the engine's row */
SET @ok = CASE WHEN (SELECT name FROM sys.dm_exec_describe_first_result_set_for_object(OBJECT_ID('workflow.usp_ExitPermission_WithdrawDecision'), 0)
                     WHERE column_ordinal = 1) = N'ExitPermissionId' THEN 1 ELSE 0 END;
EXEC #QA3_Check @ok, N'the typed withdrawal''s first result set starts with ExitPermissionId';
IF @@TRANCOUNT > 0 ROLLBACK;
GO

/* ---------------- phase 7: CON-1 - a REFUSED withdrawal changes nothing (it used to commit the restored minutes) ---------------- */
BEGIN TRAN;
EXEC #QA3_Seed;
DECLARE @hr1 INT = (SELECT v FROM #ctx WHERE k = 'hr1'), @hr2 INT = (SELECT v FROM #ctx WHERE k = 'hr2'),
        @emp INT = (SELECT v FROM #ctx WHERE k = 'empId'), @uEmp INT = (SELECT v FROM #ctx WHERE k = 'emp'),
        @rHR INT = (SELECT v FROM #ctx WHERE k = 'rHR'), @rOwner INT = (SELECT v FROM #ctx WHERE k = 'rOwner');
DECLARE @def INT, @rid INT, @ok BIT, @err NVARCHAR(400), @what NVARCHAR(400);
EXEC #QA3_Chain 'EXIT_PERMISSION', @rHR, @rOwner, @Adjust1 = 1, @DefId = @def OUTPUT;
EXEC #QA3_NewRequest 'EXIT_PERMISSION', @emp, @uEmp, @rid OUTPUT;
INSERT INTO workflow.EXIT_PERMISSION (RequestInstanceId, EmployeeId, ExitDate, FromTime, ToTime, RequestedMinutes, ApprovedMinutes, Reason, ConvertToLeave)
VALUES (@rid, @emp, '2097-03-05', '11:00', '14:00', 180, 120, N'QA3 family matter', 0);
UPDATE workflow.REQUEST_STEP_INSTANCE SET ValueBefore = N'180' WHERE RequestInstanceId = @rid AND StepNo = 1;
EXEC #QA3_Approve @rid, @hr1, @Comment = N'QA3 two hours is enough', @ChangeSummary = N'Minutes away: 180 -> 120';
BEGIN TRY
    EXEC workflow.usp_ExitPermission_WithdrawDecision @RequestInstanceId = @rid, @StepNo = 1, @ActedByUserId = @hr2,
         @Reason = N'QA3 not mine to withdraw', @SignedWithPassword = 1;
END TRY BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
SET @what = CONCAT(N'somebody else''s decision is not withdrawn and the minutes stay at 120 - got: ', ISNULL(@err, N'accepted'));
SET @ok = CASE WHEN @err LIKE N'You can only withdraw a decision you made yourself%'
                AND EXISTS (SELECT 1 FROM workflow.EXIT_PERMISSION WHERE RequestInstanceId = @rid AND ApprovedMinutes = 120) THEN 1 ELSE 0 END;
EXEC #QA3_Check @ok, @what;
IF @@TRANCOUNT > 0 ROLLBACK;
GO
PRINT 'ok wf_retract_rules';
GO
