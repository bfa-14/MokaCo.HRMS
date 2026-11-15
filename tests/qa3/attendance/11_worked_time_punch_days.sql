/* Script 114: the Worked time report measures a "not on roster" day (approved month, no roster row, no attendance day)
   from its punches EXACTLY as the processor measures a day with no shift. Each day below is measured by
   report.usp_Report_WorkedTime_PunchDays, then the month is taken off approval and attendance.usp_Attendance_ComputeDay
   builds the same day as a no-shift attendance day: worked minutes and the missing-punch flag must match.
   Both direction modes, a double press, a break, an odd number of punches, a single punch; a dismissed day is left out.
   Runs on a dev database with docs/113 and docs/114 applied, inside a transaction that is rolled back.
   sqlcmd -I -b -i tests/qa3/attendance/11_worked_time_punch_days.sql   ->  prints 'ok 11_worked_time_punch_days' */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
BEGIN TRAN;
DECLARE @fails INT = 0, @mode VARCHAR(20), @msg NVARCHAR(400);
DECLARE @Dep INT = (SELECT TOP 1 DepartmentId FROM hr.DEPARTMENT ORDER BY DepartmentId);
DECLARE @Pos INT = (SELECT TOP 1 PositionId FROM hr.[POSITION] ORDER BY PositionId);
DECLARE @M DATE = '2026-09-01';
DECLARE @got TABLE (Mode VARCHAR(20), EmployeeId INT, WorkDate DATE, BranchId INT, FirstIn DATETIME2, LastOut DATETIME2, PunchCount INT, WorkedMinutes INT, MissingPunch BIT);
DECLARE @one TABLE (EmployeeId INT, WorkDate DATE, BranchId INT, FirstIn DATETIME2, LastOut DATETIME2, PunchCount INT, WorkedMinutes INT, MissingPunch BIT);

INSERT INTO hr.BRANCH (Name, IsActive) VALUES (N'QA3 Punch Days', 1); DECLARE @B INT = SCOPE_IDENTITY();
INSERT INTO hr.EMPLOYEE (BranchId, DepartmentId, PositionId, FullName, HireDate)
VALUES (@B, @Dep, @Pos, N'QA3 Punch Days One', '2020-01-01'), (@B, @Dep, @Pos, N'QA3 Punch Days Two', '2020-01-01');
DECLARE @E1 INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Punch Days One');
DECLARE @E2 INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA3 Punch Days Two');
INSERT INTO hr.EMPLOYEE_BRANCH_HISTORY (EmployeeId, BranchId, EffectiveFrom) VALUES (@E1, @B, '2020-01-01'), (@E2, @B, '2020-01-01');
INSERT INTO attendance.DEVICE (SerialNumber, BranchId, [Name]) VALUES (CONCAT('QA3-PD-', @B), @B, N'QA3 punch days'); DECLARE @Dev INT = SCOPE_IDENTITY();
INSERT INTO attendance.ROSTER_MONTH (BranchId, MonthDate, [Status]) VALUES (@B, @M, 'Approved');

/* E1 day 8: in 08:00 (+ a double press 20 s later), out 12:00, in 12:45, out 17:10 -> 240 + 265 = 505, no missing punch
   E1 day 9: 09:00, 13:00, 14:00 -> odd: a missing punch
   E1 day 10: one punch only
   E2 day 8: keys sent by the terminal: in 07:30, in 07:35 (a second in), out 15:30 -> what each mode makes of it
   E2 day 9: punched, then dismissed by the branch manager -> not measured */
INSERT INTO attendance.RAW_DEVICE_LOG (DeviceId, EnrollPin, EmployeeId, PunchTimeUtc, PunchType, [Source], DedupHash)
SELECT @Dev, 'QA3', p.E, p.T, p.K, 'Device', CONVERT(VARCHAR(64), NEWID())
FROM (VALUES (@E1, CAST('2026-09-08 08:00:00' AS DATETIME2), 0), (@E1, '2026-09-08 08:00:20', 0), (@E1, '2026-09-08 12:00', 1),
             (@E1, '2026-09-08 12:45', 0), (@E1, '2026-09-08 17:10', 1),
             (@E1, '2026-09-09 09:00', 0), (@E1, '2026-09-09 13:00', 1), (@E1, '2026-09-09 14:00', 0),
             (@E1, '2026-09-10 10:00', 0),
             (@E2, '2026-09-08 07:30', 0), (@E2, '2026-09-08 07:35', 0), (@E2, '2026-09-08 15:30', 1),
             (@E2, '2026-09-09 08:00', 0), (@E2, '2026-09-09 16:00', 1)) p (E, T, K);
INSERT INTO attendance.UNROSTERED_DAY_DECISION (EmployeeId, WorkDate, Decision, Note, PunchCount, FirstPunch, LastPunch, DecidedByUserId)
VALUES (@E2, '2026-09-09', 'Dismissed', N'QA3: came in to collect a payslip', 2, '2026-09-09 08:00', '2026-09-09 16:00', NULL);

IF NOT EXISTS (SELECT 1 FROM core.SETTING WHERE SettingKey = 'PunchDebounceMinutes')
    INSERT INTO core.SETTING (SettingKey, SettingValue, DataType) VALUES ('PunchDebounceMinutes', '1', 'int');
ELSE UPDATE core.SETTING SET SettingValue = '1' WHERE SettingKey = 'PunchDebounceMinutes';
IF NOT EXISTS (SELECT 1 FROM core.SETTING WHERE SettingKey = 'PunchDirectionMode')
    INSERT INTO core.SETTING (SettingKey, SettingValue, DataType) VALUES ('PunchDirectionMode', 'Alternate', 'string');

DECLARE modes CURSOR LOCAL FAST_FORWARD FOR SELECT m FROM (VALUES ('Alternate'), ('Device')) v (m);
OPEN modes; FETCH NEXT FROM modes INTO @mode;
WHILE @@FETCH_STATUS = 0
BEGIN
    UPDATE core.SETTING SET SettingValue = @mode WHERE SettingKey = 'PunchDirectionMode';
    DELETE FROM @one;
    INSERT INTO @one EXEC report.usp_Report_WorkedTime_PunchDays @From = '2026-09-01', @To = '2026-09-30', @EmployeeId = NULL;
    INSERT INTO @got SELECT @mode, * FROM @one WHERE EmployeeId IN (@E1, @E2);
    FETCH NEXT FROM modes INTO @mode;
END
CLOSE modes; DEALLOCATE modes;

/* 1. what the report measures */
IF NOT EXISTS (SELECT 1 FROM @got WHERE Mode = 'Alternate' AND EmployeeId = @E1 AND WorkDate = '2026-09-08' AND WorkedMinutes = 505 AND MissingPunch = 0 AND PunchCount = 4 AND BranchId = @B)
BEGIN SET @fails += 1; PRINT 'FAIL 1a: a day with a break and a double press is 505 minutes, 4 punches kept'; END
IF NOT EXISTS (SELECT 1 FROM @got WHERE Mode = 'Alternate' AND EmployeeId = @E1 AND WorkDate = '2026-09-09' AND MissingPunch = 1)
BEGIN SET @fails += 1; PRINT 'FAIL 1b: an odd number of punches is a missing punch'; END
IF NOT EXISTS (SELECT 1 FROM @got WHERE Mode = 'Alternate' AND EmployeeId = @E1 AND WorkDate = '2026-09-10' AND WorkedMinutes = 0 AND MissingPunch = 1)
BEGIN SET @fails += 1; PRINT 'FAIL 1c: a single punch is 0 minutes and a missing punch'; END
IF EXISTS (SELECT 1 FROM @got WHERE EmployeeId = @E2 AND WorkDate = '2026-09-09')
BEGIN SET @fails += 1; PRINT 'FAIL 1d: a dismissed day is not measured'; END
IF (SELECT COUNT(*) FROM @got WHERE Mode = 'Device') <> 4
BEGIN SET @fails += 1; PRINT 'FAIL 1e: four days measured in Device mode too'; END

/* 2. the processor, given the same days without an approved roster, agrees in both modes */
UPDATE attendance.ROSTER_MONTH SET [Status] = 'PendingApproval' WHERE BranchId = @B AND MonthDate = @M;
DECLARE @E INT, @D DATE, @W INT, @Miss BIT, @RW INT, @RA BIT;
DECLARE days CURSOR LOCAL FAST_FORWARD FOR SELECT Mode, EmployeeId, WorkDate, WorkedMinutes, MissingPunch FROM @got ORDER BY Mode, EmployeeId, WorkDate;
OPEN days; FETCH NEXT FROM days INTO @mode, @E, @D, @W, @Miss;
WHILE @@FETCH_STATUS = 0
BEGIN
    UPDATE core.SETTING SET SettingValue = @mode WHERE SettingKey = 'PunchDirectionMode';
    EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @E, @WorkDate = @D;
    SELECT @RW = WorkedMinutes, @RA = HasAnomaly FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E AND WorkDate = @D;
    IF @RW IS NULL OR @RW <> @W OR @RA <> @Miss
    BEGIN
        SET @fails += 1;
        SET @msg = CONCAT('FAIL 2: ', @mode, ' employee ', @E, ' on ', CONVERT(CHAR(10), @D, 23), ': report ', @W, ' min / missing ', @Miss,
                          ', processor ', ISNULL(CAST(@RW AS VARCHAR(10)), 'no day'), ' min / missing ', ISNULL(CAST(@RA AS VARCHAR(1)), '-'));
        PRINT @msg;
    END
    SELECT @RW = NULL, @RA = NULL;
    FETCH NEXT FROM days INTO @mode, @E, @D, @W, @Miss;
END
CLOSE days; DEALLOCATE days;

ROLLBACK;
IF @fails = 0 PRINT 'ok 11_worked_time_punch_days';
ELSE RAISERROR('11_worked_time_punch_days: %d failure(s)', 16, 1, @fails);
