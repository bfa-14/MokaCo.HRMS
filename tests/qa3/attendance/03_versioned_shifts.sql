/* QA3 attendance (unit B) - ATT-7, ROS-9, REL-10, and script 117: a shift's hours are DATED. A worked shift's hours
   change from a date (the days before keep the hours they were judged against), for a period (the hours before come
   back the day after), reaching back (the days touched are derived again), and a change can be taken back. A day
   without a rostered shift is measured against the shift its first punch fits. A Late/Early decision is withdrawn
   when the shift time it was measured against changes.
   Runs on a dev database with docs/117_shift_hours_by_date.sql applied, inside a transaction that is rolled back. */
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

/* ---- script 117: the hours of a WORKED shift change from a date ---- */
DECLARE @t TABLE (DaysRederived INT);
DECLARE @h TABLE (ShiftHoursId INT, ShiftId INT, EffectiveFrom DATE, EffectiveTo DATE, StartTime TIME, EndTime TIME, CrossesMidnight BIT, BreakMinutes INT,
                  GraceMinutes INT, StandardMinutes INT, Note NVARCHAR(200), CreatedBy NVARCHAR(100), CreatedAtUtc DATETIME2, IsFirst BIT, IsCurrent BIT);
DECLARE @n INT, @rc INT;

/* from the day AFTER the worked day: that day keeps 06:45 (35 min late), the shift shows the new hours (today is later) */
EXEC attendance.usp_Shift_Update @ShiftId = @S2, @Name = N'QA3 06:45-14:45', @StartTime = '06:30', @EndTime = '14:30', @GraceMinutes = NULL,
     @CrossesMidnight = 0, @BreakMinutes = 30, @IsActive = 1, @EffectiveFrom = '2026-09-08', @Note = N'QA3 earlier start';
EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @E, @WorkDate = '2026-09-07';
IF (SELECT LateMinutes FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E AND WorkDate = '2026-09-07') <> 35
    BEGIN SET @fails += 1; RAISERROR('03: a day before the change was judged against the new hours.', 16, 1); END
IF NOT EXISTS (SELECT 1 FROM attendance.SHIFT WHERE ShiftId = @S2 AND StartTime = '06:30' AND EndTime = '14:30')
    BEGIN SET @fails += 1; RAISERROR('03: attendance.SHIFT does not show the hours in force today.', 16, 1); END
IF (SELECT StartTime FROM attendance.fn_ShiftHoursOn(@S2, '2026-09-07')) <> '06:45' OR (SELECT StartTime FROM attendance.fn_ShiftHoursOn(@S2, '2026-09-08')) <> '06:30'
    BEGIN SET @fails += 1; RAISERROR('03: the hours by date are not 06:45 up to the 7th and 06:30 from the 8th.', 16, 1); END

/* for a PERIOD: 09:00-17:00 on the 10th-12th, and the hours before come back on the 13th */
INSERT INTO @t EXEC attendance.usp_Shift_SetHours @ShiftId = @S2, @EffectiveFrom = '2026-09-10', @EffectiveTo = '2026-09-12',
     @StartTime = '09:00', @EndTime = '17:00', @CrossesMidnight = 0, @BreakMinutes = 30, @Note = N'QA3 three late days';
IF (SELECT StartTime FROM attendance.fn_ShiftHoursOn(@S2, '2026-09-09')) <> '06:30' OR (SELECT StartTime FROM attendance.fn_ShiftHoursOn(@S2, '2026-09-11')) <> '09:00'
   OR (SELECT StartTime FROM attendance.fn_ShiftHoursOn(@S2, '2026-09-13')) <> '06:30' OR (SELECT StandardMinutes FROM attendance.fn_ShiftHoursOn(@S2, '2026-09-11')) <> 450
    BEGIN SET @fails += 1; RAISERROR('03: a change for a period did not apply inside it and return after it.', 16, 1); END
INSERT INTO @h EXEC attendance.usp_Shift_GetHours @ShiftId = @S2;
IF (SELECT COUNT(*) FROM @h) <> 4 OR (SELECT EffectiveTo FROM @h WHERE EffectiveFrom = '2026-09-10') <> '2026-09-12'
   OR (SELECT COUNT(*) FROM @h WHERE IsCurrent = 1) <> 1 OR (SELECT EffectiveFrom FROM @h WHERE IsCurrent = 1) <> '2026-09-13'
   OR (SELECT COUNT(*) FROM @h WHERE IsFirst = 1 AND EffectiveFrom = '2000-01-01' AND StartTime = '06:45') <> 1
    BEGIN SET @fails += 1; SET @n = (SELECT COUNT(*) FROM @h); RAISERROR('03: the history is not first hours / 8th / 10th-12th / back on the 13th (%d rows).', 16, 1, @n); END

/* REACHING BACK: the worked day itself gets 06:00 for that one day - it is derived again (80 min late), the 8th is 06:30 again */
DELETE FROM @t;
INSERT INTO @t EXEC attendance.usp_Shift_SetHours @ShiftId = @S2, @EffectiveFrom = '2026-09-07', @EffectiveTo = '2026-09-07',
     @StartTime = '06:00', @EndTime = '14:00', @CrossesMidnight = 0, @BreakMinutes = 30;
IF (SELECT DaysRederived FROM @t) < 1 OR (SELECT LateMinutes FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E AND WorkDate = '2026-09-07') <> 80
    BEGIN SET @fails += 1; RAISERROR('03: a change reaching back did not derive the day again (80 min late against 06:00).', 16, 1); END
IF (SELECT StartTime FROM attendance.fn_ShiftHoursOn(@S2, '2026-09-08')) <> '06:30'
    BEGIN SET @fails += 1; RAISERROR('03: the day after a one-day change lost its own hours.', 16, 1); END

/* TAKEN BACK: the one-day change removed - the day is 35 min late again */
DELETE FROM @t;
SET @n = (SELECT ShiftHoursId FROM attendance.SHIFT_HOURS WHERE ShiftId = @S2 AND EffectiveFrom = '2026-09-07');
INSERT INTO @t EXEC attendance.usp_Shift_DeleteHours @ShiftHoursId = @n;
IF (SELECT LateMinutes FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E AND WorkDate = '2026-09-07') <> 35
    BEGIN SET @fails += 1; RAISERROR('03: taking a change back did not restore the day (35 min late).', 16, 1); END
/* ... and the row that only brought the hours back after it went with it: first hours / 8th / 10th-12th / 13th remain */
IF (SELECT COUNT(*) FROM attendance.SHIFT_HOURS WHERE ShiftId = @S2) <> 4
    BEGIN SET @fails += 1; SET @n = (SELECT COUNT(*) FROM attendance.SHIFT_HOURS WHERE ShiftId = @S2); RAISERROR('03: after a change is taken back the history has %d rows, not 4.', 16, 1, @n); END
/* an exit permission's minutes are a share of the day they fall on: an hour of a 6-hour day is 0.17 of a day */
IF core.fn_MinutesToLeaveDaysOn(60, 360) <> 0.17 OR core.fn_MinutesToLeaveDaysOn(60, 0) <> core.fn_MinutesToLeaveDays(60)
    BEGIN SET @fails += 1; RAISERROR('03: minutes to leave days do not follow the day''s own length (the default day when it has none).', 16, 1); END

/* ---- script 117: a day WITHOUT a rostered shift is measured against the shift its first punch fits ---- */
DECLARE @A INT, @P INT;
UPDATE attendance.SHIFT SET IsActive = 0;                                   -- only this test's two shifts can be fitted
INSERT INTO attendance.SHIFT (Name, StartTime, EndTime, GraceMinutes, CrossesMidnight, BreakMinutes) VALUES (N'QA3 fit 07-15', '07:00', '15:00', NULL, 0, 30);
SET @A = SCOPE_IDENTITY();
INSERT INTO attendance.SHIFT (Name, StartTime, EndTime, GraceMinutes, CrossesMidnight, BreakMinutes) VALUES (N'QA3 fit 14-22:30', '14:00', '22:30', NULL, 0, 0);
SET @P = SCOPE_IDENTITY();
INSERT INTO attendance.RAW_DEVICE_LOG (DeviceId, EnrollPin, EmployeeId, PunchTimeUtc, PunchType, [Source], DedupHash)
VALUES (@Dev, 'QA3', @E, '2026-10-05 14:20', 0, 'Device', CONVERT(VARCHAR(64), NEWID())),
       (@Dev, 'QA3', @E, '2026-10-05 22:15', 1, 'Device', CONVERT(VARCHAR(64), NEWID())),
       (@Dev, 'QA3', @E, '2026-10-06 07:05', 0, 'Device', CONVERT(VARCHAR(64), NEWID())),
       (@Dev, 'QA3', @E, '2026-10-06 15:00', 1, 'Device', CONVERT(VARCHAR(64), NEWID()));
EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @E, @WorkDate = '2026-10-05';
EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @E, @WorkDate = '2026-10-06';
/* the 5th fits the afternoon shift (8 h 30): 475 worked of 510, no lateness without a roster; the 6th the morning one (7 h 30 after its break) */
IF NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E AND WorkDate = '2026-10-05' AND RelatedShiftId = @P
               AND StandardMinutes = 510 AND WorkedMinutes = 475 AND LateMinutes = 0 AND OvertimeMinutes = 0 AND ShiftAssignmentId IS NULL)
    BEGIN SET @fails += 1; RAISERROR('03: an afternoon day without a roster was not measured against the afternoon shift (510 min, no lateness).', 16, 1); END
IF NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E AND WorkDate = '2026-10-06' AND RelatedShiftId = @A
               AND StandardMinutes = 450 AND WorkedMinutes = 445 AND BreakApplied = 30)
    BEGIN SET @fails += 1; RAISERROR('03: a morning day without a roster was not measured against the morning shift (450 min, its break off once).', 16, 1); END

/* the afternoon shift is shorter in October (14:00-20:00): the day is derived again against 6 h - 115 min beyond it */
DELETE FROM @t;
INSERT INTO @t EXEC attendance.usp_Shift_SetHours @ShiftId = @P, @EffectiveFrom = '2026-10-01', @EffectiveTo = '2026-10-31',
     @StartTime = '14:00', @EndTime = '20:00', @CrossesMidnight = 0, @BreakMinutes = 0;
IF NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E AND WorkDate = '2026-10-05' AND StandardMinutes = 360 AND OvertimeMinutes = 115)
    BEGIN SET @fails += 1; RAISERROR('03: a day without a roster did not follow its shift''s hours of that month (360 min, 115 beyond).', 16, 1); END
IF (SELECT EndTime FROM attendance.SHIFT WHERE ShiftId = @P) <> '22:30'
    BEGIN SET @fails += 1; RAISERROR('03: a change that ended before today is shown as the shift''s present hours.', 16, 1); END
/* the hour of pay on that day follows the day; with no shift to fit, the default day is a shift''s length too */
IF payroll.fn_DayStandardMinutes(@E, '2026-10-05') <> 360 OR payroll.fn_DayStandardMinutes(@E, '2026-10-07') <> 450
    BEGIN SET @fails += 1; RAISERROR('03: the length of the day for pay is not the day''s own (360), then the last working day''s (450).', 16, 1); END
IF core.fn_StandardDayMinutes() NOT IN (450, 510)
    BEGIN SET @fails += 1; SET @n = core.fn_StandardDayMinutes(); RAISERROR('03: the default day (%d min) is not the length of an active shift.', 16, 1, @n); END
IF EXISTS (SELECT 1 FROM core.SETTING WHERE SettingKey = 'StandardWorkDayHours')
    BEGIN SET @fails += 1; RAISERROR('03: the setting StandardWorkDayHours is still there.', 16, 1); END

/* ---- a PAID day keeps the hours it was paid on: September is paid for this employee ---- */
INSERT INTO payroll.PAYROLL_RUN (PeriodYearMonth, PeriodStart, PeriodEnd, PrimaryCurrency, CreatedByUserId, RunType, [Status])
VALUES ('2026-09', '2026-09-01', '2026-09-30', 'USD', (SELECT TOP 1 UserId FROM security.[USER] ORDER BY UserId), 'Primary', 'Approved');
INSERT INTO payroll.PAYSLIP (PayrollRunId, EmployeeId, EmployeeName) VALUES (SCOPE_IDENTITY(), @E, N'QA3 Att Shift');

/* the refusals (last: a refusal caught here leaves the test's transaction unusable). Each is checked before anything
   is written, so one after the other is enough. */
SET @msg = NULL; SET @n = (SELECT ShiftHoursId FROM attendance.SHIFT_HOURS WHERE ShiftId = @S2 AND EffectiveFrom = '2000-01-01');
BEGIN TRY EXEC attendance.usp_Shift_DeleteHours @ShiftHoursId = @n; END TRY BEGIN CATCH SET @msg = ERROR_MESSAGE(); END CATCH;
IF @msg IS NULL OR @msg NOT LIKE N'%first hours%'
    BEGIN SET @fails += 1; RAISERROR('03: a shift''s first hours could be removed (%s).', 16, 1, @msg); END
SET @msg = NULL;
BEGIN TRY
    EXEC attendance.usp_Shift_Update @ShiftId = @Free, @Name = N'QA3 unused', @StartTime = '09:00', @EndTime = '09:00', @GraceMinutes = NULL, @CrossesMidnight = 0, @BreakMinutes = 0, @IsActive = 1;
END TRY BEGIN CATCH SET @msg = ERROR_MESSAGE(); END CATCH;
IF @msg IS NULL OR @msg NOT LIKE N'%cannot start and end at the same time%'
    BEGIN SET @fails += 1; RAISERROR('03: a shift starting and ending at the same time was accepted (%s).', 16, 1, @msg); END
SET @msg = NULL;
BEGIN TRY
    EXEC attendance.usp_Shift_SetHours @ShiftId = @S2, @EffectiveFrom = '2026-09-01', @StartTime = '08:00', @EndTime = '16:00';
END TRY BEGIN CATCH SET @msg = ERROR_MESSAGE(); END CATCH;
IF @msg IS NULL OR @msg NOT LIKE N'%up to 2026-09-07 are already paid%Start the new hours after that day%'
    BEGIN SET @fails += 1; RAISERROR('03: the hours of a paid day could be changed (%s).', 16, 1, @msg); END
IF (SELECT StartTime FROM attendance.fn_ShiftHoursOn(@S2, '2026-09-07')) <> '06:45'
    BEGIN SET @fails += 1; RAISERROR('03: the refused change of a paid day was written.', 16, 1); END
SET @msg = NULL;
BEGIN TRY
    EXEC attendance.usp_Shift_SetHours @ShiftId = @S2, @EffectiveFrom = '2026-09-20', @EffectiveTo = '2026-09-19', @StartTime = '08:00', @EndTime = '16:00';
END TRY BEGIN CATCH SET @msg = ERROR_MESSAGE(); END CATCH;
IF @msg IS NULL OR @msg NOT LIKE N'%before their first day%'
    BEGIN SET @fails += 1; RAISERROR('03: a period ending before it starts was accepted (%s).', 16, 1, @msg); END
SET @msg = NULL;
BEGIN TRY
    EXEC attendance.usp_Shift_SetHours @ShiftId = @S2, @EffectiveFrom = '2026-09-20', @StartTime = '08:00', @EndTime = '16:00', @BreakMinutes = 480;
END TRY BEGIN CATCH SET @msg = ERROR_MESSAGE(); END CATCH;
IF @msg IS NULL OR @msg NOT LIKE N'%shorter than the shift%'
    BEGIN SET @fails += 1; RAISERROR('03: a break as long as the shift was accepted (%s).', 16, 1, @msg); END

IF @@TRANCOUNT > 0 ROLLBACK TRAN;
IF @fails = 0 PRINT 'ok 03_versioned_shifts';
