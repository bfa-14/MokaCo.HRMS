/* ============================================================================
   tests/qa3/roster/employment_bounds.sql -- QA3 ROS-1 / REL-1 (docs/102_qa3_roster.sql).
   Setting a termination date on the employee form removes the roster rows after it (days not paid) and derives the
   days again - the non-manual records after it go (script 100's rule), a manual one stays and lets go of its row -
   and marks the approved month as changed; moving the hire date later does the same before it; saving again changes
   nothing; a single day outside the employment is refused with a sentence.
   Runs on a real dev database: everything inside one transaction that is rolled back; seeded rows start with 'QA3 '.
   Uses the previous and the next month. Prints 'ok employment_bounds', or raises the first wrong result. Needs 99-102.
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
SET QUOTED_IDENTIFIER ON;
BEGIN TRAN;
BEGIN TRY
    DECLARE @msg NVARCHAR(2000), @err NVARCHAR(2000), @n INT;
    DECLARE @Today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE);
    DECLARE @PM DATE = DATEADD(MONTH, -1, DATEFROMPARTS(YEAR(@Today), MONTH(@Today), 1)), @PMEnd DATE = EOMONTH(DATEADD(MONTH, -1, @Today));
    DECLARE @NM DATE = DATEADD(MONTH, 1, DATEFROMPARTS(YEAR(@Today), MONTH(@Today), 1)), @NMEnd DATE = EOMONTH(DATEADD(MONTH, 1, @Today));
    DECLARE @Term DATE = DATEADD(DAY, 18, @PM);
    DECLARE @Dep INT = (SELECT TOP 1 DepartmentId FROM hr.DEPARTMENT ORDER BY DepartmentId);
    DECLARE @Pos INT = (SELECT TOP 1 PositionId FROM hr.[POSITION] ORDER BY PositionId);

    INSERT INTO hr.BRANCH (Name, IsActive) VALUES (N'QA3 Leavers Branch', 1);
    DECLARE @B INT = SCOPE_IDENTITY();
    INSERT INTO hr.EMPLOYEE (BranchId, DepartmentId, PositionId, FullName, HireDate)
    VALUES (@B, @Dep, @Pos, N'QA3 Leaver', '2020-01-01'), (@B, @Dep, @Pos, N'QA3 Late Starter', '2020-01-01');
    DECLARE @E1 INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Leaver');
    DECLARE @E2 INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Late Starter');
    INSERT INTO attendance.SHIFT (Name, StartTime, EndTime, GraceMinutes, CrossesMidnight, BreakMinutes, IsActive)
    VALUES (N'QA3 Leavers Day', '08:00', '16:00', NULL, 0, 30, 1);
    DECLARE @Sh INT = SCOPE_IDENTITY();

    /* the leaver's previous month (approved, processed: the nightly job marked the days absent) and next month */
    DECLARE @d DATE = @PM;
    WHILE @d <= @NMEnd
    BEGIN
        IF @d <= @PMEnd OR @d >= @NM
            INSERT INTO attendance.SHIFT_ASSIGNMENT (EmployeeId, ShiftId, WorkDate, IsRestDay) VALUES (@E1, @Sh, @d, 0);
        IF @d >= @NM
            INSERT INTO attendance.SHIFT_ASSIGNMENT (EmployeeId, ShiftId, WorkDate, IsRestDay) VALUES (@E2, @Sh, @d, 0);
        SET @d = DATEADD(DAY, 1, @d);
    END
    UPDATE attendance.SHIFT_ASSIGNMENT SET ModifiedUtc = DATEADD(HOUR, -3, SYSUTCDATETIME()) WHERE EmployeeId IN (@E1, @E2);
    INSERT INTO attendance.ROSTER_MONTH (BranchId, MonthDate, [Status], ApprovedAt) VALUES (@B, @PM, 'Approved', DATEADD(HOUR, -2, SYSUTCDATETIME()));
    SET @d = DATEADD(DAY, 15, @PM);
    WHILE @d <= @PMEnd
    BEGIN
        EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @E1, @WorkDate = @d;
        SET @d = DATEADD(DAY, 1, @d);
    END
    /* one day after the last day was entered by hand */
    DECLARE @ManualDay DATE = DATEADD(DAY, 3, @Term);
    UPDATE attendance.ATTENDANCE_RECORD SET IsManual = 1, HrNote = N'QA3 manual' WHERE EmployeeId = @E1 AND WorkDate = @ManualDay;
    IF (SELECT COUNT(*) FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E1 AND WorkDate > @Term) < 5
        RAISERROR('FAIL employment_bounds: the absences after the last day could not be set up.', 16, 1);

    /* the termination is entered on the employee form */
    DECLARE @Name NVARCHAR(150) = N'QA3 Leaver';
    EXEC hr.usp_Employee_Update @EmployeeId = @E1, @BranchId = @B, @DepartmentId = @Dep, @PositionId = @Pos, @FullName = @Name,
         @HireDate = '2020-01-01', @TerminationDate = @Term;
    SELECT @n = COUNT(*) FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId = @E1 AND WorkDate > @Term;
    IF @n > 0
    BEGIN SET @msg = CONCAT('FAIL employment_bounds: ', @n, ' roster row(s) left after the termination date.'); RAISERROR(@msg, 16, 1); END
    IF NOT EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId = @E1 AND WorkDate = @Term)
        RAISERROR('FAIL employment_bounds: the last day itself must stay rostered.', 16, 1);
    IF EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E1 AND WorkDate > @Term AND IsManual = 0)
        RAISERROR('FAIL employment_bounds: an absence after the termination date survived (script 100: not a working day).', 16, 1);
    IF NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E1 AND WorkDate = @ManualDay AND IsManual = 1 AND ShiftAssignmentId IS NULL)
        RAISERROR('FAIL employment_bounds: the manual day must stay, letting go of its removed row.', 16, 1);
    IF NOT EXISTS (SELECT 1 FROM attendance.ROSTER_MONTH WHERE BranchId = @B AND MonthDate = @PM AND LastChangedUtc > ApprovedAt)
        RAISERROR('FAIL employment_bounds: the approved month must read as changed after the leaver''s rows went.', 16, 1);

    /* saving the form again changes nothing */
    DECLARE @rows INT = (SELECT COUNT(*) FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId = @E1);
    EXEC hr.usp_Employee_Update @EmployeeId = @E1, @BranchId = @B, @DepartmentId = @Dep, @PositionId = @Pos, @FullName = @Name,
         @HireDate = '2020-01-01', @TerminationDate = @Term;
    IF (SELECT COUNT(*) FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId = @E1) <> @rows
        RAISERROR('FAIL employment_bounds: saving the form again changed the roster.', 16, 1);

    /* the hire date moved later: the rows before it go */
    DECLARE @Hire DATE = DATEADD(DAY, 10, @NM);
    SET @Name = N'QA3 Late Starter';
    EXEC hr.usp_Employee_Update @EmployeeId = @E2, @BranchId = @B, @DepartmentId = @Dep, @PositionId = @Pos, @FullName = @Name, @HireDate = @Hire;
    IF EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId = @E2 AND WorkDate < @Hire)
        RAISERROR('FAIL employment_bounds: roster rows left before the (later) hire date.', 16, 1);
    IF NOT EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId = @E2 AND WorkDate = @Hire)
        RAISERROR('FAIL employment_bounds: the hire date itself must stay rostered.', 16, 1);

    /* one day outside the employment is refused, with the reason */
    DECLARE @r TABLE (Id INT);
    DECLARE @After DATE = DATEADD(DAY, 2, @Term);
    SET @err = NULL;
    BEGIN TRY INSERT INTO @r EXEC attendance.usp_ShiftAssignment_Upsert @EmployeeId = @E1, @WorkDate = @NM, @ShiftId = @Sh, @IsRestDay = 0; END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH;
    IF ISNULL(@err, N'') NOT LIKE N'QA3 Leaver is no longer employed on %'
    BEGIN SET @msg = CONCAT('FAIL employment_bounds: a day after the termination: ', ISNULL(@err, 'allowed')); RAISERROR(@msg, 16, 1); END
    SET @err = NULL;
    BEGIN TRY INSERT INTO @r EXEC attendance.usp_ShiftAssignment_Upsert @EmployeeId = @E2, @WorkDate = @NM, @ShiftId = @Sh, @IsRestDay = 0; END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH;
    IF ISNULL(@err, N'') NOT LIKE N'QA3 Late Starter is not employed yet on %'
    BEGIN SET @msg = CONCAT('FAIL employment_bounds: a day before the hire: ', ISNULL(@err, 'allowed')); RAISERROR(@msg, 16, 1); END

    ROLLBACK;
    PRINT 'ok employment_bounds';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    DECLARE @failure NVARCHAR(4000) = ERROR_MESSAGE();
    RAISERROR(@failure, 16, 1);
END CATCH;
