/* ============================================================================
   Chain builder — authoring the per-step RequiresSignature flag, and clearing a
   dead reference that had quietly broken both definition procedures.

   TWO things this fixes:

   1. workflow.WORKFLOW_STEP.RejectionEndsRequest was DROPPED when rejection
      behaviour moved onto the ROLE (Settings → "When a role rejects"), but
      usp_Definition_AddStep and usp_Definition_GetSteps still referenced it — so
      both threw "Invalid column name 'RejectionEndsRequest'" at runtime. Adding a
      step through the builder could not have worked. Every reference to it is
      removed here; the rule lives on the role now and nothing per-step reads it.

   2. WORKFLOW_STEP.RequiresSignature exists and the DECISION engine already reads
      it (usp_Request_GetSteps surfaces it as StepRequiresSignature, feeding the
      sign prompt and WithdrawNeedsSignature), but nothing could SET it: AddStep had
      no @RequiresSignature parameter and GetSteps never returned it. Both gaps are
      closed so the builder can turn per-step signing on and show whether it is on.

   Both procedures are rewritten in full — current shape, minus the dropped column,
   plus the signature flag — so this file alone is their source of truth. Every new
   parameter defaults to its prior behaviour, so existing callers are unaffected.
   ============================================================================ */

CREATE OR ALTER PROCEDURE workflow.usp_Definition_AddStep
    @WorkflowDefinitionId INT,
    @StepNo          INT,
    @Name            NVARCHAR(80),
    @ApproverType    VARCHAR(20),
    @ApproverRoleId  INT = NULL,
    @ApproverUserId  INT = NULL,
    @FallbackRoleId  INT = NULL,          -- deputy who may also sign
    @IsMandatory     BIT = 1,
    @CanAdjust       BIT = 0,
    @RequiresComment BIT = 0,
    @RequiresSignature BIT = 0            -- every decision here signed with a password, whoever signs
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM workflow.WORKFLOW_DEFINITION
                   WHERE WorkflowDefinitionId = @WorkflowDefinitionId AND [Status] = 'Draft')
    BEGIN
        RAISERROR('Steps can only be added to a Draft definition. Create a new draft version instead.', 16, 1);
        RETURN;
    END

    IF @FallbackRoleId IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM security.USER_ROLE ur
                       JOIN security.[USER] u ON u.UserId = ur.UserId
                       WHERE ur.RoleId = @FallbackRoleId AND u.IsActive = 1)
    BEGIN
        RAISERROR('That fallback role has no active members, so it could never sign anything.', 16, 1);
        RETURN;
    END

    IF EXISTS (SELECT 1 FROM workflow.WORKFLOW_STEP
               WHERE WorkflowDefinitionId = @WorkflowDefinitionId AND StepNo = @StepNo)
        UPDATE workflow.WORKFLOW_STEP
        SET Name = @Name, ApproverType = @ApproverType,
            ApproverRoleId = @ApproverRoleId, ApproverUserId = @ApproverUserId,
            FallbackRoleId = @FallbackRoleId, IsMandatory = @IsMandatory,
            CanAdjust = @CanAdjust, RequiresComment = @RequiresComment,
            RequiresSignature = @RequiresSignature
        WHERE WorkflowDefinitionId = @WorkflowDefinitionId AND StepNo = @StepNo;
    ELSE
        INSERT INTO workflow.WORKFLOW_STEP
            (WorkflowDefinitionId, StepNo, Name, ApproverType, ApproverRoleId,
             ApproverUserId, FallbackRoleId, IsMandatory, CanAdjust, RequiresComment,
             RequiresSignature)
        VALUES (@WorkflowDefinitionId, @StepNo, @Name, @ApproverType, @ApproverRoleId,
                @ApproverUserId, @FallbackRoleId, @IsMandatory, @CanAdjust, @RequiresComment,
                @RequiresSignature);
END;
GO

CREATE OR ALTER PROCEDURE workflow.usp_Definition_GetSteps @WorkflowDefinitionId INT
AS BEGIN SET NOCOUNT ON;
    SELECT s.WorkflowStepId, s.StepNo, s.Name, s.ApproverType,
           s.ApproverRoleId, r.Name AS ApproverRoleName,
           s.ApproverUserId, u.Username AS ApproverUsername,
           s.FallbackRoleId, fr.Name AS FallbackRoleName,
           s.IsMandatory, s.CanAdjust, s.RequiresComment, s.RequiresSignature,
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
