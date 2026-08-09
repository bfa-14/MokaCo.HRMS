/* ============================================================================
   Signature requirement — carry HasSignatureImage.

   usp_Step_GetSignatureRequirement is read WITH the page so the sign popup knows,
   before anyone commits, whether a signature is required and how to explain it. It
   now also returns whether the CALLER has a signature image on file, so the popup
   can show it (or the quiet "no image" line) from this one read rather than a
   second call. Image-presence is the caller's, not the request's — a mark belongs
   to the person.

   QUOTED_IDENTIFIER ON so the recompiled procedure keeps the setting the tables'
   filtered indexes require.
   ============================================================================ */

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

CREATE OR ALTER PROCEDURE workflow.usp_Step_GetSignatureRequirement
    @RequestInstanceId INT,
    @UserId            INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Step INT, @DefId INT;
    SELECT @Step = CurrentStepNo, @DefId = WorkflowDefinitionId
    FROM workflow.REQUEST_INSTANCE
    WHERE RequestInstanceId = @RequestInstanceId AND [Status] IN ('Pending','OnHold');

    DECLARE @StepRequires BIT = ISNULL((
        SELECT RequiresSignature FROM workflow.WORKFLOW_STEP
        WHERE WorkflowDefinitionId = @DefId AND StepNo = @Step), 0);

    /* the role that is making them sign, if any - named so the prompt can explain */
    DECLARE @RoleName NVARCHAR(80) = (
        SELECT TOP 1 r.Name
        FROM security.USER_ROLE ur
        JOIN security.[ROLE] r ON r.RoleId = ur.RoleId
        WHERE ur.UserId = @UserId AND r.RequiresSignaturePassword = 1
        ORDER BY r.Name);

    DECLARE @Grace INT = ISNULL(TRY_CAST((SELECT SettingValue FROM core.SETTING
                                          WHERE SettingKey = 'SignatureGraceMinutes') AS INT), 0);

    SELECT
        CAST(CASE WHEN @StepRequires = 1 OR @RoleName IS NOT NULL
                  THEN 1 ELSE 0 END AS BIT) AS SignatureRequired,
        @RoleName        AS RequiredByRole,
        @StepRequires    AS RequiredByStep,
        @Grace           AS GraceMinutes,
        CASE WHEN @StepRequires = 1
               THEN N'This step must be signed, whoever approves it.'
             WHEN @RoleName IS NOT NULL
               THEN CONCAT(N'Decisions made as ', @RoleName, N' must be signed with your password.')
             ELSE NULL END AS Explanation,
        CAST(CASE WHEN EXISTS (SELECT 1 FROM security.USER_SIGNATURE WHERE UserId = @UserId)
                  THEN 1 ELSE 0 END AS BIT) AS HasSignatureImage;
END;
GO
