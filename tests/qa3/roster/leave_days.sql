/* ============================================================================
   tests/qa3/roster/leave_days.sql -- QA3 ROS-4 / LEV-5 (docs/102_qa3_roster.sql).
   The roster page's leave overlay (attendance.usp_Roster_GetLeaveDays) reads the APPROVED leave requests day by day:
   every day of the range (not one ledger row per month), a half day as 0.5, a partial approval up to the day it was
   approved to (ApprovedToDate), nothing for a pending request or for exit-permission minutes converted to leave, and
   a day belongs to the employee's branch OF THAT DAY.
   Runs on a real dev database: everything inside one transaction that is rolled back; seeded rows start with 'QA3 '.
   Months in 2097. Prints 'ok leave_days', or raises the first wrong result. Needs 99-102.
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
SET QUOTED_IDENTIFIER ON;
BEGIN TRAN;
BEGIN TRY
    DECLARE @msg NVARCHAR(2000);
    DECLARE @Dep INT = (SELECT TOP 1 DepartmentId FROM hr.DEPARTMENT ORDER BY DepartmentId);
    DECLARE @Pos INT = (SELECT TOP 1 PositionId FROM hr.[POSITION] ORDER BY PositionId);
    DECLARE @User INT = (SELECT TOP 1 UserId FROM security.[USER] ORDER BY UserId);
    DECLARE @LT INT = (SELECT RequestTypeId FROM workflow.REQUEST_TYPE WHERE Code = 'LEAVE_REQUEST');
    DECLARE @LDef INT = (SELECT TOP 1 WorkflowDefinitionId FROM workflow.WORKFLOW_DEFINITION WHERE RequestTypeId = @LT
                         ORDER BY CASE WHEN [Status] = 'Active' THEN 0 ELSE 1 END, WorkflowDefinitionId DESC);
    DECLARE @Annual INT = (SELECT TOP 1 LeaveTypeId FROM hr.LEAVE_TYPE ORDER BY CASE WHEN Name = N'Annual' THEN 0 ELSE 1 END, LeaveTypeId);
    IF @LT IS NULL OR @LDef IS NULL OR @Annual IS NULL RAISERROR('FAIL leave_days: no LEAVE_REQUEST workflow or leave type on this database.', 16, 1);

    INSERT INTO hr.BRANCH (Name, IsActive) VALUES (N'QA3 Leave Days A', 1);
    DECLARE @BA INT = SCOPE_IDENTITY();
    INSERT INTO hr.BRANCH (Name, IsActive) VALUES (N'QA3 Leave Days B', 1);
    DECLARE @BB INT = SCOPE_IDENTITY();
    INSERT INTO hr.EMPLOYEE (BranchId, DepartmentId, PositionId, FullName, HireDate) VALUES (@BA, @Dep, @Pos, N'QA3 Leave Days E1', '2090-01-01');
    DECLARE @E INT = SCOPE_IDENTITY();
    /* transferred to branch B from 20 April 2097 */
    INSERT INTO hr.EMPLOYEE_BRANCH_HISTORY (EmployeeId, BranchId, EffectiveFrom, Note) VALUES (@E, @BA, '2090-01-01', N'QA3'), (@E, @BB, '2097-04-20', N'QA3');

    DECLARE @rid INT;
    /* (1) 6-10 April, approved in full */
    INSERT INTO workflow.REQUEST_INSTANCE (RequestTypeId, WorkflowDefinitionId, EmployeeId, RaisedByUserId, [Status], Title, ClosedAt)
    VALUES (@LT, @LDef, @E, @User, 'Approved', N'QA3 leave days 1', SYSUTCDATETIME());
    SET @rid = SCOPE_IDENTITY();
    INSERT INTO workflow.LEAVE_REQUEST (RequestInstanceId, EmployeeId, LeaveTypeId, FromDate, ToDate, DaysRequested, IsDiscretionary)
    VALUES (@rid, @E, @Annual, '2097-04-06', '2097-04-10', 5, 0);
    /* (2) 14 April, a morning */
    INSERT INTO workflow.REQUEST_INSTANCE (RequestTypeId, WorkflowDefinitionId, EmployeeId, RaisedByUserId, [Status], Title, ClosedAt)
    VALUES (@LT, @LDef, @E, @User, 'Approved', N'QA3 leave days 2', SYSUTCDATETIME());
    SET @rid = SCOPE_IDENTITY();
    INSERT INTO workflow.LEAVE_REQUEST (RequestInstanceId, EmployeeId, LeaveTypeId, FromDate, ToDate, DaysRequested, HalfDay, IsDiscretionary)
    VALUES (@rid, @E, @Annual, '2097-04-14', '2097-04-14', 0.5, 'AM', 0);
    /* (3) 17-24 April asked, approved up to the 21st (a partial approval keeps the first days) */
    INSERT INTO workflow.REQUEST_INSTANCE (RequestTypeId, WorkflowDefinitionId, EmployeeId, RaisedByUserId, [Status], Title, ClosedAt)
    VALUES (@LT, @LDef, @E, @User, 'Approved', N'QA3 leave days 3', SYSUTCDATETIME());
    SET @rid = SCOPE_IDENTITY();
    INSERT INTO workflow.LEAVE_REQUEST (RequestInstanceId, EmployeeId, LeaveTypeId, FromDate, ToDate, DaysRequested, DaysApproved, ApprovedToDate, IsDiscretionary)
    VALUES (@rid, @E, @Annual, '2097-04-17', '2097-04-24', 8, 5, '2097-04-21', 0);
    /* (4) 27-28 April, still pending */
    INSERT INTO workflow.REQUEST_INSTANCE (RequestTypeId, WorkflowDefinitionId, EmployeeId, RaisedByUserId, [Status], Title)
    VALUES (@LT, @LDef, @E, @User, 'Pending', N'QA3 leave days 4');
    SET @rid = SCOPE_IDENTITY();
    INSERT INTO workflow.LEAVE_REQUEST (RequestInstanceId, EmployeeId, LeaveTypeId, FromDate, ToDate, DaysRequested, IsDiscretionary)
    VALUES (@rid, @E, @Annual, '2097-04-27', '2097-04-28', 2, 0);
    /* (5) exit-permission minutes converted to leave on 2 April: a ledger row, not a leave request */
    INSERT INTO hr.LEAVE_LEDGER (EmployeeId, LeaveTypeId, PeriodYearMonth, MovementType, Days, EffectiveDate, Note)
    VALUES (@E, @Annual, '2097-04', 'Usage', -0.25, '2097-04-02', N'QA3 exit permission converted to leave');

    DECLARE @lv TABLE (EmployeeId INT, [Date] DATE, DaysOnLeave DECIMAL(6,2));
    INSERT INTO @lv EXEC attendance.usp_Roster_GetLeaveDays @FromDate = '2097-04-01', @ToDate = '2097-04-30', @BranchId = NULL, @CallerUserId = NULL;
    DELETE FROM @lv WHERE EmployeeId <> @E;
    DECLARE @expect TABLE ([Date] DATE PRIMARY KEY, DaysOnLeave DECIMAL(6,2));
    INSERT INTO @expect VALUES ('2097-04-06', 1), ('2097-04-07', 1), ('2097-04-08', 1), ('2097-04-09', 1), ('2097-04-10', 1),
                               ('2097-04-14', 0.5),
                               ('2097-04-17', 1), ('2097-04-18', 1), ('2097-04-19', 1), ('2097-04-20', 1), ('2097-04-21', 1);
    IF EXISTS (SELECT [Date], DaysOnLeave FROM @lv EXCEPT SELECT [Date], DaysOnLeave FROM @expect)
       OR EXISTS (SELECT [Date], DaysOnLeave FROM @expect EXCEPT SELECT [Date], DaysOnLeave FROM @lv)
    BEGIN
        SELECT @msg = CONCAT('FAIL leave_days: expected 6-10 (1), 14 (0.5), 17-21 (1) April; got ',
                             ISNULL((SELECT STRING_AGG(CONCAT(DAY([Date]), '=', DaysOnLeave), ', ') WITHIN GROUP (ORDER BY [Date]) FROM @lv), 'nothing'));
        RAISERROR(@msg, 16, 1);
    END

    /* branch of the day: A holds the days before the 20th, B the 20th and 21st */
    DELETE FROM @lv;
    INSERT INTO @lv EXEC attendance.usp_Roster_GetLeaveDays @FromDate = '2097-04-01', @ToDate = '2097-04-30', @BranchId = @BB, @CallerUserId = NULL;
    IF (SELECT COUNT(*) FROM @lv WHERE EmployeeId = @E) <> 2 OR EXISTS (SELECT 1 FROM @lv WHERE EmployeeId = @E AND [Date] < '2097-04-20')
        RAISERROR('FAIL leave_days: branch B must show only the leave days from the transfer (20-21 April).', 16, 1);

    ROLLBACK;
    PRINT 'ok leave_days';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    DECLARE @failure NVARCHAR(4000) = ERROR_MESSAGE();
    RAISERROR(@failure, 16, 1);
END CATCH;
