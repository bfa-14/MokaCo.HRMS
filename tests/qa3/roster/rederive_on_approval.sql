/* ============================================================================
   tests/qa3/roster/rederive_on_approval.sql -- QA3 ROS-2 / ATT-1, ROS-12 (docs/102_qa3_roster.sql).
   Approving a roster month derives its completed days again from the approved roster: a day processed while the
   roster was a draft is measured against its shift, every past rostered day gets its record (payroll readiness no
   longer counts "rostered days with no record"), today and later days are left alone, the leave of the month is
   re-priced (unit D's hr.usp_LeaveLedger_Reprice), the month is marked re-derived, and a month approved again since
   is picked up by the nightly safety net.
   Runs on a real dev database: everything inside one transaction that is rolled back; seeded rows start with 'QA3 '.
   Uses the PREVIOUS month (past days; never paid for a QA3 employee). Prints 'ok rederive_on_approval', or raises the
   first wrong result. Needs 99-102.
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
SET QUOTED_IDENTIFIER ON;
BEGIN TRAN;
BEGIN TRY
    DECLARE @msg NVARCHAR(2000), @n INT;
    DECLARE @Today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE);
    DECLARE @PM DATE = DATEADD(MONTH, -1, DATEFROMPARTS(YEAR(@Today), MONTH(@Today), 1));
    DECLARE @PMEnd DATE = EOMONTH(@PM);
    DECLARE @CM DATE = DATEFROMPARTS(YEAR(@Today), MONTH(@Today), 1);
    DECLARE @Dep INT = (SELECT TOP 1 DepartmentId FROM hr.DEPARTMENT ORDER BY DepartmentId);
    DECLARE @Pos INT = (SELECT TOP 1 PositionId FROM hr.[POSITION] ORDER BY PositionId);
    DECLARE @User INT = (SELECT TOP 1 UserId FROM security.[USER] ORDER BY UserId);

    INSERT INTO hr.BRANCH (Name, IsActive) VALUES (N'QA3 Rederive Branch', 1);
    DECLARE @B INT = SCOPE_IDENTITY();
    INSERT INTO attendance.SHIFT (Name, StartTime, EndTime, GraceMinutes, CrossesMidnight, BreakMinutes, IsActive)
    VALUES (N'QA3 Short', '18:00', '23:00', NULL, 0, 0, 1);
    DECLARE @Short INT = SCOPE_IDENTITY();
    INSERT INTO hr.EMPLOYEE (BranchId, DepartmentId, PositionId, FullName, HireDate) VALUES (@B, @Dep, @Pos, N'QA3 Rederive E1', '2020-01-01');
    DECLARE @E1 INT = SCOPE_IDENTITY();

    /* a week of approved leave in the month, approved and posted BEFORE the month was rostered (ROS-12) */
    DECLARE @LvMon DATE = DATEADD(DAY, 7, @PM);
    WHILE DATEDIFF(DAY, '19000101', @LvMon) % 7 <> 0 SET @LvMon = DATEADD(DAY, 1, @LvMon);
    DECLARE @LT INT = (SELECT RequestTypeId FROM workflow.REQUEST_TYPE WHERE Code = 'LEAVE_REQUEST');
    DECLARE @LDef INT = (SELECT TOP 1 WorkflowDefinitionId FROM workflow.WORKFLOW_DEFINITION WHERE RequestTypeId = @LT
                         ORDER BY CASE WHEN [Status] = 'Active' THEN 0 ELSE 1 END, WorkflowDefinitionId DESC);
    DECLARE @Annual INT = (SELECT TOP 1 LeaveTypeId FROM hr.LEAVE_TYPE ORDER BY CASE WHEN Name = N'Annual' THEN 0 ELSE 1 END, LeaveTypeId);
    DECLARE @RT INT = (SELECT RequestTypeId FROM workflow.REQUEST_TYPE WHERE Code = 'ROSTER_APPROVAL');
    DECLARE @RDef INT = (SELECT TOP 1 WorkflowDefinitionId FROM workflow.WORKFLOW_DEFINITION WHERE RequestTypeId = @RT
                         ORDER BY CASE WHEN [Status] = 'Active' THEN 0 ELSE 1 END, WorkflowDefinitionId DESC);
    IF @LT IS NULL OR @LDef IS NULL OR @Annual IS NULL OR @RT IS NULL OR @RDef IS NULL
        RAISERROR('FAIL rederive_on_approval: no LEAVE_REQUEST / ROSTER_APPROVAL workflow on this database.', 16, 1);
    INSERT INTO workflow.REQUEST_INSTANCE (RequestTypeId, WorkflowDefinitionId, EmployeeId, RaisedByUserId, [Status], Title, ClosedAt)
    VALUES (@LT, @LDef, @E1, @User, 'Approved', N'QA3 rederive leave', DATEADD(DAY, -40, SYSUTCDATETIME()));
    DECLARE @LvRid INT = SCOPE_IDENTITY();
    INSERT INTO workflow.LEAVE_REQUEST (RequestInstanceId, EmployeeId, LeaveTypeId, FromDate, ToDate, DaysRequested, IsDiscretionary)
    VALUES (@LvRid, @E1, @Annual, @LvMon, DATEADD(DAY, 6, @LvMon), 7, 0);
    DECLARE @LrId INT = SCOPE_IDENTITY();
    EXEC hr.usp_LeaveLedger_PostRequest @RequestInstanceId = @LvRid, @ActorUserId = @User;

    /* the month's roster: Mon-Sat the 5-hour shift, Sunday rest - still a draft */
    DECLARE @d DATE = @PM;
    WHILE @d <= @PMEnd
    BEGIN
        INSERT INTO attendance.SHIFT_ASSIGNMENT (EmployeeId, ShiftId, WorkDate, IsRestDay)
        VALUES (@E1, CASE WHEN DATEDIFF(DAY, '19000101', @d) % 7 = 6 THEN NULL ELSE @Short END, @d,
                CASE WHEN DATEDIFF(DAY, '19000101', @d) % 7 = 6 THEN 1 ELSE 0 END);
        SET @d = DATEADD(DAY, 1, @d);
    END
    UPDATE attendance.SHIFT_ASSIGNMENT SET ModifiedUtc = DATEADD(DAY, -35, SYSUTCDATETIME()) WHERE EmployeeId = @E1;

    /* the first Monday was worked in full and processed by the nightly job while the roster was a draft */
    DECLARE @D1 DATE = @PM;
    WHILE DATEDIFF(DAY, '19000101', @D1) % 7 <> 0 SET @D1 = DATEADD(DAY, 1, @D1);
    DECLARE @Dev INT = (SELECT TOP 1 DeviceId FROM attendance.DEVICE ORDER BY DeviceId);
    IF @Dev IS NULL
    BEGIN
        INSERT INTO attendance.DEVICE (SerialNumber, BranchId) VALUES ('QA3-RDV-0001', @B);
        SET @Dev = SCOPE_IDENTITY();
    END
    INSERT INTO attendance.RAW_DEVICE_LOG (DeviceId, EnrollPin, EmployeeId, PunchTimeUtc, PunchType, [Source], DedupHash, IsProcessed)
    VALUES (@Dev, 'QA3RD', @E1, DATEADD(MINUTE, 18 * 60, CAST(@D1 AS DATETIME2)), 0, 'Device', CONCAT('QA3-', NEWID()), 0),
           (@Dev, 'QA3RD', @E1, DATEADD(MINUTE, 23 * 60, CAST(@D1 AS DATETIME2)), 1, 'Device', CONCAT('QA3-', NEWID()), 0);
    EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @E1, @WorkDate = @D1;
    DECLARE @StdBefore INT = (SELECT StandardMinutes FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E1 AND WorkDate = @D1);
    IF @StdBefore IS NULL RAISERROR('FAIL rederive_on_approval: the worked day was not processed before the approval (setup).', 16, 1);

    /* the month is approved (as usp_Request_Approve leaves it), then the API's hook runs */
    INSERT INTO workflow.REQUEST_INSTANCE (RequestTypeId, WorkflowDefinitionId, EmployeeId, RaisedByUserId, [Status], Title, ClosedAt)
    VALUES (@RT, @RDef, @E1, @User, 'Approved', N'QA3 rederive roster', DATEADD(MINUTE, -30, SYSUTCDATETIME()));
    DECLARE @Rid INT = SCOPE_IDENTITY();
    INSERT INTO workflow.ROSTER_APPROVAL (RequestInstanceId, BranchId, MonthDate) VALUES (@Rid, @B, @PM);
    EXEC workflow.usp_Request_ApplyApprovalEffects @RequestInstanceId = @Rid;
    IF NOT EXISTS (SELECT 1 FROM attendance.ROSTER_MONTH WHERE BranchId = @B AND MonthDate = @PM AND [Status] = 'Approved')
        RAISERROR('FAIL rederive_on_approval: the approval effect did not approve the month (setup).', 16, 1);
    IF OBJECT_ID('dbo.QA3_REPRICE_LOG') IS NOT NULL DELETE FROM dbo.QA3_REPRICE_LOG;
    EXEC attendance.usp_Roster_RederiveForRequest @RequestInstanceId = @Rid;

    /* (a) the worked day is measured against the 5-hour shift now */
    IF NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD ar
                   JOIN attendance.SHIFT_ASSIGNMENT sa ON sa.ShiftAssignmentId = ar.ShiftAssignmentId
                   WHERE ar.EmployeeId = @E1 AND ar.WorkDate = @D1 AND ar.StandardMinutes = 300 AND ar.DayFraction = 1.00)
    BEGIN
        SELECT @msg = CONCAT('FAIL rederive_on_approval (a): the worked day should be a full 300-minute day after the approval; got ',
                             ISNULL((SELECT CONCAT(StandardMinutes, ' min, fraction ', DayFraction, ', row ', ISNULL(ShiftAssignmentId, -1))
                                     FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E1 AND WorkDate = @D1), 'no record'),
                             ' (before: ', @StdBefore, ' min)');
        RAISERROR(@msg, 16, 1);
    END
    /* (b) no past rostered day is left without a record */
    SELECT @n = COUNT(*) FROM attendance.SHIFT_ASSIGNMENT sa
    WHERE sa.EmployeeId = @E1 AND sa.WorkDate BETWEEN @PM AND @PMEnd AND sa.WorkDate < @Today
      AND NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD ar WHERE ar.EmployeeId = sa.EmployeeId AND ar.WorkDate = sa.WorkDate);
    IF @n > 0
    BEGIN SET @msg = CONCAT('FAIL rederive_on_approval (b): ', @n, ' past rostered day(s) still have no record after the approval.'); RAISERROR(@msg, 16, 1); END
    IF NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E1 AND WorkDate = @LvMon AND [Status] = 'Leave')
        RAISERROR('FAIL rederive_on_approval (b): a leave day should read Leave.', 16, 1);
    /* (c) the marker */
    IF NOT EXISTS (SELECT 1 FROM attendance.ROSTER_MONTH WHERE BranchId = @B AND MonthDate = @PM
                   AND RederivedAt >= ApprovedAt AND RederivedStatus = 'Approved')
        RAISERROR('FAIL rederive_on_approval (c): the month is not marked as re-derived after its approval.', 16, 1);
    /* (d) the leave is priced on the approved roster: Sunday is a rest day (unit D's contract) */
    IF OBJECT_ID('dbo.QA3_REPRICE_LOG') IS NOT NULL
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM dbo.QA3_REPRICE_LOG WHERE EmployeeId = @E1 AND FromDate = @PM AND ToDate = @PMEnd)
            RAISERROR('FAIL rederive_on_approval (d): the month''s leave was not re-priced (stand-in log).', 16, 1);
    END
    ELSE IF (SELECT -SUM(Days) FROM hr.LEAVE_LEDGER WHERE LeaveRequestId = @LrId AND MovementType = 'Usage') <> 6
    BEGIN
        SELECT @msg = CONCAT('FAIL rederive_on_approval (d): the leave should cost 6 working days on the approved roster; the ledger says ',
                             (SELECT -SUM(Days) FROM hr.LEAVE_LEDGER WHERE LeaveRequestId = @LrId AND MovementType = 'Usage'));
        RAISERROR(@msg, 16, 1);
    END

    /* (e) the current month: re-deriving never writes today or a later day */
    INSERT INTO attendance.SHIFT_ASSIGNMENT (EmployeeId, ShiftId, WorkDate, IsRestDay)
    SELECT @E1, @Short, x.d, 0
    FROM (VALUES (@Today), (DATEADD(DAY, 1, @Today))) x(d)
    WHERE x.d < DATEADD(MONTH, 1, @CM);
    INSERT INTO attendance.ROSTER_MONTH (BranchId, MonthDate, [Status], ApprovedAt) VALUES (@B, @CM, 'Approved', DATEADD(MINUTE, -5, SYSUTCDATETIME()));
    DECLARE @Y INT = YEAR(@CM), @Mo INT = MONTH(@CM);
    EXEC attendance.usp_Roster_RederiveMonth @BranchId = @B, @Year = @Y, @Month = @Mo;
    IF EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E1 AND WorkDate >= @Today)
        RAISERROR('FAIL rederive_on_approval (e): re-deriving wrote a record for today or a later day.', 16, 1);

    /* (f) the safety net takes a month approved again since its last re-derivation */
    UPDATE attendance.ROSTER_MONTH SET RederivedAt = DATEADD(MINUTE, -1, ApprovedAt) WHERE BranchId = @B AND MonthDate = @PM;   -- as if approved again since
    IF NOT EXISTS (SELECT 1 FROM attendance.ROSTER_MONTH rm
                   WHERE rm.BranchId = @B AND rm.MonthDate = @PM
                     AND rm.[Status] = 'Approved' AND (rm.RederivedAt IS NULL OR rm.RederivedAt < ISNULL(rm.ApprovedAt, '19000101')))
        RAISERROR('FAIL rederive_on_approval (f): a month approved again should be due for the safety net.', 16, 1);
    /* the sweep itself runs only when nothing else on this database is due (it would re-derive those months too) */
    IF NOT EXISTS (SELECT 1 FROM attendance.ROSTER_MONTH rm
                   WHERE NOT (rm.BranchId = @B AND rm.MonthDate = @PM)
                     AND ((rm.[Status] = 'Approved' AND (rm.RederivedAt IS NULL OR rm.RederivedAt < ISNULL(rm.ApprovedAt, '19000101')))
                          OR (rm.RederivedStatus = 'Approved' AND rm.[Status] <> 'Approved')))
    BEGIN
        DECLARE @sweep TABLE (MonthsRederived INT, MonthsFailed INT, FirstError NVARCHAR(2048));
        INSERT INTO @sweep EXEC attendance.usp_Roster_RederivePending;
        IF NOT EXISTS (SELECT 1 FROM @sweep WHERE MonthsRederived = 1 AND MonthsFailed = 0)
        BEGIN
            SELECT @msg = CONCAT('FAIL rederive_on_approval (f): the sweep should re-derive exactly this month; got ',
                                 ISNULL((SELECT CONCAT(MonthsRederived, ' done, ', MonthsFailed, ' failed: ', FirstError) FROM @sweep), 'nothing'));
            RAISERROR(@msg, 16, 1);
        END
        IF EXISTS (SELECT 1 FROM attendance.ROSTER_MONTH WHERE BranchId = @B AND MonthDate = @PM AND RederivedAt < ApprovedAt)
            RAISERROR('FAIL rederive_on_approval (f): the sweep did not stamp the month.', 16, 1);
    END
    ELSE PRINT 'note rederive_on_approval: other months are due on this database - the sweep itself was not run.';

    ROLLBACK;
    PRINT 'ok rederive_on_approval';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    DECLARE @failure NVARCHAR(4000) = ERROR_MESSAGE();
    RAISERROR(@failure, 16, 1);
END CATCH;
