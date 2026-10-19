/* QA3 attendance (unit B) - ATT-8, LEV-2, REL-6 (a partially approved leave covers its approved days only) and
   ATT-13 (the manual writer mirrors the machine one: roster only in an approved month, half-day leave).
   Runs on a dev database with docs/100_qa3_attendance.sql applied, inside a transaction that is rolled back. */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
BEGIN TRAN;
DECLARE @fails INT = 0;
DECLARE @B INT, @E INT, @E2 INT, @S INT, @U INT, @RT INT, @WD INT, @LT INT, @Ri INT, @d DATE, @st VARCHAR(20), @fr DECIMAL(5,2), @std INT, @late INT, @rc INT;
DECLARE @x TABLE (n INT);
INSERT INTO hr.BRANCH (Name) VALUES (N'QA3 Att Branch'); SET @B = SCOPE_IDENTITY();
INSERT INTO hr.EMPLOYEE (BranchId, DepartmentId, PositionId, FullName, HireDate)
VALUES (@B, (SELECT TOP 1 DepartmentId FROM hr.DEPARTMENT ORDER BY DepartmentId), (SELECT TOP 1 PositionId FROM hr.POSITION ORDER BY PositionId), N'QA3 Att Leave', '2025-01-01');
SET @E = SCOPE_IDENTITY();
INSERT INTO hr.EMPLOYEE (BranchId, DepartmentId, PositionId, FullName, HireDate)
VALUES (@B, (SELECT TOP 1 DepartmentId FROM hr.DEPARTMENT ORDER BY DepartmentId), (SELECT TOP 1 PositionId FROM hr.POSITION ORDER BY PositionId), N'QA3 Att Manual', '2025-01-01');
SET @E2 = SCOPE_IDENTITY();
INSERT INTO attendance.SHIFT (Name, StartTime, EndTime, GraceMinutes, CrossesMidnight, BreakMinutes) VALUES (N'QA3 07-15', '07:00', '15:00', NULL, 0, 30);
SET @S = SCOPE_IDENTITY();
INSERT INTO attendance.ROSTER_MONTH (BranchId, MonthDate, [Status]) VALUES (@B, '2026-09-01', 'Approved'), (@B, '2026-11-01', 'Draft');
SET @d = '2026-09-14';
WHILE @d <= '2026-09-21' BEGIN INSERT INTO attendance.SHIFT_ASSIGNMENT (EmployeeId, ShiftId, WorkDate, IsRestDay) VALUES (@E, @S, @d, 0), (@E2, @S, @d, 0); SET @d = DATEADD(DAY, 1, @d); END
INSERT INTO attendance.SHIFT_ASSIGNMENT (EmployeeId, ShiftId, WorkDate, IsRestDay) VALUES (@E2, @S, '2026-11-02', 0);
SET @U = (SELECT TOP 1 UserId FROM security.[USER] ORDER BY UserId);
SELECT TOP 1 @WD = WorkflowDefinitionId, @RT = RequestTypeId FROM workflow.WORKFLOW_DEFINITION ORDER BY WorkflowDefinitionId;
INSERT INTO hr.LEAVE_TYPE (Name, IsPaid) VALUES (N'QA3 Annual', 1); SET @LT = SCOPE_IDENTITY();

/* (a) 14-18 Sep asked, 3 days approved: the ledger keeps the first days, so ApprovedToDate = the 16th (script 99) */
INSERT INTO workflow.REQUEST_INSTANCE (RequestTypeId, WorkflowDefinitionId, EmployeeId, RaisedByUserId, [Status], Title) VALUES (@RT, @WD, @E, @U, 'Approved', N'QA3 leave');
SET @Ri = SCOPE_IDENTITY();
INSERT INTO workflow.LEAVE_REQUEST (RequestInstanceId, EmployeeId, LeaveTypeId, FromDate, ToDate, DaysRequested, DaysApproved, ApprovedToDate)
VALUES (@Ri, @E, @LT, '2026-09-14', '2026-09-18', 5, 3, '2026-09-16');
SET @d = '2026-09-14';
WHILE @d <= '2026-09-18' BEGIN INSERT INTO @x EXEC attendance.usp_Attendance_MarkAbsentees @WorkDate = @d; SET @d = DATEADD(DAY, 1, @d); END
IF (SELECT COUNT(*) FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E AND WorkDate BETWEEN '2026-09-14' AND '2026-09-16' AND [Status] = 'Leave') <> 3
    BEGIN SET @fails += 1; RAISERROR('02a: the three approved days are not Leave.', 16, 1); END
IF (SELECT COUNT(*) FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E AND WorkDate IN ('2026-09-17', '2026-09-18') AND [Status] = 'Absent') <> 2
    BEGIN SET @fails += 1; RAISERROR('02a: the two days beyond the approved part are not judged from the punches (Absent).', 16, 1); END

/* (b) a day the old rule marked Leave beyond the approved part: the nightly leave marker re-derives it */
UPDATE attendance.ATTENDANCE_RECORD SET [Status] = 'Leave', DayFraction = NULL, ShortfallMinutes = 0 WHERE EmployeeId = @E AND WorkDate = '2026-09-17';
INSERT INTO @x EXEC attendance.usp_Attendance_MarkLeaveDays @PeriodYearMonth = '2026-09';
IF NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E AND WorkDate = '2026-09-17' AND [Status] = 'Absent')
    BEGIN SET @fails += 1; RAISERROR('02b: MarkLeaveDays left a Leave day no approved leave covers.', 16, 1); END

/* (c) ATT-13: November's roster is a DRAFT - inert for the machine, and now for a manual entry too */
EXEC @rc = attendance.usp_Attendance_ManualUpsert @EmployeeId = @E2, @WorkDate = '2026-11-02', @FirstInUtc = '2026-11-02 07:30', @LastOutUtc = '2026-11-02 14:00', @Quiet = 1;
SELECT @std = StandardMinutes, @late = LateMinutes FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E2 AND WorkDate = '2026-11-02';
IF @rc <> 0 OR @std <> core.fn_StandardDayMinutes() OR @late <> 0
    BEGIN SET @fails += 1; RAISERROR('02c: a manual day in a draft roster month was measured against the inert roster (std %d, late %d).', 16, 1, @std, @late); END

/* (d) ATT-13: an approved AM half-day leave - the manual day is the measured PM half plus half a day of leave */
INSERT INTO workflow.REQUEST_INSTANCE (RequestTypeId, WorkflowDefinitionId, EmployeeId, RaisedByUserId, [Status], Title) VALUES (@RT, @WD, @E2, @U, 'Approved', N'QA3 half');
SET @Ri = SCOPE_IDENTITY();
INSERT INTO workflow.LEAVE_REQUEST (RequestInstanceId, EmployeeId, LeaveTypeId, FromDate, ToDate, HalfDay, DaysRequested, ApprovedToDate)
VALUES (@Ri, @E2, @LT, '2026-09-21', '2026-09-21', 'AM', 0.5, '2026-09-21');
EXEC @rc = attendance.usp_Attendance_ManualUpsert @EmployeeId = @E2, @WorkDate = '2026-09-21', @FirstInUtc = '2026-09-21 11:00', @LastOutUtc = '2026-09-21 15:00', @Quiet = 1;
SELECT @st = [Status], @fr = DayFraction, @std = StandardMinutes FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E2 AND WorkDate = '2026-09-21';
IF @rc <> 0 OR @st <> 'Present' OR @fr <> 1.00 OR @std <> 450
BEGIN
    DECLARE @frs VARCHAR(12) = CONVERT(VARCHAR(12), @fr);
    SET @fails += 1; RAISERROR('02d: a manual day with a half-day leave is %s / %s / %d (expected Present / 1.00 / 450).', 16, 1, @st, @frs, @std);
END
/* the measured half left two hours early: an EarlyDeparture anomaly of 120 min, as the machine path reports it */
EXEC @rc = attendance.usp_Attendance_ManualUpsert @EmployeeId = @E2, @WorkDate = '2026-09-21', @FirstInUtc = '2026-09-21 11:00', @LastOutUtc = '2026-09-21 13:00', @Quiet = 1;
IF NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_ANOMALY an JOIN attendance.ATTENDANCE_RECORD a ON a.AttendanceId = an.AttendanceId
               WHERE a.EmployeeId = @E2 AND a.WorkDate = '2026-09-21' AND an.[Type] = 'EarlyDeparture' AND an.[Minutes] = 120)
    BEGIN SET @fails += 1; RAISERROR('02d: the early departure of the measured half is not an anomaly of 120 min.', 16, 1); END
/* a FULL-day approved leave still makes a manual day Leave */
EXEC @rc = attendance.usp_Attendance_ManualUpsert @EmployeeId = @E, @WorkDate = '2026-09-15', @FirstInUtc = '2026-09-15 07:00', @LastOutUtc = '2026-09-15 09:00', @Quiet = 1;
IF NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E AND WorkDate = '2026-09-15' AND [Status] = 'Leave' AND IsManual = 1)
    BEGIN SET @fails += 1; RAISERROR('02d: a manual day inside the approved leave is not Leave.', 16, 1); END

IF @@TRANCOUNT > 0 ROLLBACK TRAN;
IF @fails = 0 PRINT 'ok 02_partial_leave_and_manual_days';
