/* ============================================================================
   hr.usp_Org_GetMaxDepth — how deep the current reporting ladder actually goes.

   The chain builder lets a Line-manager step climb N levels up the reporting
   line (EscalationLevels). If N is deeper than any real ladder, the engine
   resolves nobody and the step SKIPS. That is legal — an org grows into a chain
   built for a taller structure — but the builder should WARN, so an admin knows
   the step does nothing for anyone today.

   "Depth" here is defined exactly as hr.fn_GetLineManager climbs: up
   ReportsToEmployeeId, over IsDeleted = 0 employees only, level 1 = the direct
   manager. MaxDepth is the largest level at which SOME current employee still
   has a manager — i.e. the longest ReportsTo chain. 0 when nobody reports to
   anyone. Level (MaxDepth + 1) skips for every current employee.

   CREATE OR ALTER with QUOTED_IDENTIFIER ON so the procedure keeps the setting
   the EMPLOYEE table's filtered indexes require.
   ============================================================================ */

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

CREATE OR ALTER PROCEDURE hr.usp_Org_GetMaxDepth
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH ladder AS (
        /* level 1 = each current employee's direct manager */
        SELECT e.EmployeeId AS RootEmp, e.ReportsToEmployeeId AS MgrId, 1 AS Levels
        FROM hr.EMPLOYEE e
        WHERE e.IsDeleted = 0 AND e.ReportsToEmployeeId IS NOT NULL
        UNION ALL
        /* climb one more level while that manager themselves reports to someone.
           The Levels < 100 bound is a cycle backstop — writes already refuse loops,
           and no real org is 100 deep, so this only caps a corrupt chain. */
        SELECT l.RootEmp, m.ReportsToEmployeeId, l.Levels + 1
        FROM ladder l
        JOIN hr.EMPLOYEE m ON m.EmployeeId = l.MgrId AND m.IsDeleted = 0
        WHERE m.ReportsToEmployeeId IS NOT NULL AND l.Levels < 100
    )
    SELECT ISNULL(MAX(Levels), 0) AS MaxDepth
    FROM ladder
    OPTION (MAXRECURSION 100);
END;
GO
