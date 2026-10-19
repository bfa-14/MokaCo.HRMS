/* ============================================================================
   tests/qa3/roster/month_status.sql -- QA3 ROS-7 (docs/102_qa3_roster.sql).
   A month approved, changed, re-submitted and the re-submission REJECTED: the month is still "changed since
   approval" (measured against the latest APPROVED request, not the rejected one), so Submit stays live and a new
   submission is accepted.
   Runs on a real dev database: everything inside one transaction that is rolled back; seeded rows start with 'QA3 '.
   Uses next month. Prints 'ok month_status', or raises the first wrong result. Needs 99-102.
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
SET QUOTED_IDENTIFIER ON;
BEGIN TRAN;
BEGIN TRY
    DECLARE @msg NVARCHAR(2000);
    DECLARE @Today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE);
    DECLARE @NM DATE = DATEADD(MONTH, 1, DATEFROMPARTS(YEAR(@Today), MONTH(@Today), 1));
    DECLARE @Dep INT = (SELECT TOP 1 DepartmentId FROM hr.DEPARTMENT ORDER BY DepartmentId);
    DECLARE @Pos INT = (SELECT TOP 1 PositionId FROM hr.[POSITION] ORDER BY PositionId);
    DECLARE @User INT = (SELECT TOP 1 UserId FROM security.[USER] ORDER BY UserId);
    DECLARE @RT INT = (SELECT RequestTypeId FROM workflow.REQUEST_TYPE WHERE Code = 'ROSTER_APPROVAL');
    DECLARE @RDef INT = (SELECT TOP 1 WorkflowDefinitionId FROM workflow.WORKFLOW_DEFINITION WHERE RequestTypeId = @RT
                         ORDER BY CASE WHEN [Status] = 'Active' THEN 0 ELSE 1 END, WorkflowDefinitionId DESC);
    IF @RT IS NULL OR @RDef IS NULL RAISERROR('FAIL month_status: no ROSTER_APPROVAL workflow on this database.', 16, 1);

    INSERT INTO hr.BRANCH (Name, IsActive) VALUES (N'QA3 Status Branch', 1);
    DECLARE @B INT = SCOPE_IDENTITY();
    INSERT INTO hr.EMPLOYEE (BranchId, DepartmentId, PositionId, FullName, HireDate) VALUES (@B, @Dep, @Pos, N'QA3 Status Barista', '2020-01-01');
    DECLARE @E INT = SCOPE_IDENTITY();
    INSERT INTO attendance.SHIFT (Name, StartTime, EndTime, GraceMinutes, CrossesMidnight, BreakMinutes, IsActive)
    VALUES (N'QA3 Status Day', '08:00', '16:00', NULL, 0, 30, 1);
    DECLARE @Sh INT = SCOPE_IDENTITY();
    DECLARE @d DATE = @NM;
    WHILE @d <= EOMONTH(@NM)
    BEGIN
        INSERT INTO attendance.SHIFT_ASSIGNMENT (EmployeeId, ShiftId, WorkDate, IsRestDay) VALUES (@E, @Sh, @d, 0);
        SET @d = DATEADD(DAY, 1, @d);
    END
    UPDATE attendance.SHIFT_ASSIGNMENT SET ModifiedUtc = DATEADD(HOUR, -3, SYSUTCDATETIME()) WHERE EmployeeId = @E;

    /* #1 approved two hours ago */
    INSERT INTO workflow.REQUEST_INSTANCE (RequestTypeId, WorkflowDefinitionId, EmployeeId, RaisedByUserId, [Status], Title, ClosedAt)
    VALUES (@RT, @RDef, @E, @User, 'Approved', N'QA3 status #1', DATEADD(HOUR, -2, SYSUTCDATETIME()));
    DECLARE @R1 INT = SCOPE_IDENTITY();
    INSERT INTO workflow.ROSTER_APPROVAL (RequestInstanceId, BranchId, MonthDate) VALUES (@R1, @B, @NM);
    EXEC workflow.usp_Request_ApplyApprovalEffects @RequestInstanceId = @R1;
    DECLARE @Approved1 DATETIME2 = (SELECT ClosedAt FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId = @R1);

    /* a day changed an hour ago, re-submitted (#2) and rejected */
    DECLARE @Day DATE = DATEADD(DAY, 9, @NM);
    DECLARE @r TABLE (Id INT);
    INSERT INTO @r EXEC attendance.usp_ShiftAssignment_Upsert @EmployeeId = @E, @WorkDate = @Day, @ShiftId = NULL, @IsRestDay = 1;
    INSERT INTO workflow.REQUEST_INSTANCE (RequestTypeId, WorkflowDefinitionId, EmployeeId, RaisedByUserId, [Status], Title, ClosedAt, ClosedReason)
    VALUES (@RT, @RDef, @E, @User, 'Rejected', N'QA3 status #2', DATEADD(SECOND, 30, SYSUTCDATETIME()), N'QA3: not this change');
    DECLARE @R2 INT = SCOPE_IDENTITY();
    INSERT INTO workflow.ROSTER_APPROVAL (RequestInstanceId, BranchId, MonthDate) VALUES (@R2, @B, @NM);
    UPDATE attendance.ROSTER_MONTH SET RequestInstanceId = @R2 WHERE BranchId = @B AND MonthDate = @NM;   -- as the submission left it

    DECLARE @st TABLE (RosterMonthId INT, BranchId INT, MonthDate DATE, [Status] VARCHAR(30), ApprovedAt DATETIME2, RequestInstanceId INT,
                       RequestStatus VARCHAR(20), OpenRequestId INT, OpenRequestStatus VARCHAR(20), LastApprovedAt DATETIME2,
                       ChangedSinceApproval BIT, LastChangedUtc DATETIME2, RederivedAt DATETIME2);
    INSERT INTO @st EXEC attendance.usp_RosterMonth_Get @BranchId = @B, @MonthDate = @NM;
    IF NOT EXISTS (SELECT 1 FROM @st WHERE [Status] = 'Approved' AND ChangedSinceApproval = 1 AND LastApprovedAt = @Approved1 AND OpenRequestId IS NULL)
    BEGIN
        SELECT @msg = CONCAT('FAIL month_status: after a rejected re-submission the month must still read Approved + changed since ',
                             CONVERT(VARCHAR(30), @Approved1, 126), '; got ',
                             ISNULL((SELECT CONCAT([Status], ', changed=', ChangedSinceApproval, ', last approved ', CONVERT(VARCHAR(30), LastApprovedAt, 126))
                                     FROM @st), 'no row'));
        RAISERROR(@msg, 16, 1);
    END

    /* Submit is accepted again (when this database has the chain to submit into) */
    IF EXISTS (SELECT 1 FROM workflow.WORKFLOW_DEFINITION WHERE RequestTypeId = @RT AND [Status] = 'Active')
    BEGIN
        DECLARE @UHr INT;
        INSERT INTO security.[USER] (Username, PasswordHash, IsActive) VALUES (N'qa3.status.hr', N'x', 1);
        SET @UHr = SCOPE_IDENTITY();
        INSERT INTO security.[ROLE] (Name) VALUES (N'QA3 Status HR');
        INSERT INTO security.ROLE_PERMISSION (RoleId, PermissionId) SELECT SCOPE_IDENTITY(), PermissionId FROM security.PERMISSION WHERE Code = 'EMP_VIEW_ALL';
        INSERT INTO security.USER_ROLE (UserId, RoleId) SELECT @UHr, RoleId FROM security.[ROLE] WHERE Name = N'QA3 Status HR';
        EXEC workflow.usp_RosterApproval_Create @EmployeeId = @E, @RaisedByUserId = @UHr, @BranchId = @B, @MonthDate = @NM;
        IF @@TRANCOUNT = 0 RAISERROR('FAIL month_status: the submission was refused and rolled the test back.', 16, 1);
        IF NOT EXISTS (SELECT 1 FROM workflow.ROSTER_APPROVAL ra JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = ra.RequestInstanceId
                       WHERE ra.BranchId = @B AND ra.MonthDate = @NM AND ri.RequestInstanceId > @R2)
            RAISERROR('FAIL month_status: a new submission after the rejected one was not accepted.', 16, 1);
    END
    ELSE PRINT 'note month_status: no active ROSTER_APPROVAL chain - the new submission was not exercised.';

    ROLLBACK;
    PRINT 'ok month_status';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    DECLARE @failure NVARCHAR(4000) = ERROR_MESSAGE();
    RAISERROR(@failure, 16, 1);
END CATCH;
