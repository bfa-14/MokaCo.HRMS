/* QA3 LEAD-2 scenario (docs/107_qa3_tier_chains.sql): a chain set to tier X serves tiers 1..X (D6: 1 = the head), the
   narrowest first, the default chain last. The probe tells which rule the live submit follows; the aligner edits the old
   rule out of the submit and the preview only when their text holds it exactly as the repo wrote it, and keeps the edit
   only when the probe then agrees; SetMinTier takes any tier but the lowest.
   Every phase is one transaction rolled back at its end (the stand-in submits installed here go with it). A wrong result
   RAISERRORs (sqlcmd -I -b); success prints 'ok tier_chains'. */
SET NOCOUNT ON; SET XACT_ABORT OFF; SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON;
GO
IF OBJECT_ID('tempdb..#QA3_Check') IS NOT NULL DROP PROCEDURE #QA3_Check;
IF OBJECT_ID('tempdb..#QA3_OldSubmit') IS NOT NULL DROP PROCEDURE #QA3_OldSubmit;
IF OBJECT_ID('tempdb..#QA3_Types') IS NOT NULL DROP PROCEDURE #QA3_Types;
GO
CREATE PROCEDURE #QA3_Check @Ok BIT, @What NVARCHAR(400) AS
BEGIN
    IF ISNULL(@Ok, 0) = 0 BEGIN RAISERROR(N'QA3 FAILED: %s', 16, 1, @What); RETURN 1; END
    RETURN 0;
END;
GO
/* a stand-in submit that picks its chain by @Rule's text: 'old' = the repo's old rule, exactly as written; 'old-tight' =
   the same rule spelled without spaces; 'new' = the rule of script 107. Returns the six columns of the live submit. */
CREATE PROCEDURE #QA3_OldSubmit @Rule VARCHAR(10) AS
BEGIN
    DECLARE @Pick NVARCHAR(400) = CASE @Rule
        WHEN 'old' THEN N'      AND ISNULL(d.MinRequesterTier, 1) <= @Tier
    ORDER BY ISNULL(d.MinRequesterTier, 1) DESC, d.[Version] DESC;'
        WHEN 'old-tight' THEN N'      AND ISNULL(d.MinRequesterTier,1)<=@Tier
    ORDER BY ISNULL(d.MinRequesterTier,1) DESC, d.[Version] DESC;'
        ELSE N'      AND (d.MinRequesterTier IS NULL OR d.MinRequesterTier >= @Tier)
    ORDER BY CASE WHEN d.MinRequesterTier IS NULL THEN 1 ELSE 0 END, d.MinRequesterTier, d.[Version] DESC;' END;
    DECLARE @Sql NVARCHAR(MAX) = CONCAT(N'CREATE OR ALTER PROCEDURE workflow.usp_Request_Submit
    @RequestTypeCode VARCHAR(30), @EmployeeId INT, @RaisedByUserId INT, @Title NVARCHAR(150) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Tier INT = (SELECT ISNULL(ApprovalTier, 1) FROM hr.EMPLOYEE WHERE EmployeeId = @EmployeeId);
    DECLARE @DefId INT;
    SELECT TOP 1 @DefId = d.WorkflowDefinitionId
    FROM workflow.WORKFLOW_DEFINITION d
    JOIN workflow.REQUEST_TYPE rt ON rt.RequestTypeId = d.RequestTypeId
    WHERE rt.Code = @RequestTypeCode AND d.[Status] = ''Active''
', @Pick, N'
    SELECT CAST(NULL AS INT) AS RequestInstanceId, CAST(''Pending'' AS VARCHAR(20)) AS [Status], CAST(NULL AS INT) AS CurrentStepNo,
           @DefId AS WorkflowDefinitionId, CAST(1 AS INT) AS WorkflowVersion, CAST(NULL AS INT) AS MinRequesterTier;
END;');
    EXEC (@Sql);
END;
GO
/* a type with a default chain and a chain for tier 2, and three people: the head (1), tier 2 and the lowest tier */
CREATE PROCEDURE #QA3_Types @DefaultDef INT OUTPUT, @TierDef INT OUTPUT, @Head INT OUTPUT, @Two INT OUTPUT, @Low INT OUTPUT AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @T INT, @B INT = (SELECT TOP 1 BranchId FROM hr.BRANCH ORDER BY BranchId), @D INT = (SELECT TOP 1 DepartmentId FROM hr.DEPARTMENT ORDER BY DepartmentId),
            @P INT = (SELECT TOP 1 PositionId FROM hr.[POSITION] ORDER BY PositionId), @Lowest INT = (SELECT MAX(TierNo) FROM hr.APPROVAL_TIER);
    INSERT INTO workflow.REQUEST_TYPE (Code, Name, IsActive) VALUES ('QA3_TIERS', N'QA3 tiers', 1); SET @T = SCOPE_IDENTITY();
    INSERT INTO workflow.WORKFLOW_DEFINITION (RequestTypeId, [Version], [Status], MinRequesterTier) VALUES (@T, 1, 'Active', NULL); SET @DefaultDef = SCOPE_IDENTITY();
    INSERT INTO workflow.WORKFLOW_DEFINITION (RequestTypeId, [Version], [Status], MinRequesterTier) VALUES (@T, 2, 'Active', 2); SET @TierDef = SCOPE_IDENTITY();
    INSERT INTO hr.EMPLOYEE (BranchId, DepartmentId, PositionId, FullName, HireDate, Email, PhoneNumber, ApprovalTier)
    VALUES (@B, @D, @P, N'QA3 tiers head', '2026-01-01', N'qa3.tiers.head@invalid.example', '96100000001', 1); SET @Head = SCOPE_IDENTITY();
    INSERT INTO hr.EMPLOYEE (BranchId, DepartmentId, PositionId, FullName, HireDate, Email, PhoneNumber, ApprovalTier)
    VALUES (@B, @D, @P, N'QA3 tiers two', '2026-01-01', N'qa3.tiers.two@invalid.example', '96100000002', 2); SET @Two = SCOPE_IDENTITY();
    INSERT INTO hr.EMPLOYEE (BranchId, DepartmentId, PositionId, FullName, HireDate, Email, PhoneNumber, ApprovalTier)
    VALUES (@B, @D, @P, N'QA3 tiers lowest', '2026-01-01', N'qa3.tiers.lowest@invalid.example', '96100000003', @Lowest); SET @Low = SCOPE_IDENTITY();
END;
GO

/* ---- phase 1: the old rule, written as the repo wrote it -> the submit and the preview are edited, the probe agrees ---- */
BEGIN TRAN;
DECLARE @Rule VARCHAR(10), @Detail NVARCHAR(400), @Ok BIT, @Before NVARCHAR(MAX), @DefaultDef INT, @TierDef INT, @Head INT, @Two INT, @Low INT;
EXEC #QA3_OldSubmit 'old';
EXEC workflow.usp_TierChains_Probe @Rule = @Rule OUTPUT, @Detail = @Detail OUTPUT, @Quiet = 1;
SET @Ok = IIF(@Rule = 'Junior', 1, 0); EXEC #QA3_Check @Ok, N'phase 1: the probe finds the old rule in the old submit';

EXEC workflow.usp_TierChains_Align;
EXEC workflow.usp_TierChains_Probe @Rule = @Rule OUTPUT, @Detail = @Detail OUTPUT, @Quiet = 1;
SET @Ok = IIF(@Rule = 'Senior', 1, 0); EXEC #QA3_Check @Ok, N'phase 1: after the aligner the submit serves tier X and every more senior tier';
SET @Ok = IIF(CHARINDEX(N'(d.MinRequesterTier IS NULL OR d.MinRequesterTier >= @Tier)', OBJECT_DEFINITION(OBJECT_ID('workflow.usp_Definition_GetActive'))) > 0
              AND CHARINDEX(N'DECLARE @Tier INT = 2147483647;', OBJECT_DEFINITION(OBJECT_ID('workflow.usp_Definition_GetActive'))) > 0, 1, 0);
EXEC #QA3_Check @Ok, N'phase 1: the preview is edited with the submit';
SET @Ok = IIF(CHARINDEX(N'CREATE OR ALTER', OBJECT_DEFINITION(OBJECT_ID('workflow.usp_Request_Submit'))) = 0
              AND CHARINDEX(N'@RaisedByUserId INT', OBJECT_DEFINITION(OBJECT_ID('workflow.usp_Request_Submit'))) > 0, 1, 0);
EXEC #QA3_Check @Ok, N'phase 1: the rest of the submit is as it was (stored as CREATE, parameters kept)';

/* the preview: the head and tier 2 get the tier chain, the lowest tier and "no requester" the default one */
EXEC #QA3_Types @DefaultDef OUTPUT, @TierDef OUTPUT, @Head OUTPUT, @Two OUTPUT, @Low OUTPUT;
DECLARE @G TABLE (WorkflowDefinitionId INT, [Version] INT, PublishedAt DATETIME2, MinRequesterTier INT, StepNo INT, Name NVARCHAR(100),
                  ApproverType VARCHAR(30), ApproverRoleId INT, ApproverRoleName NVARCHAR(100), FallbackRoleId INT, FallbackRoleName NVARCHAR(100),
                  IsMandatory BIT, CanAdjust BIT, EscalationLevels INT, ResolvedApproverName NVARCHAR(150));
INSERT INTO @G EXEC workflow.usp_Definition_GetActive @RequestTypeCode = 'QA3_TIERS', @ForEmployeeId = @Head;
SET @Ok = IIF((SELECT TOP 1 WorkflowDefinitionId FROM @G) = @TierDef, 1, 0); EXEC #QA3_Check @Ok, N'phase 1: the preview gives the head the tier-2 chain';
DELETE FROM @G; INSERT INTO @G EXEC workflow.usp_Definition_GetActive @RequestTypeCode = 'QA3_TIERS', @ForEmployeeId = @Two;
SET @Ok = IIF((SELECT TOP 1 WorkflowDefinitionId FROM @G) = @TierDef, 1, 0); EXEC #QA3_Check @Ok, N'phase 1: the preview gives tier 2 the tier-2 chain';
DELETE FROM @G; INSERT INTO @G EXEC workflow.usp_Definition_GetActive @RequestTypeCode = 'QA3_TIERS', @ForEmployeeId = @Low;
SET @Ok = IIF((SELECT TOP 1 WorkflowDefinitionId FROM @G) = @DefaultDef, 1, 0); EXEC #QA3_Check @Ok, N'phase 1: the preview gives the lowest tier the default chain';
DELETE FROM @G; INSERT INTO @G EXEC workflow.usp_Definition_GetActive @RequestTypeCode = 'QA3_TIERS', @ForEmployeeId = NULL;
SET @Ok = IIF((SELECT TOP 1 WorkflowDefinitionId FROM @G) = @DefaultDef, 1, 0); EXEC #QA3_Check @Ok, N'phase 1: the preview without a requester shows the default chain';

/* the submit agrees with the preview for each */
DECLARE @S TABLE (RequestInstanceId INT, [Status] VARCHAR(20), CurrentStepNo INT, WorkflowDefinitionId INT, WorkflowVersion INT, MinRequesterTier INT);
INSERT INTO @S EXEC workflow.usp_Request_Submit @RequestTypeCode = 'QA3_TIERS', @EmployeeId = @Two, @RaisedByUserId = NULL;
SET @Ok = IIF((SELECT TOP 1 WorkflowDefinitionId FROM @S) = @TierDef, 1, 0); EXEC #QA3_Check @Ok, N'phase 1: the submit gives tier 2 the tier-2 chain';

/* run again: nothing changes */
SET @Before = OBJECT_DEFINITION(OBJECT_ID('workflow.usp_Request_Submit'));
EXEC workflow.usp_TierChains_Align;
SET @Ok = IIF(OBJECT_DEFINITION(OBJECT_ID('workflow.usp_Request_Submit')) = @Before, 1, 0); EXEC #QA3_Check @Ok, N'phase 1: a second run changes nothing';
ROLLBACK;
GO

/* ---- phase 2: the old rule spelled differently -> nothing is changed (an OWNER CHECK is printed) ---- */
BEGIN TRAN;
DECLARE @Rule VARCHAR(10), @Detail NVARCHAR(400), @Ok BIT, @Submit NVARCHAR(MAX), @Preview NVARCHAR(MAX);
EXEC #QA3_OldSubmit 'old-tight';
SET @Submit = OBJECT_DEFINITION(OBJECT_ID('workflow.usp_Request_Submit'));
SET @Preview = OBJECT_DEFINITION(OBJECT_ID('workflow.usp_Definition_GetActive'));
EXEC workflow.usp_TierChains_Align;
EXEC workflow.usp_TierChains_Probe @Rule = @Rule OUTPUT, @Detail = @Detail OUTPUT, @Quiet = 1;
SET @Ok = IIF(@Rule = 'Junior' AND OBJECT_DEFINITION(OBJECT_ID('workflow.usp_Request_Submit')) = @Submit, 1, 0);
EXEC #QA3_Check @Ok, N'phase 2: a submit whose text is not the expected one is left alone';
SET @Ok = IIF(OBJECT_DEFINITION(OBJECT_ID('workflow.usp_Definition_GetActive')) = @Preview, 1, 0);
EXEC #QA3_Check @Ok, N'phase 2: the preview stays on the old rule with the submit, so it still shows what will happen';
ROLLBACK;
GO

/* ---- phase 3: a submit already on the new rule -> left alone; the preview is brought to it ---- */
BEGIN TRAN;
DECLARE @Ok BIT, @Submit NVARCHAR(MAX);
EXEC #QA3_OldSubmit 'new';
SET @Submit = OBJECT_DEFINITION(OBJECT_ID('workflow.usp_Request_Submit'));
EXEC workflow.usp_TierChains_Align;
SET @Ok = IIF(OBJECT_DEFINITION(OBJECT_ID('workflow.usp_Request_Submit')) = @Submit, 1, 0); EXEC #QA3_Check @Ok, N'phase 3: a submit on the new rule is left alone';
SET @Ok = IIF(CHARINDEX(N'(d.MinRequesterTier IS NULL OR d.MinRequesterTier >= @Tier)', OBJECT_DEFINITION(OBJECT_ID('workflow.usp_Definition_GetActive'))) > 0, 1, 0);
EXEC #QA3_Check @Ok, N'phase 3: the preview follows the submit onto the new rule';
ROLLBACK;
GO

/* ---- phase 4: the probe leaves nothing behind, inside a caller's transaction or without one ---- */
DECLARE @Rule VARCHAR(10), @Detail NVARCHAR(400), @Ok BIT, @Types INT = (SELECT COUNT(*) FROM workflow.REQUEST_TYPE),
        @People INT = (SELECT COUNT(*) FROM hr.EMPLOYEE), @Requests INT = (SELECT COUNT(*) FROM workflow.REQUEST_INSTANCE);
EXEC workflow.usp_TierChains_Probe @Rule = @Rule OUTPUT, @Detail = @Detail OUTPUT, @Quiet = 1;
SET @Ok = IIF(@@TRANCOUNT = 0 AND (SELECT COUNT(*) FROM workflow.REQUEST_TYPE) = @Types AND (SELECT COUNT(*) FROM hr.EMPLOYEE) = @People
              AND (SELECT COUNT(*) FROM workflow.REQUEST_INSTANCE) = @Requests AND @Rule IN ('Senior', 'Junior', 'None'), 1, 0);
EXEC #QA3_Check @Ok, N'phase 4: the probe keeps nothing and closes what it opened';
BEGIN TRAN;
EXEC workflow.usp_TierChains_Probe @Rule = @Rule OUTPUT, @Detail = @Detail OUTPUT, @Quiet = 1;
SET @Ok = IIF(@@TRANCOUNT = 1 AND (SELECT COUNT(*) FROM hr.EMPLOYEE) = @People, 1, 0);
EXEC #QA3_Check @Ok, N'phase 4: inside a transaction the probe rolls back to its savepoint only';
ROLLBACK;
GO

/* ---- phase 5: SetMinTier takes any tier of the dictionary but the lowest, on a draft only ---- */
BEGIN TRAN;
DECLARE @Ok BIT, @T INT, @Draft INT, @Active INT, @Lowest INT = (SELECT MAX(TierNo) FROM hr.APPROVAL_TIER), @Err NVARCHAR(400);
DECLARE @R TABLE (WorkflowDefinitionId INT, [Version] INT, MinRequesterTier INT);
INSERT INTO workflow.REQUEST_TYPE (Code, Name, IsActive) VALUES ('QA3_TIERS5', N'QA3 tiers 5', 1); SET @T = SCOPE_IDENTITY();
INSERT INTO workflow.WORKFLOW_DEFINITION (RequestTypeId, [Version], [Status]) VALUES (@T, 1, 'Active'); SET @Active = SCOPE_IDENTITY();
INSERT INTO workflow.WORKFLOW_DEFINITION (RequestTypeId, [Version], [Status]) VALUES (@T, 2, 'Draft'); SET @Draft = SCOPE_IDENTITY();

INSERT INTO @R EXEC workflow.usp_Definition_SetMinTier @WorkflowDefinitionId = @Draft, @MinRequesterTier = 1;
SET @Ok = IIF((SELECT MinRequesterTier FROM @R) = 1, 1, 0); EXEC #QA3_Check @Ok, N'phase 5: tier 1 (the head only) can be chosen';
DELETE FROM @R; INSERT INTO @R EXEC workflow.usp_Definition_SetMinTier @WorkflowDefinitionId = @Draft, @MinRequesterTier = 5;
SET @Ok = IIF((SELECT MinRequesterTier FROM @R) = 5, 1, 0); EXEC #QA3_Check @Ok, N'phase 5: tier 5 can be chosen (the first model took only 2 or 3)';

SET @Err = NULL; BEGIN TRY EXEC workflow.usp_Definition_SetMinTier @WorkflowDefinitionId = @Draft, @MinRequesterTier = @Lowest; END TRY BEGIN CATCH SET @Err = ERROR_MESSAGE(); END CATCH
SET @Ok = IIF(@Err LIKE N'%is the lowest tier%', 1, 0); EXEC #QA3_Check @Ok, N'phase 5: the lowest tier is refused with a sentence';
SET @Err = NULL; BEGIN TRY EXEC workflow.usp_Definition_SetMinTier @WorkflowDefinitionId = @Draft, @MinRequesterTier = 99; END TRY BEGIN CATCH SET @Err = ERROR_MESSAGE(); END CATCH
SET @Ok = IIF(@Err LIKE N'%not on the tier list%', 1, 0); EXEC #QA3_Check @Ok, N'phase 5: a tier not on the list is refused';
SET @Err = NULL; BEGIN TRY EXEC workflow.usp_Definition_SetMinTier @WorkflowDefinitionId = @Active, @MinRequesterTier = 2; END TRY BEGIN CATCH SET @Err = ERROR_MESSAGE(); END CATCH
SET @Ok = IIF(@Err LIKE N'%only be set on a Draft%', 1, 0); EXEC #QA3_Check @Ok, N'phase 5: a published chain keeps its tier';
SET @Ok = IIF((SELECT MinRequesterTier FROM workflow.WORKFLOW_DEFINITION WHERE WorkflowDefinitionId = @Draft) = 5, 1, 0);
EXEC #QA3_Check @Ok, N'phase 5: a refused change leaves the draft as it was';
DELETE FROM @R; INSERT INTO @R EXEC workflow.usp_Definition_SetMinTier @WorkflowDefinitionId = @Draft, @MinRequesterTier = NULL;
SET @Ok = IIF((SELECT MinRequesterTier FROM workflow.WORKFLOW_DEFINITION WHERE WorkflowDefinitionId = @Draft) IS NULL, 1, 0);
EXEC #QA3_Check @Ok, N'phase 5: back to everyone';
ROLLBACK;
GO

PRINT 'ok tier_chains';
GO
