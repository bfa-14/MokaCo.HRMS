/* QA3 attendance (unit B) - ATT-7, ROS-9, REL-10: the times of a shift that has been worked are fixed (a new shift is
   created instead); a Late/Early decision is withdrawn when the shift time it was measured against changes.
   Runs on a dev database with docs/100_qa3_attendance.sql applied, inside a transaction that is rolled back. */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
BEGIN TRAN;
DECLARE @fails INT = 0, @msg NVARCHAR(2048);
DECLARE @B INT, @E INT, @S INT, @S2 INT, @Free INT, @Dev INT, @an BIGINT, @dec VARCHAR(10), @note NVARCHAR(300);
DECLARE @r TABLE (c1 BIGINT, c2 BIGINT, c3 INT, c4 DATE, c5 VARCHAR(20), c6 INT, c7 VARCHAR(10), c8 INT, c9 DATETIME2, c10 NVARCHAR(300),
                  c11 DATETIME2, c12 DATETIME2, c13 INT, c14 INT, c15 INT, c16 DECIMAL(5,2), c17 BIT, c18 INT, c19 INT, c20 INT, c21 INT, c22 BIT, c23 BIT, c24 VARCHAR(20));
INSERT INTO hr.BRANCH (Name) VALUES (N'QA3 Att Branch'); SET @B = SCOPE_IDENTITY();
INSERT INTO hr.EMPLOYEE (BranchId, DepartmentId, PositionId, FullName, HireDate)
VALUES (@B, (SELECT TOP 1 DepartmentId FROM hr.DEPARTMENT ORDER BY DepartmentId), (SELECT TOP 1 PositionId FROM hr.POSITION ORDER BY PositionId), N'QA3 Att Shift', '2025-01-01');
SET @E = SCOPE_IDENTITY();
INSERT INTO attendance.SHIFT (Name, StartTime, EndTime, GraceMinutes, CrossesMidnight, BreakMinutes) VALUES (N'QA3 07-15', '07:00', '15:00', NULL, 0, 30);
SET @S = SCOPE_IDENTITY();
INSERT INTO attendance.SHIFT (Name, StartTime, EndTime, GraceMinutes, CrossesMidnight, BreakMinutes) VALUES (N'QA3 06:45-14:45', '06:45', '14:45', NULL, 0, 30);
SET @S2 = SCOPE_IDENTITY();
INSERT INTO attendance.SHIFT (Name, StartTime, EndTime, GraceMinutes, CrossesMidnight, BreakMinutes) VALUES (N'QA3 unused', '08:00', '16:00', NULL, 0, 30);
SET @Free = SCOPE_IDENTITY();
INSERT INTO attendance.ROSTER_MONTH (BranchId, MonthDate, [Status]) VALUES (@B, '2026-09-01', 'Approved');
INSERT INTO attendance.SHIFT_ASSIGNMENT (EmployeeId, ShiftId, WorkDate, IsRestDay) VALUES (@E, @S, '2026-09-07', 0);
INSERT INTO attendance.DEVICE (SerialNumber, BranchId, [Name]) VALUES (CONCAT('QA3-ATT-', @B), @B, N'QA3 device'); SET @Dev = SCOPE_IDENTITY();
INSERT INTO attendance.RAW_DEVICE_LOG (DeviceId, EnrollPin, EmployeeId, PunchTimeUtc, PunchType, [Source], DedupHash)
VALUES (@Dev, 'QA3', @E, '2026-09-07 07:20', 0, 'Device', CONVERT(VARCHAR(64), NEWID())),
       (@Dev, 'QA3', @E, '2026-09-07 15:00', 1, 'Device', CONVERT(VARCHAR(64), NEWID()));
EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @E, @WorkDate = '2026-09-07';
SET @an = (SELECT an.AnomalyId FROM attendance.ATTENDANCE_ANOMALY an JOIN attendance.ATTENDANCE_RECORD a ON a.AttendanceId = an.AttendanceId
           WHERE a.EmployeeId = @E AND a.WorkDate = '2026-09-07' AND an.[Type] = 'LateArrival');
INSERT INTO @r EXEC attendance.usp_Anomaly_Decide @AnomalyId = @an, @Decision = 'Deduct', @Note = N'QA3 deduct';
IF (SELECT LateDeductMinutes FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E AND WorkDate = '2026-09-07') <> 20
    BEGIN SET @fails += 1; RAISERROR('03: the late arrival of 20 min was not deducted.', 16, 1); END

/* the name and Active of a worked shift still change; an unused shift's times change */
EXEC attendance.usp_Shift_Update @ShiftId = @S, @Name = N'QA3 07-15 (old)', @StartTime = '07:00', @EndTime = '15:00', @GraceMinutes = NULL, @CrossesMidnight = 0, @BreakMinutes = 30, @IsActive = 0;
IF NOT EXISTS (SELECT 1 FROM attendance.SHIFT WHERE ShiftId = @S AND Name = N'QA3 07-15 (old)' AND IsActive = 0)
    BEGIN SET @fails += 1; RAISERROR('03: renaming / retiring a worked shift was refused.', 16, 1); END
EXEC attendance.usp_Shift_Update @ShiftId = @Free, @Name = N'QA3 unused', @StartTime = '08:30', @EndTime = '16:30', @GraceMinutes = 5, @CrossesMidnight = 0, @BreakMinutes = 45, @IsActive = 1;
IF NOT EXISTS (SELECT 1 FROM attendance.SHIFT WHERE ShiftId = @Free AND StartTime = '08:30' AND BreakMinutes = 45 AND GraceMinutes = 5)
    BEGIN SET @fails += 1; RAISERROR('03: the times of a shift nobody worked could not change.', 16, 1); END

/* the day is re-rostered to another shift (unit C allows a past-day roster change in narrow cases): the Deduct was
   about "20 min late against 07:00"; against 06:45 it is a different fact - withdrawn, with a note */
UPDATE attendance.SHIFT_ASSIGNMENT SET ShiftId = @S2 WHERE EmployeeId = @E AND WorkDate = '2026-09-07';
EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @E, @WorkDate = '2026-09-07';
SELECT @dec = Decision, @note = Note FROM attendance.ATTENDANCE_ANOMALY WHERE AnomalyId = @an;
IF @dec IS NOT NULL OR @note NOT LIKE N'The shift changed after this was decided%'
    BEGIN SET @fails += 1; RAISERROR('03: a decision survived a change of the shift it was measured against (%s / %s).', 16, 1, @dec, @note); END
IF (SELECT LateMinutes FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E AND WorkDate = '2026-09-07') <> 35
    BEGIN SET @fails += 1; RAISERROR('03: the day was not measured against the new shift (35 min late).', 16, 1); END

/* the refusals (last) */
SET @msg = NULL;
BEGIN TRY
    EXEC attendance.usp_Shift_Update @ShiftId = @S2, @Name = N'QA3 06:45-14:45', @StartTime = '06:30', @EndTime = '14:45', @GraceMinutes = NULL, @CrossesMidnight = 0, @BreakMinutes = 30, @IsActive = 1;
END TRY BEGIN CATCH SET @msg = ERROR_MESSAGE(); END CATCH;
IF @msg IS NULL OR @msg NOT LIKE N'%already in use%Create a new shift%'
    BEGIN SET @fails += 1; RAISERROR('03: the start of a worked shift could be changed (%s).', 16, 1, @msg); END
IF NOT EXISTS (SELECT 1 FROM attendance.SHIFT WHERE ShiftId = @S2 AND StartTime = '06:45')
    BEGIN SET @fails += 1; RAISERROR('03: the refused shift change was written.', 16, 1); END
SET @msg = NULL;
BEGIN TRY
    EXEC attendance.usp_Shift_Update @ShiftId = @Free, @Name = N'QA3 unused', @StartTime = '09:00', @EndTime = '09:00', @GraceMinutes = NULL, @CrossesMidnight = 0, @BreakMinutes = 0, @IsActive = 1;
END TRY BEGIN CATCH SET @msg = ERROR_MESSAGE(); END CATCH;
IF @msg IS NULL OR @msg NOT LIKE N'%cannot start and end at the same time%'
    BEGIN SET @fails += 1; RAISERROR('03: a shift starting and ending at the same time was accepted (%s).', 16, 1, @msg); END

IF @@TRANCOUNT > 0 ROLLBACK TRAN;
IF @fails = 0 PRINT 'ok 03_versioned_shifts';
