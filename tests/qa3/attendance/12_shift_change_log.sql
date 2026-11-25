/* Script 122: every change to a shift is written down and kept (attendance.SHIFT_CHANGE): created, hours changed,
   hours removed, renamed, switched off and on - with who, the before and the after - and nothing for a write that
   changes nothing (the nightly sync, the same hours again, the tidy-up of a repeated version). The days a change
   could not work out again are counted and logged. A correction and a day report read whether the day's shift
   crosses midnight from the hours in force ON THAT DAY.
   Runs on a dev database with docs/122_shift_change_log.sql applied. Three phases, each in a transaction that is
   rolled back (the last two end with the transaction doomed on purpose: a refusal raised by a trigger, and a day
   refused by script 117's writers, which run with XACT_ABORT ON). */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
IF OBJECT_ID('tempdb..#fails') IS NOT NULL DROP TABLE #fails;
CREATE TABLE #fails (n INT);
GO

/* ======== phase 1: what is logged, and the dated overnight flag ======== */
BEGIN TRAN;
DECLARE @fails INT = 0, @n INT, @rc INT, @msg NVARCHAR(2048);
DECLARE @U INT = (SELECT TOP 1 UserId FROM security.[USER] ORDER BY UserId);
DECLARE @U2 INT = (SELECT TOP 1 UserId FROM security.[USER] WHERE UserId <> @U ORDER BY UserId);
DECLARE @S INT, @Base INT;
DECLARE @t TABLE (Id INT);
DECLARE @d TABLE (DaysRederived INT);
DECLARE @c TABLE (Seq INT IDENTITY(1,1), ShiftChangeId INT, ShiftId INT, ChangedAtUtc DATETIME2(0), ChangedOn DATE, ChangedByUserId INT, ChangedBy NVARCHAR(150),
                  [Action] VARCHAR(20), EffectiveFrom DATE, EffectiveTo DATE,
                  OldStartTime TIME, NewStartTime TIME, OldEndTime TIME, NewEndTime TIME, OldCrossesMidnight BIT, NewCrossesMidnight BIT,
                  OldBreakMinutes INT, NewBreakMinutes INT, OldGraceMinutes INT, NewGraceMinutes INT,
                  OldName NVARCHAR(100), NewName NVARCHAR(100), DaysCount INT, Note NVARCHAR(400));

/* ---- created: one row, with the name, the hours and who (the caller the API puts in the session) ---- */
EXEC sys.sp_set_session_context @key = N'UserId', @value = @U;
INSERT INTO @t EXEC attendance.usp_Shift_Create @Name = N'QA3 Log 08-16', @StartTime = '08:00', @EndTime = '16:00', @GraceMinutes = NULL,
     @CrossesMidnight = 0, @BreakMinutes = 30, @CallerUserId = @U;
SET @S = (SELECT Id FROM @t);
SET @Base = ISNULL((SELECT MAX(ShiftChangeId) FROM attendance.SHIFT_CHANGE WHERE ShiftId = @S), 0);
IF (SELECT COUNT(*) FROM attendance.SHIFT_CHANGE WHERE ShiftId = @S) <> 1
   OR NOT EXISTS (SELECT 1 FROM attendance.SHIFT_CHANGE WHERE ShiftId = @S AND [Action] = 'Created' AND NewName = N'QA3 Log 08-16'
                  AND NewStartTime = '08:00' AND NewEndTime = '16:00' AND NewBreakMinutes = 30 AND OldStartTime IS NULL
                  AND EffectiveFrom = '2000-01-01' AND ChangedByUserId = @U)
    BEGIN SET @fails += 1; RAISERROR('12: creating a shift did not log one Created row with its name, hours and who.', 16, 1); END

/* ---- a rename and switching it off: two rows; switching it on again: one more ---- */
EXEC attendance.usp_Shift_Update @ShiftId = @S, @Name = N'QA3 Log Morning', @StartTime = '08:00', @EndTime = '16:00', @GraceMinutes = NULL,
     @CrossesMidnight = 0, @BreakMinutes = 30, @IsActive = 0, @CallerUserId = @U;
IF NOT EXISTS (SELECT 1 FROM attendance.SHIFT_CHANGE WHERE ShiftId = @S AND [Action] = 'Renamed' AND OldName = N'QA3 Log 08-16' AND NewName = N'QA3 Log Morning' AND ChangedByUserId = @U)
   OR NOT EXISTS (SELECT 1 FROM attendance.SHIFT_CHANGE WHERE ShiftId = @S AND [Action] = 'Deactivated' AND ChangedByUserId = @U)
   OR (SELECT COUNT(*) FROM attendance.SHIFT_CHANGE WHERE ShiftId = @S) <> 3
    BEGIN SET @fails += 1; RAISERROR('12: a rename and switching the shift off were not logged as two rows.', 16, 1); END
EXEC attendance.usp_Shift_Update @ShiftId = @S, @Name = N'QA3 Log Morning', @StartTime = '08:00', @EndTime = '16:00', @GraceMinutes = NULL,
     @CrossesMidnight = 0, @BreakMinutes = 30, @IsActive = 1, @CallerUserId = @U;
IF (SELECT COUNT(*) FROM attendance.SHIFT_CHANGE WHERE ShiftId = @S) <> 4
   OR (SELECT TOP 1 [Action] FROM attendance.SHIFT_CHANGE WHERE ShiftId = @S ORDER BY ShiftChangeId DESC) <> 'Activated'
    BEGIN SET @fails += 1; RAISERROR('12: switching the shift on again was not logged once (and only once).', 16, 1); END

/* ---- noise is not logged: the nightly sync, a save that changes nothing, a direct write of the hours on SHIFT ---- */
EXEC attendance.usp_Shift_SyncCurrent @Quiet = 1;
EXEC attendance.usp_Shift_Update @ShiftId = @S, @Name = N'QA3 Log Morning', @StartTime = '08:00', @EndTime = '16:00', @GraceMinutes = NULL,
     @CrossesMidnight = 0, @BreakMinutes = 30, @IsActive = 1, @CallerUserId = @U;
UPDATE attendance.SHIFT SET StartTime = '08:00' WHERE ShiftId = @S;
IF (SELECT COUNT(*) FROM attendance.SHIFT_CHANGE WHERE ShiftId = @S) <> 4
    BEGIN SET @fails += 1; RAISERROR('12: a write that changes nothing was logged.', 16, 1); END

/* ---- new hours from a date: before and after, from when, open-ended ---- */
INSERT INTO @d EXEC attendance.usp_Shift_SetHours @ShiftId = @S, @EffectiveFrom = '2026-12-01', @StartTime = '09:00', @EndTime = '17:00',
     @CrossesMidnight = 0, @BreakMinutes = 30, @Note = N'QA3 winter', @CallerUserId = @U;
IF NOT EXISTS (SELECT 1 FROM attendance.SHIFT_CHANGE WHERE ShiftId = @S AND [Action] = 'HoursChanged' AND EffectiveFrom = '2026-12-01' AND EffectiveTo IS NULL
                  AND OldStartTime = '08:00' AND OldEndTime = '16:00' AND NewStartTime = '09:00' AND NewEndTime = '17:00'
                  AND OldBreakMinutes = 30 AND NewBreakMinutes = 30 AND Note = N'QA3 winter' AND ChangedByUserId = @U)
    BEGIN SET @fails += 1; RAISERROR('12: new hours from a date were not logged 08:00-16:00 -> 09:00-17:00 from 2026-12-01.', 16, 1); END

/* ---- the same date entered again (the version is overwritten): logged from the overwritten hours ---- */
DELETE FROM @d;
INSERT INTO @d EXEC attendance.usp_Shift_SetHours @ShiftId = @S, @EffectiveFrom = '2026-12-01', @StartTime = '09:30', @EndTime = '17:30',
     @CrossesMidnight = 0, @BreakMinutes = 45, @CallerUserId = @U;
IF NOT EXISTS (SELECT 1 FROM attendance.SHIFT_CHANGE WHERE ShiftId = @S AND [Action] = 'HoursChanged' AND EffectiveFrom = '2026-12-01'
                  AND OldStartTime = '09:00' AND NewStartTime = '09:30' AND OldBreakMinutes = 30 AND NewBreakMinutes = 45)
    BEGIN SET @fails += 1; RAISERROR('12: a version overwritten on the same date was not logged with the hours it replaced.', 16, 1); END
SET @n = (SELECT COUNT(*) FROM attendance.SHIFT_CHANGE WHERE ShiftId = @S);
/* ... and the same hours once more: nothing */
DELETE FROM @d;
INSERT INTO @d EXEC attendance.usp_Shift_SetHours @ShiftId = @S, @EffectiveFrom = '2026-12-01', @StartTime = '09:30', @EndTime = '17:30',
     @CrossesMidnight = 0, @BreakMinutes = 45, @CallerUserId = @U;
IF (SELECT COUNT(*) FROM attendance.SHIFT_CHANGE WHERE ShiftId = @S) <> @n
    BEGIN SET @fails += 1; RAISERROR('12: the same hours entered again were logged.', 16, 1); END

/* ---- without a caller in the session: hours written are put down to the version's CreatedByUserId ---- */
EXEC sys.sp_set_session_context @key = N'UserId', @value = NULL;
DELETE FROM @d;
INSERT INTO @d EXEC attendance.usp_Shift_SetHours @ShiftId = @S, @EffectiveFrom = '2027-01-10', @EffectiveTo = '2027-01-20', @StartTime = '07:00', @EndTime = '15:00',
     @CrossesMidnight = 0, @BreakMinutes = 45, @Note = N'QA3 ten early days', @CallerUserId = @U2;
/* a change for a period is two versions: the new hours on the 10th (until the 20th), the hours before back on the 21st */
IF NOT EXISTS (SELECT 1 FROM attendance.SHIFT_CHANGE WHERE ShiftId = @S AND [Action] = 'HoursChanged' AND EffectiveFrom = '2027-01-10'
                  AND OldStartTime = '09:30' AND NewStartTime = '07:00' AND ChangedByUserId = @U2)
   OR NOT EXISTS (SELECT 1 FROM attendance.SHIFT_CHANGE WHERE ShiftId = @S AND [Action] = 'HoursChanged' AND EffectiveFrom = '2027-01-21'
                  AND OldStartTime = '07:00' AND NewStartTime = '09:30' AND EffectiveTo IS NULL AND Note LIKE N'Back to the hours before%')
    BEGIN SET @fails += 1; RAISERROR('12: a change for a period was not logged as the new hours, then the old hours back (by the caller written on the version).', 16, 1); END

/* ---- taken back: one HoursRemoved row (09:30 again from the 10th, open-ended); the "back" version that goes with it
   only repeated the hours before, so its removal is not logged ---- */
EXEC sys.sp_set_session_context @key = N'UserId', @value = @U;
SET @n = (SELECT COUNT(*) FROM attendance.SHIFT_CHANGE WHERE ShiftId = @S);
DECLARE @Hid INT = (SELECT ShiftHoursId FROM attendance.SHIFT_HOURS WHERE ShiftId = @S AND EffectiveFrom = '2027-01-10');
DELETE FROM @d;
INSERT INTO @d EXEC attendance.usp_Shift_DeleteHours @ShiftHoursId = @Hid, @CallerUserId = @U;
IF (SELECT COUNT(*) FROM attendance.SHIFT_CHANGE WHERE ShiftId = @S) <> @n + 1
   OR NOT EXISTS (SELECT 1 FROM attendance.SHIFT_CHANGE WHERE ShiftId = @S AND [Action] = 'HoursRemoved' AND EffectiveFrom = '2027-01-10'
                  AND OldStartTime = '07:00' AND NewStartTime = '09:30' AND EffectiveTo IS NULL AND ChangedByUserId = @U AND Note = N'QA3 ten early days')
   OR EXISTS (SELECT 1 FROM attendance.SHIFT_HOURS WHERE ShiftId = @S AND EffectiveFrom = '2027-01-21')
    BEGIN SET @n = (SELECT COUNT(*) FROM attendance.SHIFT_CHANGE WHERE ShiftId = @S) - @n;
          SET @fails += 1; RAISERROR('12: taking a change back was not logged as one HoursRemoved row (%d new rows).', 16, 1, @n); END

/* ---- the read: newest first, with the person's name ---- */
INSERT INTO @c (ShiftChangeId, ShiftId, ChangedAtUtc, ChangedOn, ChangedByUserId, ChangedBy, [Action], EffectiveFrom, EffectiveTo,
                OldStartTime, NewStartTime, OldEndTime, NewEndTime, OldCrossesMidnight, NewCrossesMidnight, OldBreakMinutes, NewBreakMinutes,
                OldGraceMinutes, NewGraceMinutes, OldName, NewName, DaysCount, Note)
EXEC attendance.usp_Shift_GetChanges @ShiftId = @S;
IF (SELECT COUNT(*) FROM @c) <> (SELECT COUNT(*) FROM attendance.SHIFT_CHANGE WHERE ShiftId = @S)
   OR (SELECT [Action] FROM @c WHERE Seq = 1) <> 'HoursRemoved'
   OR EXISTS (SELECT 1 FROM @c a JOIN @c b ON b.Seq = a.Seq + 1 WHERE b.ShiftChangeId > a.ShiftChangeId)
   OR EXISTS (SELECT 1 FROM @c WHERE ChangedByUserId IS NOT NULL AND ChangedBy IS NULL)
   OR EXISTS (SELECT 1 FROM @c WHERE ChangedOn IS NULL)
    BEGIN SET @fails += 1; RAISERROR('12: usp_Shift_GetChanges does not list the shift''s log newest first with who and when.', 16, 1); END

/* ---- a correction and a day report read the overnight flag of THAT day ---- */
DECLARE @B INT, @E INT, @UE INT, @Night INT, @Att BIGINT, @Dev INT;
INSERT INTO hr.BRANCH (Name) VALUES (N'QA3 Log Branch'); SET @B = SCOPE_IDENTITY();
INSERT INTO security.[USER] (Username, PasswordHash, IsActive) VALUES (N'qa3.log.person', N'x', 1); SET @UE = SCOPE_IDENTITY();
INSERT INTO hr.EMPLOYEE (UserId, BranchId, DepartmentId, PositionId, FullName, HireDate)
VALUES (@UE, @B, (SELECT TOP 1 DepartmentId FROM hr.DEPARTMENT ORDER BY DepartmentId), (SELECT TOP 1 PositionId FROM hr.POSITION ORDER BY PositionId), N'QA3 Log Person', '2025-01-01');
SET @E = SCOPE_IDENTITY();
DELETE FROM @t;
INSERT INTO @t EXEC attendance.usp_Shift_Create @Name = N'QA3 Log Night', @StartTime = '22:00', @EndTime = '06:00', @GraceMinutes = NULL,
     @CrossesMidnight = 1, @BreakMinutes = 0, @CallerUserId = @U;
SET @Night = (SELECT Id FROM @t);
INSERT INTO attendance.SHIFT_ASSIGNMENT (EmployeeId, ShiftId, WorkDate, IsRestDay) VALUES (@E, @Night, '2026-09-14', 0);
INSERT INTO attendance.DEVICE (SerialNumber, BranchId, [Name]) VALUES (CONCAT('QA3-LOG-', @B), @B, N'QA3 log device'); SET @Dev = SCOPE_IDENTITY();
INSERT INTO attendance.RAW_DEVICE_LOG (DeviceId, EnrollPin, EmployeeId, PunchTimeUtc, PunchType, [Source], DedupHash)
VALUES (@Dev, 'QA3L', @E, '2026-09-14 22:05', 0, 'Device', CONVERT(VARCHAR(64), NEWID()));
EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @E, @WorkDate = '2026-09-14';
SET @Att = (SELECT AttendanceId FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E AND WorkDate = '2026-09-14');
/* from the 20th the shift is a day shift: today attendance.SHIFT says it does not cross midnight */
DELETE FROM @d;
INSERT INTO @d EXEC attendance.usp_Shift_SetHours @ShiftId = @Night, @EffectiveFrom = '2026-09-20', @StartTime = '08:00', @EndTime = '16:00',
     @CrossesMidnight = 0, @BreakMinutes = 0, @CallerUserId = @U;
IF (SELECT CrossesMidnight FROM attendance.SHIFT WHERE ShiftId = @Night) <> 0
    BEGIN SET @fails += 1; RAISERROR('12: the night shift did not become a day shift today (test set-up).', 16, 1); END
/* the 14th was a night: an out time the next morning is accepted */
DELETE FROM @t;
SET @msg = NULL;
BEGIN TRY
    INSERT INTO @t EXEC attendance.usp_Correction_Create @AttendanceId = @Att, @RequestedBy = @U, @NewLastOutUtc = '2026-09-15 06:00', @Reason = N'QA3 forgot to punch out';
END TRY
BEGIN CATCH
    SET @msg = ERROR_MESSAGE();
END CATCH
IF @Att IS NULL OR NOT EXISTS (SELECT 1 FROM @t) OR @msg IS NOT NULL
    BEGIN SET @fails += 1; SET @msg = ISNULL(@msg, N'(no message)'); RAISERROR('12: a correction to the morning after a night shift was refused (it read today''s hours): %s', 16, 1, @msg); END
DECLARE @r TABLE (ReportId INT);
SET @msg = NULL;
BEGIN TRY
    INSERT INTO @r EXEC attendance.usp_DayReport_Create @EmployeeId = @E, @WorkDate = '2026-09-14', @ClaimedIn = '2026-09-14 22:05', @ClaimedOut = '2026-09-15 06:00',
         @Message = N'QA3 I left at 06:00', @CallerUserId = @UE;
END TRY
BEGIN CATCH
    SET @msg = ERROR_MESSAGE();
END CATCH
IF NOT EXISTS (SELECT 1 FROM @r) OR @msg IS NOT NULL
    BEGIN SET @fails += 1; SET @msg = ISNULL(@msg, N'(no message)'); RAISERROR('12: a day report with the morning after a night shift was refused (it read today''s hours): %s', 16, 1, @msg); END
/* a day on the day-shift hours (the 21st) keeps the same-day rule */
INSERT INTO attendance.SHIFT_ASSIGNMENT (EmployeeId, ShiftId, WorkDate, IsRestDay) VALUES (@E, @Night, '2026-09-21', 0);
SET @msg = NULL;
BEGIN TRY
    INSERT INTO @r EXEC attendance.usp_DayReport_Create @EmployeeId = @E, @WorkDate = '2026-09-21', @ClaimedIn = '2026-09-21 08:00', @ClaimedOut = '2026-09-22 06:00',
         @Message = N'QA3 next morning on a day shift', @CallerUserId = @UE;
END TRY
BEGIN CATCH
    SET @msg = ERROR_MESSAGE();
END CATCH
IF ISNULL(@msg, N'') NOT LIKE N'The times must be on 2026-09-21.%'
    BEGIN SET @fails += 1; RAISERROR('12: a day report with the next morning on a day shift was not refused.', 16, 1); END

IF @@TRANCOUNT > 0 ROLLBACK TRAN;
INSERT INTO #fails (n) VALUES (@fails);
GO

/* ======== phase 2: the log is never deleted (the refusal is raised by a trigger, so it dooms the transaction; reads still work) ======== */
BEGIN TRAN;
DECLARE @fails INT = 0, @msg NVARCHAR(2048), @S INT;
DECLARE @t TABLE (Id INT);
INSERT INTO @t EXEC attendance.usp_Shift_Create @Name = N'QA3 Log Keep', @StartTime = '08:00', @EndTime = '16:00', @GraceMinutes = NULL,
     @CrossesMidnight = 0, @BreakMinutes = 0, @CallerUserId = NULL;
SET @S = (SELECT Id FROM @t);
BEGIN TRY
    DELETE FROM attendance.SHIFT_CHANGE WHERE ShiftId = @S;
END TRY
BEGIN CATCH
    SET @msg = ERROR_MESSAGE();
END CATCH
IF (SELECT COUNT(*) FROM attendance.SHIFT_CHANGE WHERE ShiftId = @S) <> 1 OR ISNULL(@msg, N'') NOT LIKE N'%never deleted%'
    BEGIN SET @fails += 1; RAISERROR('12: rows of the change log could be deleted.', 16, 1); END
IF @@TRANCOUNT > 0 ROLLBACK TRAN;
INSERT INTO #fails (n) VALUES (@fails);
GO

/* ======== phase 3: a day a change could not work out again is COUNTED ========
   Inside a caller's transaction the refused day dooms that transaction (the writers run with XACT_ABORT ON), so the
   change-log row is skipped here and usp_Shift_RederiveDays still returns normally with the count. On the API's path
   (no outer transaction: usp_Shift_SetHours commits before it re-derives) the DaysNotRederived row is written. */
BEGIN TRAN;
DECLARE @fails INT = 0, @rc INT, @S INT, @B INT, @E INT, @Days INT, @Failed INT, @msg NVARCHAR(2048);
DECLARE @t TABLE (Id INT);
INSERT INTO @t EXEC attendance.usp_Shift_Create @Name = N'QA3 Log Rederive', @StartTime = '08:00', @EndTime = '16:00', @GraceMinutes = NULL,
     @CrossesMidnight = 0, @BreakMinutes = 0, @CallerUserId = NULL;
SET @S = (SELECT Id FROM @t);
INSERT INTO hr.BRANCH (Name) VALUES (N'QA3 Log Branch 3'); SET @B = SCOPE_IDENTITY();
INSERT INTO hr.EMPLOYEE (BranchId, DepartmentId, PositionId, FullName, HireDate)
VALUES (@B, (SELECT TOP 1 DepartmentId FROM hr.DEPARTMENT ORDER BY DepartmentId), (SELECT TOP 1 PositionId FROM hr.POSITION ORDER BY PositionId), N'QA3 Log Person 3', '2025-01-01');
SET @E = SCOPE_IDENTITY();
INSERT INTO attendance.SHIFT_ASSIGNMENT (EmployeeId, ShiftId, WorkDate, IsRestDay) VALUES (@E, @S, '2026-09-07', 0);
EXEC @rc = attendance.usp_Attendance_ManualUpsert @EmployeeId = @E, @WorkDate = '2026-09-07', @FirstInUtc = '2026-09-07 08:00', @LastOutUtc = '2026-09-07 16:00',
     @BranchId = @B, @Quiet = 1;
UPDATE hr.EMPLOYEE SET TerminationDate = '2026-09-01' WHERE EmployeeId = @E;   -- the manual day is now outside the employment
BEGIN TRY
    EXEC attendance.usp_Shift_RederiveDays @ShiftId = @S, @From = '2026-09-07', @To = '2026-09-07', @Days = @Days OUTPUT, @Failed = @Failed OUTPUT;
END TRY
BEGIN CATCH
    SET @msg = ERROR_MESSAGE();
END CATCH
IF ISNULL(@rc, 0) <> 0 OR @msg IS NOT NULL OR ISNULL(@Failed, -1) <> 1 OR ISNULL(@Days, -1) <> 0
    BEGIN SET @fails += 1; SET @msg = ISNULL(@msg, N'-'); RAISERROR('12: a day that could not be worked out again was not counted (@Failed = 1, @Days = 0, no error: %s).', 16, 1, @msg); END
IF @@TRANCOUNT > 0 ROLLBACK TRAN;
INSERT INTO #fails (n) VALUES (@fails);
GO

DECLARE @fails INT = (SELECT SUM(n) FROM #fails), @phases INT = (SELECT COUNT(*) FROM #fails);
DROP TABLE #fails;
IF @fails = 0 AND @phases = 3 PRINT 'ok 12_shift_change_log';
ELSE RAISERROR('12_shift_change_log: %d check(s) failed (%d of 3 phases ran).', 16, 1, @fails, @phases);
GO
