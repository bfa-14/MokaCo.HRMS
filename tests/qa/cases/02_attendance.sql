/* ============================================================================
   cases/02_attendance.sql — processes the QA punches with the real procs and
   checks A1..A12 (A4 decisions, A6 manual correction and A11's request are driven
   through the API in api-tests.mjs; their record-level checks are here too).
   Runs after api-tests phase1 (roster approved, leaves and exit permission approved).
   ============================================================================ */
SET NOCOUNT ON;
DECLARE @E1 INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA E1');
DECLARE @E3 INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA E3');
DECLARE @E4 INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA E4');
DECLARE @E5 INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA E5');
DECLARE @E6 INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA E6');
DECLARE @E9 INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA E9');
DECLARE @D INT = (SELECT DeviceId FROM attendance.DEVICE WHERE SerialNumber = 'QA-DEVICE-001');
DECLARE @exp NVARCHAR(600), @act NVARCHAR(600), @pass BIT, @t NVARCHAR(1000), @n INT, @n2 INT;
DECLARE @Std INT = (SELECT DATEDIFF(MINUTE, StartTime, EndTime) - BreakMinutes FROM attendance.SHIFT WHERE Name = N'Morning');  -- 510
EXEC dbo.QA_Note 'Rules read from the DB: grace and break are per SHIFT (Morning grace 10, break 30, standard 510 min); PunchDirectionMode=Alternate; PunchDebounceMinutes=1; OvernightAttributionHours=4; FullDayThreshold=1.00; ExitLeaveBasis=Actual; LateDeductionBasis=BeyondGrace (script 76: one day rule in attendance.fn_AttendanceDayRule / usp_Attendance_ComputeDay; DayFraction = (Worked + Covered) / Standard where Covered = approved exit minutes + grace-protected late minutes + variance minutes HR dispositioned Ignore/Overtime).';

/* roster must be approved for the processor to use the shifts */
SET @act = (SELECT rm.[Status] FROM attendance.ROSTER_MONTH rm JOIN hr.BRANCH b ON b.BranchId = rm.BranchId WHERE b.Name = N'QA Branch' AND rm.MonthDate = '2026-08-01');
SET @pass = CASE WHEN @act = 'Approved' THEN 1 ELSE 0 END;
EXEC dbo.QA_Check 'A0', 'QA Branch roster month is Approved before processing (the processor ignores an unapproved roster)', 'Approved', @act, @pass;

/* ---- A7 (API path): the same DedupHash is inserted once ---- */
DECLARE @h VARCHAR(64) = (SELECT DedupHash FROM attendance.RAW_DEVICE_LOG WHERE EmployeeId = @E1 AND PunchTimeUtc = '2026-08-11 07:00:00' AND PunchType = 0);
DECLARE @ins TABLE (RawLogId BIGINT, WasDuplicate BIT, WasUnresolved BIT);
INSERT INTO @ins EXEC attendance.usp_RawLog_Insert @DeviceId = @D, @EnrollPin = 'QA1', @PunchTimeUtc = '2026-08-11 07:00:00', @PunchType = 0, @Source = 'QA', @DedupHash = @h;
SELECT @n = COUNT(*) FROM attendance.RAW_DEVICE_LOG WHERE DedupHash = @h;
SELECT @act = CONCAT('WasDuplicate=', WasDuplicate, ', rows with that hash=', @n) FROM @ins;
SET @pass = CASE WHEN @n = 1 AND EXISTS (SELECT 1 FROM @ins WHERE WasDuplicate = 1) THEN 1 ELSE 0 END;
EXEC dbo.QA_Check 'A7a', 'usp_RawLog_Insert with an already-known DedupHash is ignored (WasDuplicate=1), one row remains', 'WasDuplicate=1, rows=1', @act, @pass;

/* ---- processing: real procs, scoped so that no real employee gains a row ---- */
SELECT @n = COUNT(*) FROM attendance.RAW_DEVICE_LOG r JOIN hr.EMPLOYEE e ON e.EmployeeId = r.EmployeeId WHERE r.IsProcessed = 0 AND e.FullName NOT LIKE N'QA %';
SET @act = CAST(@n AS NVARCHAR(10)); SET @pass = CASE WHEN @n = 0 THEN 1 ELSE 0 END;
EXEC dbo.QA_Check 'A0b', 'no real (non-QA) punches are waiting to be processed, so running the processor touches only QA days', '0', @act, @pass;
DECLARE @proc TABLE (EmployeeDaysProcessed INT);
INSERT INTO @proc EXEC attendance.usp_Attendance_ProcessRawLogs @WorkDate = NULL;
SELECT @t = CONCAT('usp_Attendance_ProcessRawLogs employee-days processed = ', EmployeeDaysProcessed) FROM @proc;
EXEC dbo.QA_Note @t;

/* MarkAbsentees per day of M: run the real proc inside a transaction and delete the rows it created for non-QA employees */
DECLARE @day DATE = '2026-08-01', @maxId BIGINT, @realAdded INT = 0, @qaAdded INT = 0, @c INT;
WHILE @day <= '2026-08-31'
BEGIN
    SET @maxId = ISNULL((SELECT MAX(AttendanceId) FROM attendance.ATTENDANCE_RECORD), 0);
    BEGIN TRAN;
    EXEC attendance.usp_Attendance_MarkAbsentees @WorkDate = @day;
    DELETE a FROM attendance.ATTENDANCE_RECORD a JOIN hr.EMPLOYEE e ON e.EmployeeId = a.EmployeeId
    WHERE a.AttendanceId > @maxId AND e.FullName NOT LIKE N'QA %';
    SET @realAdded += @@ROWCOUNT;
    SELECT @c = COUNT(*) FROM attendance.ATTENDANCE_RECORD a JOIN hr.EMPLOYEE e ON e.EmployeeId = a.EmployeeId WHERE a.AttendanceId > @maxId AND e.FullName LIKE N'QA %';
    SET @qaAdded += @c;
    COMMIT;
    SET @day = DATEADD(DAY, 1, @day);
END
SET @t = CONCAT('usp_Attendance_MarkAbsentees: rows created for QA employees = ', @qaAdded, '; rows it would have created for REAL employees (deleted before commit) = ', @realAdded);
EXEC dbo.QA_Note @t;

/* MarkLeaveDays for M (only flips Absent -> Leave; check that no real row was touched) */
SELECT @n = COUNT(*) FROM attendance.ATTENDANCE_RECORD a JOIN hr.EMPLOYEE e ON e.EmployeeId = a.EmployeeId WHERE e.FullName NOT LIKE N'QA %' AND a.WorkDate BETWEEN '2026-08-01' AND '2026-08-31' AND a.[Status] = 'Absent' AND a.IsManual = 0;
DECLARE @lv TABLE (DaysMarkedAsLeave INT);
INSERT INTO @lv EXEC attendance.usp_Attendance_MarkLeaveDays @PeriodYearMonth = '2026-08';
SELECT @t = CONCAT('usp_Attendance_MarkLeaveDays 2026-08: days marked = ', DaysMarkedAsLeave, ' (real Absent rows in scope before the call: ', @n, ')') FROM @lv;
EXEC dbo.QA_Note @t;

/* apply E1's approved exit permission (13 Aug) exactly as the nightly job would, for that one permission */
DECLARE @ep INT = (SELECT TOP 1 ep.ExitPermissionId FROM workflow.EXIT_PERMISSION ep WHERE ep.EmployeeId = @E1 AND ep.ExitDate = '2026-08-13');
IF @ep IS NOT NULL EXEC workflow.usp_ExitPermission_ApplyToAttendance @ExitPermissionId = @ep;
ELSE EXEC dbo.QA_Note 'A11: no approved exit permission found for E1 on 13 Aug (phase1 must have failed to create it).';

/* ---------------------------------------------------------------- checks ---- */
DECLARE @r TABLE (WorkDate DATE, [Status] VARCHAR(20), FirstIn DATETIME2, LastOut DATETIME2, Gross INT, Worked INT, Standard INT, Fraction DECIMAL(5,2),
                  Late INT, OT INT, ExitActual INT, ExitApproved INT, ExitVar INT, Anomaly BIT, IsManual BIT, Pairs INT, Shortfall INT);
INSERT INTO @r SELECT WorkDate, [Status], FirstInUtc, LastOutUtc, GrossMinutes, WorkedMinutes, StandardMinutes, DayFraction, LateMinutes, OvertimeMinutes,
                      ExitActualMinutes, ExitApprovedMinutes, ExitVarianceMinutes, HasAnomaly, IsManual, PunchPairs, ShortfallMinutes
               FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E1;

/* A1 */
SET @act = NULL; SET @pass = 0;
SELECT @act = CONCAT('late=', Late, ' exitVar=', ExitVar, ' fraction=', Fraction, ' worked=', Worked, ' status=', [Status]), @pass = CASE WHEN Late = 0 AND ExitVar = 0 AND Fraction = 1.00 THEN 1 ELSE 0 END FROM @r WHERE WorkDate = '2026-08-03';
SET @act = ISNULL(@act, 'no record');
EXEC dbo.QA_Check 'A1', 'E1 in 07:00 / out 16:00 -> LateMinutes 0, ExitVariance 0, DayFraction 1', 'late=0 exitVar=0 fraction=1.00 worked=510', @act, @pass;
/* A2 */
SET @act = NULL; SET @pass = 0;
SELECT @act = CONCAT('late=', Late, ' fraction=', Fraction, ' worked=', Worked), @pass = CASE WHEN Late = 12 THEN 1 ELSE 0 END FROM @r WHERE WorkDate = '2026-08-04';
SET @act = ISNULL(@act, 'no record');
EXEC dbo.QA_Note 'A2 rule (script 76): the grace is a THRESHOLD. LateMinutes = FirstIn - ShiftStart when FirstIn > ShiftStart + Grace, else 0; LateDeductMinutes (basis BeyondGrace) = the minutes after the grace; the grace minutes are covered in pay.';
EXEC dbo.QA_Check 'A2', 'E1 in 07:12 with grace 10 -> LateMinutes 12 (grace as a threshold, per the brief)', 'late=12', @act, @pass;
SET @act = NULL; SET @pass = 0;
SELECT @act = CONCAT('late=', LateMinutes, ' lateDeduct=', LateDeductMinutes, ' covered=', CoveredMinutes, ' worked=', WorkedMinutes, ' fraction=', DayFraction), @pass = CASE WHEN LateMinutes = 12 AND LateDeductMinutes = 2 AND CoveredMinutes = 10 THEN 1 ELSE 0 END
FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E1 AND WorkDate = '2026-08-04';
SET @act = ISNULL(@act, 'no record');
EXEC dbo.QA_Check 'A2b', 'E1 in 07:12 with grace 10, LateDeductionBasis=BeyondGrace -> only the 2 minutes beyond the grace are deducted (LateDeductMinutes 2, the 10 grace minutes covered)', 'late=12 lateDeduct=2 covered=10', @act, @pass;
/* A3 */
SET @act = NULL; SET @pass = 0;
SELECT @act = CONCAT('late=', Late, ' fraction=', Fraction, ' worked=', Worked), @pass = CASE WHEN Late = 0 THEN 1 ELSE 0 END FROM @r WHERE WorkDate = '2026-08-05';
SET @act = ISNULL(@act, 'no record');
EXEC dbo.QA_Check 'A3', 'E1 in 07:08 (inside grace) -> LateMinutes 0', 'late=0', @act, @pass;
SET @pass = 0; SELECT @pass = CASE WHEN Fraction = 1.00 THEN 1 ELSE 0 END FROM @r WHERE WorkDate = '2026-08-05';
EXEC dbo.QA_Check 'A3b', 'inside-grace arrival is not penalised in pay (DayFraction stays 1)', 'fraction=1.00', @act, @pass;
/* A4 record-level (queue/decision checks are in api-tests phase2) */
SET @act = NULL; SET @pass = 0;
SELECT @act = CONCAT('exitActual=', ExitActual, ' exitVar=', ExitVar, ' worked=', Worked, ' shortfall=', Shortfall, ' fraction=', Fraction), @pass = CASE WHEN ExitVar <> 0 THEN 1 ELSE 0 END FROM @r WHERE WorkDate = '2026-08-06';
SET @act = ISNULL(@act, 'no record');
EXEC dbo.QA_Check 'A4-rec', 'E1 out 75 min early on 6 Aug -> ExitVarianceMinutes <> 0 (so it reaches the queue)', 'exitVar=75', @act, @pass;
/* A5 */
SET @act = NULL; SET @pass = 0;
SELECT @act = CONCAT('status=', [Status], ' fraction=', Fraction, ' anomaly=', Anomaly, ' standard=', Standard), @pass = CASE WHEN [Status] = 'Absent' AND Fraction = 0 AND Anomaly = 0 THEN 1 ELSE 0 END FROM @r WHERE WorkDate = '2026-08-07';
SET @act = ISNULL(@act, 'no record');
EXEC dbo.QA_Check 'A5', 'E1 no punches on a working day -> Absent, DayFraction 0, not an anomaly', 'status=Absent fraction=0.00 anomaly=0', @act, @pass;
/* A6 (before the API correction): anomaly listed */
SET @act = NULL; SET @pass = 0;
SELECT @act = CONCAT('status=', [Status], ' anomaly=', Anomaly, ' pairs=', Pairs, ' worked=', Worked, ' lastOut=', ISNULL(CONVERT(VARCHAR(19), LastOut, 120), 'NULL')), @pass = CASE WHEN Anomaly = 1 AND LastOut IS NULL THEN 1 ELSE 0 END FROM @r WHERE WorkDate = '2026-08-10';
SET @act = ISNULL(@act, 'no record');
EXEC dbo.QA_Check 'A6a', 'E1 in punch only on 10 Aug -> HasAnomaly 1', 'anomaly=1 lastOut=NULL', @act, @pass;
DECLARE @anom TABLE (AttendanceId BIGINT, EmployeeId INT, FullName NVARCHAR(300), WorkDate DATE, FirstInUtc DATETIME2, LastOutUtc DATETIME2, PunchPairs INT, [Status] VARCHAR(20), [Source] VARCHAR(10));
INSERT INTO @anom EXEC attendance.usp_Attendance_GetAnomalies '2026-08-10', '2026-08-10';
SELECT @n2 = COUNT(*) FROM @anom WHERE EmployeeId = @E1;
SET @act = CAST(@n2 AS NVARCHAR(10)); SET @pass = CASE WHEN @n2 = 1 THEN 1 ELSE 0 END;
EXEC dbo.QA_Check 'A6a2', 'the anomaly appears in the anomalies list (usp_Attendance_GetAnomalies) for that day', '1 row for E1', @act, @pass;
/* A7 (debounce) */
SET @act = NULL; SET @pass = 0;
SELECT @act = CONCAT('pairs=', Pairs, ' firstIn=', CONVERT(VARCHAR(19), FirstIn, 120), ' worked=', Worked, ' anomaly=', Anomaly), @pass = CASE WHEN Pairs = 1 AND Anomaly = 0 AND FirstIn = '2026-08-11 07:00:00' THEN 1 ELSE 0 END FROM @r WHERE WorkDate = '2026-08-11';
SET @act = ISNULL(@act, 'no record');
EXEC dbo.QA_Check 'A7b', 'two presses within the 1-minute debounce window (07:00 and 07:00:30) count as one In; day has 1 pair, no anomaly', 'pairs=1 firstIn=07:00 anomaly=0', @act, @pass;
/* A9 */
SET @act = NULL; SET @pass = 0;
SELECT @act = CONCAT('late=', Late, ' gross=', Gross, ' worked=', Worked, ' ot=', OT, ' fraction=', Fraction), @pass = CASE WHEN Late = 0 THEN 1 ELSE 0 END FROM @r WHERE WorkDate = '2026-08-12';
SET @act = ISNULL(@act, 'no record');
EXEC dbo.QA_Check 'A9a', 'E1 in 06:40 for a 07:00 shift -> early arrival ignored for lateness', 'late=0', @act, @pass;
SET @pass = 0; SELECT @pass = CASE WHEN Worked = @Std THEN 1 ELSE 0 END FROM @r WHERE WorkDate = '2026-08-12';
EXEC dbo.QA_Note 'A9 rule (script 76): EffectiveIn = max(FirstIn, ShiftStart); WorkedMinutes = (min(LastOut, ShiftEnd) - EffectiveIn) - break - mid-day gap, so the 20 early minutes count neither as work nor as overtime.';
EXEC dbo.QA_Check 'A9b', 'worked minutes start at shift start (early-in not counted as work)', 'worked=510 ot=0', @act, @pass;
/* A11 */
SET @act = NULL; SET @pass = 0;
SELECT @act = CONCAT('exitActual=', ExitActual, ' exitApproved=', ExitApproved, ' exitVar=', ExitVar, ' worked=', Worked, ' fraction=', Fraction), @pass = CASE WHEN ExitVar <= 0 AND ExitVar = ExitActual - ExitApproved AND ExitApproved = 60 THEN 1 ELSE 0 END FROM @r WHERE WorkDate = '2026-08-13';
SET @act = ISNULL(@act, 'no record');
EXEC dbo.QA_Check 'A11', 'exit permission 60 min approved, employee left 55 min early -> no variance to queue (script 76: EarlyExit 55 is the actual, variance = 55 - 60 = -5, never > 0)', 'exitApproved=60 exitVar=-5 (not positive)', @act, @pass;
SET @pass = 0; SELECT @pass = CASE WHEN Worked = 455 THEN 1 ELSE 0 END FROM @r WHERE WorkDate = '2026-08-13';
EXEC dbo.QA_Check 'A11b', 'applying the approved 60 min does not reduce the day twice (worked stays at the punched 455 = 485 gross - 30 break)', 'worked=455', @act, @pass;
SET @pass = 0; SELECT @pass = CASE WHEN Fraction = 1.00 THEN 1 ELSE 0 END FROM @r WHERE WorkDate = '2026-08-13';
EXEC dbo.QA_Check 'A11c', 'the approved permission protects pay: the 55 early minutes are covered, DayFraction 1.00 (it is converted to leave at period close)', 'fraction=1.00', @act, @pass;

/* A8 overnight (E3) */
SET @act = NULL; SET @pass = 0;
SELECT @act = CONCAT('firstIn=', CONVERT(VARCHAR(19), FirstInUtc, 120), ' lastOut=', CONVERT(VARCHAR(19), LastOutUtc, 120), ' gross=', GrossMinutes, ' worked=', WorkedMinutes, ' late=', LateMinutes, ' fraction=', DayFraction, ' ot=', OvertimeMinutes),
       @pass = CASE WHEN LastOutUtc = '2026-08-04 01:10:00' AND GrossMinutes = 545 AND LateMinutes = 0 AND DayFraction = 1.00 THEN 1 ELSE 0 END
FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E3 AND WorkDate = '2026-08-03';
SET @act = ISNULL(@act, 'no record');
EXEC dbo.QA_Check 'A8a', 'E3 Evening: in 16:05, out 01:10 next day -> both on the roster date 3 Aug, gross 545 (worked 515 after the 30-min break), late 0 (5 min inside grace)', 'lastOut=2026-08-04 01:10 gross=545 late=0 fraction=1.00', @act, @pass;
SET @act = NULL; SET @pass = 0;
SELECT @act = CONCAT('firstIn=', CONVERT(VARCHAR(19), FirstInUtc, 120), ' status=', [Status]), @pass = CASE WHEN FirstInUtc = '2026-08-04 16:00:00' THEN 1 ELSE 0 END
FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E3 AND WorkDate = '2026-08-04';
SET @act = ISNULL(@act, 'no record');
EXEC dbo.QA_Check 'A8b', 'nothing of the 3 Aug shift is attributed to 4 Aug (E3''s 4 Aug record starts with the 16:00 In)', 'firstIn=2026-08-04 16:00', @act, @pass;
SET @act = NULL; SET @pass = 0;
SELECT @act = CONCAT('firstIn=', CONVERT(VARCHAR(19), FirstIn, 120)), @pass = CASE WHEN FirstIn = '2026-08-04 07:12:00' THEN 1 ELSE 0 END FROM @r WHERE WorkDate = '2026-08-04';
SET @act = ISNULL(@act, 'no record');
EXEC dbo.QA_Check 'A8c', 'a Morning-shift colleague''s (E1) 07:12 punch on 4 Aug is not stolen by the overnight rule', 'firstIn=2026-08-04 07:12', @act, @pass;
SELECT @n = COUNT(*) FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E3 AND WorkDate = '2026-09-01';
SET @act = CAST(@n AS NVARCHAR(10)); SET @pass = CASE WHEN @n = 0 THEN 1 ELSE 0 END;
EXEC dbo.QA_Check 'A8d', 'E3''s 31 Aug shift ending 01:00 on 1 Sep does not create a 1 Sep record', '0', @act, @pass;

/* R2: rest-day punches */
SET @act = NULL; SET @pass = 0;
SELECT @act = CONCAT('status=', [Status], ' worked=', Worked, ' fraction=', Fraction), @pass = CASE WHEN [Status] = 'RestDay' THEN 1 ELSE 0 END FROM @r WHERE WorkDate = '2026-08-02';
SET @act = ISNULL(@act, 'no record');
SET @pass = CASE WHEN @pass = 1 AND EXISTS (SELECT 1 FROM @r WHERE WorkDate = '2026-08-02' AND Fraction IS NULL) THEN 1 ELSE 0 END;
EXEC dbo.QA_Check 'R2b', 'E1 punches on Sunday 2 Aug (rest day) -> recorded as RestDay, never Absent; DayFraction NULL (nothing to measure, nothing to deduct)', 'status=RestDay fraction=NULL', @act, @pass;
SET @act = NULL; SET @pass = 0;
SELECT @act = CONCAT('status=', [Status], ' worked=', WorkedMinutes, ' fraction=', ISNULL(CAST(DayFraction AS VARCHAR(6)), 'NULL')), @pass = CASE WHEN [Status] = 'RestDay' AND DayFraction IS NULL THEN 1 ELSE 0 END FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E4 AND WorkDate = '2026-08-08';
SET @act = ISNULL(@act, 'no record');
EXEC dbo.QA_Check 'R2c', 'E4 punches on Saturday 8 Aug (rest day) -> RestDay, DayFraction NULL', 'status=RestDay fraction=NULL', @act, @pass;
SELECT @n = COUNT(*) FROM attendance.ATTENDANCE_RECORD a JOIN attendance.SHIFT_ASSIGNMENT sa ON sa.EmployeeId = a.EmployeeId AND sa.WorkDate = a.WorkDate
JOIN hr.EMPLOYEE e ON e.EmployeeId = a.EmployeeId WHERE e.FullName LIKE N'QA %' AND sa.IsRestDay = 1 AND a.[Status] = 'Absent';
SET @act = CAST(@n AS NVARCHAR(10)); SET @pass = CASE WHEN @n = 0 THEN 1 ELSE 0 END;
EXEC dbo.QA_Check 'R2d', 'no QA rest day is recorded as Absent', '0', @act, @pass;
SELECT @n = COUNT(*), @n2 = SUM(CASE WHEN a.DayFraction IS NULL THEN 1 ELSE 0 END) FROM attendance.ATTENDANCE_RECORD a WHERE a.EmployeeId = @E9 AND a.[Status] = 'RestDay';
SET @act = CONCAT('rows=', @n, ' with DayFraction NULL=', @n2);
SET @pass = CASE WHEN @n > 0 AND @n = @n2 THEN 1 ELSE 0 END;
EXEC dbo.QA_Check 'R2e', 'E9''s rest days (no punches) get RestDay rows from usp_Attendance_MarkAbsentees with DayFraction NULL, never 0 (so payroll cannot deduct them)', 'every RestDay row has DayFraction NULL', @act, @pass;

/* A10: leave day with an accidental punch (E5) */
SET @act = NULL; SET @pass = 0;
SELECT @act = CONCAT('status=', [Status], ' worked=', WorkedMinutes, ' fraction=', DayFraction), @pass = CASE WHEN [Status] = 'Leave' THEN 1 ELSE 0 END FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E5 AND WorkDate = '2026-08-18';
SET @act = ISNULL(@act, 'no record');
EXEC dbo.QA_Check 'A10a', 'E5 on approved annual leave 17-19 Aug punches 07:00-09:00 on 18 Aug -> the leave wins (Status Leave, no absence)', 'status=Leave', @act, @pass;
SET @act = (SELECT ISNULL(STRING_AGG(CONCAT(CONVERT(VARCHAR(10), WorkDate, 23), '=', [Status]), ', ') WITHIN GROUP (ORDER BY WorkDate), 'no rows')
            FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E5 AND WorkDate IN ('2026-08-17', '2026-08-19', '2026-08-24'));
SELECT @n = COUNT(*) FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E5 AND WorkDate IN ('2026-08-17', '2026-08-19', '2026-08-24') AND [Status] = 'Leave';
SET @pass = CASE WHEN @n = 3 THEN 1 ELSE 0 END;
EXEC dbo.QA_Check 'A10b', 'E5''s other leave days (17, 19 Aug annual; 24 Aug sick) are marked Leave, not Absent', '2026-08-17=Leave, 2026-08-19=Leave, 2026-08-24=Leave', @act, @pass;
SET @act = (SELECT ISNULL(STRING_AGG(CONCAT(CONVERT(VARCHAR(10), WorkDate, 23), '=', [Status]), ', ') WITHIN GROUP (ORDER BY WorkDate), 'no rows') FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E6 AND WorkDate IN ('2026-08-10', '2026-08-11'));
SELECT @n = COUNT(*) FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E6 AND WorkDate IN ('2026-08-10', '2026-08-11') AND [Status] = 'Leave';
SET @pass = CASE WHEN @n = 2 THEN 1 ELSE 0 END;
EXEC dbo.QA_Check 'L6-att', 'E6''s approved unpaid leave days 10-11 Aug are marked Leave (both days)', '2026-08-10=Leave, 2026-08-11=Leave', @act, @pass;

/* A12: reprocess the whole month twice -> identical, no duplicates */
DECLARE @snap TABLE (Pass INT, EmployeeId INT, WorkDate DATE, Cs INT, Descr NVARCHAR(200));
INSERT INTO @snap SELECT 0, a.EmployeeId, a.WorkDate, CHECKSUM(a.[Status], a.FirstInUtc, a.LastOutUtc, a.WorkedMinutes, a.DayFraction, a.LateMinutes, a.OvertimeMinutes, a.ExitActualMinutes, a.ExitApprovedMinutes, a.ExitVarianceMinutes, a.HasAnomaly, a.IsManual, a.ShiftAssignmentId),
    CONCAT(a.[Status], ' worked=', a.WorkedMinutes, ' exitActual=', a.ExitActualMinutes, ' exitVar=', a.ExitVarianceMinutes)
FROM attendance.ATTENDANCE_RECORD a JOIN hr.EMPLOYEE e ON e.EmployeeId = a.EmployeeId WHERE e.FullName LIKE N'QA %';
SET @day = '2026-08-01';
WHILE @day <= '2026-09-01' BEGIN EXEC attendance.usp_Attendance_ReprocessDay @WorkDate = @day; SET @day = DATEADD(DAY, 1, @day); END
INSERT INTO @snap SELECT 1, a.EmployeeId, a.WorkDate, CHECKSUM(a.[Status], a.FirstInUtc, a.LastOutUtc, a.WorkedMinutes, a.DayFraction, a.LateMinutes, a.OvertimeMinutes, a.ExitActualMinutes, a.ExitApprovedMinutes, a.ExitVarianceMinutes, a.HasAnomaly, a.IsManual, a.ShiftAssignmentId),
    CONCAT(a.[Status], ' worked=', a.WorkedMinutes, ' exitActual=', a.ExitActualMinutes, ' exitVar=', a.ExitVarianceMinutes)
FROM attendance.ATTENDANCE_RECORD a JOIN hr.EMPLOYEE e ON e.EmployeeId = a.EmployeeId WHERE e.FullName LIKE N'QA %';
SET @day = '2026-08-01';
WHILE @day <= '2026-09-01' BEGIN EXEC attendance.usp_Attendance_ReprocessDay @WorkDate = @day; SET @day = DATEADD(DAY, 1, @day); END
INSERT INTO @snap SELECT 2, a.EmployeeId, a.WorkDate, CHECKSUM(a.[Status], a.FirstInUtc, a.LastOutUtc, a.WorkedMinutes, a.DayFraction, a.LateMinutes, a.OvertimeMinutes, a.ExitActualMinutes, a.ExitApprovedMinutes, a.ExitVarianceMinutes, a.HasAnomaly, a.IsManual, a.ShiftAssignmentId),
    CONCAT(a.[Status], ' worked=', a.WorkedMinutes, ' exitActual=', a.ExitActualMinutes, ' exitVar=', a.ExitVarianceMinutes)
FROM attendance.ATTENDANCE_RECORD a JOIN hr.EMPLOYEE e ON e.EmployeeId = a.EmployeeId WHERE e.FullName LIKE N'QA %';
DECLARE @c0 INT = (SELECT COUNT(*) FROM @snap WHERE Pass = 0), @c1 INT = (SELECT COUNT(*) FROM @snap WHERE Pass = 1), @c2 INT = (SELECT COUNT(*) FROM @snap WHERE Pass = 2);
DECLARE @diff01 NVARCHAR(600) = (SELECT STRING_AGG(CONCAT(e.FullName, ' ', CONVERT(VARCHAR(10), s0.WorkDate, 23), ': ', s0.Descr, ' -> ', s1.Descr), '; ') WITHIN GROUP (ORDER BY s0.WorkDate)
    FROM @snap s0 JOIN @snap s1 ON s1.Pass = 1 AND s1.EmployeeId = s0.EmployeeId AND s1.WorkDate = s0.WorkDate JOIN hr.EMPLOYEE e ON e.EmployeeId = s0.EmployeeId WHERE s0.Pass = 0 AND s0.Cs <> s1.Cs);
DECLARE @diff12 INT = (SELECT COUNT(*) FROM @snap s1 JOIN @snap s2 ON s2.Pass = 2 AND s2.EmployeeId = s1.EmployeeId AND s2.WorkDate = s1.WorkDate WHERE s1.Pass = 1 AND s1.Cs <> s2.Cs);
DECLARE @dupes INT = (SELECT COUNT(*) FROM (SELECT EmployeeId, WorkDate FROM attendance.ATTENDANCE_RECORD GROUP BY EmployeeId, WorkDate HAVING COUNT(*) > 1) x);
SET @act = CONCAT('records ', @c0, '/', @c1, '/', @c2, ', duplicates=', @dupes, ', records changed by the 1st reprocess: ', ISNULL(@diff01, 'none'), '; changed by the 2nd: ', @diff12);
SET @pass = CASE WHEN @c0 = @c1 AND @c1 = @c2 AND @diff01 IS NULL AND @diff12 = 0 AND @dupes = 0 THEN 1 ELSE 0 END;
EXEC dbo.QA_Check 'A12', 'reprocessing every day of the month twice gives identical records and no duplicates', 'same count, no record changed, duplicates=0', @act, @pass;
SET @act = (SELECT ISNULL(STRING_AGG(CONCAT(CONVERT(VARCHAR(10), WorkDate, 23), '=', [Status]), ', ') WITHIN GROUP (ORDER BY WorkDate), 'no rows') FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E5 AND WorkDate IN ('2026-08-17', '2026-08-18', '2026-08-19'));
SET @t = CONCAT('A12 side check: E5 leave-day statuses after two full reprocesses (the day rule reads the approved LEAVE_REQUEST itself, so a reprocess keeps them Leave): ', @act);
EXEC dbo.QA_Note @t;
/* ReprocessDay flips and re-derives the punches by ATTRIBUTED date (script 76): overnight out-punches must not be left behind */
SELECT @n = COUNT(*) FROM attendance.RAW_DEVICE_LOG r JOIN hr.EMPLOYEE e ON e.EmployeeId = r.EmployeeId WHERE e.FullName LIKE N'QA %' AND r.IsProcessed = 0;
SET @act = (SELECT CONCAT(@n, ' unprocessed QA punch(es)', CASE WHEN @n > 0 THEN CONCAT(' e.g. ', (SELECT TOP 1 CONCAT(e.FullName, ' ', CONVERT(VARCHAR(16), r.PunchTimeUtc, 120)) FROM attendance.RAW_DEVICE_LOG r JOIN hr.EMPLOYEE e ON e.EmployeeId = r.EmployeeId WHERE e.FullName LIKE N'QA %' AND r.IsProcessed = 0 ORDER BY r.PunchTimeUtc)) ELSE '' END));
SET @pass = CASE WHEN @n = 0 THEN 1 ELSE 0 END;
EXEC dbo.QA_Check 'A12b', 'after reprocessing every day, no QA punch is left flagged unprocessed (usp_Attendance_ReprocessDay must not strand overnight out-punches, or payroll readiness blocks)', '0 unprocessed', @act, @pass;
IF @n > 0
BEGIN
    DELETE FROM @proc; INSERT INTO @proc EXEC attendance.usp_Attendance_ProcessRawLogs @WorkDate = NULL;
    SELECT @t = CONCAT('A12b: cleared the stranded punches with usp_Attendance_ProcessRawLogs(NULL) as the nightly job would; employee-days re-derived = ', EmployeeDaysProcessed) FROM @proc;
    EXEC dbo.QA_Note @t;
END
GO
