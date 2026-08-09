/* ============================================================================
   Employee profile — resolve the manager's NAME alongside ReportsToEmployeeId.

   usp_Employee_GetProfile already returns ReportsToEmployeeId (it selects e.*), but
   not the manager's name. The edit form wants the name so it can show the current
   manager immediately — before the full employee list has loaded, and even if that
   person is somehow not in it — instead of a blank control. A LEFT JOIN to the
   manager row adds ReportsToName; everything else is unchanged.

   QUOTED_IDENTIFIER ON so the recompiled procedure keeps the setting the tables'
   filtered indexes require.
   ============================================================================ */

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

CREATE OR ALTER PROCEDURE hr.usp_Employee_GetProfile
    @EmployeeId INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT e.*, b.Name AS BranchName, d.Name AS DepartmentName, p.Title AS PositionTitle,
           mgr.FullName AS ReportsToName
    FROM hr.EMPLOYEE e
    JOIN hr.BRANCH b     ON b.BranchId = e.BranchId
    JOIN hr.DEPARTMENT d ON d.DepartmentId = e.DepartmentId
    JOIN hr.[POSITION] p ON p.PositionId = e.PositionId
    LEFT JOIN hr.EMPLOYEE mgr ON mgr.EmployeeId = e.ReportsToEmployeeId AND mgr.IsDeleted = 0
    WHERE e.EmployeeId = @EmployeeId;

    SELECT sc.SalaryComponentId, ct.Name AS ComponentName, sc.Amount, sc.CurrencyCode,
           sc.EffectiveFrom, sc.EffectiveTo
    FROM hr.SALARY_COMPONENT sc
    JOIN hr.COMPONENT_TYPE ct ON ct.ComponentTypeId = sc.ComponentTypeId
    WHERE sc.EmployeeId = @EmployeeId
      AND (sc.EffectiveTo IS NULL OR sc.EffectiveTo >= CAST(SYSUTCDATETIME() AS DATE))
    ORDER BY ct.Name;
END;
GO
