/* QA3 attendance (unit B) - ROS-1, ATT-2, REL-1: a day outside the employment is nobody's working day.
   Runs on a dev database with docs/100_qa3_attendance.sql applied, inside a transaction that is rolled back.
   sqlcmd -I -b -i tests/qa3/attendance/01_employment_window.sql   ->  prints 'ok 01_employment_window' */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
BEGIN TRAN;
DECLARE @B INT, @E INT, @S INT, @Dev INT, @U INT, @RT INT, @WD INT, @LT INT, @Ri INT, @Ep INT, @Att BIGINT, @n INT, @o VARCHAR(10);
DECLARE @x TABLE (n INT);
DECLARE @fails INT = 0;
INSERT INTO hr.BRANCH (Name) VALUES (N'QA3 Att Branch'); SET @B = SCOPE_IDENTITY();
INSERT INTO hr.EMPLOYEE (BranchId, DepartmentId, PositionId, FullName, HireDate, TerminationDate)
VALUES (@B, (SELECT TOP 1 DepartmentId FROM hr.DEPARTMENT ORDER BY DepartmentId), (SELECT TOP 1 PositionId FROM hr.POSITION ORDER BY PositionId),
        N'QA3 Att Leaver', '2026-09-03', '2026-09-15');
SET @E = SCOPE_IDENTITY();
INSERT INTO attendance.SHIFT (Name, StartTime, EndTime, GraceMinutes, CrossesMidnight, BreakMinutes) VALUES (N'QA3 07-15', '07:00', '15:00', NULL, 0, 30);
SET @S = SCOPE_IDENTITY();
INSERT INTO attendance.ROSTER_MONTH (BranchId, MonthDate, [Status]) VALUES (@B, '2026-09-01', 'Approved');
INSERT INTO attendance.SHIFT_ASSIGNMENT (EmployeeId, ShiftId, WorkDate, IsRestDay)
VALUES (@E, @S, '2026-09-02', 0), (@E, @S, '2026-09-15', 0), (@E, @S, '2026-09-16', 0), (@E, @S, '2026-09-17', 0), (@E, @S, '2026-09-18', 0);
INSERT INTO attendance.DEVICE (SerialNumber, BranchId, [Name]) VALUES (CONCAT('QA3-ATT-', @B), @B, N'QA3 device'); SET @Dev = SCOPE_IDENTITY();
SET @U = (SELECT TOP 1 UserId FROM security.[USER] ORDER BY UserId);
SELECT TOP 1 @WD = WorkflowDefinitionId, @RT = RequestTypeId FROM workflow.WORKFLOW_DEFINITION ORDER BY WorkflowDefinitionId;
INSERT INTO hr.LEAVE_TYPE (Name, IsPaid) VALUES (N'QA3 Annual', 1); SET @LT = SCOPE_IDENTITY();

/* the last day worked, and a punch the day after the termination (somebody used the leaver's finger) */
INSERT INTO attendance.RAW_DEVICE_LOG (DeviceId, EnrollPin, EmployeeId, PunchTimeUtc, PunchType, [Source], DedupHash)
VALUES (@Dev, 'QA3', @E, '2026-09-15 07:00', 0, 'Device', CONVERT(VARCHAR(64), NEWID())),
       (@Dev, 'QA3', @E, '2026-09-15 15:00', 1, 'Device', CONVERT(VARCHAR(64), NEWID())),
       (@Dev, 'QA3', @E, '2026-09-16 07:00', 0, 'Device', CONVERT(VARCHAR(64), NEWID())),
       (@Dev, 'QA3', @E, '2026-09-16 15:00', 1, 'Device', CONVERT(VARCHAR(64), NEWID()));
EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @E, @WorkDate = '2026-09-15';
EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @E, @WorkDate = '2026-09-16', @Outcome = @o OUTPUT;
IF @o <> 'None' BEGIN SET @fails += 1; RAISERROR('01: a punch after the termination still derived a day (%s).', 16, 1, @o); END
INSERT INTO @x EXEC attendance.usp_Attendance_MarkAbsentees @WorkDate = '2026-09-17';
INSERT INTO @x EXEC attendance.usp_Attendance_MarkAbsentees @WorkDate = '2026-09-18';
INSERT INTO @x EXEC attendance.usp_Attendance_MarkAbsentees @WorkDate = '2026-09-02';      -- before the hire date
IF (SELECT SUM(n) FROM @x) <> 0 BEGIN SET @fails += 1; RAISERROR('01: MarkAbsentees marked days outside the employment.', 16, 1); END
IF EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E AND WorkDate <> '2026-09-15')
    BEGIN SET @fails += 1; RAISERROR('01: a record exists outside the employment.', 16, 1); END
IF NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E AND WorkDate = '2026-09-15' AND [Status] = 'Present' AND DayFraction = 1)
    BEGIN SET @fails += 1; RAISERROR('01: the last working day is not a full Present day.', 16, 1); END

/* a record the old rule wrote on the 17th (Absent) with its exit-permission leave posted: re-deriving removes both */
INSERT INTO attendance.ATTENDANCE_RECORD (EmployeeId, ShiftAssignmentId, WorkDate, StandardMinutes, DayFraction, ShortfallMinutes, [Status], [Source], BranchId, ExitLeaveMinutes)
VALUES (@E, (SELECT ShiftAssignmentId FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId = @E AND WorkDate = '2026-09-17'), '2026-09-17', 450, 0, 450, 'Absent', 'Device', @B, 60);
INSERT INTO workflow.REQUEST_INSTANCE (RequestTypeId, WorkflowDefinitionId, EmployeeId, RaisedByUserId, [Status], Title) VALUES (@RT, @WD, @E, @U, 'Approved', N'QA3 exit');
SET @Ri = SCOPE_IDENTITY();
INSERT INTO workflow.EXIT_PERMISSION (RequestInstanceId, EmployeeId, ExitDate, FromTime, ToTime, RequestedMinutes, ApprovedMinutes, Reason, ConvertToLeave)
VALUES (@Ri, @E, '2026-09-17', '10:00', '11:00', 60, 60, N'QA3', 1);
SET @Ep = SCOPE_IDENTITY();
INSERT INTO hr.LEAVE_LEDGER (EmployeeId, LeaveTypeId, PeriodYearMonth, MovementType, Days, EffectiveDate, Note, SourceType, SourceRef)
VALUES (@E, @LT, '2026-09', 'Usage', -0.13, '2026-09-17', N'QA3 posted', 'ExitPermission', @Ep);
EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @E, @WorkDate = '2026-09-17';
IF EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E AND WorkDate = '2026-09-17')
    BEGIN SET @fails += 1; RAISERROR('01: the record after the termination was not removed.', 16, 1); END
IF EXISTS (SELECT 1 FROM hr.LEAVE_LEDGER WHERE SourceType = 'ExitPermission' AND SourceRef = @Ep)
    BEGIN SET @fails += 1; RAISERROR('01: the exit-permission leave posted for the removed day is still on the ledger.', 16, 1); END

/* the refusals (last: a caught refusal leaves the transaction uncommittable, reads still work) */
DECLARE @msg NVARCHAR(2048) = NULL;
BEGIN TRY
    EXEC attendance.usp_Attendance_ManualUpsert @EmployeeId = @E, @WorkDate = '2026-09-18', @FirstInUtc = '2026-09-18 07:00', @LastOutUtc = '2026-09-18 15:00', @Quiet = 1;
END TRY BEGIN CATCH SET @msg = ERROR_MESSAGE(); END CATCH;
IF @msg IS NULL OR @msg NOT LIKE N'%left on 2026-09-15%'
    BEGIN SET @fails += 1; RAISERROR('01: a manual day after the termination was not refused with the sentence (%s).', 16, 1, @msg); END
IF EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E AND WorkDate = '2026-09-18')
    BEGIN SET @fails += 1; RAISERROR('01: the refused manual day was written.', 16, 1); END

IF @@TRANCOUNT > 0 ROLLBACK TRAN;
IF @fails = 0 PRINT 'ok 01_employment_window';
