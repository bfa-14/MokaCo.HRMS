/* ============================================================================
   tests/qa3/roster/generators.sql -- QA3 ROS-1, ROS-3, ROS-9, ROS-13, D5 (docs/102_qa3_roster.sql).
   The three generators (Generate / Copy previous month / Apply patterns) write only days inside the employment, never
   a public holiday of the branch, never a retired shift, never a rest day on an approved leave day (a working row
   instead); Copy and Apply act on ONE branch (the branch of the day); Copy breaks a tie the same way every time
   (working first, then the earliest start); the bulk generation returns the real counts.
   Runs on a real dev database: everything inside one transaction that is rolled back; seeded rows start with 'QA3 '.
   Months in 2097, so nothing depends on today. Prints 'ok generators', or raises the first wrong result. Needs 99-102.
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
SET QUOTED_IDENTIFIER ON;
BEGIN TRAN;
BEGIN TRY
    DECLARE @msg NVARCHAR(2000), @err NVARCHAR(2000), @n INT, @n2 INT;
    DECLARE @Dep INT = (SELECT TOP 1 DepartmentId FROM hr.DEPARTMENT ORDER BY DepartmentId);
    DECLARE @Pos INT = (SELECT TOP 1 PositionId FROM hr.[POSITION] ORDER BY PositionId);
    DECLARE @User INT = (SELECT TOP 1 UserId FROM security.[USER] ORDER BY UserId);

    INSERT INTO hr.BRANCH (Name, IsActive) VALUES (N'QA3 Gen Branch A', 1);
    DECLARE @BA INT = SCOPE_IDENTITY();
    INSERT INTO hr.BRANCH (Name, IsActive) VALUES (N'QA3 Gen Branch B', 1);
    DECLARE @BB INT = SCOPE_IDENTITY();
    INSERT INTO attendance.SHIFT (Name, StartTime, EndTime, GraceMinutes, CrossesMidnight, BreakMinutes, IsActive)
    VALUES (N'QA3 Early', '07:00', '15:00', NULL, 0, 30, 1), (N'QA3 Late', '15:00', '23:00', NULL, 0, 30, 1), (N'QA3 Old', '09:00', '17:00', NULL, 0, 30, 0);
    DECLARE @Early INT = (SELECT ShiftId FROM attendance.SHIFT WHERE Name = N'QA3 Early');
    DECLARE @Late  INT = (SELECT ShiftId FROM attendance.SHIFT WHERE Name = N'QA3 Late');
    DECLARE @Old   INT = (SELECT ShiftId FROM attendance.SHIFT WHERE Name = N'QA3 Old');

    INSERT INTO hr.EMPLOYEE (BranchId, DepartmentId, PositionId, FullName, HireDate, TerminationDate)
    VALUES (@BA, @Dep, @Pos, N'QA3 Gen E1', '2090-01-01', NULL),            -- bulk + D5
           (@BA, @Dep, @Pos, N'QA3 Gen E2', '2090-01-01', '2097-03-15'),    -- bulk: leaves on the 15th
           (@BA, @Dep, @Pos, N'QA3 Gen E3', '2097-03-10', NULL),            -- bulk: starts on the 10th
           (@BA, @Dep, @Pos, N'QA3 Gen E5', '2090-01-01', '2097-03-20'),    -- copy
           (@BB, @Dep, @Pos, N'QA3 Gen E6', '2090-01-01', NULL),            -- copy: another branch
           (@BA, @Dep, @Pos, N'QA3 Gen E7', '2090-01-01', NULL),            -- patterns
           (@BB, @Dep, @Pos, N'QA3 Gen E8', '2090-01-01', NULL);            -- patterns: another branch
    DECLARE @E1 INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Gen E1');
    DECLARE @E2 INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Gen E2');
    DECLARE @E3 INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Gen E3');
    DECLARE @E5 INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Gen E5');
    DECLARE @E6 INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Gen E6');
    DECLARE @E7 INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Gen E7');
    DECLARE @E8 INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Gen E8');

    /* March 2097: a branch-A holiday on the third Wednesday; approved leave for E1 (a Mon-Sun week), E5 (a Wednesday),
       E7 (a Saturday). Weekday: DATEDIFF(DAY, '19000101', d) % 7, 0 = Monday. */
    DECLARE @M DATE = '2097-03-01', @MEnd DATE = '2097-03-31';
    DECLARE @Hol DATE = '2097-03-15';
    WHILE DATEDIFF(DAY, '19000101', @Hol) % 7 <> 2 SET @Hol = DATEADD(DAY, 1, @Hol);              -- a Wednesday after the 15th
    INSERT INTO core.HOLIDAY (HolidayDate, Name, IsPaid, BranchId) VALUES (@Hol, N'QA3 Branch A holiday', 1, @BA);
    DECLARE @LvMon DATE = '2097-03-22';
    WHILE DATEDIFF(DAY, '19000101', @LvMon) % 7 <> 0 SET @LvMon = DATEADD(DAY, 1, @LvMon);         -- the last whole Mon-Sun week, after the holiday
    DECLARE @LvSun DATE = DATEADD(DAY, 6, @LvMon);
    DECLARE @E5Wed DATE = '2097-03-02';
    WHILE DATEDIFF(DAY, '19000101', @E5Wed) % 7 <> 2 SET @E5Wed = DATEADD(DAY, 1, @E5Wed);         -- E5's first Wednesday
    DECLARE @E7Sat DATE = '2097-03-02';
    WHILE DATEDIFF(DAY, '19000101', @E7Sat) % 7 <> 5 SET @E7Sat = DATEADD(DAY, 1, @E7Sat);         -- E7's first Saturday

    DECLARE @LT INT = (SELECT RequestTypeId FROM workflow.REQUEST_TYPE WHERE Code = 'LEAVE_REQUEST');
    DECLARE @LDef INT = (SELECT TOP 1 WorkflowDefinitionId FROM workflow.WORKFLOW_DEFINITION WHERE RequestTypeId = @LT
                         ORDER BY CASE WHEN [Status] = 'Active' THEN 0 ELSE 1 END, WorkflowDefinitionId DESC);
    DECLARE @Annual INT = (SELECT TOP 1 LeaveTypeId FROM hr.LEAVE_TYPE ORDER BY CASE WHEN Name = N'Annual' THEN 0 ELSE 1 END, LeaveTypeId);
    IF @LT IS NULL OR @LDef IS NULL OR @Annual IS NULL RAISERROR('FAIL generators: no LEAVE_REQUEST workflow or leave type on this database.', 16, 1);
    DECLARE @rid INT;
    INSERT INTO workflow.REQUEST_INSTANCE (RequestTypeId, WorkflowDefinitionId, EmployeeId, RaisedByUserId, [Status], Title, ClosedAt)
    VALUES (@LT, @LDef, @E1, @User, 'Approved', N'QA3 gen leave E1', SYSUTCDATETIME());
    SET @rid = SCOPE_IDENTITY();
    INSERT INTO workflow.LEAVE_REQUEST (RequestInstanceId, EmployeeId, LeaveTypeId, FromDate, ToDate, DaysRequested, IsDiscretionary)
    VALUES (@rid, @E1, @Annual, @LvMon, @LvSun, 7, 0);
    INSERT INTO workflow.REQUEST_INSTANCE (RequestTypeId, WorkflowDefinitionId, EmployeeId, RaisedByUserId, [Status], Title, ClosedAt)
    VALUES (@LT, @LDef, @E5, @User, 'Approved', N'QA3 gen leave E5', SYSUTCDATETIME());
    SET @rid = SCOPE_IDENTITY();
    INSERT INTO workflow.LEAVE_REQUEST (RequestInstanceId, EmployeeId, LeaveTypeId, FromDate, ToDate, DaysRequested, IsDiscretionary)
    VALUES (@rid, @E5, @Annual, @E5Wed, @E5Wed, 1, 0);
    INSERT INTO workflow.REQUEST_INSTANCE (RequestTypeId, WorkflowDefinitionId, EmployeeId, RaisedByUserId, [Status], Title, ClosedAt)
    VALUES (@LT, @LDef, @E7, @User, 'Approved', N'QA3 gen leave E7', SYSUTCDATETIME());
    SET @rid = SCOPE_IDENTITY();
    INSERT INTO workflow.LEAVE_REQUEST (RequestInstanceId, EmployeeId, LeaveTypeId, FromDate, ToDate, DaysRequested, IsDiscretionary)
    VALUES (@rid, @E7, @Annual, @E7Sat, @E7Sat, 1, 0);

    /* ---- (a) BULK: employment, holiday, D5, and the real counts (ROS-1, ROS-13) ---- */
    DECLARE @bulk TABLE (EmployeesProcessed INT, RowsInserted INT);
    DECLARE @ids NVARCHAR(100) = CONCAT(@E1, ',', @E2, ',', @E3);
    INSERT INTO @bulk EXEC attendance.usp_ShiftAssignment_GenerateRange_Bulk
         @EmployeeIds = @ids, @FromDate = @M, @ToDate = @MEnd, @ShiftId = @Early, @Weekdays = '1111100', @Overwrite = 0;
    IF @@TRANCOUNT = 0 RAISERROR('FAIL generators (a): the bulk generation rolled the test back.', 16, 1);
    /* expected: E1 the whole month but the holiday (30), E2 the 1st-15th (15, the holiday is later), E3 the 10th-31st but the holiday (21) */
    DECLARE @exp INT = 30 + 15 + 21;
    IF NOT EXISTS (SELECT 1 FROM @bulk WHERE EmployeesProcessed = 3 AND RowsInserted = @exp)
    BEGIN
        SELECT @msg = CONCAT('FAIL generators (a): bulk should report 3 employees / ', @exp, ' rows; got ',
                             ISNULL((SELECT CONCAT(EmployeesProcessed, ' / ', RowsInserted) FROM @bulk), 'nothing'));
        RAISERROR(@msg, 16, 1);
    END
    IF EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId = @E2 AND WorkDate > '2097-03-15')
        RAISERROR('FAIL generators (a): rows written after the termination date.', 16, 1);
    IF EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId = @E3 AND WorkDate < '2097-03-10')
        RAISERROR('FAIL generators (a): rows written before the hire date.', 16, 1);
    IF EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId IN (@E1, @E3) AND WorkDate = @Hol)
        RAISERROR('FAIL generators (a): a row was written on a public holiday of the branch.', 16, 1);
    IF EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId = @E1 AND WorkDate BETWEEN @LvMon AND @LvSun
               AND (IsRestDay = 1 OR ISNULL(ShiftId, -1) <> @Early))
        RAISERROR('FAIL generators (a): a rest day was put on an approved leave day (D5: a working row).', 16, 1);
    IF NOT EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId = @E1 AND WorkDate = DATEADD(DAY, -1, @LvMon) AND IsRestDay = 1)
        RAISERROR('FAIL generators (a): the Sunday before the leave should still be a rest day.', 16, 1);

    /* ---- (b) a retired shift is refused; another branch's days are not touched ---- */
    SET @err = NULL;
    BEGIN TRY
        EXEC attendance.usp_ShiftAssignment_GenerateRange @EmployeeId = @E6, @FromDate = @M, @ToDate = @MEnd, @ShiftId = @Old, @Weekdays = '1111100';
    END TRY BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH;
    IF @@TRANCOUNT = 0 RAISERROR('FAIL generators (b): the refusal rolled the test back.', 16, 1);
    IF @err IS NULL OR @err NOT LIKE N'That shift is retired%'
    BEGIN SET @msg = CONCAT('FAIL generators (b): a retired shift must be refused; got ', ISNULL(@err, 'no refusal')); RAISERROR(@msg, 16, 1); END
    DECLARE @g TABLE (RowsInserted INT);
    INSERT INTO @g EXEC attendance.usp_ShiftAssignment_GenerateRange @EmployeeId = @E6, @FromDate = @M, @ToDate = @MEnd,
         @ShiftId = @Early, @Weekdays = '1111100', @Overwrite = 0, @CallerUserId = NULL, @BranchId = @BA;
    IF (SELECT RowsInserted FROM @g) <> 0 OR EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId = @E6 AND WorkDate >= @M)
        RAISERROR('FAIL generators (b): generating for branch A wrote days of a branch-B employee.', 16, 1);

    /* ---- (c) COPY PREVIOUS MONTH: one branch, employment, retired shift, D5, the tie-break (ROS-3, ROS-9) ---- */
    /* February 2097 of E5 (branch A): Mondays 2x Late and 2x Early (a tie), Tuesdays the retired shift, Wednesdays rest,
       the other days Early. E6 (branch B) worked February too. */
    DECLARE @d DATE = '2097-02-01', @k INT = 0;
    WHILE @d <= '2097-02-28'
    BEGIN
        DECLARE @dow INT = DATEDIFF(DAY, '19000101', @d) % 7;
        IF @dow = 0 SET @k = @k + 1;
        INSERT INTO attendance.SHIFT_ASSIGNMENT (EmployeeId, ShiftId, WorkDate, IsRestDay)
        VALUES (@E5, CASE @dow WHEN 0 THEN CASE WHEN @k % 2 = 1 THEN @Late ELSE @Early END WHEN 1 THEN @Old WHEN 2 THEN NULL ELSE @Early END,
                @d, CASE WHEN @dow = 2 THEN 1 ELSE 0 END),
               (@E6, @Early, @d, 0);
        SET @d = DATEADD(DAY, 1, @d);
    END
    SET @err = NULL;
    BEGIN TRY
        EXEC attendance.usp_ShiftAssignment_CopyPeriod @SourceYearMonth = '2097-02', @TargetYearMonth = '2097-03', @EmployeeId = NULL, @Overwrite = 0;
    END TRY BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH;
    IF @@TRANCOUNT = 0 RAISERROR('FAIL generators (c): the refusal rolled the test back.', 16, 1);
    IF @err IS NULL OR @err NOT LIKE N'Choose a branch%'
    BEGIN SET @msg = CONCAT('FAIL generators (c): a copy without a branch must be refused; got ', ISNULL(@err, 'no refusal')); RAISERROR(@msg, 16, 1); END
    DELETE FROM @g;
    INSERT INTO @g EXEC attendance.usp_ShiftAssignment_CopyPeriod @SourceYearMonth = '2097-02', @TargetYearMonth = '2097-03',
         @EmployeeId = NULL, @Overwrite = 0, @BranchId = @BA;
    IF EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId = @E6 AND WorkDate >= @M)
        RAISERROR('FAIL generators (c): the copy of branch A wrote rows of branch B.', 16, 1);
    IF EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId = @E5 AND WorkDate > '2097-03-20')
        RAISERROR('FAIL generators (c): the copy wrote days after the termination date.', 16, 1);
    IF EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId = @E5 AND WorkDate >= @M AND ShiftId = @Old)
        RAISERROR('FAIL generators (c): the copy rostered a retired shift.', 16, 1);
    IF EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId = @E5 AND WorkDate BETWEEN @M AND '2097-03-20'
               AND DATEDIFF(DAY, '19000101', WorkDate) % 7 = 0 AND ISNULL(ShiftId, -1) <> @Early)
        RAISERROR('FAIL generators (c): a tie between two shifts must go to the earliest start (Early), every time.', 16, 1);
    IF NOT EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId = @E5 AND WorkDate = @E5Wed AND IsRestDay = 0 AND ShiftId = @Early)
        RAISERROR('FAIL generators (c): the leave Wednesday should get the usual working shift, not a rest day (D5).', 16, 1);
    IF NOT EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId = @E5 AND WorkDate = DATEADD(DAY, 7, @E5Wed) AND IsRestDay = 1)
        RAISERROR('FAIL generators (c): a Wednesday outside the leave should be copied as a rest day.', 16, 1);
    IF EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId = @E5 AND WorkDate = @Hol)
        RAISERROR('FAIL generators (c): the copy wrote a row on the branch holiday.', 16, 1);

    /* ---- (d) APPLY PATTERNS: one branch, the retired shift skipped, holiday, D5 ---- */
    INSERT INTO attendance.EMPLOYEE_SHIFT_PATTERN (EmployeeId, DayOfWeek, ShiftId, IsRestDay, IsActive)
    SELECT e.EmployeeId, v.Dow, CASE WHEN v.Dow <= 5 THEN @Early WHEN v.Dow = 7 THEN @Old END, CASE WHEN v.Dow = 6 THEN 1 ELSE 0 END, 1
    FROM (VALUES (@E7), (@E8)) e(EmployeeId)
    CROSS JOIN (VALUES (1), (2), (3), (4), (5), (6), (7)) v(Dow);
    SET @err = NULL;
    BEGIN TRY
        EXEC attendance.usp_ShiftAssignment_ApplyPatternForMonth @YearMonth = '2097-03', @EmployeeId = NULL, @Overwrite = 0;
    END TRY BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH;
    IF @@TRANCOUNT = 0 RAISERROR('FAIL generators (d): the refusal rolled the test back.', 16, 1);
    IF @err IS NULL OR @err NOT LIKE N'Choose a branch%'
    BEGIN SET @msg = CONCAT('FAIL generators (d): applying patterns without a branch must be refused; got ', ISNULL(@err, 'no refusal')); RAISERROR(@msg, 16, 1); END
    DELETE FROM @g;
    INSERT INTO @g EXEC attendance.usp_ShiftAssignment_ApplyPatternForMonth @YearMonth = '2097-03', @EmployeeId = NULL, @Overwrite = 0, @BranchId = @BA;
    SELECT @n = COUNT(*) FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId = @E7 AND WorkDate BETWEEN @M AND @MEnd;
    /* every March day of E7 but the Sundays (retired shift) and the holiday */
    SELECT @n2 = COUNT(*) FROM (SELECT DATEADD(DAY, v.i, @M) AS d FROM (SELECT TOP (31) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS i FROM sys.all_objects) v) x
    WHERE DATEDIFF(DAY, '19000101', x.d) % 7 <> 6 AND x.d <> @Hol;
    IF @n <> @n2
    BEGIN SET @msg = CONCAT('FAIL generators (d): E7 should get ', @n2, ' rows (no Sunday on the retired shift, no holiday); got ', @n); RAISERROR(@msg, 16, 1); END
    IF EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId = @E8 AND WorkDate >= @M)
        RAISERROR('FAIL generators (d): applying branch A''s patterns wrote rows of branch B.', 16, 1);
    IF NOT EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId = @E7 AND WorkDate = @E7Sat AND IsRestDay = 0 AND ShiftId = @Early)
        RAISERROR('FAIL generators (d): the leave Saturday should get the usual working shift, not a rest day (D5).', 16, 1);
    IF NOT EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId = @E7 AND WorkDate = DATEADD(DAY, 7, @E7Sat) AND IsRestDay = 1)
        RAISERROR('FAIL generators (d): a Saturday outside the leave should be a rest day.', 16, 1);

    /* ---- (e) Overwrite never changes a row inside a leave (D5) ---- */
    DELETE FROM @bulk;
    INSERT INTO @bulk EXEC attendance.usp_ShiftAssignment_GenerateRange_Bulk
         @EmployeeIds = @ids, @FromDate = @LvMon, @ToDate = @LvSun, @ShiftId = @Late, @Weekdays = '1111111', @Overwrite = 1;
    IF EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId = @E1 AND WorkDate BETWEEN @LvMon AND @LvSun AND ShiftId <> @Early)
        RAISERROR('FAIL generators (e): Overwrite changed a row inside an approved leave.', 16, 1);
    IF NOT EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId = @E3 AND WorkDate = @LvMon AND ShiftId = @Late)
        RAISERROR('FAIL generators (e): Overwrite should still change a row outside any leave.', 16, 1);

    ROLLBACK;
    PRINT 'ok generators';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    DECLARE @failure NVARCHAR(4000) = ERROR_MESSAGE();
    RAISERROR(@failure, 16, 1);
END CATCH;
