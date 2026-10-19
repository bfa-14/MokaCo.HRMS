/* QA3 workflow scenario (wf1_reversal_money): WF-1: taking back an approved salary advance and payroll adjustment (retract, and both halves of a reopen) */
/* Runs on a real dev database (MokaCo_HRMS_Dev) or a stand-in: every phase is ONE transaction that is
   rolled back at the end of its phase (a refusal raised under XACT_ABORT dooms the transaction it is caught in, so a
   phase checks at most one refusal, last); rows are seeded with a 'QA3 ' prefix. A wrong result RAISERRORs (run with sqlcmd -I -b);
   success prints 'ok wf1_reversal_money'. Needs docs/101_qa3_workflow.sql (and 99). */
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
/* ---------------- phase 1: the advance - approve, retract, approve again, GM + Owner reopen ---------------- */
BEGIN TRAN;
EXEC #QA3_Seed;
DECLARE @hr1 INT = (SELECT v FROM #ctx WHERE k = 'hr1'), @owner INT = (SELECT v FROM #ctx WHERE k = 'owner'),
        @gm INT = (SELECT v FROM #ctx WHERE k = 'gm'), @emp INT = (SELECT v FROM #ctx WHERE k = 'empId'),
        @uEmp INT = (SELECT v FROM #ctx WHERE k = 'emp'),
        @rHR INT = (SELECT v FROM #ctx WHERE k = 'rHR'), @rOwner INT = (SELECT v FROM #ctx WHERE k = 'rOwner');
DECLARE @def INT, @rid INT, @st VARCHAR(20), @err NVARCHAR(400), @ok BIT, @n INT, @what NVARCHAR(400);
DECLARE @BeirutToday DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE);
EXEC #QA3_Chain 'SALARY_ADVANCE', @rHR, @rOwner, @DefId = @def OUTPUT;

EXEC #QA3_NewRequest 'SALARY_ADVANCE', @emp, @uEmp, @rid OUTPUT;
INSERT INTO workflow.SALARY_ADVANCE_REQUEST (RequestInstanceId, EmployeeId, Amount, MonthlyDeduction, CurrencyCode, FirstDeductionPeriod, Reason)
VALUES (@rid, @emp, 300, 100, 'USD', '2097-02', N'QA3 advance');
EXEC #QA3_Approve @rid, @hr1;
EXEC #QA3_Approve @rid, @owner, @Status = @st OUTPUT;
SET @ok = CASE WHEN @st = 'Approved' AND EXISTS (SELECT 1 FROM workflow.SALARY_ADVANCE_REQUEST q JOIN payroll.SALARY_ADVANCE a ON a.SalaryAdvanceId = q.CreatedAdvanceId
                                                 WHERE q.RequestInstanceId = @rid AND a.AdvanceDate = @BeirutToday) THEN 1 ELSE 0 END;
EXEC #QA3_Check @ok, N'the approved advance exists, dated on Beirut''s calendar';

/* the Owner, the last signer, retracts it the same day: the advance goes, the request is back at the Owner's step */
EXEC workflow.usp_Request_RetractLastDecision @RequestInstanceId = @rid, @ActedByUserId = @owner, @Reason = N'QA3 approved by mistake', @SignedWithPassword = 1;
SET @ok = CASE WHEN EXISTS (SELECT 1 FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId = @rid AND [Status] = 'Pending' AND CurrentStepNo = 2)
                AND NOT EXISTS (SELECT 1 FROM payroll.SALARY_ADVANCE WHERE RequestInstanceId = @rid)
                AND EXISTS (SELECT 1 FROM workflow.SALARY_ADVANCE_REQUEST WHERE RequestInstanceId = @rid AND CreatedAdvanceId IS NULL AND AdvanceCreatedAt IS NULL)
                AND EXISTS (SELECT 1 FROM workflow.WORKFLOW_SIGNATURE WHERE RequestInstanceId = @rid AND StepNo = 2 AND RetractedAt IS NOT NULL)
               THEN 1 ELSE 0 END;
EXEC #QA3_Check @ok, N'the retract of an approved advance clears the pointer, removes the advance and puts the request back at step 2';

/* it goes on: approved again, the advance exists once */
EXEC #QA3_Approve @rid, @owner, @Status = @st OUTPUT;
SET @n = (SELECT COUNT(*) FROM payroll.SALARY_ADVANCE WHERE RequestInstanceId = @rid);
SET @ok = CASE WHEN @st = 'Approved' AND @n = 1 THEN 1 ELSE 0 END;
EXEC #QA3_Check @ok, N'after the retract the advance is approved again and exists once';

/* GM + Owner reopen: the first half moves nothing, the second (another person, the other role) completes it */
DECLARE @half TABLE ([State] VARCHAR(20), FirstSignRole NVARCHAR(30));
INSERT INTO @half EXEC workflow.usp_Request_Reopen @RequestInstanceId = @rid, @ActedByUserId = @gm, @Reason = N'QA3 wrong amount', @SignedWithPassword = 1;
SET @ok = CASE WHEN (SELECT [State] FROM @half) = 'AwaitingSecond'
                AND EXISTS (SELECT 1 FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId = @rid AND [Status] = 'Approved')
                AND EXISTS (SELECT 1 FROM payroll.SALARY_ADVANCE WHERE RequestInstanceId = @rid) THEN 1 ELSE 0 END;
EXEC #QA3_Check @ok, N'the first half of a reopen records the signature and moves nothing';
DECLARE @done TABLE (RequestInstanceId INT, [Status] VARCHAR(20), CurrentStepNo INT);
INSERT INTO @done EXEC workflow.usp_Request_Reopen @RequestInstanceId = @rid, @ActedByUserId = @owner, @Reason = NULL, @SignedWithPassword = 1;
SET @ok = CASE WHEN (SELECT [Status] FROM @done) = 'Pending'
                AND EXISTS (SELECT 1 FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId = @rid AND [Status] = 'Pending' AND CurrentStepNo = 2)
                AND NOT EXISTS (SELECT 1 FROM payroll.SALARY_ADVANCE WHERE RequestInstanceId = @rid)
                AND EXISTS (SELECT 1 FROM workflow.REQUEST_REVERSAL WHERE RequestInstanceId = @rid AND Kind = 'Reopen' AND CompletedAt IS NOT NULL
                                                                     AND FirstSignUserId = @gm AND SecondSignUserId = @owner)
               THEN 1 ELSE 0 END;
EXEC #QA3_Check @ok, N'the Owner''s second half reopens the approved advance and removes it';
IF @@TRANCOUNT > 0 ROLLBACK;
GO

/* ---------------- phase 2: one person cannot sign both halves of a reopen ---------------- */
BEGIN TRAN;
EXEC #QA3_Seed;
DECLARE @hr1 INT = (SELECT v FROM #ctx WHERE k = 'hr1'), @owner INT = (SELECT v FROM #ctx WHERE k = 'owner'),
        @gm INT = (SELECT v FROM #ctx WHERE k = 'gm'), @emp INT = (SELECT v FROM #ctx WHERE k = 'empId'),
        @uEmp INT = (SELECT v FROM #ctx WHERE k = 'emp'),
        @rHR INT = (SELECT v FROM #ctx WHERE k = 'rHR'), @rOwner INT = (SELECT v FROM #ctx WHERE k = 'rOwner');
DECLARE @def INT, @rid INT, @st VARCHAR(20), @err NVARCHAR(400), @ok BIT, @what NVARCHAR(400);
EXEC #QA3_Chain 'SALARY_ADVANCE', @rHR, @rOwner, @DefId = @def OUTPUT;
EXEC #QA3_NewRequest 'SALARY_ADVANCE', @emp, @uEmp, @rid OUTPUT;
INSERT INTO workflow.SALARY_ADVANCE_REQUEST (RequestInstanceId, EmployeeId, Amount, MonthlyDeduction, CurrencyCode, FirstDeductionPeriod, Reason)
VALUES (@rid, @emp, 300, 100, 'USD', '2097-02', N'QA3 advance');
EXEC #QA3_Approve @rid, @hr1;
EXEC #QA3_Approve @rid, @owner, @Status = @st OUTPUT;
DECLARE @half TABLE ([State] VARCHAR(20), FirstSignRole NVARCHAR(30));
INSERT INTO @half EXEC workflow.usp_Request_Reopen @RequestInstanceId = @rid, @ActedByUserId = @gm, @Reason = N'QA3 wrong amount', @SignedWithPassword = 1;
BEGIN TRY EXEC workflow.usp_Request_Reopen @RequestInstanceId = @rid, @ActedByUserId = @gm, @Reason = NULL, @SignedWithPassword = 1; END TRY
BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
SET @what = CONCAT(N'one person cannot sign both halves of a reopen - got: ', ISNULL(@err, N'accepted'));
SET @ok = CASE WHEN @err LIKE N'You already signed this reopen%'
                AND EXISTS (SELECT 1 FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId = @rid AND [Status] = 'Approved') THEN 1 ELSE 0 END;
EXEC #QA3_Check @ok, @what;
IF @@TRANCOUNT > 0 ROLLBACK;
GO

/* ---------------- phase 3: an advance whose recovery has started cannot be taken back ---------------- */
BEGIN TRAN;
EXEC #QA3_Seed;
DECLARE @hr1 INT = (SELECT v FROM #ctx WHERE k = 'hr1'), @owner INT = (SELECT v FROM #ctx WHERE k = 'owner'),
        @emp INT = (SELECT v FROM #ctx WHERE k = 'empId'), @uEmp INT = (SELECT v FROM #ctx WHERE k = 'emp'),
        @rHR INT = (SELECT v FROM #ctx WHERE k = 'rHR'), @rOwner INT = (SELECT v FROM #ctx WHERE k = 'rOwner');
DECLARE @def INT, @rid INT, @st VARCHAR(20), @err NVARCHAR(400), @ok BIT, @what NVARCHAR(400);
EXEC #QA3_Chain 'SALARY_ADVANCE', @rHR, @rOwner, @DefId = @def OUTPUT;
EXEC #QA3_NewRequest 'SALARY_ADVANCE', @emp, @uEmp, @rid OUTPUT;
INSERT INTO workflow.SALARY_ADVANCE_REQUEST (RequestInstanceId, EmployeeId, Amount, MonthlyDeduction, CurrencyCode, FirstDeductionPeriod, Reason)
VALUES (@rid, @emp, 300, 100, 'USD', '2097-02', N'QA3 advance');
EXEC #QA3_Approve @rid, @hr1;
EXEC #QA3_Approve @rid, @owner, @Status = @st OUTPUT;
UPDATE a SET RemainingAmount = Amount - 100 FROM payroll.SALARY_ADVANCE a WHERE a.RequestInstanceId = @rid;
BEGIN TRY EXEC workflow.usp_Request_RetractLastDecision @RequestInstanceId = @rid, @ActedByUserId = @owner, @Reason = N'QA3 too late', @SignedWithPassword = 1; END TRY
BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
SET @what = CONCAT(N'an advance already being recovered is refused and stays approved - got: ', ISNULL(@err, N'accepted'));
SET @ok = CASE WHEN @err IS NOT NULL AND EXISTS (SELECT 1 FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId = @rid AND [Status] = 'Approved')
                AND EXISTS (SELECT 1 FROM payroll.SALARY_ADVANCE WHERE RequestInstanceId = @rid) THEN 1 ELSE 0 END;
EXEC #QA3_Check @ok, @what;
IF @@TRANCOUNT > 0 ROLLBACK;
GO

/* ---------------- phase 4: the payroll adjustment - retract, approve again, Owner + GM reopen ---------------- */
BEGIN TRAN;
EXEC #QA3_Seed;
DECLARE @hr1 INT = (SELECT v FROM #ctx WHERE k = 'hr1'), @owner INT = (SELECT v FROM #ctx WHERE k = 'owner'),
        @gm INT = (SELECT v FROM #ctx WHERE k = 'gm'), @emp INT = (SELECT v FROM #ctx WHERE k = 'empId'),
        @rHR INT = (SELECT v FROM #ctx WHERE k = 'rHR'), @rOwner INT = (SELECT v FROM #ctx WHERE k = 'rOwner');
DECLARE @def INT, @rid INT, @st VARCHAR(20), @ok BIT;
DECLARE @Comp INT = (SELECT TOP 1 ComponentTypeId FROM hr.COMPONENT_TYPE ORDER BY ComponentTypeId);
EXEC #QA3_Chain 'PAYROLL_ADJUSTMENT', @rHR, @rOwner, @DefId = @def OUTPUT;
EXEC #QA3_NewRequest 'PAYROLL_ADJUSTMENT', @emp, @hr1, @rid OUTPUT;
INSERT INTO workflow.PAYROLL_ADJUSTMENT_REQUEST (RequestInstanceId, EmployeeId, ComponentTypeId, Amount, CurrencyCode, TargetPeriod, Reason)
VALUES (@rid, @emp, @Comp, 50, 'USD', '2097-02', N'QA3 adjustment');
EXEC #QA3_Approve @rid, @hr1;
EXEC #QA3_Approve @rid, @owner, @Status = @st OUTPUT;
SET @ok = CASE WHEN @st = 'Approved' AND EXISTS (SELECT 1 FROM payroll.PAYROLL_ADJUSTMENT WHERE RequestInstanceId = @rid) THEN 1 ELSE 0 END;
EXEC #QA3_Check @ok, N'the approved adjustment exists';
EXEC workflow.usp_Request_RetractLastDecision @RequestInstanceId = @rid, @ActedByUserId = @owner, @Reason = N'QA3 wrong period', @SignedWithPassword = 1;
SET @ok = CASE WHEN NOT EXISTS (SELECT 1 FROM payroll.PAYROLL_ADJUSTMENT WHERE RequestInstanceId = @rid)
                AND EXISTS (SELECT 1 FROM workflow.PAYROLL_ADJUSTMENT_REQUEST WHERE RequestInstanceId = @rid AND CreatedAdjustmentId IS NULL)
                AND EXISTS (SELECT 1 FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId = @rid AND [Status] = 'Pending' AND CurrentStepNo = 2) THEN 1 ELSE 0 END;
EXEC #QA3_Check @ok, N'the retract of an approved adjustment clears the pointer and removes the adjustment';
EXEC #QA3_Approve @rid, @owner, @Status = @st OUTPUT;
DECLARE @half TABLE ([State] VARCHAR(20), FirstSignRole NVARCHAR(30));
INSERT INTO @half EXEC workflow.usp_Request_Reopen @RequestInstanceId = @rid, @ActedByUserId = @owner, @Reason = N'QA3 wrong component', @SignedWithPassword = 1;
DECLARE @done TABLE (RequestInstanceId INT, [Status] VARCHAR(20), CurrentStepNo INT);
INSERT INTO @done EXEC workflow.usp_Request_Reopen @RequestInstanceId = @rid, @ActedByUserId = @gm, @Reason = NULL, @SignedWithPassword = 1;
SET @ok = CASE WHEN (SELECT [Status] FROM @done) = 'Pending' AND (SELECT FirstSignRole FROM @half) = N'Owner'
                AND NOT EXISTS (SELECT 1 FROM payroll.PAYROLL_ADJUSTMENT WHERE RequestInstanceId = @rid) THEN 1 ELSE 0 END;
EXEC #QA3_Check @ok, N'Owner then GM reopen the approved adjustment and remove it';
IF @@TRANCOUNT > 0 ROLLBACK;
GO
PRINT 'ok wf1_reversal_money';
GO
