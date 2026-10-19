/* QA3 workflow scenario (wf_move_version): WF-10 and WF-9: moving a request onto a newer version of its chain */
/* Runs on a real dev database (MokaCo_HRMS_Dev) or a stand-in: every phase is ONE transaction that is
   rolled back at the end of its phase (a refusal raised under XACT_ABORT dooms the transaction it is caught in, so a
   phase checks at most one refusal, last); rows are seeded with a 'QA3 ' prefix. A wrong result RAISERRORs (run with sqlcmd -I -b);
   success prints 'ok wf_move_version'. Needs docs/101_qa3_workflow.sql (and 99). */
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
/* ---------------- phase 1: a request stays inside its population - the management chain is not offered nor accepted ---------------- */
BEGIN TRAN;
EXEC #QA3_Seed;
DECLARE @hr1 INT = (SELECT v FROM #ctx WHERE k = 'hr1'), @emp INT = (SELECT v FROM #ctx WHERE k = 'empId'), @uEmp INT = (SELECT v FROM #ctx WHERE k = 'emp'),
        @rHR INT = (SELECT v FROM #ctx WHERE k = 'rHR'), @rOwner INT = (SELECT v FROM #ctx WHERE k = 'rOwner');
DECLARE @va INT, @vm INT, @rid INT, @T INT, @ok BIT, @err NVARCHAR(400), @what NVARCHAR(400);
EXEC #QA3_Chain 'SALARY_ADVANCE', @rHR, @rOwner, @DefId = @va OUTPUT;
EXEC #QA3_Chain 'SALARY_ADVANCE', @rOwner, @Tier = 2, @DefId = @vm OUTPUT;           -- the management chain, active alongside
SET @T = (SELECT RequestTypeId FROM workflow.WORKFLOW_DEFINITION WHERE WorkflowDefinitionId = @va);
EXEC #QA3_NewRequest 'SALARY_ADVANCE', @emp, @uEmp, @rid OUTPUT;
INSERT INTO workflow.SALARY_ADVANCE_REQUEST (RequestInstanceId, EmployeeId, Amount, MonthlyDeduction, CurrencyCode, FirstDeductionPeriod) VALUES (@rid, @emp, 200, 100, 'USD', '2097-02');
EXEC #QA3_Approve @rid, @hr1;
DECLARE @old TABLE (RequestInstanceId INT, RequestTypeCode VARCHAR(30), RequestTypeName NVARCHAR(80), EmployeeId INT, EmployeeName NVARCHAR(150), BranchName NVARCHAR(80),
                    Title NVARCHAR(150), SubmittedAt DATETIME2, CurrentStepNo INT, CurrentStepName NVARCHAR(80), CurrentVersion INT, ActiveVersion INT,
                    ActiveWorkflowDefinitionId INT, DaysWaiting INT);
INSERT INTO @old EXEC workflow.usp_Request_GetOnOldVersions @RequestTypeId = @T;
SET @ok = CASE WHEN NOT EXISTS (SELECT 1 FROM @old WHERE RequestInstanceId = @rid) THEN 1 ELSE 0 END;
EXEC #QA3_Check @ok, N'a request on the ACTIVE default chain is not listed as "on an old version" because the management chain is active too';
BEGIN TRY EXEC workflow.usp_Request_MoveToVersion @RequestInstanceId = @rid, @TargetWorkflowDefinitionId = @vm, @ActedByUserId = @hr1, @Reason = N'QA3 newer chain'; END TRY
BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
SET @what = CONCAT(N'a staff request is not moved onto the management chain - got: ', ISNULL(@err, N'accepted'));
SET @ok = CASE WHEN @err LIKE N'That version serves a different population%'
                AND EXISTS (SELECT 1 FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId = @rid AND WorkflowDefinitionId = @va AND [Status] = 'Pending') THEN 1 ELSE 0 END;
EXEC #QA3_Check @ok, @what;
IF @@TRANCOUNT > 0 ROLLBACK;
GO

/* ---------------- phase 2: rebuilt by position after the last acted step; the passed step is logged; deputy and flags copied ---------------- */
BEGIN TRAN;
EXEC #QA3_Seed;
DECLARE @hr1 INT = (SELECT v FROM #ctx WHERE k = 'hr1'), @mgr INT = (SELECT v FROM #ctx WHERE k = 'mgr'), @emp INT = (SELECT v FROM #ctx WHERE k = 'empId'),
        @uEmp INT = (SELECT v FROM #ctx WHERE k = 'emp'), @rHR INT = (SELECT v FROM #ctx WHERE k = 'rHR'), @rOwner INT = (SELECT v FROM #ctx WHERE k = 'rOwner'),
        @rGM INT = (SELECT v FROM #ctx WHERE k = 'rGM');
DECLARE @va INT, @vb INT, @rid INT, @T INT, @ok BIT, @what NVARCHAR(400), @adj BIT;
EXEC #QA3_Chain 'SALARY_ADVANCE', @rHR, @rOwner, @DefId = @va OUTPUT;
SET @T = (SELECT RequestTypeId FROM workflow.WORKFLOW_DEFINITION WHERE WorkflowDefinitionId = @va);
EXEC #QA3_NewRequest 'SALARY_ADVANCE', @emp, @uEmp, @rid OUTPUT;
INSERT INTO workflow.SALARY_ADVANCE_REQUEST (RequestInstanceId, EmployeeId, Amount, MonthlyDeduction, CurrencyCode, FirstDeductionPeriod) VALUES (@rid, @emp, 200, 100, 'USD', '2097-02');
EXEC #QA3_Approve @rid, @hr1;
/* version b of the same (default) chain: a named manager first, then HR with the GM as deputy, then the Owner (may adjust) */
UPDATE workflow.WORKFLOW_DEFINITION SET [Status] = 'Retired' WHERE WorkflowDefinitionId = @va;
INSERT INTO workflow.WORKFLOW_DEFINITION (RequestTypeId, [Version], [Status]) VALUES (@T, (SELECT MAX([Version]) FROM workflow.WORKFLOW_DEFINITION WHERE RequestTypeId = @T) + 1, 'Active');
SET @vb = SCOPE_IDENTITY();
INSERT INTO workflow.WORKFLOW_STEP (WorkflowDefinitionId, StepNo, Name, ApproverType, ApproverUserId) VALUES (@vb, 1, N'QA3 manager', 'SpecificUser', @mgr);
INSERT INTO workflow.WORKFLOW_STEP (WorkflowDefinitionId, StepNo, Name, ApproverType, ApproverRoleId, FallbackRoleId) VALUES (@vb, 2, N'QA3 HR', 'Role', @rHR, @rGM);
INSERT INTO workflow.WORKFLOW_STEP (WorkflowDefinitionId, StepNo, Name, ApproverType, ApproverRoleId, CanAdjust) VALUES (@vb, 3, N'QA3 Owner', 'Role', @rOwner, 1);
DECLARE @old TABLE (RequestInstanceId INT, RequestTypeCode VARCHAR(30), RequestTypeName NVARCHAR(80), EmployeeId INT, EmployeeName NVARCHAR(150), BranchName NVARCHAR(80),
                    Title NVARCHAR(150), SubmittedAt DATETIME2, CurrentStepNo INT, CurrentStepName NVARCHAR(80), CurrentVersion INT, ActiveVersion INT,
                    ActiveWorkflowDefinitionId INT, DaysWaiting INT);
INSERT INTO @old EXEC workflow.usp_Request_GetOnOldVersions @RequestTypeId = @T;
SET @ok = CASE WHEN EXISTS (SELECT 1 FROM @old WHERE RequestInstanceId = @rid AND ActiveWorkflowDefinitionId = @vb) THEN 1 ELSE 0 END;
EXEC #QA3_Check @ok, N'the request on the retired version is offered the active version of its own chain';
DECLARE @mv TABLE (RequestInstanceId INT, [Status] VARCHAR(20), CurrentStepNo INT, MovedFromVersion INT, MovedToVersion INT, VersionMovedAt DATETIME2, VersionMovedBy INT);
INSERT INTO @mv EXEC workflow.usp_Request_MoveToVersion @RequestInstanceId = @rid, @TargetWorkflowDefinitionId = NULL, @ActedByUserId = @hr1, @Reason = N'QA3 the new chain';
SELECT @what = CONCAT(N'after the move: status ', [Status], N', step ', CurrentStepNo, N'; steps ',
                      (SELECT STRING_AGG(CONCAT(si.StepNo, N':', si.[Status], N':', ISNULL(CAST(si.FallbackRoleId AS NVARCHAR(10)), N'-')), N' ') WITHIN GROUP (ORDER BY si.StepNo)
                       FROM workflow.REQUEST_STEP_INSTANCE si WHERE si.RequestInstanceId = @rid)) FROM @mv;
SET @ok = CASE WHEN (SELECT [Status] FROM @mv) = 'Pending' AND (SELECT CurrentStepNo FROM @mv) = 2
                AND EXISTS (SELECT 1 FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId = @rid AND WorkflowDefinitionId = @vb AND OriginalWorkflowDefinitionId = @va)
                AND EXISTS (SELECT 1 FROM workflow.REQUEST_STEP_INSTANCE WHERE RequestInstanceId = @rid AND StepNo = 1 AND [Status] = 'Approved' AND ActedByUserId = @hr1)
                AND EXISTS (SELECT 1 FROM workflow.REQUEST_STEP_INSTANCE WHERE RequestInstanceId = @rid AND StepNo = 2 AND [Status] = 'Pending' AND FallbackRoleId = @rGM)
                AND EXISTS (SELECT 1 FROM workflow.REQUEST_STEP_INSTANCE WHERE RequestInstanceId = @rid AND StepNo = 3 AND [Status] = 'Pending')
                AND (SELECT COUNT(*) FROM workflow.REQUEST_STEP_INSTANCE WHERE RequestInstanceId = @rid) = 3
                AND EXISTS (SELECT 1 FROM workflow.WORKFLOW_SIGNATURE WHERE RequestInstanceId = @rid AND [Action] = 'Skipped' AND StepNo IS NULL
                                                                       AND Comment LIKE N'Step 1 of version % (QA3 manager) was not added%')
                AND EXISTS (SELECT 1 FROM workflow.WORKFLOW_SIGNATURE WHERE RequestInstanceId = @rid AND [Action] = 'VersionMoved') THEN 1 ELSE 0 END;
EXEC #QA3_Check @ok, @what;
IF COL_LENGTH('workflow.REQUEST_STEP_INSTANCE', 'CanAdjust') IS NOT NULL
BEGIN
    EXEC sp_executesql N'SELECT @a = CanAdjust FROM workflow.REQUEST_STEP_INSTANCE WHERE RequestInstanceId = @r AND StepNo = 3', N'@r INT, @a BIT OUTPUT', @r = @rid, @a = @adj OUTPUT;
    SET @ok = CASE WHEN @adj = 1 THEN 1 ELSE 0 END;
    EXEC #QA3_Check @ok, N'the step flags of the new chain are copied (CanAdjust)';
END
IF @@TRANCOUNT > 0 ROLLBACK;
GO

/* ---------------- phase 3: a move that would leave nothing to sign is refused unless confirmed ---------------- */
BEGIN TRAN;
EXEC #QA3_Seed;
DECLARE @hr1 INT = (SELECT v FROM #ctx WHERE k = 'hr1'), @emp INT = (SELECT v FROM #ctx WHERE k = 'empId'), @uEmp INT = (SELECT v FROM #ctx WHERE k = 'emp'),
        @rHR INT = (SELECT v FROM #ctx WHERE k = 'rHR'), @rOwner INT = (SELECT v FROM #ctx WHERE k = 'rOwner');
DECLARE @va INT, @vc INT, @rid INT, @ok BIT, @err NVARCHAR(400), @what NVARCHAR(400);
EXEC #QA3_Chain 'SALARY_ADVANCE', @rHR, @rOwner, @DefId = @va OUTPUT;
EXEC #QA3_NewRequest 'SALARY_ADVANCE', @emp, @uEmp, @rid OUTPUT;
INSERT INTO workflow.SALARY_ADVANCE_REQUEST (RequestInstanceId, EmployeeId, Amount, MonthlyDeduction, CurrencyCode, FirstDeductionPeriod) VALUES (@rid, @emp, 200, 100, 'USD', '2097-02');
EXEC #QA3_Approve @rid, @hr1;
EXEC #QA3_Chain 'SALARY_ADVANCE', @rHR, @DefId = @vc OUTPUT;                  -- the new version has only the HR step, already passed
BEGIN TRY EXEC workflow.usp_Request_MoveToVersion @RequestInstanceId = @rid, @TargetWorkflowDefinitionId = @vc, @ActedByUserId = @hr1, @Reason = N'QA3 shorter chain'; END TRY
BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
SET @what = CONCAT(N'a move that would approve the request needs a confirmation - got: ', ISNULL(@err, N'accepted'));
SET @ok = CASE WHEN @err LIKE N'Moving this request to version % leaves no step to sign%'
                AND EXISTS (SELECT 1 FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId = @rid AND [Status] = 'Pending' AND WorkflowDefinitionId = @va) THEN 1 ELSE 0 END;
EXEC #QA3_Check @ok, @what;
IF @@TRANCOUNT > 0 ROLLBACK;
GO

/* ---------------- phase 4: ...and when confirmed, the request is approved AND its effect applied (WF-9) ---------------- */
BEGIN TRAN;
EXEC #QA3_Seed;
DECLARE @hr1 INT = (SELECT v FROM #ctx WHERE k = 'hr1'), @emp INT = (SELECT v FROM #ctx WHERE k = 'empId'), @uEmp INT = (SELECT v FROM #ctx WHERE k = 'emp'),
        @rHR INT = (SELECT v FROM #ctx WHERE k = 'rHR'), @rOwner INT = (SELECT v FROM #ctx WHERE k = 'rOwner');
DECLARE @va INT, @vc INT, @rid INT, @ok BIT;
EXEC #QA3_Chain 'SALARY_ADVANCE', @rHR, @rOwner, @DefId = @va OUTPUT;
EXEC #QA3_NewRequest 'SALARY_ADVANCE', @emp, @uEmp, @rid OUTPUT;
INSERT INTO workflow.SALARY_ADVANCE_REQUEST (RequestInstanceId, EmployeeId, Amount, MonthlyDeduction, CurrencyCode, FirstDeductionPeriod) VALUES (@rid, @emp, 200, 100, 'USD', '2097-02');
EXEC #QA3_Approve @rid, @hr1;
EXEC #QA3_Chain 'SALARY_ADVANCE', @rHR, @DefId = @vc OUTPUT;
DECLARE @mv TABLE (RequestInstanceId INT, [Status] VARCHAR(20), CurrentStepNo INT, MovedFromVersion INT, MovedToVersion INT, VersionMovedAt DATETIME2, VersionMovedBy INT);
INSERT INTO @mv EXEC workflow.usp_Request_MoveToVersion @RequestInstanceId = @rid, @TargetWorkflowDefinitionId = @vc, @ActedByUserId = @hr1,
     @Reason = N'QA3 shorter chain', @ConfirmClose = 1;
SET @ok = CASE WHEN (SELECT [Status] FROM @mv) = 'Approved'
                AND EXISTS (SELECT 1 FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId = @rid AND ClosedReason LIKE N'Approved automatically%')
                AND EXISTS (SELECT 1 FROM workflow.SALARY_ADVANCE_REQUEST q JOIN payroll.SALARY_ADVANCE a ON a.SalaryAdvanceId = q.CreatedAdvanceId WHERE q.RequestInstanceId = @rid)
               THEN 1 ELSE 0 END;
EXEC #QA3_Check @ok, N'a confirmed move that closes the request applies the approval''s effect (the advance exists)';
IF @@TRANCOUNT > 0 ROLLBACK;
GO
/* ---------------- phase 5: a step skipped at submit AFTER the current one has not been passed ---------------- */
BEGIN TRAN;
EXEC #QA3_Seed;
DECLARE @hr1 INT = (SELECT v FROM #ctx WHERE k = 'hr1'), @emp INT = (SELECT v FROM #ctx WHERE k = 'empId'), @uEmp INT = (SELECT v FROM #ctx WHERE k = 'emp'),
        @rHR INT = (SELECT v FROM #ctx WHERE k = 'rHR'), @rOwner INT = (SELECT v FROM #ctx WHERE k = 'rOwner'), @rGM INT = (SELECT v FROM #ctx WHERE k = 'rGM');
DECLARE @va INT, @vb INT, @rid INT, @T INT, @ok BIT, @what NVARCHAR(400);
EXEC #QA3_Chain 'SALARY_ADVANCE', @rHR, @rOwner, @DefId = @va OUTPUT;
SET @T = (SELECT RequestTypeId FROM workflow.WORKFLOW_DEFINITION WHERE WorkflowDefinitionId = @va);
INSERT INTO workflow.WORKFLOW_STEP (WorkflowDefinitionId, StepNo, Name, ApproverType, ApproverRoleId) VALUES (@va, 3, N'QA3 step 3', 'Role', @rGM);
EXEC #QA3_NewRequest 'SALARY_ADVANCE', @emp, @uEmp, @rid OUTPUT;
INSERT INTO workflow.SALARY_ADVANCE_REQUEST (RequestInstanceId, EmployeeId, Amount, MonthlyDeduction, CurrencyCode, FirstDeductionPeriod) VALUES (@rid, @emp, 200, 100, 'USD', '2097-02');
UPDATE workflow.REQUEST_STEP_INSTANCE SET [Status] = 'Skipped', SkipReason = N'QA3 skipped at submit' WHERE RequestInstanceId = @rid AND StepNo = 3;
EXEC #QA3_Approve @rid, @hr1;                                    -- step 1 signed; the request waits on step 2
UPDATE workflow.WORKFLOW_DEFINITION SET [Status] = 'Retired' WHERE WorkflowDefinitionId = @va;
INSERT INTO workflow.WORKFLOW_DEFINITION (RequestTypeId, [Version], [Status]) VALUES (@T, (SELECT MAX([Version]) FROM workflow.WORKFLOW_DEFINITION WHERE RequestTypeId = @T) + 1, 'Active');
SET @vb = SCOPE_IDENTITY();
INSERT INTO workflow.WORKFLOW_STEP (WorkflowDefinitionId, StepNo, Name, ApproverType, ApproverRoleId) VALUES (@vb, 1, N'QA3 HR', 'Role', @rHR), (@vb, 2, N'QA3 GM', 'Role', @rGM), (@vb, 3, N'QA3 Owner', 'Role', @rOwner);
DECLARE @mv TABLE (RequestInstanceId INT, [Status] VARCHAR(20), CurrentStepNo INT, MovedFromVersion INT, MovedToVersion INT, VersionMovedAt DATETIME2, VersionMovedBy INT);
INSERT INTO @mv EXEC workflow.usp_Request_MoveToVersion @RequestInstanceId = @rid, @TargetWorkflowDefinitionId = @vb, @ActedByUserId = @hr1, @Reason = N'QA3 new chain';
SELECT @what = CONCAT(N'steps after the move: ', (SELECT STRING_AGG(CONCAT(si.StepNo, N':', si.Name, N':', si.[Status]), N' ') WITHIN GROUP (ORDER BY si.StepNo)
                                                   FROM workflow.REQUEST_STEP_INSTANCE si WHERE si.RequestInstanceId = @rid));
SET @ok = CASE WHEN (SELECT CurrentStepNo FROM @mv) = 2
                AND EXISTS (SELECT 1 FROM workflow.REQUEST_STEP_INSTANCE WHERE RequestInstanceId = @rid AND StepNo = 2 AND Name = N'QA3 GM' AND [Status] = 'Pending')
                AND EXISTS (SELECT 1 FROM workflow.REQUEST_STEP_INSTANCE WHERE RequestInstanceId = @rid AND StepNo = 3 AND Name = N'QA3 Owner' AND [Status] = 'Pending') THEN 1 ELSE 0 END;
EXEC #QA3_Check @ok, @what;
IF @@TRANCOUNT > 0 ROLLBACK;
GO
PRINT 'ok wf_move_version';
GO
