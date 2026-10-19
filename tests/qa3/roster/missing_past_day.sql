/* ============================================================================
   tests/qa3/roster/missing_past_day.sql -- QA3 ROS-6 (docs/102_qa3_roster.sql).
   In an approved month, HR (EMP_VIEW_ALL) may ADD a missing roster day in the past when the day has no attendance
   record and is not paid, and the day is derived at once; every other change of the past is refused with its own
   reason: a recorded day, an existing past row, a generator over the past, a branch manager adding the day. A future
   day of an approved month may still change.
   Runs on a real dev database: everything inside one transaction that is rolled back; seeded rows start with 'QA3 '
   (users 'qa3.past.*'). Uses the previous month (never paid for a QA3 employee). Prints 'ok missing_past_day', or
   raises the first wrong result. Needs 99-102.
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
SET QUOTED_IDENTIFIER ON;
BEGIN TRAN;
BEGIN TRY
    DECLARE @msg NVARCHAR(2000), @err NVARCHAR(2000);
    DECLARE @Today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE);
    DECLARE @PM DATE = DATEADD(MONTH, -1, DATEFROMPARTS(YEAR(@Today), MONTH(@Today), 1)), @PMEnd DATE = EOMONTH(DATEADD(MONTH, -1, @Today));
    DECLARE @NM DATE = DATEADD(MONTH, 1, DATEFROMPARTS(YEAR(@Today), MONTH(@Today), 1));
    DECLARE @Dep INT = (SELECT TOP 1 DepartmentId FROM hr.DEPARTMENT ORDER BY DepartmentId);
    DECLARE @Pos INT = (SELECT TOP 1 PositionId FROM hr.[POSITION] ORDER BY PositionId);

    INSERT INTO hr.BRANCH (Name, IsActive) VALUES (N'QA3 Past Branch', 1);
    DECLARE @B INT = SCOPE_IDENTITY();
    INSERT INTO security.[USER] (Username, PasswordHash, IsActive) VALUES (N'qa3.past.mgr', N'x', 1), (N'qa3.past.hr', N'x', 1);
    DECLARE @UMgr INT = (SELECT UserId FROM security.[USER] WHERE Username = N'qa3.past.mgr');
    DECLARE @UHr  INT = (SELECT UserId FROM security.[USER] WHERE Username = N'qa3.past.hr');
    INSERT INTO security.[ROLE] (Name) VALUES (N'QA3 Past HR');
    DECLARE @RoleHr INT = SCOPE_IDENTITY();
    INSERT INTO security.ROLE_PERMISSION (RoleId, PermissionId) SELECT @RoleHr, PermissionId FROM security.PERMISSION WHERE Code = 'EMP_VIEW_ALL';
    INSERT INTO security.USER_ROLE (UserId, RoleId) VALUES (@UHr, @RoleHr);
    INSERT INTO hr.EMPLOYEE (UserId, BranchId, DepartmentId, PositionId, FullName, HireDate)
    VALUES (@UMgr, @B, @Dep, @Pos, N'QA3 Past Manager', '2020-01-01'), (NULL, @B, @Dep, @Pos, N'QA3 Past Barista', '2020-01-01');
    UPDATE hr.BRANCH SET ManagerEmployeeId = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Past Manager') WHERE BranchId = @B;
    DECLARE @E INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Past Barista');
    INSERT INTO attendance.SHIFT (Name, StartTime, EndTime, GraceMinutes, CrossesMidnight, BreakMinutes, IsActive)
    VALUES (N'QA3 Past Day', '08:00', '16:00', NULL, 0, 30, 1);
    DECLARE @Sh INT = SCOPE_IDENTITY();

    /* the previous month rostered every day but two (X: the "worked without roster" day, W: another hole), approved */
    DECLARE @X DATE = DATEADD(DAY, 9, @PM), @W DATE = DATEADD(DAY, 11, @PM), @Y DATE = DATEADD(DAY, 13, @PM), @Z DATE = DATEADD(DAY, 15, @PM);
    DECLARE @d DATE = @PM;
    WHILE @d <= @PMEnd
    BEGIN
        IF @d NOT IN (@X, @W) INSERT INTO attendance.SHIFT_ASSIGNMENT (EmployeeId, ShiftId, WorkDate, IsRestDay) VALUES (@E, @Sh, @d, 0);
        SET @d = DATEADD(DAY, 1, @d);
    END
    INSERT INTO attendance.ROSTER_MONTH (BranchId, MonthDate, [Status], ApprovedAt) VALUES (@B, @PM, 'Approved', DATEADD(DAY, -30, SYSUTCDATETIME()));
    EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @E, @WorkDate = @Y;              -- Y already judged by attendance
    IF NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E AND WorkDate = @Y)
        RAISERROR('FAIL missing_past_day: the recorded day could not be set up.', 16, 1);

    DECLARE @r TABLE (Id INT);
    /* (a) a branch manager may not add the missing past day */
    SET @err = NULL;
    BEGIN TRY INSERT INTO @r EXEC attendance.usp_ShiftAssignment_Upsert @EmployeeId = @E, @WorkDate = @X, @ShiftId = @Sh, @IsRestDay = 0, @CallerUserId = @UMgr; END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH;
    IF ISNULL(@err, N'') NOT LIKE N'This day is already in an approved roster and is in the past%only HR can add the missing day.'
    BEGIN SET @msg = CONCAT('FAIL missing_past_day (a): a manager adding the past day: ', ISNULL(@err, 'allowed')); RAISERROR(@msg, 16, 1); END

    /* (b) HR adds it, and the day is derived at once */
    DELETE FROM @r;
    INSERT INTO @r EXEC attendance.usp_ShiftAssignment_Upsert @EmployeeId = @E, @WorkDate = @X, @ShiftId = @Sh, @IsRestDay = 0, @CallerUserId = @UHr;
    IF NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD ar
                   JOIN attendance.SHIFT_ASSIGNMENT sa ON sa.ShiftAssignmentId = ar.ShiftAssignmentId
                   WHERE ar.EmployeeId = @E AND ar.WorkDate = @X AND sa.WorkDate = @X)
        RAISERROR('FAIL missing_past_day (b): HR added the past day but it was not derived (no record on its row).', 16, 1);

    /* (c) an existing past row cannot change */
    SET @err = NULL;
    BEGIN TRY INSERT INTO @r EXEC attendance.usp_ShiftAssignment_Upsert @EmployeeId = @E, @WorkDate = @Z, @ShiftId = NULL, @IsRestDay = 1, @CallerUserId = @UHr; END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH;
    IF ISNULL(@err, N'') NOT LIKE N'This day is already in an approved roster and is in the past%it can no longer be changed.'
    BEGIN SET @msg = CONCAT('FAIL missing_past_day (c): changing an existing past row: ', ISNULL(@err, 'allowed')); RAISERROR(@msg, 16, 1); END

    /* (d) a recorded day names the record */
    SET @err = NULL;
    BEGIN TRY INSERT INTO @r EXEC attendance.usp_ShiftAssignment_Upsert @EmployeeId = @E, @WorkDate = @Y, @ShiftId = NULL, @IsRestDay = 1, @CallerUserId = @UHr; END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH;
    IF ISNULL(@err, N'') NOT LIKE N'This day is already in an approved roster and attendance was recorded%'
    BEGIN SET @msg = CONCAT('FAIL missing_past_day (d): changing a recorded day: ', ISNULL(@err, 'allowed')); RAISERROR(@msg, 16, 1); END

    /* (e) a generator does not fill the past, even for HR */
    SET @err = NULL;
    BEGIN TRY INSERT INTO @r EXEC attendance.usp_ShiftAssignment_GenerateRange @EmployeeId = @E, @FromDate = @W, @ToDate = @W, @ShiftId = @Sh,
                                   @Weekdays = '1111111', @Overwrite = 0, @CallerUserId = @UHr; END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH;
    IF ISNULL(@err, N'') NOT LIKE N'This day is already in an approved roster and is in the past%a generator does not fill it%'
    BEGIN SET @msg = CONCAT('FAIL missing_past_day (e): a generator over the past: ', ISNULL(@err, 'allowed')); RAISERROR(@msg, 16, 1); END
    IF EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId = @E AND WorkDate = @W)
        RAISERROR('FAIL missing_past_day (e): the refused generator wrote the day.', 16, 1);

    /* (f) a future day of an approved month may still change */
    INSERT INTO attendance.SHIFT_ASSIGNMENT (EmployeeId, ShiftId, WorkDate, IsRestDay) VALUES (@E, @Sh, @NM, 0);
    INSERT INTO attendance.ROSTER_MONTH (BranchId, MonthDate, [Status], ApprovedAt) VALUES (@B, @NM, 'Approved', DATEADD(DAY, -1, SYSUTCDATETIME()));
    DELETE FROM @r;
    INSERT INTO @r EXEC attendance.usp_ShiftAssignment_Upsert @EmployeeId = @E, @WorkDate = @NM, @ShiftId = NULL, @IsRestDay = 1, @CallerUserId = @UMgr;
    IF NOT EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId = @E AND WorkDate = @NM AND IsRestDay = 1)
        RAISERROR('FAIL missing_past_day (f): a future day of an approved month could not change.', 16, 1);
    IF EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E AND WorkDate = @NM)
        RAISERROR('FAIL missing_past_day (f): a future day was derived.', 16, 1);

    ROLLBACK;
    PRINT 'ok missing_past_day';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    DECLARE @failure NVARCHAR(4000) = ERROR_MESSAGE();
    RAISERROR(@failure, 16, 1);
END CATCH;
