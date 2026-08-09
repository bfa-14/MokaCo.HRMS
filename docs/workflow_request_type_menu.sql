/* ============================================================================
   REQUEST TYPES AS A MENU  -  one entry per form, generated not hardcoded
   MokaCo_HRMS
   RUN AFTER: workflow_update_all.sql
   ----------------------------------------------------------------------------
   THE PROBLEM WITH BOTH OBVIOUS ANSWERS

     A single "New request" that then asks which kind is one click too many, and it
     hides what the system can actually do behind a picker.

     Hardcoding "Add exit permission" into the navigation is worse: adding a leave
     form later would mean editing the menu, the router and the nav component - and
     the whole point of this engine is that request types are DATA.

   SO: the menu is BUILT FROM THIS TABLE. Each raisable type becomes its own entry
   under Requests, with its own route. Adding a type means inserting a row, writing
   its typed table and _Decide procedure, and dropping in one form component.
   Nothing about the navigation changes.

   WHAT 'RAISABLE' MEANS
     Active, AND has a published chain. usp_Request_Submit raises an error when a
     type has no active workflow, so a menu entry for one would be a link that
     always fails. usp_RequestType_GetRaisable returns only what can actually be
     used, and the config screen gets the full list with the reason each is missing.

   ADDS: Icon, SortOrder, MenuLabel on REQUEST_TYPE; 2 procedures
   ============================================================================ */
USE MokaCo_HRMS;
GO

DROP PROCEDURE IF EXISTS workflow.usp_RequestType_GetRaisable;
DROP PROCEDURE IF EXISTS workflow.usp_RequestType_GetAllWithChainState;
GO

/* Presentation belongs with the type, not scattered through the frontend - it is
   configuration, and someone who adds a request type should be able to say how it
   appears without touching code. */
IF COL_LENGTH('workflow.REQUEST_TYPE', 'Icon') IS NULL
    ALTER TABLE workflow.REQUEST_TYPE ADD
        Icon      VARCHAR(40)  NULL,      -- lucide-react name. e.g. 'door-open'
        MenuLabel NVARCHAR(60) NULL,      -- shorter than Name, for the nav. e.g. 'Exit permission'
        SortOrder INT NOT NULL DEFAULT 0; -- menu order. e.g. 10
GO

UPDATE workflow.REQUEST_TYPE
SET Icon = 'door-open', MenuLabel = N'Exit permission', SortOrder = 10
WHERE Code = 'EXIT_PERMISSION';
GO

/* What a user may actually raise right now. Drives the navigation.
   A type with no published chain is EXCLUDED - offering it would produce a form
   that fails at the last step, after the person had filled it in. */
CREATE PROCEDURE workflow.usp_RequestType_GetRaisable
AS
BEGIN
    SET NOCOUNT ON;
    SELECT rt.RequestTypeId, rt.Code, rt.Name,
           ISNULL(rt.MenuLabel, rt.Name) AS MenuLabel,
           rt.[Description], rt.Icon, rt.SortOrder,
           d.WorkflowDefinitionId, d.[Version] AS WorkflowVersion,
           (SELECT COUNT(*) FROM workflow.WORKFLOW_STEP s
            WHERE s.WorkflowDefinitionId = d.WorkflowDefinitionId) AS StepCount
    FROM workflow.REQUEST_TYPE rt
    JOIN workflow.WORKFLOW_DEFINITION d
      ON d.RequestTypeId = rt.RequestTypeId AND d.[Status] = 'Active'
    WHERE rt.IsActive = 1
    ORDER BY rt.SortOrder, ISNULL(rt.MenuLabel, rt.Name);
END;
GO

/* The full list for the configuration screen, saying WHY anything is unusable.
   The menu hides those; an administrator needs to see them and the reason. */
CREATE PROCEDURE workflow.usp_RequestType_GetAllWithChainState
AS
BEGIN
    SET NOCOUNT ON;
    SELECT rt.RequestTypeId, rt.Code, rt.Name,
           ISNULL(rt.MenuLabel, rt.Name) AS MenuLabel,
           rt.[Description], rt.Icon, rt.SortOrder, rt.IsActive,
           act.WorkflowDefinitionId AS ActiveDefinitionId,
           act.[Version]            AS ActiveVersion,
           (SELECT COUNT(*) FROM workflow.WORKFLOW_DEFINITION d
            WHERE d.RequestTypeId = rt.RequestTypeId) AS VersionCount,
           CAST(CASE WHEN rt.IsActive = 1 AND act.WorkflowDefinitionId IS NOT NULL
                     THEN 1 ELSE 0 END AS BIT) AS IsRaisable,
           CASE WHEN rt.IsActive = 0
                  THEN N'Retired - kept for history, cannot be raised.'
                WHEN act.WorkflowDefinitionId IS NULL
                  THEN N'No published chain. Build one and publish it before anyone can raise this.'
                ELSE NULL END AS NotRaisableReason
    FROM workflow.REQUEST_TYPE rt
    LEFT JOIN workflow.WORKFLOW_DEFINITION act
           ON act.RequestTypeId = rt.RequestTypeId AND act.[Status] = 'Active'
    ORDER BY rt.SortOrder, rt.Name;
END;
GO

EXEC workflow.usp_RequestType_GetRaisable;
EXEC workflow.usp_RequestType_GetAllWithChainState;
GO
