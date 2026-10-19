/* QA3 attendance (unit B) - ATT-10 (a correction is checked when it is raised; approving it is all or nothing) and
   CON-4 (deciding an anomaly of a manual day answers with ONE result set - the decide procedure's own).
   Runs on a dev database with docs/100_qa3_attendance.sql applied, inside a transaction that is rolled back.
   (The all-or-nothing approval itself is held by MokaCo.HRMS.Tests AttendanceAnomalyTests: a refusal inside a
   TRY block would jump past the procedure's own rollback.) */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
BEGIN TRAN;
DECLARE @fails INT = 0, @msg NVARCHAR(2048);
DECLARE @B INT, @E INT, @S INT, @Dev INT, @U INT, @Att BIGINT, @Att2 BIGINT, @an BIGINT, @cid INT;
DECLARE @c TABLE (CorrectionId INT);
DECLARE @r TABLE (c1 BIGINT, c2 BIGINT, c3 INT, c4 DATE, c5 VARCHAR(20), c6 INT, c7 VARCHAR(10), c8 INT, c9 DATETIME2, c10 NVARCHAR(300),
                  c11 DATETIME2, c12 DATETIME2, c13 INT, c14 INT, c15 INT, c16 DECIMAL(5,2), c17 BIT, c18 INT, c19 INT, c20 INT, c21 INT, c22 BIT, c23 BIT, c24 VARCHAR(20));
DECLARE @all TABLE (Decided INT, Skipped INT, DaysRecomputed INT);
INSERT INTO hr.BRANCH (Name) VALUES (N'QA3 Att Branch'); SET @B = SCOPE_IDENTITY();
INSERT INTO hr.EMPLOYEE (BranchId, DepartmentId, PositionId, FullName, HireDate)
VALUES (@B, (SELECT TOP 1 DepartmentId FROM hr.DEPARTMENT ORDER BY DepartmentId), (SELECT TOP 1 PositionId FROM hr.POSITION ORDER BY PositionId), N'QA3 Att Correct', '2025-01-01');
SET @E = SCOPE_IDENTITY();
INSERT INTO attendance.SHIFT (Name, StartTime, EndTime, GraceMinutes, CrossesMidnight, BreakMinutes) VALUES (N'QA3 07-15', '07:00', '15:00', NULL, 0, 30);
SET @S = SCOPE_IDENTITY();
INSERT INTO attendance.ROSTER_MONTH (BranchId, MonthDate, [Status]) VALUES (@B, '2026-09-01', 'Approved');
INSERT INTO attendance.SHIFT_ASSIGNMENT (EmployeeId, ShiftId, WorkDate, IsRestDay) VALUES (@E, @S, '2026-09-07', 0), (@E, @S, '2026-09-08', 0);
INSERT INTO attendance.DEVICE (SerialNumber, BranchId, [Name]) VALUES (CONCAT('QA3-ATT-', @B), @B, N'QA3 device'); SET @Dev = SCOPE_IDENTITY();
SET @U = (SELECT TOP 1 UserId FROM security.[USER] ORDER BY UserId);
/* the 7th: in only (MissingPunch); the 8th: a manual day, 10 min late */
INSERT INTO attendance.RAW_DEVICE_LOG (DeviceId, EnrollPin, EmployeeId, PunchTimeUtc, PunchType, [Source], DedupHash)
VALUES (@Dev, 'QA3', @E, '2026-09-07 07:00', 0, 'Device', CONVERT(VARCHAR(64), NEWID()));
EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @E, @WorkDate = '2026-09-07';
SET @Att = (SELECT AttendanceId FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E AND WorkDate = '2026-09-07');
EXEC attendance.usp_Attendance_ManualUpsert @EmployeeId = @E, @WorkDate = '2026-09-08', @FirstInUtc = '2026-09-08 07:10', @LastOutUtc = '2026-09-08 15:00', @Quiet = 1;
SET @Att2 = (SELECT AttendanceId FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E AND WorkDate = '2026-09-08');

/* a sound correction goes through: the day becomes manual, the MissingPunch is the record of it */
INSERT INTO @c EXEC attendance.usp_Correction_Create @AttendanceId = @Att, @RequestedBy = @U, @NewLastOutUtc = '2026-09-07 15:00', @Reason = N'QA3 forgot to punch out';
SET @cid = (SELECT CorrectionId FROM @c);
EXEC attendance.usp_Correction_Approve @CorrectionId = @cid, @ApprovedBy = @U;      -- itself captures the manual writer (INSERT...EXEC cannot nest)
IF NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD WHERE AttendanceId = @Att AND WorkedMinutes = 450)
   OR NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_CORRECTION WHERE CorrectionId = @cid AND ApprovalStatus = 'Approved')
   OR NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD WHERE AttendanceId = @Att AND IsManual = 1 AND DayFraction = 1)
   OR NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_ANOMALY WHERE AttendanceId = @Att AND [Type] = 'MissingPunch' AND Decision = 'Corrected')
    BEGIN SET @fails += 1; RAISERROR('04: a sound correction did not apply as one (day manual and whole, correction Approved, anomaly Corrected).', 16, 1); END

/* CON-4: deciding the manual day's anomaly answers with the decide procedure's 24 columns only (the manual writer's
   19-column row used to come first: this INSERT...EXEC would then fail) */
SET @an = (SELECT AnomalyId FROM attendance.ATTENDANCE_ANOMALY WHERE AttendanceId = @Att2 AND [Type] = 'LateArrival');
INSERT INTO @r EXEC attendance.usp_Anomaly_Decide @AnomalyId = @an, @Decision = 'Excuse', @Note = N'QA3 excuse';
IF NOT EXISTS (SELECT 1 FROM @r WHERE c1 = @an AND c7 = 'Excused')
    BEGIN SET @fails += 1; RAISERROR('04: the decision on a manual day did not answer with its own row.', 16, 1); END
UPDATE attendance.ATTENDANCE_ANOMALY SET Decision = NULL, DecidedAt = NULL WHERE AnomalyId = @an;
INSERT INTO @all EXEC attendance.usp_Anomaly_DecideAll @PeriodYearMonth = '2026-09', @Decision = 'Deduct', @BranchId = @B, @Note = N'QA3 all';
IF NOT EXISTS (SELECT 1 FROM @all WHERE Decided = 1 AND DaysRecomputed = 1)
    BEGIN SET @fails += 1; RAISERROR('04: decide-all on a manual day did not answer with its own counts.', 16, 1); END
IF (SELECT LateDeductMinutes FROM attendance.ATTENDANCE_RECORD WHERE AttendanceId = @Att2) <> 10
    BEGIN SET @fails += 1; RAISERROR('04: decide-all did not deduct the manual day.', 16, 1); END

/* the refusals at creation (last): out before in, the next day on a day shift, an unknown status */
SET @msg = NULL;
BEGIN TRY INSERT INTO @c EXEC attendance.usp_Correction_Create @AttendanceId = @Att2, @RequestedBy = @U, @NewLastOutUtc = '2026-09-08 03:00', @Reason = N'QA3 typo';
END TRY BEGIN CATCH SET @msg = ERROR_MESSAGE(); END CATCH;
IF @msg IS NULL OR @msg NOT LIKE N'%must be after the in time%'
    BEGIN SET @fails += 1; RAISERROR('04: a correction with the out time before the in time was accepted (%s).', 16, 1, @msg); END
SET @msg = NULL;
BEGIN TRY INSERT INTO @c EXEC attendance.usp_Correction_Create @AttendanceId = @Att2, @RequestedBy = @U, @NewLastOutUtc = '2026-09-09 03:00', @Reason = N'QA3 wrong day';
END TRY BEGIN CATCH SET @msg = ERROR_MESSAGE(); END CATCH;
IF @msg IS NULL OR @msg NOT LIKE N'%does not cross midnight%'
    BEGIN SET @fails += 1; RAISERROR('04: a next-day out time on a day shift was accepted (%s).', 16, 1, @msg); END
SET @msg = NULL;
BEGIN TRY INSERT INTO @c EXEC attendance.usp_Correction_Create @AttendanceId = @Att2, @RequestedBy = @U, @NewStatus = 'Sick', @Reason = N'QA3 status';
END TRY BEGIN CATCH SET @msg = ERROR_MESSAGE(); END CATCH;
IF @msg IS NULL OR @msg NOT LIKE N'Status must be%'
    BEGIN SET @fails += 1; RAISERROR('04: an unknown status was accepted (%s).', 16, 1, @msg); END
IF (SELECT COUNT(*) FROM attendance.ATTENDANCE_CORRECTION WHERE AttendanceId = @Att2) <> 0
    BEGIN SET @fails += 1; RAISERROR('04: a refused correction was stored.', 16, 1); END

IF @@TRANCOUNT > 0 ROLLBACK TRAN;
IF @fails = 0 PRINT 'ok 04_corrections_and_decisions';
