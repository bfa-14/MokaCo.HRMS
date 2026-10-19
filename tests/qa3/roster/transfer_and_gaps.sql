/* ============================================================================
   tests/qa3/roster/transfer_and_gaps.sql -- QA3 ROS-8 / REL-9, ATT-14 / ROS-5, ROS-10 (docs/102_qa3_roster.sql).
   A transfer dated in the middle of an approved month moves the rows from its date into the other branch: both
   branches' months read "changed since approval" and the moved rows carry a new ModifiedUtc; no attendance record is
   made for a day after today; the gaps are those of the branch OF THE DAY and a public holiday of that branch is not
   a gap. Cancelling the future transfer marks both months again.
   Runs on a real dev database: everything inside one transaction that is rolled back; seeded rows start with 'QA3 '.
   Uses next month. Prints 'ok transfer_and_gaps', or raises the first wrong result. Needs 99-102.
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
SET QUOTED_IDENTIFIER ON;
BEGIN TRAN;
BEGIN TRY
    DECLARE @msg NVARCHAR(2000), @n INT;
    DECLARE @Today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE);
    DECLARE @NM DATE = DATEADD(MONTH, 1, DATEFROMPARTS(YEAR(@Today), MONTH(@Today), 1)), @NMEnd DATE = EOMONTH(DATEADD(MONTH, 1, @Today));
    DECLARE @Eff DATE = DATEADD(DAY, 15, @NM);
    DECLARE @Dep INT = (SELECT TOP 1 DepartmentId FROM hr.DEPARTMENT ORDER BY DepartmentId);
    DECLARE @Pos INT = (SELECT TOP 1 PositionId FROM hr.[POSITION] ORDER BY PositionId);

    INSERT INTO hr.BRANCH (Name, IsActive) VALUES (N'QA3 Transfer From', 1);
    DECLARE @BF INT = SCOPE_IDENTITY();
    INSERT INTO hr.BRANCH (Name, IsActive) VALUES (N'QA3 Transfer To', 1);
    DECLARE @BT INT = SCOPE_IDENTITY();
    INSERT INTO hr.EMPLOYEE (BranchId, DepartmentId, PositionId, FullName, HireDate)
    VALUES (@BF, @Dep, @Pos, N'QA3 Transfer Mover', '2020-01-01'), (@BT, @Dep, @Pos, N'QA3 Transfer Stayer', '2020-01-01');
    DECLARE @E1 INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Transfer Mover');
    DECLARE @E2 INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Transfer Stayer');
    INSERT INTO hr.EMPLOYEE_BRANCH_HISTORY (EmployeeId, BranchId, EffectiveFrom, Note) VALUES (@E1, @BF, '2020-01-01', N'QA3'), (@E2, @BT, '2020-01-01', N'QA3');
    INSERT INTO attendance.SHIFT (Name, StartTime, EndTime, GraceMinutes, CrossesMidnight, BreakMinutes, IsActive)
    VALUES (N'QA3 Transfer Day', '08:00', '16:00', NULL, 0, 30, 1);
    DECLARE @Sh INT = SCOPE_IDENTITY();
    DECLARE @d DATE = @NM;
    WHILE @d <= @NMEnd
    BEGIN
        INSERT INTO attendance.SHIFT_ASSIGNMENT (EmployeeId, ShiftId, WorkDate, IsRestDay) VALUES (@E1, @Sh, @d, 0), (@E2, @Sh, @d, 0);
        SET @d = DATEADD(DAY, 1, @d);
    END
    UPDATE attendance.SHIFT_ASSIGNMENT SET ModifiedUtc = DATEADD(HOUR, -3, SYSUTCDATETIME()) WHERE EmployeeId IN (@E1, @E2);
    INSERT INTO attendance.ROSTER_MONTH (BranchId, MonthDate, [Status], ApprovedAt)
    VALUES (@BF, @NM, 'Approved', DATEADD(HOUR, -2, SYSUTCDATETIME())), (@BT, @NM, 'Approved', DATEADD(HOUR, -2, SYSUTCDATETIME()));

    /* the transfer, from the employee form */
    DECLARE @Name NVARCHAR(150) = N'QA3 Transfer Mover';
    EXEC hr.usp_Employee_Update @EmployeeId = @E1, @BranchId = @BT, @DepartmentId = @Dep, @PositionId = @Pos, @FullName = @Name,
         @HireDate = '2020-01-01', @BranchEffectiveFrom = @Eff;

    DECLARE @st TABLE (RosterMonthId INT, BranchId INT, MonthDate DATE, [Status] VARCHAR(30), ApprovedAt DATETIME2, RequestInstanceId INT,
                       RequestStatus VARCHAR(20), OpenRequestId INT, OpenRequestStatus VARCHAR(20), LastApprovedAt DATETIME2,
                       ChangedSinceApproval BIT, LastChangedUtc DATETIME2, RederivedAt DATETIME2);
    INSERT INTO @st EXEC attendance.usp_RosterMonth_Get @BranchId = @BF, @MonthDate = @NM;
    INSERT INTO @st EXEC attendance.usp_RosterMonth_Get @BranchId = @BT, @MonthDate = @NM;
    IF (SELECT COUNT(*) FROM @st WHERE ChangedSinceApproval = 1) <> 2
        RAISERROR('FAIL transfer_and_gaps: after the transfer BOTH branches'' months must read "changed since approval".', 16, 1);
    IF EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT sa JOIN attendance.ROSTER_MONTH rm ON rm.BranchId = @BT AND rm.MonthDate = @NM
               WHERE sa.EmployeeId = @E1 AND sa.WorkDate >= @Eff AND sa.ModifiedUtc <= rm.ApprovedAt)
        RAISERROR('FAIL transfer_and_gaps: a moved row kept its old ModifiedUtc.', 16, 1);
    IF EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId = @E1 AND WorkDate < @Eff AND ModifiedUtc > DATEADD(HOUR, -2, SYSUTCDATETIME()))
        RAISERROR('FAIL transfer_and_gaps: a row before the transfer date was marked as changed.', 16, 1);
    IF EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E1 AND WorkDate > @Today)
        RAISERROR('FAIL transfer_and_gaps: the transfer made an attendance record for a future day (ATT-14).', 16, 1);

    /* the gaps of the branch of the day; a holiday of the branch is not a gap */
    DECLARE @Hole1 DATE = DATEADD(DAY, 2, @Eff), @Hole2 DATE = DATEADD(DAY, 3, @Eff), @Hole0 DATE = DATEADD(DAY, -3, @Eff);
    DELETE FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId = @E1 AND WorkDate IN (@Hole0, @Hole1, @Hole2);
    INSERT INTO core.HOLIDAY (HolidayDate, Name, IsPaid, BranchId) VALUES (@Hole2, N'QA3 To-branch holiday', 1, @BT);
    DECLARE @gaps TABLE (EmployeeId INT, FullName NVARCHAR(150), WorkDate DATE, BranchId INT);
    INSERT INTO @gaps EXEC attendance.usp_ShiftAssignment_GetGaps @FromDate = @NM, @ToDate = @NMEnd, @CallerUserId = NULL, @BranchId = @BT;
    IF NOT EXISTS (SELECT 1 FROM @gaps WHERE EmployeeId = @E1 AND WorkDate = @Hole1)
        RAISERROR('FAIL transfer_and_gaps: the new branch''s gaps miss the moved employee''s missing day.', 16, 1);
    IF EXISTS (SELECT 1 FROM @gaps WHERE EmployeeId = @E1 AND WorkDate IN (@Hole0, @Hole2))
        RAISERROR('FAIL transfer_and_gaps: the new branch''s gaps show a day of the old branch, or a public holiday of its own.', 16, 1);
    DELETE FROM @gaps;
    INSERT INTO @gaps EXEC attendance.usp_ShiftAssignment_GetGaps @FromDate = @NM, @ToDate = @NMEnd, @CallerUserId = NULL, @BranchId = @BF;
    IF NOT EXISTS (SELECT 1 FROM @gaps WHERE EmployeeId = @E1 AND WorkDate = @Hole0) OR EXISTS (SELECT 1 FROM @gaps WHERE EmployeeId = @E1 AND WorkDate >= @Eff)
        RAISERROR('FAIL transfer_and_gaps: the old branch''s gaps must hold its own days of the employee and no later ones.', 16, 1);

    /* cancelling the future transfer marks both months again */
    UPDATE attendance.ROSTER_MONTH SET LastChangedUtc = NULL, ApprovedAt = DATEADD(SECOND, -1, SYSUTCDATETIME()) WHERE MonthDate = @NM AND BranchId IN (@BF, @BT);
    UPDATE attendance.SHIFT_ASSIGNMENT SET ModifiedUtc = DATEADD(HOUR, -3, SYSUTCDATETIME()) WHERE EmployeeId IN (@E1, @E2);
    DECLARE @H INT = (SELECT EmployeeBranchHistoryId FROM hr.EMPLOYEE_BRANCH_HISTORY WHERE EmployeeId = @E1 AND EffectiveFrom = @Eff);
    DECLARE @c TABLE (EmployeeBranchHistoryId INT, Cancelled BIT);
    INSERT INTO @c EXEC hr.usp_EmployeeBranchHistory_CancelFuture @EmployeeBranchHistoryId = @H;
    IF hr.fn_EmployeeBranchOn(@E1, @Eff) <> @BF
        RAISERROR('FAIL transfer_and_gaps: the cancelled transfer still moves the employee (setup).', 16, 1);
    IF (SELECT COUNT(*) FROM attendance.ROSTER_MONTH WHERE MonthDate = @NM AND BranchId IN (@BF, @BT) AND LastChangedUtc > ApprovedAt) <> 2
        RAISERROR('FAIL transfer_and_gaps: cancelling the transfer must mark both months as changed.', 16, 1);

    ROLLBACK;
    PRINT 'ok transfer_and_gaps';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    DECLARE @failure NVARCHAR(4000) = ERROR_MESSAGE();
    RAISERROR(@failure, 16, 1);
END CATCH;
