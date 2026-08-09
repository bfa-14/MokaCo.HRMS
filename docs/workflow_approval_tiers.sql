/* Stored procedures capture these at CREATE time; the tables here carry filtered indexes that
   require QUOTED_IDENTIFIER ON, so set them before (re)creating any procedure. */
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ============================================================================
   Approval tiers — a requester's tier picks which published chain runs.

   MODEL
     hr.EMPLOYEE.ApprovalTier              1 = staff (default), 2 = management, 3 = executive
     workflow.WORKFLOW_DEFINITION.MinRequesterTier
                                           NULL = the default chain (everyone),
                                           2 = management and above, 3 = executive only
   A request follows the MOST SPECIFIC active chain the requester qualifies for: the
   highest MinRequesterTier that is <= their tier (NULL counts as 1). So TWO active
   chains per type is now normal, and NOT a conflict.

   This file is idempotent: the columns and the two setter procedures already exist in
   the live database from an earlier apply, so those are guarded / CREATE OR ALTER, and
   re-running changes nothing. What it actually FIXES is the three READ procedures that
   had not caught up:
     - usp_Definition_GetActive was NOT tier-aware — with two active chains it merged
       their steps. It now resolves to one chain, by the requester's tier.
     - usp_Definition_GetAll did not return MinRequesterTier (chains list needs it).
     - usp_Employee_GetAll did not return ApprovalTier (employee list tag needs it).
   ============================================================================ */

/* ---- columns (guarded — already present in live) ---- */
IF COL_LENGTH('hr.EMPLOYEE', 'ApprovalTier') IS NULL
    ALTER TABLE hr.EMPLOYEE ADD ApprovalTier INT NOT NULL CONSTRAINT DF_Employee_ApprovalTier DEFAULT 1;
GO
IF COL_LENGTH('workflow.WORKFLOW_DEFINITION', 'MinRequesterTier') IS NULL
    ALTER TABLE workflow.WORKFLOW_DEFINITION ADD MinRequesterTier INT NULL;
GO

/* ---- setters (already live; CREATE OR ALTER keeps this file the source of truth) ---- */
CREATE OR ALTER PROCEDURE hr.usp_Employee_SetApprovalTier
    @EmployeeId INT, @ApprovalTier INT
AS BEGIN SET NOCOUNT ON;
    IF @ApprovalTier NOT BETWEEN 1 AND 3
    BEGIN RAISERROR('Tier must be 1 (staff), 2 (management) or 3 (executive).', 16, 1); RETURN; END
    UPDATE hr.EMPLOYEE SET ApprovalTier = @ApprovalTier WHERE EmployeeId = @EmployeeId;
    SELECT EmployeeId, FullName, ApprovalTier FROM hr.EMPLOYEE WHERE EmployeeId = @EmployeeId;
END;
GO

/* set on a DRAFT only — the tier is part of what gets published */
CREATE OR ALTER PROCEDURE workflow.usp_Definition_SetMinTier
    @WorkflowDefinitionId INT, @MinRequesterTier INT = NULL
AS BEGIN SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM workflow.WORKFLOW_DEFINITION
                   WHERE WorkflowDefinitionId = @WorkflowDefinitionId AND [Status] = 'Draft')
    BEGIN RAISERROR('The tier can only be set on a Draft definition.', 16, 1); RETURN; END
    IF @MinRequesterTier IS NOT NULL AND @MinRequesterTier NOT BETWEEN 2 AND 3
    BEGIN RAISERROR('MinRequesterTier is 2, 3, or NULL for the default chain.', 16, 1); RETURN; END
    UPDATE workflow.WORKFLOW_DEFINITION SET MinRequesterTier = @MinRequesterTier
    WHERE WorkflowDefinitionId = @WorkflowDefinitionId;
    SELECT WorkflowDefinitionId, [Version], MinRequesterTier FROM workflow.WORKFLOW_DEFINITION
    WHERE WorkflowDefinitionId = @WorkflowDefinitionId;
END;
GO

/* ---- READS — the actual fix ---- */

/* The chain a NEW request would follow, resolved BY THE REQUESTER'S TIER when a
   @ForEmployeeId is given — the same resolution usp_Request_Submit uses, so the
   preview matches what will actually run. Without an employee it falls back to the
   default (everyone) chain rather than merging every active version's steps. */
CREATE OR ALTER PROCEDURE workflow.usp_Definition_GetActive
    @RequestTypeCode VARCHAR(30),
    @ForEmployeeId   INT = NULL
AS BEGIN SET NOCOUNT ON;

    DECLARE @Tier INT = 1;
    IF @ForEmployeeId IS NOT NULL
        SELECT @Tier = ISNULL(ApprovalTier, 1) FROM hr.EMPLOYEE WHERE EmployeeId = @ForEmployeeId;

    /* most specific chain the requester qualifies for: highest MinRequesterTier <= tier,
       NULL treated as 1 and sorting last */
    DECLARE @DefId INT;
    SELECT TOP 1 @DefId = d.WorkflowDefinitionId
    FROM workflow.WORKFLOW_DEFINITION d
    JOIN workflow.REQUEST_TYPE rt ON rt.RequestTypeId = d.RequestTypeId
    WHERE rt.Code = @RequestTypeCode AND d.[Status] = 'Active'
      AND ISNULL(d.MinRequesterTier, 1) <= @Tier
    ORDER BY ISNULL(d.MinRequesterTier, 1) DESC, d.[Version] DESC;

    SELECT d.WorkflowDefinitionId, d.[Version], d.PublishedAt, d.MinRequesterTier,
           s.StepNo, s.Name, s.ApproverType, s.ApproverRoleId, r.Name AS ApproverRoleName,
           s.FallbackRoleId, fr.Name AS FallbackRoleName,
           s.IsMandatory, s.CanAdjust
    FROM workflow.WORKFLOW_DEFINITION d
    LEFT JOIN workflow.WORKFLOW_STEP s ON s.WorkflowDefinitionId = d.WorkflowDefinitionId
    LEFT JOIN security.[ROLE] r  ON r.RoleId = s.ApproverRoleId
    LEFT JOIN security.[ROLE] fr ON fr.RoleId = s.FallbackRoleId
    WHERE d.WorkflowDefinitionId = @DefId
    ORDER BY s.StepNo;
END;
GO

/* Definitions list — now carrying MinRequesterTier so the chains page can show which
   population each chain serves, and the builder can show/edit it on a draft. */
CREATE OR ALTER PROCEDURE workflow.usp_Definition_GetAll
    @RequestTypeId INT = NULL
AS BEGIN SET NOCOUNT ON;
    SELECT d.WorkflowDefinitionId, d.RequestTypeId, rt.Code AS RequestTypeCode,
           rt.Name AS RequestTypeName, d.[Version], d.[Status], d.Notes,
           d.PublishedAt, d.CreatedAt, d.MinRequesterTier,
           (SELECT COUNT(*) FROM workflow.WORKFLOW_STEP s
            WHERE s.WorkflowDefinitionId = d.WorkflowDefinitionId) AS StepCount
    FROM workflow.WORKFLOW_DEFINITION d
    JOIN workflow.REQUEST_TYPE rt ON rt.RequestTypeId = d.RequestTypeId
    WHERE (@RequestTypeId IS NULL OR d.RequestTypeId = @RequestTypeId)
    ORDER BY rt.Name, d.[Version] DESC; END;
GO

/* Publish — retire only the CURRENT active chain of the SAME POPULATION, so a default chain and a
   management/executive chain can be active at the same time. Before this, publish retired every
   active version of the type, which made two active chains impossible. Requests already in flight
   still keep the version they locked at submit; nothing is migrated. */
CREATE OR ALTER PROCEDURE workflow.usp_Definition_Publish
    @WorkflowDefinitionId INT, @PublishedBy INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @TypeId INT, @DraftMinTier INT;
    SELECT @TypeId = RequestTypeId, @DraftMinTier = MinRequesterTier
    FROM workflow.WORKFLOW_DEFINITION
    WHERE WorkflowDefinitionId = @WorkflowDefinitionId AND [Status] = 'Draft';

    IF @TypeId IS NULL
    BEGIN RAISERROR('No Draft definition with that id.', 16, 1); RETURN; END

    IF NOT EXISTS (SELECT 1 FROM workflow.WORKFLOW_STEP WHERE WorkflowDefinitionId = @WorkflowDefinitionId)
    BEGIN RAISERROR('A workflow must have at least one step before it can be published.', 16, 1); RETURN; END

    BEGIN TRAN;

    /* only the active serving the SAME population steps aside — NULL matches NULL */
    UPDATE workflow.WORKFLOW_DEFINITION
    SET [Status] = 'Retired'
    WHERE RequestTypeId = @TypeId AND [Status] = 'Active'
      AND WorkflowDefinitionId <> @WorkflowDefinitionId
      AND ((MinRequesterTier IS NULL AND @DraftMinTier IS NULL) OR MinRequesterTier = @DraftMinTier);

    UPDATE workflow.WORKFLOW_DEFINITION
    SET [Status] = 'Active', PublishedAt = SYSUTCDATETIME(), PublishedBy = @PublishedBy
    WHERE WorkflowDefinitionId = @WorkflowDefinitionId;

    COMMIT TRAN;

    SELECT WorkflowDefinitionId, RequestTypeId, [Version], [Status], PublishedAt
    FROM workflow.WORKFLOW_DEFINITION WHERE WorkflowDefinitionId = @WorkflowDefinitionId;
END;
GO

/* Employee list — now carrying ApprovalTier so the grid can tag tier > 1. */
CREATE OR ALTER PROCEDURE hr.usp_Employee_GetAll
AS BEGIN SET NOCOUNT ON;
    SELECT e.EmployeeId, e.FullName, e.NationalId, e.NssfNumber, e.HireDate, e.TerminationDate,
           e.ApprovalTier,
           b.Name AS Branch, d.Name AS Department, p.Title AS Position
    FROM hr.EMPLOYEE e
    JOIN hr.BRANCH b     ON b.BranchId = e.BranchId
    JOIN hr.DEPARTMENT d ON d.DepartmentId = e.DepartmentId
    JOIN hr.[POSITION] p ON p.PositionId = e.PositionId
    WHERE e.IsDeleted = 0
    ORDER BY e.FullName;
END;
GO
