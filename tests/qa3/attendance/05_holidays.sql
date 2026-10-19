/* QA3 attendance (unit B) - ATT-14, ROS-5 (a holiday re-derives only the days up to today), REL-12 (the leave over a
   holiday is re-priced), the status precedence of the handoff (leave, public holiday, rest day, punches) and a holiday
   worked with a lost punch (a MissingPunch anomaly).
   Runs on a dev database with docs/100_qa3_attendance.sql applied, inside a transaction that is rolled back. */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
BEGIN TRAN;
DECLARE @fails INT = 0;
DECLARE @B INT, @E1 INT, @E2 INT, @E3 INT, @S INT, @Dev INT, @U INT, @RT INT, @WD INT, @LT INT, @Ri INT, @H INT, @H2 INT;
DECLARE @Today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE);
DECLARE @Future DATE = DATEADD(DAY, 20, @Today), @Future2 DATE = DATEADD(DAY, 21, @Today);
DECLARE @Past DATE = '2026-09-10';
INSERT INTO hr.BRANCH (Name) VALUES (N'QA3 Att Branch'); SET @B = SCOPE_IDENTITY();
INSERT INTO hr.EMPLOYEE (BranchId, DepartmentId, PositionId, FullName, HireDate)
SELECT @B, (SELECT TOP 1 DepartmentId FROM hr.DEPARTMENT ORDER BY DepartmentId), (SELECT TOP 1 PositionId FROM hr.POSITION ORDER BY PositionId), v.n, '2025-01-01'
FROM (VALUES (N'QA3 Att Hol Worker'), (N'QA3 Att Hol Rest'), (N'QA3 Att Hol Leave')) v(n);
SELECT @E1 = MIN(EmployeeId), @E3 = MAX(EmployeeId) FROM hr.EMPLOYEE WHERE BranchId = @B;
SET @E2 = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE BranchId = @B AND FullName = N'QA3 Att Hol Rest');
INSERT INTO attendance.SHIFT (Name, StartTime, EndTime, GraceMinutes, CrossesMidnight, BreakMinutes) VALUES (N'QA3 07-15', '07:00', '15:00', NULL, 0, 30);
SET @S = SCOPE_IDENTITY();
INSERT INTO attendance.ROSTER_MONTH (BranchId, MonthDate, [Status])
SELECT DISTINCT @B, DATEFROMPARTS(YEAR(x.d), MONTH(x.d), 1), 'Approved' FROM (VALUES (@Past), (@Future), (@Future2)) x(d);
INSERT INTO attendance.SHIFT_ASSIGNMENT (EmployeeId, ShiftId, WorkDate, IsRestDay)
VALUES (@E1, @S, @Past, 0), (@E2, NULL, @Past, 1), (@E3, @S, @Past, 0),
       (@E1, @S, @Future, 0), (@E2, @S, @Future, 0), (@E1, @S, @Future2, 0), (@E2, @S, @Future2, 0);
INSERT INTO attendance.DEVICE (SerialNumber, BranchId, [Name]) VALUES (CONCAT('QA3-ATT-', @B), @B, N'QA3 device'); SET @Dev = SCOPE_IDENTITY();
SET @U = (SELECT TOP 1 UserId FROM security.[USER] ORDER BY UserId);
SELECT TOP 1 @WD = WorkflowDefinitionId, @RT = RequestTypeId FROM workflow.WORKFLOW_DEFINITION ORDER BY WorkflowDefinitionId;
INSERT INTO hr.LEAVE_TYPE (Name, IsPaid) VALUES (N'QA3 Annual', 1); SET @LT = SCOPE_IDENTITY();
/* E1 works the past holiday but the out-punch is lost; E3 is on approved leave over it */
INSERT INTO attendance.RAW_DEVICE_LOG (DeviceId, EnrollPin, EmployeeId, PunchTimeUtc, PunchType, [Source], DedupHash)
VALUES (@Dev, 'QA3', @E1, DATEADD(HOUR, 8, CAST(@Past AS DATETIME2)), 0, 'Device', CONVERT(VARCHAR(64), NEWID()));
INSERT INTO workflow.REQUEST_INSTANCE (RequestTypeId, WorkflowDefinitionId, EmployeeId, RaisedByUserId, [Status], Title) VALUES (@RT, @WD, @E3, @U, 'Approved', N'QA3 leave');
SET @Ri = SCOPE_IDENTITY();
INSERT INTO workflow.LEAVE_REQUEST (RequestInstanceId, EmployeeId, LeaveTypeId, FromDate, ToDate, DaysRequested, DaysApproved, ApprovedToDate)
VALUES (@Ri, @E3, @LT, '2026-09-09', '2026-09-11', 3, 3, '2026-09-11');
/* the leave is posted as its approval posts it (3 working days); where a stand-in for unit D's re-pricing records its
   calls (dbo.T_RepriceCalls, stub databases only) the calls are checked, otherwise their effect on the ledger */
DECLARE @Stand BIT = CASE WHEN OBJECT_ID('dbo.T_RepriceCalls') IS NOT NULL THEN 1 ELSE 0 END, @calls INT, @used DECIMAL(9,2);
IF OBJECT_ID('hr.usp_LeaveLedger_PostRequest', 'P') IS NOT NULL EXEC hr.usp_LeaveLedger_PostRequest @RequestInstanceId = @Ri;
IF @Stand = 1 EXEC (N'DELETE FROM dbo.T_RepriceCalls');

/* a holiday recorded ahead, then moved: nothing is written on a day that has not happened */
EXEC core.usp_Holiday_Upsert @HolidayDate = @Future, @Name = N'QA3 Holiday ahead', @BranchId = @B, @ActedByUserId = @U;
SET @H = (SELECT HolidayId FROM core.HOLIDAY WHERE BranchId = @B AND HolidayDate = @Future);
EXEC core.usp_Holiday_Upsert @HolidayId = @H, @HolidayDate = @Future2, @Name = N'QA3 Holiday ahead', @BranchId = @B, @ActedByUserId = @U;
IF EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId IN (@E1, @E2) AND WorkDate > @Today)
    BEGIN SET @fails += 1; RAISERROR('05: a holiday ahead wrote attendance records on days that have not happened.', 16, 1); END

/* the past holiday: E1 Holiday with a MissingPunch, E2's rest day is the holiday (Holiday, not RestDay), E3 Leave */
EXEC core.usp_Holiday_Upsert @HolidayDate = @Past, @Name = N'QA3 Holiday', @BranchId = @B, @ActedByUserId = @U;
SET @H2 = (SELECT HolidayId FROM core.HOLIDAY WHERE BranchId = @B AND HolidayDate = @Past);
IF NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD a JOIN attendance.ATTENDANCE_ANOMALY an ON an.AttendanceId = a.AttendanceId
               WHERE a.EmployeeId = @E1 AND a.WorkDate = @Past AND a.[Status] = 'Holiday' AND a.HasAnomaly = 1 AND an.[Type] = 'MissingPunch')
    BEGIN SET @fails += 1; RAISERROR('05: a holiday worked with a lost out-punch has no MissingPunch anomaly.', 16, 1); END
IF NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E2 AND WorkDate = @Past AND [Status] = 'Holiday')
    BEGIN SET @fails += 1; RAISERROR('05: a public holiday on a rest day is not Holiday (handoff precedence).', 16, 1); END
IF NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E3 AND WorkDate = @Past AND [Status] = 'Leave')
    BEGIN SET @fails += 1; RAISERROR('05: approved leave did not win over the holiday.', 16, 1); END
IF @Stand = 1
BEGIN
    EXEC sp_executesql N'SELECT @n = COUNT(*) FROM dbo.T_RepriceCalls WHERE EmployeeId = @E3 AND FromDate = @D AND ToDate = @D', N'@n INT OUTPUT, @E3 INT, @D DATE', @calls OUTPUT, @E3, @Past;
    IF @calls <> 1 BEGIN SET @fails += 1; RAISERROR('05: the leave over the new holiday was not re-priced.', 16, 1); END
    EXEC sp_executesql N'SELECT @n = COUNT(*) FROM dbo.T_RepriceCalls WHERE EmployeeId IN (@E1, @E2)', N'@n INT OUTPUT, @E1 INT, @E2 INT', @calls OUTPUT, @E1, @E2;
    IF @calls <> 0 BEGIN SET @fails += 1; RAISERROR('05: an employee with no leave over the holiday was re-priced.', 16, 1); END
END
ELSE
BEGIN
    SET @used = (SELECT -SUM(l.Days) FROM hr.LEAVE_LEDGER l JOIN workflow.LEAVE_REQUEST lr ON lr.LeaveRequestId = l.LeaveRequestId
                 WHERE lr.RequestInstanceId = @Ri AND l.MovementType = 'Usage');
    IF ISNULL(@used, -1) <> 2 BEGIN SET @fails += 1; RAISERROR('05: the leave over the new holiday still costs the holiday (re-priced to 2 days expected).', 16, 1); END
END

/* removed again: the rest day is a rest day, and the leave is re-priced once more */
IF @Stand = 1 EXEC (N'DELETE FROM dbo.T_RepriceCalls');
EXEC core.usp_Holiday_Delete @HolidayId = @H2, @ActedByUserId = @U;
IF NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E2 AND WorkDate = @Past AND [Status] = 'RestDay')
    BEGIN SET @fails += 1; RAISERROR('05: the rest day did not come back when the holiday was removed.', 16, 1); END
IF @Stand = 1
BEGIN
    EXEC sp_executesql N'SELECT @n = COUNT(*) FROM dbo.T_RepriceCalls WHERE EmployeeId = @E3 AND FromDate = @D', N'@n INT OUTPUT, @E3 INT, @D DATE', @calls OUTPUT, @E3, @Past;
    IF @calls <> 1 BEGIN SET @fails += 1; RAISERROR('05: the leave over the removed holiday was not re-priced.', 16, 1); END
END
ELSE
BEGIN
    SET @used = (SELECT -SUM(l.Days) FROM hr.LEAVE_LEDGER l JOIN workflow.LEAVE_REQUEST lr ON lr.LeaveRequestId = l.LeaveRequestId
                 WHERE lr.RequestInstanceId = @Ri AND l.MovementType = 'Usage');
    IF ISNULL(@used, -1) <> 3 BEGIN SET @fails += 1; RAISERROR('05: the leave over the removed holiday was not re-priced back to 3 days.', 16, 1); END
END

IF @@TRANCOUNT > 0 ROLLBACK TRAN;
IF @fails = 0 PRINT 'ok 05_holidays';
