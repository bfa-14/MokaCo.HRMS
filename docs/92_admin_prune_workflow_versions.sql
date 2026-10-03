/* ============================================================================
   92_admin_prune_workflow_versions.sql — remove approval-chain versions nothing uses.

   Every edit of an approval chain publishes a NEW version (workflow.WORKFLOW_DEFINITION) and
   retires the previous one; retired versions are kept because requests submitted under them
   still point at them. Once those requests are gone (a data clean-up), the retired versions
   are dead weight, and "Requests on old chain versions" keeps listing them.

   dbo.usp_Admin_PruneWorkflowVersions @Execute = 0|1, @Renumber = 1|0
     DELETES a version when ALL of these hold:
       * its Status is 'Retired' (Active and Draft versions are never deleted);
       * no row anywhere references it - checked through every foreign key to
         WORKFLOW_DEFINITION, and to WORKFLOW_STEP for its steps - read from the catalog;
     with its steps and their allowed decisions.
     @Renumber = 1: for a request type none of whose remaining versions is used by a request,
       the remaining versions are renumbered 1, 2, ... in their existing order (the Active
       chain becomes version 1). Types with requests keep their numbers.
     @Execute = 0 (default) only reports. One transaction.

   EXEC dbo.usp_Admin_PruneWorkflowVersions;                  -- report
   EXEC dbo.usp_Admin_PruneWorkflowVersions @Execute = 1;     -- apply
   Idempotent: CREATE OR ALTER. Apply with sqlcmd -C -I -b.
   ============================================================================ */
CREATE OR ALTER PROCEDURE dbo.usp_Admin_PruneWorkflowVersions
    @Execute  BIT = 0,
    @Renumber BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @DefObj      INT = OBJECT_ID(N'workflow.WORKFLOW_DEFINITION'),
            @StepObj     INT = OBJECT_ID(N'workflow.WORKFLOW_STEP'),
            @DecisionObj INT = OBJECT_ID(N'workflow.WORKFLOW_STEP_DECISION');

    /* versions referenced by anything other than their own steps / step decisions */
    CREATE TABLE #used (WorkflowDefinitionId INT);
    DECLARE @sql NVARCHAR(MAX) = (
        SELECT STRING_AGG(CAST(
                 CASE WHEN fk.referenced_object_id = @DefObj
                      THEN N'INSERT #used SELECT DISTINCT x.' + QUOTENAME(c.name) + N' FROM '
                         + QUOTENAME(s.name) + N'.' + QUOTENAME(t.name) + N' x WHERE x.' + QUOTENAME(c.name) + N' IS NOT NULL;'
                      ELSE N'INSERT #used SELECT DISTINCT ws.WorkflowDefinitionId FROM '
                         + QUOTENAME(s.name) + N'.' + QUOTENAME(t.name) + N' x JOIN workflow.WORKFLOW_STEP ws ON ws.WorkflowStepId = x.'
                         + QUOTENAME(c.name) + N';'
                 END AS NVARCHAR(MAX)), NCHAR(10))
        FROM sys.foreign_keys fk
        JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
        JOIN sys.tables  t ON t.object_id = fk.parent_object_id
        JOIN sys.schemas s ON s.schema_id = t.schema_id
        JOIN sys.columns c ON c.object_id = fkc.parent_object_id AND c.column_id = fkc.parent_column_id
        WHERE (fk.referenced_object_id = @DefObj  AND fk.parent_object_id <> @StepObj)
           OR (fk.referenced_object_id = @StepObj AND fk.parent_object_id NOT IN (@StepObj, @DecisionObj)));
    IF @sql IS NOT NULL EXEC sys.sp_executesql @sql;

    CREATE TABLE #v (
        WorkflowDefinitionId INT PRIMARY KEY, RequestTypeId INT, [Version] INT, [Status] VARCHAR(20),
        InUse BIT, Action VARCHAR(10), NewVersion INT NULL);

    INSERT #v (WorkflowDefinitionId, RequestTypeId, [Version], [Status], InUse)
    SELECT d.WorkflowDefinitionId, d.RequestTypeId, d.[Version], d.[Status],
           CASE WHEN EXISTS (SELECT 1 FROM #used u WHERE u.WorkflowDefinitionId = d.WorkflowDefinitionId) THEN 1 ELSE 0 END
    FROM workflow.WORKFLOW_DEFINITION d;

    UPDATE #v SET Action = CASE WHEN [Status] = 'Retired' AND InUse = 0 THEN 'DELETE' ELSE 'KEEP' END;

    /* renumber the survivors of a type when none of them is used by a request */
    IF @Renumber = 1
        UPDATE v SET NewVersion = r.rn
        FROM #v v
        JOIN (SELECT WorkflowDefinitionId,
                     ROW_NUMBER() OVER (PARTITION BY RequestTypeId ORDER BY [Version]) AS rn
              FROM #v WHERE Action = 'KEEP') r ON r.WorkflowDefinitionId = v.WorkflowDefinitionId
        WHERE NOT EXISTS (SELECT 1 FROM #v u WHERE u.RequestTypeId = v.RequestTypeId AND u.Action = 'KEEP' AND u.InUse = 1);

    SELECT rt.Code AS [Request type], v.[Version], v.[Status],
           CASE WHEN v.InUse = 1 THEN N'yes' ELSE N'no' END AS [Used by requests],
           v.Action,
           CASE WHEN v.Action = 'KEEP' AND v.NewVersion IS NOT NULL AND v.NewVersion <> v.[Version]
                THEN N'v' + CAST(v.[Version] AS NVARCHAR(10)) + N' -> v' + CAST(v.NewVersion AS NVARCHAR(10)) END AS Renumber
    FROM #v v JOIN workflow.REQUEST_TYPE rt ON rt.RequestTypeId = v.RequestTypeId
    ORDER BY rt.Code, v.[Version];

    IF @Execute = 0
    BEGIN PRINT 'Report only. Re-run with @Execute = 1 to apply.'; RETURN; END

    BEGIN TRAN;
        DELETE sd FROM workflow.WORKFLOW_STEP_DECISION sd
        JOIN workflow.WORKFLOW_STEP ws ON ws.WorkflowStepId = sd.WorkflowStepId
        JOIN #v v ON v.WorkflowDefinitionId = ws.WorkflowDefinitionId AND v.Action = 'DELETE';

        DELETE ws FROM workflow.WORKFLOW_STEP ws
        JOIN #v v ON v.WorkflowDefinitionId = ws.WorkflowDefinitionId AND v.Action = 'DELETE';

        DELETE d FROM workflow.WORKFLOW_DEFINITION d
        JOIN #v v ON v.WorkflowDefinitionId = d.WorkflowDefinitionId AND v.Action = 'DELETE';

        /* two steps, so (RequestTypeId, Version) stays unique while numbers move */
        UPDATE d SET [Version] = d.[Version] + 1000000
        FROM workflow.WORKFLOW_DEFINITION d
        JOIN #v v ON v.WorkflowDefinitionId = d.WorkflowDefinitionId
        WHERE v.NewVersion IS NOT NULL AND v.NewVersion <> v.[Version];

        UPDATE d SET [Version] = v.NewVersion
        FROM workflow.WORKFLOW_DEFINITION d
        JOIN #v v ON v.WorkflowDefinitionId = d.WorkflowDefinitionId
        WHERE v.NewVersion IS NOT NULL AND v.NewVersion <> v.[Version];
    COMMIT;

    SELECT N'DONE' AS Result,
           (SELECT COUNT(*) FROM #v WHERE Action = 'DELETE') AS [Versions deleted],
           (SELECT COUNT(*) FROM #v WHERE NewVersion IS NOT NULL AND NewVersion <> [Version]) AS [Versions renumbered];
END;
GO
