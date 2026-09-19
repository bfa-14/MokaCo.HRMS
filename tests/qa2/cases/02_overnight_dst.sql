/* ============================================================================
   cases/02_overnight_dst.sql — A2: the overnight shift (QA2 E3, QA2 Overnight 22:00-06:00, break 30,
   standard 450), month end, and the two DST nights.

   PUNCH TIMES ARE THE TERMINAL'S WALL CLOCK (RAW_DEVICE_LOG.PunchTimeUtc is a misnomer kept by the schema), and a
   shift is built from WorkDate + StartTime with no zone. So on a DST night a 22:00-06:00 shift is always 8 wall
   hours: 7 real hours in spring, 9 in autumn. The rule: both are a full day with no anomaly; the 9th real hour of
   the autumn night is overtime only when an overtime request was approved for it.
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
GO
DECLARE @E3 INT = dbo.QA2_Emp(N'E3'), @Hr INT = dbo.QA2_User(N'hr'), @rid INT, @d DATE, @t DATETIME2(0);
/* A2d: annual leave on the last night of M-1 */
SET @d = dbo.QA2_Date('A2d');
EXEC workflow.usp_LeaveRequest_Create @EmployeeId = @E3, @RaisedByUserId = @Hr, @LeaveTypeId = 1, @FromDate = @d, @ToDate = @d, @Reason = N'QA2 A2d';
SET @rid = dbo.QA2_LastRequest(@E3); EXEC dbo.QA2_Approve @rid, 'Leave';
/* punches */
SET @t = dbo.QA2_At('A2c', '21:40', 0); EXEC dbo.QA2_Punch @E3, @t, 0;   SET @t = dbo.QA2_At('A2c', '05:50', 1); EXEC dbo.QA2_Punch @E3, @t, 1;
SET @t = dbo.QA2_At('A2d', '01:00', 1); EXEC dbo.QA2_Punch @E3, @t, 1;                     -- 01:00 on the 1st of M, while on leave the night before
SET @t = dbo.QA2_At('A2b1', '22:00', 0); EXEC dbo.QA2_Punch @E3, @t, 0;  SET @t = dbo.QA2_At('A2b1', '06:00', 1); EXEC dbo.QA2_Punch @E3, @t, 1;
SET @t = dbo.QA2_At('A2b2', '22:00', 0); EXEC dbo.QA2_Punch @E3, @t, 0;  SET @t = dbo.QA2_At('A2b2', '06:00', 1); EXEC dbo.QA2_Punch @E3, @t, 1;
EXEC dbo.QA2_Process;
GO

DECLARE @E3 INT = dbo.QA2_Emp(N'E3'), @exp NVARCHAR(700), @act NVARCHAR(700), @ok BIT, @d DATE, @d1 DATE;
DECLARE @M DATE = CAST((SELECT [Value] FROM dbo.QA2_STATE WHERE [Key] = 'month') + '-01' AS DATE);
DECLARE @Last DATE = EOMONTH(@M), @Next DATE = DATEADD(DAY, 1, EOMONTH(@M));

/* A2a: the last night of M */
SELECT @act = CONCAT('record of ', CONVERT(CHAR(10), a.WorkDate, 23), ': in=', CONVERT(VARCHAR(16), a.FirstInUtc, 120), ' out=', CONVERT(VARCHAR(16), a.LastOutUtc, 120),
                     ' worked=', a.WorkedMinutes, ' fraction=', a.DayFraction, ' | record of ', CONVERT(CHAR(10), @Next, 23), ': in=',
                     ISNULL((SELECT CONVERT(VARCHAR(16), n.FirstInUtc, 120) FROM attendance.ATTENDANCE_RECORD n WHERE n.EmployeeId = @E3 AND n.WorkDate = @Next), 'no record'),
                     ' | punches of the night attributed elsewhere=', (SELECT COUNT(*) FROM attendance.RAW_DEVICE_LOG r WHERE r.EmployeeId = @E3
                            AND r.PunchTimeUtc IN (DATEADD(HOUR, 22, CAST(@Last AS DATETIME2)), DATEADD(HOUR, 6, CAST(@Next AS DATETIME2)))
                            AND attendance.fn_AttributedWorkDate(@E3, r.PunchTimeUtc) <> @Last)),
       @ok = CASE WHEN a.FirstInUtc = DATEADD(HOUR, 22, CAST(@Last AS DATETIME2)) AND a.LastOutUtc = DATEADD(HOUR, 6, CAST(@Next AS DATETIME2))
                   AND a.WorkedMinutes = 450 AND a.DayFraction = 1.00
                   AND ISNULL((SELECT n.FirstInUtc FROM attendance.ATTENDANCE_RECORD n WHERE n.EmployeeId = @E3 AND n.WorkDate = @Next), DATEADD(HOUR, 22, CAST(@Next AS DATETIME2))) = DATEADD(HOUR, 22, CAST(@Next AS DATETIME2))
              THEN 1 ELSE 0 END
FROM attendance.ATTENDANCE_RECORD a WHERE a.EmployeeId = @E3 AND a.WorkDate = @Last;
EXEC dbo.QA2_Check 'A2a', '22:00-06:00 on the last day of M', 'both punches belong to the last day of M (in 22:00, out 06:00 next morning, 450 min, full day); nothing spills into the 1st, whose own record starts at its own 22:00; payroll counts the day in M', @act, @ok;

/* A2b1: spring forward */
DECLARE @real INT, @w1 DATETIME2, @w2 DATETIME2;
SET @d = dbo.QA2_Date('A2b1');
SET @w1 = DATEADD(HOUR, 22, CAST(@d AS DATETIME2)); SET @w2 = DATEADD(HOUR, 30, CAST(@d AS DATETIME2));
SET @real = DATEDIFF(MINUTE, @w1 AT TIME ZONE 'Middle East Standard Time', @w2 AT TIME ZONE 'Middle East Standard Time');
SELECT @act = CONCAT('night of ', CONVERT(CHAR(10), @d, 23), ': real minutes=', @real,
                     ' status=', a.[Status], ' worked=', a.WorkedMinutes, ' fraction=', a.DayFraction, ' overtime=', a.OvertimeMinutes,
                     ' anomalies=', ISNULL((SELECT STRING_AGG(CONCAT([Type], ' ', [Minutes]), ',') FROM attendance.ATTENDANCE_ANOMALY an WHERE an.AttendanceId = a.AttendanceId), 'none')),
       @ok = CASE WHEN a.[Status] = 'Present' AND a.DayFraction = 1.00 AND a.OvertimeMinutes = 0 AND NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_ANOMALY an WHERE an.AttendanceId = a.AttendanceId) THEN 1 ELSE 0 END
FROM attendance.ATTENDANCE_RECORD a WHERE a.EmployeeId = @E3 AND a.WorkDate = @d;
SET @act = ISNULL(@act, 'no record');
EXEC dbo.QA2_Check 'A2b1', 'spring-forward night (the clocks skip an hour: 7 real hours between 22:00 and 06:00)', 'Present, full day, no absence, no anomaly, no overtime', @act, @ok; SET @act = NULL; SET @ok = 0;

/* A2b2: fall back — first without, then with an approved overtime request */
SET @d = dbo.QA2_Date('A2b2');
SET @w1 = DATEADD(HOUR, 22, CAST(@d AS DATETIME2)); SET @w2 = DATEADD(HOUR, 30, CAST(@d AS DATETIME2));
SET @real = DATEDIFF(MINUTE, @w1 AT TIME ZONE 'Middle East Standard Time', @w2 AT TIME ZONE 'Middle East Standard Time');
DECLARE @noOt NVARCHAR(200);
SELECT @noOt = CONCAT('status=', a.[Status], ' fraction=', a.DayFraction, ' overtime=', a.OvertimeMinutes,
                      ' anomalies=', ISNULL((SELECT STRING_AGG(CONCAT([Type], ' ', [Minutes]), ',') FROM attendance.ATTENDANCE_ANOMALY an WHERE an.AttendanceId = a.AttendanceId), 'none'))
FROM attendance.ATTENDANCE_RECORD a WHERE a.EmployeeId = @E3 AND a.WorkDate = @d;
EXEC dbo.QA2_ApprovedOvertime @E3, @d, 60;
EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @E3, @WorkDate = @d;
SELECT @act = CONCAT('night of ', CONVERT(CHAR(10), @d, 23), ': real minutes=', @real,
                     ' | without an overtime request: ', @noOt, ' | with 60 min approved: status=', a.[Status], ' fraction=', a.DayFraction, ' overtime=', a.OvertimeMinutes),
       @ok = CASE WHEN @noOt LIKE 'status=Present fraction=1.00 overtime=0 anomalies=none' AND a.[Status] = 'Present' AND a.DayFraction = 1.00 AND a.OvertimeMinutes = 60 THEN 1 ELSE 0 END
FROM attendance.ATTENDANCE_RECORD a WHERE a.EmployeeId = @E3 AND a.WorkDate = @d;
SET @act = ISNULL(@act, 'no record');
EXEC dbo.QA2_Check 'A2b2', 'autumn night (the clocks repeat an hour: 9 real hours between 22:00 and 06:00)', 'full day, no anomaly; the extra real hour is overtime (60) only once an overtime request is approved for that night, 0 without one', @act, @ok; SET @act = NULL; SET @ok = 0;

/* A2c */
SET @d = dbo.QA2_Date('A2c');
SELECT @act = CONCAT('in=', CONVERT(VARCHAR(16), a.FirstInUtc, 120), ' out=', CONVERT(VARCHAR(16), a.LastOutUtc, 120), ' worked=', a.WorkedMinutes, ' late=', a.LateMinutes, ' early=', a.EarlyExitMinutes, ' overtime=', a.OvertimeMinutes,
                     ' anomalies=', ISNULL((SELECT STRING_AGG(CONCAT([Type], ' ', [Minutes]), ',') FROM attendance.ATTENDANCE_ANOMALY an WHERE an.AttendanceId = a.AttendanceId), 'none')),
       @ok = CASE WHEN a.WorkedMinutes = 440 AND a.LateMinutes = 0 AND a.EarlyExitMinutes = 10 AND a.OvertimeMinutes = 0
                   AND (SELECT STRING_AGG(CONCAT([Type], ' ', [Minutes]), ',') FROM attendance.ATTENDANCE_ANOMALY an WHERE an.AttendanceId = a.AttendanceId) = 'EarlyDeparture 10' THEN 1 ELSE 0 END
FROM attendance.ATTENDANCE_RECORD a WHERE a.EmployeeId = @E3 AND a.WorkDate = @d;
SET @act = ISNULL(@act, 'no record');
EXEC dbo.QA2_Check 'A2c', '22:00 shift, in 21:40, out 05:50', 'the 20 early minutes are ignored (no overtime, worked 440 = 22:00->05:50 less the break); the 10-minute early exit reaches the tolerance: EarlyDeparture 10', @act, @ok; SET @act = NULL; SET @ok = 0;

/* A2d */
SET @d = dbo.QA2_Date('A2d'); SET @d1 = DATEADD(DAY, 1, @d);
SELECT @act = CONCAT('leave night ', CONVERT(CHAR(10), @d, 23), ': ', ISNULL((SELECT CONCAT('status=', a.[Status], ' fraction=', ISNULL(CAST(a.DayFraction AS VARCHAR(10)), 'NULL'), ' hasAnomaly=', a.HasAnomaly,
                            ' anomalies=', ISNULL((SELECT STRING_AGG([Type], ',') FROM attendance.ATTENDANCE_ANOMALY an WHERE an.AttendanceId = a.AttendanceId), 'none'))
                            FROM attendance.ATTENDANCE_RECORD a WHERE a.EmployeeId = @E3 AND a.WorkDate = @d), 'no record'),
                     ' | the 1st: ', ISNULL((SELECT CONCAT('status=', a.[Status], ' in=', CONVERT(VARCHAR(16), a.FirstInUtc, 120), ' pairs=', a.PunchPairs, ' fraction=', a.DayFraction,
                            ' anomalies=', ISNULL((SELECT STRING_AGG([Type], ',') FROM attendance.ATTENDANCE_ANOMALY an WHERE an.AttendanceId = a.AttendanceId), 'none'))
                            FROM attendance.ATTENDANCE_RECORD a WHERE a.EmployeeId = @E3 AND a.WorkDate = @d1), 'no record'));
SET @ok = CASE WHEN EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD a WHERE a.EmployeeId = @E3 AND a.WorkDate = @d AND a.[Status] = 'Leave' AND a.HasAnomaly = 0
                                   AND NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_ANOMALY an WHERE an.AttendanceId = a.AttendanceId))
                AND EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD a WHERE a.EmployeeId = @E3 AND a.WorkDate = @d1 AND a.[Status] = 'Present' AND a.PunchPairs = 1 AND a.DayFraction = 1.00
                                   AND a.FirstInUtc = DATEADD(HOUR, 22, CAST(@d1 AS DATETIME2))
                                   AND NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_ANOMALY an WHERE an.AttendanceId = a.AttendanceId)) THEN 1 ELSE 0 END;
EXEC dbo.QA2_Check 'A2d', 'overnight worker on approved leave the last night of the month, with a stray punch at 01:00 on the 1st',
     'the leave night stays Leave with no anomaly; the 01:00 punch does not turn the 1st into a leave day nor disturb it: the 1st is Present from its own 22:00, one pair, full day, no anomaly', @act, @ok;
GO
