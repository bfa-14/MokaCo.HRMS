/* ============================================================================
   cases/01_attendance.sql — A1: same-day combinations, on QA2 E1 (QA2 Morning 07:00-15:00, break 30,
   standard 450 min, grace NULL = tolerance 10), E2 (evening, holiday work) and E4 (part-timer).
   Every case states EXPECTED from the rules, then ACTUAL. Dates come from dbo.QA2_DAY.

   Order: 1. the requests (exit permissions, overtime, leave, holiday) are raised and approved
          2. the punches are written and the days derived (dbo.QA2_Process: QA2 days only)
          3. the checks
          4. the cases that CHANGE something afterwards (decide, reprocess, tolerance, correction, late punch)
          5. bulk Excuse — last, because it decides every undecided anomaly of the branch
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
GO

/* ---------------------------------------------------------------- 1. requests ---- */
DECLARE @E1 INT = dbo.QA2_Emp(N'E1'), @Hr INT = dbo.QA2_User(N'hr'), @rid INT, @d DATE;
/* A1a: a "late permission" — exit permission 07:00-07:30 at the start of the shift */
SET @d = dbo.QA2_Date('A1a');
EXEC workflow.usp_ExitPermission_Create @EmployeeId = @E1, @RaisedByUserId = @Hr, @ExitDate = @d, @FromTime = '07:00', @ToTime = '07:30', @Reason = N'QA2 A1a late permission';
SET @rid = dbo.QA2_LastRequest(@E1); EXEC dbo.QA2_Approve @rid, 'Exit', @Minutes = 30;
/* A1b: exit permission 14:30-15:00 (30 min) — the employee will leave 40 min early */
SET @d = dbo.QA2_Date('A1b');
EXEC workflow.usp_ExitPermission_Create @EmployeeId = @E1, @RaisedByUserId = @Hr, @ExitDate = @d, @FromTime = '14:30', @ToTime = '15:00', @Reason = N'QA2 A1b';
SET @rid = dbo.QA2_LastRequest(@E1); EXEC dbo.QA2_Approve @rid, 'Exit', @Minutes = 30;
/* A1c: two exit permissions the same day, 14:00-14:30 and 14:30-15:00 — the employee will leave 50 min early */
SET @d = dbo.QA2_Date('A1c');
BEGIN TRY
    EXEC workflow.usp_ExitPermission_Create @EmployeeId = @E1, @RaisedByUserId = @Hr, @ExitDate = @d, @FromTime = '14:00', @ToTime = '14:30', @Reason = N'QA2 A1c first';
    SET @rid = dbo.QA2_LastRequest(@E1); EXEC dbo.QA2_Approve @rid, 'Exit', @Minutes = 30;
    EXEC workflow.usp_ExitPermission_Create @EmployeeId = @E1, @RaisedByUserId = @Hr, @ExitDate = @d, @FromTime = '14:30', @ToTime = '15:00', @Reason = N'QA2 A1c second';
    SET @rid = dbo.QA2_LastRequest(@E1); EXEC dbo.QA2_Approve @rid, 'Exit', @Minutes = 30;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRAN;
    DECLARE @m1 NVARCHAR(600) = CONCAT('A1c: the second exit permission of the day could not be raised: ', ERROR_MESSAGE()); EXEC dbo.QA2_Note @m1;
END CATCH;
/* A1d: exit permission 11:00-12:00 (60 min) overlapping the 30-minute break */
SET @d = dbo.QA2_Date('A1d');
EXEC workflow.usp_ExitPermission_Create @EmployeeId = @E1, @RaisedByUserId = @Hr, @ExitDate = @d, @FromTime = '11:00', @ToTime = '12:00', @Reason = N'QA2 A1d over the break';
SET @rid = dbo.QA2_LastRequest(@E1); EXEC dbo.QA2_Approve @rid, 'Exit', @Minutes = 60;
/* A1e: approved overtime 60 min */
SET @d = dbo.QA2_Date('A1e');
EXEC dbo.QA2_ApprovedOvertime @E1, @d, 60;
/* A1f: approved full-day annual leave */
SET @d = dbo.QA2_Date('A1f');
EXEC workflow.usp_LeaveRequest_Create @EmployeeId = @E1, @RaisedByUserId = @Hr, @LeaveTypeId = 1, @FromDate = @d, @ToDate = @d, @Reason = N'QA2 A1f';
SET @rid = dbo.QA2_LastRequest(@E1); EXEC dbo.QA2_Approve @rid, 'Leave';
/* A1g1: called in on a rest day WITH approved overtime (240 min); A1g2 has none */
SET @d = dbo.QA2_Date('A1g1');
EXEC dbo.QA2_ApprovedOvertime @E1, @d, 240;
/* A1h: a public holiday of QA2 Branch 1 on E1's 13th working day, through the real procedure (D1). A holiday of EVERY
   branch would be refused here, rightly: the real employees are already paid for M. */
SET @d = dbo.QA2_Date('A1h');
IF OBJECT_ID('core.usp_Holiday_Upsert') IS NOT NULL
BEGIN
    DECLARE @B1 INT = (SELECT BranchId FROM hr.BRANCH WHERE Name = N'QA2 Branch 1');
    BEGIN TRY
        EXEC core.usp_Holiday_Upsert @HolidayId = NULL, @HolidayDate = @d, @Name = N'QA2 Holiday', @NameAr = N'عطلة QA2', @IsPaid = 1, @BranchId = @B1, @ActedByUserId = @Hr;
    END TRY BEGIN CATCH IF @@TRANCOUNT > 0 ROLLBACK TRAN; DECLARE @m2 NVARCHAR(600) = CONCAT('A1h: the holiday could not be recorded: ', ERROR_MESSAGE()); EXEC dbo.QA2_Note @m2; END CATCH;
END
DECLARE @st NVARCHAR(400) = (SELECT STRING_AGG(CONCAT(ri.RequestInstanceId, ':', ri.[Status]), ', ') FROM workflow.REQUEST_INSTANCE ri WHERE ri.EmployeeId = @E1);
SET @st = CONCAT('A1 requests raised for E1 (id:status): ', @st); EXEC dbo.QA2_Note @st;
GO

/* ---------------------------------------------------------------- 2. punches ---- */
DECLARE @E1 INT = dbo.QA2_Emp(N'E1'), @E4 INT = dbo.QA2_Emp(N'E4'), @t DATETIME2(0), @t2 DATETIME2(0);
SET @t = dbo.QA2_At('A1a', '07:25', 0); EXEC dbo.QA2_Punch @E1, @t, 0;   SET @t = dbo.QA2_At('A1a', '15:00', 0); EXEC dbo.QA2_Punch @E1, @t, 1;
SET @t = dbo.QA2_At('A1b', '07:00', 0); EXEC dbo.QA2_Punch @E1, @t, 0;   SET @t = dbo.QA2_At('A1b', '14:20', 0); EXEC dbo.QA2_Punch @E1, @t, 1;
SET @t = dbo.QA2_At('A1c', '07:00', 0); EXEC dbo.QA2_Punch @E1, @t, 0;   SET @t = dbo.QA2_At('A1c', '14:10', 0); EXEC dbo.QA2_Punch @E1, @t, 1;
SET @t = dbo.QA2_At('A1d', '07:00', 0); EXEC dbo.QA2_Punch @E1, @t, 0;   SET @t = dbo.QA2_At('A1d', '11:00', 0); EXEC dbo.QA2_Punch @E1, @t, 1;
SET @t = dbo.QA2_At('A1d', '12:00', 0); EXEC dbo.QA2_Punch @E1, @t, 0;   SET @t = dbo.QA2_At('A1d', '15:00', 0); EXEC dbo.QA2_Punch @E1, @t, 1;
SET @t = dbo.QA2_At('A1e', '07:12', 0); EXEC dbo.QA2_Punch @E1, @t, 0;   SET @t = dbo.QA2_At('A1e', '16:00', 0); EXEC dbo.QA2_Punch @E1, @t, 1;
SET @t = dbo.QA2_At('A1f', '07:00', 0); EXEC dbo.QA2_Punch @E1, @t, 0;   SET @t = dbo.QA2_At('A1f', '15:00', 0); EXEC dbo.QA2_Punch @E1, @t, 1;
SET @t = dbo.QA2_At('A1g1', '08:00', 0); EXEC dbo.QA2_Punch @E1, @t, 0;  SET @t = dbo.QA2_At('A1g1', '12:00', 0); EXEC dbo.QA2_Punch @E1, @t, 1;
SET @t = dbo.QA2_At('A1g2', '08:00', 0); EXEC dbo.QA2_Punch @E1, @t, 0;  SET @t = dbo.QA2_At('A1g2', '12:00', 0); EXEC dbo.QA2_Punch @E1, @t, 1;
/* A1h: E1 has NO punch on the holiday; E2 (evening) works it — the seed already wrote E2's standard pair */
SET @t = dbo.QA2_At('A1i', '08:00', 0); EXEC dbo.QA2_Punch @E4, @t, 0;   SET @t = dbo.QA2_At('A1i', '12:00', 0); EXEC dbo.QA2_Punch @E4, @t, 1;
SET @t = dbo.QA2_At('A1j1', '07:20', 0); EXEC dbo.QA2_Punch @E1, @t, 0;  SET @t = dbo.QA2_At('A1j1', '15:00', 0); EXEC dbo.QA2_Punch @E1, @t, 1;
SET @t = dbo.QA2_At('A1j2', '07:12', 0); EXEC dbo.QA2_Punch @E1, @t, 0;  SET @t = dbo.QA2_At('A1j2', '15:00', 0); EXEC dbo.QA2_Punch @E1, @t, 1;
SET @t = dbo.QA2_At('A1k', '07:00', 0); EXEC dbo.QA2_Punch @E1, @t, 0;   SET @t = dbo.QA2_At('A1k', '14:00', 0); EXEC dbo.QA2_Punch @E1, @t, 1;
/* A1m: a storm of 6 presses inside 90 s, then the evening punch */
DECLARE @i INT = 0;
WHILE @i < 6 BEGIN SET @t = DATEADD(SECOND, 18 * @i, dbo.QA2_At('A1m', '07:00', 0)); EXEC dbo.QA2_Punch @E1, @t, 0; SET @i += 1; END
SET @t = dbo.QA2_At('A1m', '15:00', 0); EXEC dbo.QA2_Punch @E1, @t, 1;
/* A1n: only the morning punch has arrived so far */
SET @t = dbo.QA2_At('A1n', '07:00', 0); EXEC dbo.QA2_Punch @E1, @t, 0;
EXEC dbo.QA2_Process;
/* the holiday without a punch and the absent-by-rule days have no punch to trigger them: derive them directly */
DECLARE @h DATE = dbo.QA2_Date('A1h');
EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @E1, @WorkDate = @h;
GO

/* ---------------------------------------------------------------- 3. checks ---- */
DECLARE @E1 INT = dbo.QA2_Emp(N'E1'), @E2 INT = dbo.QA2_Emp(N'E2'), @E4 INT = dbo.QA2_Emp(N'E4');
DECLARE @exp NVARCHAR(700), @act NVARCHAR(700), @ok BIT, @d DATE, @n INT;
DECLARE @Basis VARCHAR(20) = ISNULL((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'ExitLeaveBasis'), 'Actual');

/* a one-line picture of a day: the record and its anomaly rows */
DECLARE @day TABLE (CaseId NVARCHAR(20), [Status] VARCHAR(20), Worked INT, Fraction DECIMAL(5,2), Late INT, Early INT, LateDed INT, EarlyDed INT,
                    Covered INT, Overtime INT, ExitActual INT, ExitApproved INT, ExitVariance INT, ExitLeave INT, Pairs INT, HasAnomaly BIT,
                    FirstIn DATETIME2(0), LastOut DATETIME2(0), Anoms NVARCHAR(300));
INSERT INTO @day
SELECT q.CaseId, a.[Status], a.WorkedMinutes, a.DayFraction, a.LateMinutes, a.EarlyExitMinutes, a.LateDeductMinutes, a.EarlyDeductMinutes,
       a.CoveredMinutes, a.OvertimeMinutes, a.ExitActualMinutes, a.ExitApprovedMinutes, a.ExitVarianceMinutes, a.ExitLeaveMinutes, a.PunchPairs, a.HasAnomaly,
       a.FirstInUtc, a.LastOutUtc,
       ISNULL((SELECT STRING_AGG(CONCAT(an.[Type], ' ', an.[Minutes], ' ', ISNULL(an.Decision, 'undecided')), '; ') WITHIN GROUP (ORDER BY an.[Type])
               FROM attendance.ATTENDANCE_ANOMALY an WHERE an.AttendanceId = a.AttendanceId), 'none')
FROM dbo.QA2_DAY q
LEFT JOIN attendance.ATTENDANCE_RECORD a ON a.EmployeeId = q.EmployeeId AND a.WorkDate = q.WorkDate
WHERE q.CaseId LIKE 'A1%';

/* A1a */
SELECT @act = CONCAT('status=', [Status], ' fraction=', Fraction, ' lateDeduct=', LateDed, ' exitLeave=', ExitLeave, ' anomalies=', Anoms),
       @ok = CASE WHEN [Status] = 'Present' AND Fraction = 1.00 AND LateDed = 0 AND Anoms = 'none'
                   AND ExitLeave = CASE WHEN @Basis = 'Approved' THEN 30 ELSE 25 END THEN 1 ELSE 0 END FROM @day WHERE CaseId = 'A1a';
SET @exp = CONCAT('Present, full day (fraction 1.00), NO anomaly, nothing deducted; the permission minutes go to the period-close leave conversion (ExitLeaveMinutes = ', CASE WHEN @Basis = 'Approved' THEN '30 approved' ELSE '25 actually used' END, ', basis ', @Basis, ')');
EXEC dbo.QA2_Check 'A1a', 'late 25 min + approved exit permission of 30 min at shift start ("late permission")', @exp, @act, @ok;

/* A1b */
SELECT @act = CONCAT('status=', [Status], ' early=', Early, ' covered=', Covered, ' fraction=', Fraction, ' anomalies=', Anoms),
       @ok = CASE WHEN Early = 10 AND Anoms = 'EarlyDeparture 10 undecided' AND Fraction = 1.00 THEN 1 ELSE 0 END FROM @day WHERE CaseId = 'A1b';
EXEC dbo.QA2_Check 'A1b', 'early departure 40 min with an approved exit permission of 30 min (14:30-15:00)',
     'an EarlyDeparture anomaly for the 10 uncovered minutes only (undecided); the 30 permitted minutes are covered; full day until HR decides', @act, @ok;

/* A1c */
SELECT @n = COUNT(*) FROM workflow.EXIT_PERMISSION ep JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = ep.RequestInstanceId
WHERE ep.EmployeeId = @E1 AND ep.ExitDate = dbo.QA2_Date('A1c') AND ri.[Status] = 'Approved';
SELECT @act = CONCAT(@n, ' approved permission(s); status=', [Status], ' early=', Early, ' exitApproved=', ExitApproved, ' fraction=', Fraction, ' anomalies=', Anoms),
       @ok = CASE WHEN @n = 2 AND Early = 0 AND Fraction = 1.00 AND Anoms IN ('none', 'EarlyDeparture 0 Excused') THEN 1 ELSE 0 END FROM @day WHERE CaseId = 'A1c';
EXEC dbo.QA2_Check 'A1c', 'two exit permissions the same day (30 + 30) and a 50-minute early departure',
     '2 approved permissions, 60 minutes approved; the 50 minutes are all covered: no anomaly left for HR, full day', @act, @ok;

/* A1d */
SELECT @act = CONCAT('worked=', Worked, ' exitActual=', ExitActual, ' exitApproved=', ExitApproved, ' variance=', ExitVariance, ' fraction=', Fraction, ' anomalies=', Anoms),
       @ok = CASE WHEN Worked = 420 AND ExitActual = 30 AND Fraction = 1.00 AND ISNULL(ExitVariance, 0) <= 0 AND Anoms = 'none' THEN 1 ELSE 0 END FROM @day WHERE CaseId = 'A1d';
EXEC dbo.QA2_Check 'A1d', 'exit permission 11:00-12:00 overlapping the 30-minute break (punches 07:00-11:00, 12:00-15:00)',
     'the break is not double-counted: gap 60 - break 30 = 30 exit minutes, worked 420 (480 - 30 break - 30 exit), covered by the permission -> full day, no variance, no anomaly', @act, @ok;

/* A1e */
SELECT @n = ISNULL(SUM(o.ApprovedMinutes), 0) FROM workflow.OVERTIME_REQUEST o JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = o.RequestInstanceId
WHERE o.EmployeeId = @E1 AND o.WorkDate = dbo.QA2_Date('A1e') AND ri.[Status] = 'Approved';
SELECT @act = CONCAT('approved request=', @n, ' min; overtime=', Overtime, ' late=', Late, ' anomalies=', Anoms),
       @ok = CASE WHEN @n = 60 AND Overtime = 60 AND Late = 12 AND Anoms = 'LateArrival 12 undecided' THEN 1 ELSE 0 END FROM @day WHERE CaseId = 'A1e';
EXEC dbo.QA2_Check 'A1e', 'approved overtime 60 min + late arrival 12 min (in 07:12, out 16:00)',
     'overtime 60 = min(approved 60, detected 60); a LateArrival anomaly of 12 min, independent of the overtime', @act, @ok;

/* A1f */
SELECT @act = CONCAT('status=', [Status], ' fraction=', ISNULL(CAST(Fraction AS VARCHAR(10)), 'NULL'), ' lateDeduct=', LateDed, ' earlyDeduct=', EarlyDed, ' anomalies=', Anoms),
       @ok = CASE WHEN [Status] = 'Leave' AND Fraction IS NULL AND Anoms = 'none' THEN 1 ELSE 0 END FROM @day WHERE CaseId = 'A1f';
EXEC dbo.QA2_Check 'A1f', 'full-day approved leave + a punch pair the same day', 'Leave; no anomaly; no pay change (fraction NULL: the day is not measured)', @act, @ok;

/* A1g */
SELECT @act = CONCAT('with OT: status=', g1.[Status], ' worked=', g1.Worked, ' overtime=', g1.Overtime, ' anomalies=', g1.Anoms,
                     ' | without OT: status=', g2.[Status], ' worked=', g2.Worked, ' overtime=', g2.Overtime, ' anomalies=', g2.Anoms),
       @ok = CASE WHEN g1.[Status] = 'RestDay' AND g1.Worked = 240 AND g1.Overtime = 240 AND g1.Anoms = 'none'
                   AND g2.[Status] = 'RestDay' AND g2.Worked = 240 AND g2.Overtime = 0 AND g2.Anoms = 'none' THEN 1 ELSE 0 END
FROM @day g1 CROSS JOIN @day g2 WHERE g1.CaseId = 'A1g1' AND g2.CaseId = 'A1g2';
EXEC dbo.QA2_Check 'A1g', 'rest day + punches 08:00-12:00 (called in), once with an approved overtime request of 240 min and once without',
     'both RestDay with the 240 worked minutes visible, never Absent, no anomaly; overtime 240 only on the day with the approved request, 0 on the other', @act, @ok;

/* A1h */
SET @d = dbo.QA2_Date('A1h');
SELECT @act = CONCAT('holiday table=', CASE WHEN OBJECT_ID('core.HOLIDAY') IS NULL THEN 'missing' ELSE 'present' END,
                     ' | E1 (no punch): status=', ISNULL(h.[Status], 'no record'), ' fraction=', ISNULL(CAST(h.Fraction AS VARCHAR(10)), 'NULL'), ' anomalies=', h.Anoms,
                     ' | E2 (worked): status=', ISNULL(a2.[Status], 'no record'), ' worked=', a2.WorkedMinutes),
       @ok = CASE WHEN h.[Status] = 'Holiday' AND h.Fraction IS NULL AND h.Anoms = 'none' AND a2.[Status] = 'Holiday' AND a2.WorkedMinutes = 450 THEN 1 ELSE 0 END
FROM @day h LEFT JOIN attendance.ATTENDANCE_RECORD a2 ON a2.EmployeeId = @E2 AND a2.WorkDate = @d WHERE h.CaseId = 'A1h';
EXEC dbo.QA2_Check 'A1h', 'public holiday: E1 does not punch, E2 works the evening shift',
     'E1 Holiday (paid, not Absent, no anomaly); E2 Holiday with the 450 worked minutes kept for the holiday-work premium', @act, @ok;

/* A1i */
SET @d = dbo.QA2_Date('A1i');
DECLARE @listed INT = NULL;
IF OBJECT_ID('attendance.usp_Attendance_GetWorkedWithoutRoster') IS NOT NULL
BEGIN
    DECLARE @wr TABLE (EmployeeId INT, EmployeeName NVARCHAR(150), BranchId INT, BranchName NVARCHAR(100), WorkDate DATE, FirstPunch DATETIME2, LastPunch DATETIME2, PunchCount INT, WorkedMinutes INT);
    INSERT INTO @wr EXEC attendance.usp_Attendance_GetWorkedWithoutRoster @FromDate = @d, @ToDate = @d;
    SET @listed = (SELECT COUNT(*) FROM @wr WHERE EmployeeId = @E4 AND WorkDate = @d AND WorkedMinutes = 240);
END
SELECT @n = COUNT(*) FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E4 AND WorkDate = @d;
SET @act = CONCAT('attendance records for the day=', @n, '; listed in "worked without roster"=', ISNULL(CAST(@listed AS VARCHAR(10)), 'procedure missing'));
SET @ok = CASE WHEN @n = 0 AND @listed = 1 THEN 1 ELSE 0 END;
EXEC dbo.QA2_Check 'A1i', 'unrostered day (no roster row at all) + punches 08:00-12:00 (E4, a Saturday)',
     'no attendance record and therefore no deduction; the day is listed for HR in "worked without roster" with its 240 minutes', @act, @ok;

/* A1m */
SELECT @act = CONCAT('pairs=', Pairs, ' firstIn=', CONVERT(VARCHAR(8), FirstIn, 108), ' lastOut=', CONVERT(VARCHAR(8), LastOut, 108), ' worked=', Worked, ' fraction=', Fraction, ' anomalies=', Anoms,
                     ' (mode ', (SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'PunchDirectionMode'), ', debounce ', (SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'PunchDebounceMinutes'), ' min)'),
       @ok = CASE WHEN Pairs = 1 AND CONVERT(VARCHAR(8), FirstIn, 108) = '07:00:00' AND CONVERT(VARCHAR(8), LastOut, 108) = '15:00:00' AND Fraction = 1.00 AND Anoms = 'none' THEN 1 ELSE 0 END
FROM @day WHERE CaseId = 'A1m';
EXEC dbo.QA2_Check 'A1m', 'duplicate storm: 6 presses within 90 s at 07:00, then out at 15:00',
     'one punch kept (debounce): 1 pair 07:00:00-15:00:00, full day, no anomaly; the In/Out alternation is not thrown off', @act, @ok;
GO

/* ---------------------------------------------------------------- 4. cases that change something ---- */
DECLARE @E1 INT = dbo.QA2_Emp(N'E1'), @E4 INT = dbo.QA2_Emp(N'E4'), @Hr INT = dbo.QA2_User(N'hr');
DECLARE @exp NVARCHAR(700), @act NVARCHAR(700), @ok BIT, @d DATE, @d2 DATE, @n INT, @an BIGINT, @att BIGINT, @t DATETIME2(0);
DECLARE @Morning INT = (SELECT ShiftId FROM attendance.SHIFT WHERE Name = N'QA2 Morning');

/* A1j: Deduct, reprocess, tolerance 10 -> 15, reprocess */
SET @d = dbo.QA2_Date('A1j1'); SET @d2 = dbo.QA2_Date('A1j2');
SET @an = (SELECT AnomalyId FROM attendance.ATTENDANCE_ANOMALY WHERE EmployeeId = @E1 AND WorkDate = @d AND [Type] = 'LateArrival');
DECLARE @before NVARCHAR(200) = (SELECT STRING_AGG(CONCAT(CONVERT(CHAR(10), WorkDate, 23), ' ', [Type], ' ', [Minutes], ' ', ISNULL(Decision, 'undecided')), '; ') WITHIN GROUP (ORDER BY WorkDate)
                                 FROM attendance.ATTENDANCE_ANOMALY WHERE EmployeeId = @E1 AND WorkDate IN (@d, @d2));
BEGIN TRY
    EXEC attendance.usp_Anomaly_Decide @AnomalyId = @an, @Decision = 'Deduct', @Note = N'QA2 A1j', @DecidedByUserId = @Hr;
END TRY BEGIN CATCH IF @@TRANCOUNT > 0 ROLLBACK TRAN; SET @act = ERROR_MESSAGE(); END CATCH;
EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @E1, @WorkDate = @d;
SELECT @act = CONCAT('before: ', @before, ' | after Deduct + reprocess: ', an.[Type], ' ', an.[Minutes], ' ', ISNULL(an.Decision, 'undecided'), ', lateDeduct=', a.LateDeductMinutes, ', fraction=', a.DayFraction),
       @ok = CASE WHEN an.Decision = 'Deducted' AND an.[Minutes] = 20 AND a.LateDeductMinutes = 20 AND a.DayFraction < 1 THEN 1 ELSE 0 END
FROM attendance.ATTENDANCE_RECORD a LEFT JOIN attendance.ATTENDANCE_ANOMALY an ON an.AttendanceId = a.AttendanceId AND an.[Type] = 'LateArrival'
WHERE a.EmployeeId = @E1 AND a.WorkDate = @d;
EXEC dbo.QA2_Check 'A1j1', 'a 20-minute late arrival decided Deduct, then the day reprocessed', 'the decision is kept: Deducted, 20 minutes deducted, fraction below 1', @act, @ok;

UPDATE attendance.SHIFT SET GraceMinutes = 15 WHERE ShiftId = @Morning;      -- the tolerance of THIS shift 10 -> 15 (the global setting is a real row and is not touched)
EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @E1, @WorkDate = @d;
EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @E1, @WorkDate = @d2;
SELECT @act = CONCAT('decided day: ', ISNULL((SELECT CONCAT([Type], ' ', [Minutes], ' ', Decision) FROM attendance.ATTENDANCE_ANOMALY WHERE EmployeeId = @E1 AND WorkDate = @d AND [Type] = 'LateArrival'), 'row gone'),
                     ' (lateDeduct=', (SELECT LateDeductMinutes FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E1 AND WorkDate = @d), ')',
                     ' | undecided 12-minute day: ', ISNULL((SELECT CONCAT([Type], ' ', [Minutes], ' ', ISNULL(Decision, 'undecided')) FROM attendance.ATTENDANCE_ANOMALY WHERE EmployeeId = @E1 AND WorkDate = @d2 AND [Type] = 'LateArrival'), 'no anomaly'));
SET @ok = CASE WHEN EXISTS (SELECT 1 FROM attendance.ATTENDANCE_ANOMALY WHERE EmployeeId = @E1 AND WorkDate = @d AND [Type] = 'LateArrival' AND Decision = 'Deducted' AND [Minutes] = 20)
                AND (SELECT LateDeductMinutes FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E1 AND WorkDate = @d) = 20
                AND NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_ANOMALY WHERE EmployeeId = @E1 AND WorkDate = @d2 AND [Type] = 'LateArrival') THEN 1 ELSE 0 END;
EXEC dbo.QA2_Check 'A1j2', 'tolerance changed 10 -> 15 (the shift''s own grace) and both days reprocessed', 'the decided row is unchanged (Deducted, 20 min, still deducted); the undecided 12-minute row is re-evaluated and disappears (12 < 15)', @act, @ok;
UPDATE attendance.SHIFT SET GraceMinutes = NULL WHERE ShiftId = @Morning;
EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @E1, @WorkDate = @d2;   -- back to tolerance 10: the 12-minute anomaly is back, undecided

/* A1k: Deduct, then HR corrects the out-punch */
SET @d = dbo.QA2_Date('A1k');
SELECT @att = AttendanceId FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E1 AND WorkDate = @d;
SET @an = (SELECT AnomalyId FROM attendance.ATTENDANCE_ANOMALY WHERE AttendanceId = @att AND [Type] = 'EarlyDeparture');
SET @act = NULL;
BEGIN TRY
    EXEC attendance.usp_Anomaly_Decide @AnomalyId = @an, @Decision = 'Deduct', @Note = N'QA2 A1k', @DecidedByUserId = @Hr;
    SET @t = dbo.QA2_At('A1k', '14:30', 0);
    EXEC attendance.usp_Correction_Create @AttendanceId = @att, @RequestedBy = @Hr, @NewLastOutUtc = @t, @Reason = N'QA2 A1k: the terminal was 30 minutes off';
    DECLARE @cid INT = (SELECT MAX(CorrectionId) FROM attendance.ATTENDANCE_CORRECTION WHERE AttendanceId = @att);
    EXEC attendance.usp_Correction_Approve @CorrectionId = @cid, @ApprovedBy = @Hr;
END TRY BEGIN CATCH IF @@TRANCOUNT > 0 ROLLBACK TRAN; SET @act = CONCAT('error: ', ERROR_MESSAGE(), ' | '); END CATCH;
SELECT @act = CONCAT(@act, 'lastOut=', CONVERT(VARCHAR(5), a.LastOutUtc, 108), ' early=', a.EarlyExitMinutes, ' earlyDeduct=', a.EarlyDeductMinutes,
                     ' anomaly=', ISNULL((SELECT CONCAT(an.[Minutes], ' ', ISNULL(an.Decision, 'undecided'), ' note="', ISNULL(an.Note, ''), '"') FROM attendance.ATTENDANCE_ANOMALY an WHERE an.AttendanceId = a.AttendanceId AND an.[Type] = 'EarlyDeparture'), 'none')),
       @ok = CASE WHEN CONVERT(VARCHAR(5), a.LastOutUtc, 108) = '14:30' AND a.EarlyExitMinutes = 30 AND a.EarlyDeductMinutes = 0
                   AND EXISTS (SELECT 1 FROM attendance.ATTENDANCE_ANOMALY an WHERE an.AttendanceId = a.AttendanceId AND an.[Type] = 'EarlyDeparture' AND an.[Minutes] = 30 AND an.Decision IS NULL AND ISNULL(an.Note, N'') <> N'') THEN 1 ELSE 0 END
FROM attendance.ATTENDANCE_RECORD a WHERE a.AttendanceId = @att;
EXEC dbo.QA2_Check 'A1k', 'a 60-minute early departure decided Deduct, then HR corrects the out-punch 14:00 -> 14:30',
     'the day is recomputed (out 14:30, early 30); the decision is CLEARED with a note saying the fact changed, nothing is deducted any more, and HR sees the 30-minute anomaly again as undecided', @act, @ok;

/* A1n: the evening punch arrives after the day was processed */
SET @d = dbo.QA2_Date('A1n');
DECLARE @first NVARCHAR(200) = (SELECT CONCAT('hasAnomaly=', a.HasAnomaly, ' anomalies=', ISNULL((SELECT STRING_AGG([Type], ',') FROM attendance.ATTENDANCE_ANOMALY an WHERE an.AttendanceId = a.AttendanceId), 'none'))
                                FROM attendance.ATTENDANCE_RECORD a WHERE a.EmployeeId = @E1 AND a.WorkDate = @d);
SET @t = dbo.QA2_At('A1n', '15:00', 0); EXEC dbo.QA2_Punch @E1, @t, 1;
DECLARE @foreign INT = (SELECT COUNT(*) FROM attendance.RAW_DEVICE_LOG r LEFT JOIN hr.EMPLOYEE e ON e.EmployeeId = r.EmployeeId
                        WHERE r.IsProcessed = 0 AND r.EmployeeId IS NOT NULL AND e.FullName NOT LIKE N'QA2 %' AND CAST(r.PunchTimeUtc AS DATE) BETWEEN DATEADD(DAY, -1, @d) AND DATEADD(DAY, 1, @d));
IF @foreign = 0
BEGIN
    DECLARE @out INT; EXEC attendance.usp_Attendance_ProcessRawLogs @WorkDate = @d, @Quiet = 1, @DaysOut = @out OUTPUT;     -- the processor itself, exactly as the worker calls it
END
ELSE BEGIN EXEC dbo.QA2_Process; EXEC dbo.QA2_Note N'A1n: real unprocessed punches exist around that date, so the QA2-only processor was used instead of usp_Attendance_ProcessRawLogs.'; END
SELECT @act = CONCAT('first pass: ', @first, ' | after the late punch: lastOut=', CONVERT(VARCHAR(5), a.LastOutUtc, 108), ' hasAnomaly=', a.HasAnomaly, ' fraction=', a.DayFraction,
                     ' anomalies=', ISNULL((SELECT STRING_AGG([Type], ',') FROM attendance.ATTENDANCE_ANOMALY an WHERE an.AttendanceId = a.AttendanceId), 'none'),
                     ' unprocessed punches left=', (SELECT COUNT(*) FROM attendance.RAW_DEVICE_LOG r WHERE r.EmployeeId = @E1 AND CAST(r.PunchTimeUtc AS DATE) = @d AND r.IsProcessed = 0)),
       @ok = CASE WHEN @first LIKE 'hasAnomaly=1%MissingPunch%' AND CONVERT(VARCHAR(5), a.LastOutUtc, 108) = '15:00' AND a.HasAnomaly = 0 AND a.DayFraction = 1.00
                   AND NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_ANOMALY an WHERE an.AttendanceId = a.AttendanceId) THEN 1 ELSE 0 END
FROM attendance.ATTENDANCE_RECORD a WHERE a.EmployeeId = @E1 AND a.WorkDate = @d;
EXEC dbo.QA2_Check 'A1n', 'a late-arriving punch (the 15:00 out) for a day already processed with the 07:00 in only',
     'first pass: MissingPunch anomaly; when the punch arrives the day is reprocessed by the processor itself and the anomaly disappears (full day)', @act, @ok;

/* A1o: a device user id mapped to no employee */
SET @d = dbo.QA2_Date('A1o');
DECLARE @Dev INT = (SELECT DeviceId FROM attendance.DEVICE WHERE SerialNumber = 'QA2-DEVICE-001');
DECLARE @ins TABLE (RawLogId BIGINT, WasDuplicate BIT, WasUnresolved BIT);
DECLARE @tin DATETIME2(0) = dbo.QA2_At('A1o', '08:00', 0), @tout DATETIME2(0) = dbo.QA2_At('A1o', '12:00', 0);
DECLARE @h1 VARCHAR(64) = CONVERT(VARCHAR(64), HASHBYTES('SHA2_256', CONCAT('QA2|Q2X99|', CONVERT(VARCHAR(19), @tin, 126), '|0')), 2),
        @h2 VARCHAR(64) = CONVERT(VARCHAR(64), HASHBYTES('SHA2_256', CONCAT('QA2|Q2X99|', CONVERT(VARCHAR(19), @tout, 126), '|1')), 2);
INSERT INTO @ins EXEC attendance.usp_RawLog_Insert @DeviceId = @Dev, @EnrollPin = 'Q2X99', @PunchTimeUtc = @tin,  @PunchType = 0, @Source = 'QA2', @DedupHash = @h1;
INSERT INTO @ins EXEC attendance.usp_RawLog_Insert @DeviceId = @Dev, @EnrollPin = 'Q2X99', @PunchTimeUtc = @tout, @PunchType = 1, @Source = 'QA2', @DedupHash = @h2;
DECLARE @stored INT = (SELECT COUNT(*) FROM attendance.RAW_DEVICE_LOG WHERE DeviceId = @Dev AND EnrollPin = 'Q2X99' AND EmployeeId IS NULL);
DECLARE @inQuarantine INT = NULL, @mapped NVARCHAR(200) = 'map procedure missing';
IF OBJECT_ID('attendance.DEVICE_PUNCH_QUARANTINE') IS NOT NULL
    EXEC sp_executesql N'SELECT @n = COUNT(*) FROM attendance.DEVICE_PUNCH_QUARANTINE WHERE DeviceId = @dev AND EnrollPin = ''Q2X99''', N'@dev INT, @n INT OUTPUT', @dev = @Dev, @n = @inQuarantine OUTPUT;
IF OBJECT_ID('attendance.usp_DevicePunchQuarantine_MapToEmployee') IS NOT NULL
BEGIN
    BEGIN TRY
        EXEC attendance.usp_DevicePunchQuarantine_MapToEmployee @DeviceId = @Dev, @EnrollPin = 'Q2X99', @EmployeeId = @E4, @ActedByUserId = @Hr;
        SET @mapped = 'mapped';
    END TRY BEGIN CATCH IF @@TRANCOUNT > 0 ROLLBACK TRAN; SET @mapped = CONCAT('map failed: ', ERROR_MESSAGE()); END CATCH;
END
SELECT @act = CONCAT('stored with no employee=', @stored, ' of 2 (unresolved flags: ', (SELECT SUM(CAST(WasUnresolved AS INT)) FROM @ins), '); in quarantine=', ISNULL(CAST(@inQuarantine AS VARCHAR(10)), 'object missing'), '; ', @mapped,
                     '; after: punches on E4=', (SELECT COUNT(*) FROM attendance.RAW_DEVICE_LOG WHERE DeviceId = @Dev AND EnrollPin = 'Q2X99' AND EmployeeId = @E4),
                     ', record=', ISNULL((SELECT CONCAT([Status], ' worked ', WorkedMinutes, ' fraction ', DayFraction) FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E4 AND WorkDate = @d), 'none'));
SET @ok = CASE WHEN @stored = 2 AND @inQuarantine = 2 AND @mapped = 'mapped'
                AND (SELECT COUNT(*) FROM attendance.RAW_DEVICE_LOG WHERE DeviceId = @Dev AND EnrollPin = 'Q2X99' AND EmployeeId = @E4) = 2
                AND EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E4 AND WorkDate = @d AND [Status] = 'Present' AND WorkedMinutes = 240 AND DayFraction = 1.00) THEN 1 ELSE 0 END;
EXEC dbo.QA2_Check 'A1o', 'punches from a device user id (PIN Q2X99) mapped to no employee, later mapped to E4',
     'never lost: both punches are stored and quarantined, visible to HR; "map to employee" replays them: they become E4''s and the day is derived (Present, 240 min, full day)', @act, @ok;
GO

/* ---------------------------------------------------------------- 5. bulk Excuse — last ---- */
DECLARE @Hr INT = dbo.QA2_User(N'hr'), @B1 INT = (SELECT BranchId FROM hr.BRANCH WHERE Name = N'QA2 Branch 1');
DECLARE @M CHAR(7) = (SELECT [Value] FROM dbo.QA2_STATE WHERE [Key] = 'month'), @act NVARCHAR(700), @ok BIT, @before INT, @after INT, @kept INT;
SELECT @before = COUNT(*) FROM attendance.ATTENDANCE_ANOMALY an JOIN hr.EMPLOYEE e ON e.EmployeeId = an.EmployeeId
WHERE e.FullName LIKE N'QA2 %' AND an.Decision IS NULL AND an.[Type] <> 'MissingPunch' AND CONVERT(CHAR(7), an.WorkDate, 23) = @M;
BEGIN TRY
    EXEC attendance.usp_Anomaly_DecideAll @PeriodYearMonth = @M, @Decision = 'Excuse', @BranchId = @B1, @Note = N'QA2 A1j bulk excuse', @DecidedByUserId = @Hr;
END TRY BEGIN CATCH IF @@TRANCOUNT > 0 ROLLBACK TRAN; SET @act = CONCAT('error: ', ERROR_MESSAGE(), ' | '); END CATCH;
SELECT @after = COUNT(*) FROM attendance.ATTENDANCE_ANOMALY an JOIN hr.EMPLOYEE e ON e.EmployeeId = an.EmployeeId
WHERE e.FullName LIKE N'QA2 %' AND an.Decision IS NULL AND an.[Type] <> 'MissingPunch' AND CONVERT(CHAR(7), an.WorkDate, 23) = @M;
SELECT @kept = COUNT(*) FROM attendance.ATTENDANCE_ANOMALY WHERE EmployeeId = dbo.QA2_Emp(N'E1') AND WorkDate = dbo.QA2_Date('A1j1') AND Decision = 'Deducted';
SET @act = CONCAT(@act, 'undecided late/early anomalies of the QA2 branch: ', @before, ' before, ', @after, ' after; the Deducted row of A1j1 still Deducted=', @kept);
SET @ok = CASE WHEN @before > 0 AND @after = 0 AND @kept = 1 THEN 1 ELSE 0 END;
EXEC dbo.QA2_Check 'A1j3', 'bulk "Excuse all" for the month and the branch', 'every undecided late / early anomaly becomes Excused; rows already decided (the Deducted one) are not touched', @act, @ok;
GO
