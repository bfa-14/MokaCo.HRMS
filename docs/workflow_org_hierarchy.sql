/* ============================================================================
   Org hierarchy — completing the READ side.

   The engine half of this feature is already live: hr.EMPLOYEE.ReportsToEmployeeId,
   workflow.WORKFLOW_STEP.EscalationLevels, hr.fn_GetLineManager, the LineManager
   branch of workflow.fn_ResolveApprover, the three hr.usp_Employee_* procedures
   (SetReportsTo with its loop guard, GetReportingLine, GetOrgTree), and the
   LineManager resolution + skip-reason in usp_Request_Submit.

   What had NOT caught up were the two definition READ procedures the UI uses:

     - usp_Definition_GetActive (the New Request preview) returned the LineManager
       step but never resolved WHO it is for the selected employee, so the preview
       could not show the actual person. It now does, via hr.fn_GetLineManager, and
       returns EscalationLevels too.
     - usp_Definition_GetSteps (the chain builder's "chain so far") did not return
       EscalationLevels, so a Line-manager step could not show its level.

   Both are rewritten in full (current shape + the additions). CREATE OR ALTER with
   QUOTED_IDENTIFIER ON so the recompiled procedures keep the setting the tables'
   filtered indexes require.
   ============================================================================ */

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* TWO CHECK constraints on WORKFLOW_STEP were never widened for the new 'LineManager'
   type, so AddStep rejected every line-manager step:
     - CK_WfStep_Type  restricted ApproverType to the three old values;
     - CK_WfStep_Target required a role/user target per type and had no rule for
       LineManager, so a LineManager row (no role, no user) violated it.
   LineManager resolves from the requester's reporting line, so — like BranchManager —
   it carries neither a role nor a user id. */
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_WfStep_Type')
    ALTER TABLE workflow.WORKFLOW_STEP DROP CONSTRAINT CK_WfStep_Type;
GO
ALTER TABLE workflow.WORKFLOW_STEP WITH CHECK ADD CONSTRAINT CK_WfStep_Type
    CHECK (ApproverType IN ('SpecificUser', 'Role', 'BranchManager', 'LineManager'));
GO
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_WfStep_Target')
    ALTER TABLE workflow.WORKFLOW_STEP DROP CONSTRAINT CK_WfStep_Target;
GO
ALTER TABLE workflow.WORKFLOW_STEP WITH CHECK ADD CONSTRAINT CK_WfStep_Target
    CHECK (
        (ApproverType = 'Role'         AND ApproverRoleId IS NOT NULL) OR
        (ApproverType = 'SpecificUser' AND ApproverUserId IS NOT NULL) OR
        (ApproverType = 'BranchManager') OR
        (ApproverType = 'LineManager')
    );
GO

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
           s.IsMandatory, s.CanAdjust, s.EscalationLevels,
           /* the ACTUAL line-manager for THIS requester, N levels up — so the preview
              shows the real person, not a generic "Line manager". Null off the top of
              the tree (the step will skip), and null when no requester is given. */
           CASE WHEN s.ApproverType = 'LineManager' AND @ForEmployeeId IS NOT NULL
                THEN (SELECT me.FullName FROM hr.EMPLOYEE me
                      WHERE me.EmployeeId = hr.fn_GetLineManager(@ForEmployeeId, ISNULL(s.EscalationLevels, 1)))
                ELSE NULL END AS ResolvedApproverName
    FROM workflow.WORKFLOW_DEFINITION d
    LEFT JOIN workflow.WORKFLOW_STEP s ON s.WorkflowDefinitionId = d.WorkflowDefinitionId
    LEFT JOIN security.[ROLE] r  ON r.RoleId = s.ApproverRoleId
    LEFT JOIN security.[ROLE] fr ON fr.RoleId = s.FallbackRoleId
    WHERE d.WorkflowDefinitionId = @DefId
    ORDER BY s.StepNo;
END;
GO

CREATE OR ALTER PROCEDURE workflow.usp_Definition_GetSteps @WorkflowDefinitionId INT
AS BEGIN SET NOCOUNT ON;
    SELECT s.WorkflowStepId, s.StepNo, s.Name, s.ApproverType,
           s.ApproverRoleId, r.Name AS ApproverRoleName,
           s.ApproverUserId, u.Username AS ApproverUsername,
           s.FallbackRoleId, fr.Name AS FallbackRoleName,
           s.IsMandatory, s.CanAdjust, s.RequiresComment, s.RequiresSignature,
           s.EscalationLevels,
           /* the last step is final whatever any flag says - nothing follows it */
           CAST(CASE WHEN s.StepNo = (SELECT MAX(StepNo) FROM workflow.WORKFLOW_STEP x
                                      WHERE x.WorkflowDefinitionId = s.WorkflowDefinitionId)
                     THEN 1 ELSE 0 END AS BIT) AS IsFinalStep
    FROM workflow.WORKFLOW_STEP s
    LEFT JOIN security.[ROLE] r  ON r.RoleId = s.ApproverRoleId
    LEFT JOIN security.[ROLE] fr ON fr.RoleId = s.FallbackRoleId
    LEFT JOIN security.[USER] u  ON u.UserId = s.ApproverUserId
    WHERE s.WorkflowDefinitionId = @WorkflowDefinitionId
    ORDER BY s.StepNo; END;
GO
