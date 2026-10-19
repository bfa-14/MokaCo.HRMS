/* QA3 attendance (unit B) - ATT-9 (variance rulings: 'Overtime' absorbs the variance from the overtime; only the
   permission minutes used become leave), ATT-15 / LEV-15 (the period-close posting answers with its real count, one
   result set), REL-13 (a posted day that changes is posted again), REL-4 (requests outside the employment) and the
   exit-permission overlap with an OnHold request.
   Runs on a dev database with docs/100_qa3_attendance.sql applied, inside a transaction that is rolled back. */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
BEGIN TRAN;
DECLARE @fails INT = 0, @msg NVARCHAR(2048);
DECLARE @B INT, @E1 INT, @E2 INT, @E3 INT, @E4 INT, @S INT, @Dev INT, @U INT, @RT INT, @WD INT, @LT INT, @Ri INT, @Ep2 INT, @Ep3 INT, @A INT;
DECLARE @Today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE);
DECLARE @D DATE = '2026-09-08';
DECLARE @posted TABLE (LeaveMovementsPosted INT);
DECLARE @o TABLE (c1 BIGINT, c2 INT, c3 INT, c4 INT, c5 INT, c6 VARCHAR(20), c7 INT, c8 DECIMAL(5,2), c9 BIT, c10 INT, c11 VARCHAR(20));
INSERT INTO hr.BRANCH (Name) VALUES (N'QA3 Att Branch'); SET @B = SCOPE_IDENTITY();
INSERT INTO hr.EMPLOYEE (BranchId, DepartmentId, PositionId, FullName, HireDate, TerminationDate)
SELECT @B, (SELECT TOP 1 DepartmentId FROM hr.DEPARTMENT ORDER BY DepartmentId), (SELECT TOP 1 PositionId FROM hr.POSITION ORDER BY PositionId), v.n, '2025-01-01', v.t
FROM (VALUES (N'QA3 Att Exit 1', NULL), (N'QA3 Att Exit 2', NULL), (N'QA3 Att Exit 3', NULL), (N'QA3 Att Exit 4', DATEADD(DAY, -1, @Today))) v(n, t);
SELECT @E1 = EmployeeId FROM hr.EMPLOYEE WHERE BranchId = @B AND FullName = N'QA3 Att Exit 1';
SELECT @E2 = EmployeeId FROM hr.EMPLOYEE WHERE BranchId = @B AND FullName = N'QA3 Att Exit 2';
SELECT @E3 = EmployeeId FROM hr.EMPLOYEE WHERE BranchId = @B AND FullName = N'QA3 Att Exit 3';
SELECT @E4 = EmployeeId FROM hr.EMPLOYEE WHERE BranchId = @B AND FullName = N'QA3 Att Exit 4';
INSERT INTO attendance.SHIFT (Name, StartTime, EndTime, GraceMinutes, CrossesMidnight, BreakMinutes) VALUES (N'QA3 07-15', '07:00', '15:00', NULL, 0, 30);
SET @S = SCOPE_IDENTITY();
INSERT INTO attendance.ROSTER_MONTH (BranchId, MonthDate, [Status]) VALUES (@B, '2026-09-01', 'Approved');
INSERT INTO attendance.SHIFT_ASSIGNMENT (EmployeeId, ShiftId, WorkDate, IsRestDay) VALUES (@E1, @S, @D, 0), (@E2, @S, @D, 0), (@E3, @S, @D, 0);
INSERT INTO attendance.DEVICE (SerialNumber, BranchId, [Name]) VALUES (CONCAT('QA3-ATT-', @B), @B, N'QA3 device'); SET @Dev = SCOPE_IDENTITY();
SET @U = (SELECT TOP 1 UserId FROM security.[USER] ORDER BY UserId);
SELECT TOP 1 @WD = WorkflowDefinitionId, @RT = RequestTypeId FROM workflow.WORKFLOW_DEFINITION ORDER BY WorkflowDefinitionId;
INSERT INTO hr.LEAVE_TYPE (Name, IsPaid) VALUES (N'QA3 Annual', 1); SET @LT = SCOPE_IDENTITY();
INSERT INTO hr.LEAVE_LEDGER (EmployeeId, LeaveTypeId, PeriodYearMonth, MovementType, Days, EffectiveDate, Note)
VALUES (@E2, @LT, '2026-01', 'Adjustment', 21, '2026-01-01', N'QA3 opening');            -- E3 has no balance at all

/* E1: approved overtime 120; 07:00-12:00, 13:30-17:00 = 60 min of mid-day absence beyond the break, 120 after the shift */
INSERT INTO workflow.REQUEST_INSTANCE (RequestTypeId, WorkflowDefinitionId, EmployeeId, RaisedByUserId, [Status], Title) VALUES (@RT, @WD, @E1, @U, 'Approved', N'QA3 ot');
INSERT INTO workflow.OVERTIME_REQUEST (RequestInstanceId, EmployeeId, WorkDate, RequestedMinutes, ApprovedMinutes) VALUES (SCOPE_IDENTITY(), @E1, @D, 120, 120);
/* E2 and E3: a convert-to-leave permission 07:00-07:20 for a late start, the same 60-minute lunch beyond the break */
INSERT INTO workflow.REQUEST_INSTANCE (RequestTypeId, WorkflowDefinitionId, EmployeeId, RaisedByUserId, [Status], Title) VALUES (@RT, @WD, @E2, @U, 'Approved', N'QA3 exit');
INSERT INTO workflow.EXIT_PERMISSION (RequestInstanceId, EmployeeId, ExitDate, FromTime, ToTime, RequestedMinutes, ApprovedMinutes, Reason, ConvertToLeave)
VALUES (SCOPE_IDENTITY(), @E2, @D, '07:00', '07:20', 20, 20, N'QA3', 1);
SET @Ep2 = SCOPE_IDENTITY();
INSERT INTO workflow.REQUEST_INSTANCE (RequestTypeId, WorkflowDefinitionId, EmployeeId, RaisedByUserId, [Status], Title) VALUES (@RT, @WD, @E3, @U, 'Approved', N'QA3 exit');
INSERT INTO workflow.EXIT_PERMISSION (RequestInstanceId, EmployeeId, ExitDate, FromTime, ToTime, RequestedMinutes, ApprovedMinutes, Reason, ConvertToLeave)
VALUES (SCOPE_IDENTITY(), @E3, @D, '07:00', '07:20', 20, 20, N'QA3', 1);
SET @Ep3 = SCOPE_IDENTITY();
INSERT INTO attendance.RAW_DEVICE_LOG (DeviceId, EnrollPin, EmployeeId, PunchTimeUtc, PunchType, [Source], DedupHash)
SELECT @Dev, 'QA3', p.E, p.T, p.K, 'Device', CONVERT(VARCHAR(64), NEWID())
FROM (VALUES (@E1, '2026-09-08 07:00', 0), (@E1, '2026-09-08 12:00', 1), (@E1, '2026-09-08 13:30', 0), (@E1, '2026-09-08 17:00', 1),
             (@E2, '2026-09-08 07:20', 0), (@E2, '2026-09-08 12:00', 1), (@E2, '2026-09-08 13:30', 0), (@E2, '2026-09-08 15:00', 1),
             (@E3, '2026-09-08 07:20', 0), (@E3, '2026-09-08 12:00', 1), (@E3, '2026-09-08 13:30', 0), (@E3, '2026-09-08 15:00', 1)) p(E, T, K);
EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @E1, @WorkDate = @D;
EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @E2, @WorkDate = @D;
EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @E3, @WorkDate = @D;

/* ATT-9: E1's variance ruled 'Overtime' comes out of the overtime; E2's ruled unpaid and E3's ignored are not leave */
SET @A = (SELECT AttendanceId FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E1 AND WorkDate = @D);
INSERT INTO @o EXEC attendance.usp_Attendance_SetExitDisposition @AttendanceId = @A, @Disposition = 'Overtime';
IF NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD WHERE AttendanceId = @A AND OvertimeMinutes = 60 AND DayFraction = 1 AND ExitLeaveMinutes = 0)
    BEGIN SET @fails += 1; RAISERROR('06: the variance ruled Overtime was not absorbed from the overtime (expected OT 60, day 1.00).', 16, 1); END
SET @A = (SELECT AttendanceId FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E2 AND WorkDate = @D);
INSERT INTO @o EXEC attendance.usp_Attendance_SetExitDisposition @AttendanceId = @A, @Disposition = 'UnpaidAbsence';
IF NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD WHERE AttendanceId = @A AND ExitLeaveMinutes = 20 AND ShortfallMinutes = 60)
    BEGIN SET @fails += 1; RAISERROR('06: the unpaid variance is converted to leave as well (expected 20 leave minutes, 60 short).', 16, 1); END
SET @A = (SELECT AttendanceId FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E3 AND WorkDate = @D);
INSERT INTO @o EXEC attendance.usp_Attendance_SetExitDisposition @AttendanceId = @A, @Disposition = 'Ignore';
IF NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD WHERE AttendanceId = @A AND ExitLeaveMinutes = 20 AND DayFraction = 1)
    BEGIN SET @fails += 1; RAISERROR('06: the ignored variance is converted to leave (expected 20 leave minutes, day 1.00).', 16, 1); END

/* ATT-15: the period close answers with ONE result set and its real count (E2 from the balance, E3 unpaid only) */
INSERT INTO @posted EXEC workflow.usp_ExitPermission_PostLeaveUsage @PeriodYearMonth = '2026-09', @LeaveTypeId = @LT, @PostedBy = @U;
IF (SELECT LeaveMovementsPosted FROM @posted) <> 1
    BEGIN SET @fails += 1; RAISERROR('06: the period close did not answer with its real count (1 ledger movement).', 16, 1); END
IF NOT EXISTS (SELECT 1 FROM hr.LEAVE_LEDGER WHERE SourceType = 'ExitPermission' AND SourceRef = @Ep2 AND Days = -core.fn_MinutesToLeaveDays(20))
   OR NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E3 AND WorkDate = @D AND ExitUnpaidDays = core.fn_MinutesToLeaveDays(20))
    BEGIN SET @fails += 1; RAISERROR('06: the period close did not post E2 from the balance and E3 as unpaid.', 16, 1); END
DELETE FROM @posted;
INSERT INTO @posted EXEC workflow.usp_ExitPermission_PostLeaveUsage @PeriodYearMonth = '2026-09', @LeaveTypeId = @LT, @PostedBy = @U;
IF (SELECT LeaveMovementsPosted FROM @posted) <> 0
    BEGIN SET @fails += 1; RAISERROR('06: posting the period again posted something.', 16, 1); END

/* REL-13: the approver cut E2's permission to 10 minutes after the close: the posting follows; E3's is taken back
   (the request reopened and rejected): its unpaid posting goes */
UPDATE workflow.EXIT_PERMISSION SET ApprovedMinutes = 10 WHERE ExitPermissionId = @Ep2;
EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @E2, @WorkDate = @D;
IF (SELECT COUNT(*) FROM hr.LEAVE_LEDGER WHERE SourceType = 'ExitPermission' AND SourceRef = @Ep2) <> 1
   OR NOT EXISTS (SELECT 1 FROM hr.LEAVE_LEDGER WHERE SourceType = 'ExitPermission' AND SourceRef = @Ep2 AND Days = -core.fn_MinutesToLeaveDays(10))
    BEGIN SET @fails += 1; RAISERROR('06: the posting did not follow the day (expected one row of 10 minutes).', 16, 1); END
UPDATE workflow.REQUEST_INSTANCE SET [Status] = 'Rejected' WHERE RequestInstanceId = (SELECT RequestInstanceId FROM workflow.EXIT_PERMISSION WHERE ExitPermissionId = @Ep3);
EXEC attendance.usp_Attendance_ComputeDay @EmployeeId = @E3, @WorkDate = @D;
IF NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = @E3 AND WorkDate = @D AND ExitUnpaidDays IS NULL AND ExitLeaveMinutes = 0)
    BEGIN SET @fails += 1; RAISERROR('06: the unpaid posting of a day whose permission was taken back stayed.', 16, 1); END

/* the refusals (last): REL-4 outside the employment, and an overlap with a request On hold */
INSERT INTO workflow.REQUEST_INSTANCE (RequestTypeId, WorkflowDefinitionId, EmployeeId, RaisedByUserId, [Status], Title) VALUES (@RT, @WD, @E2, @U, 'OnHold', N'QA3 hold');
INSERT INTO workflow.EXIT_PERMISSION (RequestInstanceId, EmployeeId, ExitDate, FromTime, ToTime, RequestedMinutes, ApprovedMinutes, Reason, ConvertToLeave)
VALUES (SCOPE_IDENTITY(), @E2, DATEADD(DAY, 3, @Today), '10:00', '11:00', 60, 60, N'QA3', 1);
SET @msg = NULL;
BEGIN TRY EXEC workflow.usp_ExitPermission_Create @EmployeeId = @E2, @RaisedByUserId = @U, @ExitDate = @Today, @FromTime = '10:30', @ToTime = '11:30', @Reason = N'QA3';
END TRY BEGIN CATCH SET @msg = ERROR_MESSAGE(); END CATCH;
IF @msg IS NOT NULL AND @msg LIKE N'%overlaps%'
    BEGIN SET @fails += 1; RAISERROR('06: a permission on another day was refused as an overlap.', 16, 1); END
SET @msg = NULL;
DECLARE @D3 DATE = DATEADD(DAY, 3, @Today);
BEGIN TRY EXEC workflow.usp_ExitPermission_Create @EmployeeId = @E2, @RaisedByUserId = @U, @ExitDate = @D3, @FromTime = '10:30', @ToTime = '11:30', @Reason = N'QA3';
END TRY BEGIN CATCH SET @msg = ERROR_MESSAGE(); END CATCH;
IF @msg IS NULL OR @msg NOT LIKE N'%on-hold%overlaps%'
    BEGIN SET @fails += 1; RAISERROR('06: a permission overlapping one On hold was not refused (%s).', 16, 1, @msg); END
SET @msg = NULL;
BEGIN TRY EXEC workflow.usp_ExitPermission_Create @EmployeeId = @E4, @RaisedByUserId = @U, @ExitDate = @Today, @FromTime = '10:00', @ToTime = '11:00', @Reason = N'QA3';
END TRY BEGIN CATCH SET @msg = ERROR_MESSAGE(); END CATCH;
IF @msg IS NULL OR @msg NOT LIKE N'%leaves on%no working day%'
    BEGIN SET @fails += 1; RAISERROR('06: an exit permission after the termination was not refused (%s).', 16, 1, @msg); END
SET @msg = NULL;
DECLARE @D5 DATE = DATEADD(DAY, 5, @Today);
BEGIN TRY EXEC workflow.usp_Overtime_Create @EmployeeId = @E4, @RaisedByUserId = @U, @WorkDate = @D5, @RequestedMinutes = 60, @Reason = N'QA3';
END TRY BEGIN CATCH SET @msg = ERROR_MESSAGE(); END CATCH;
IF @msg IS NULL OR @msg NOT LIKE N'%leaves on%no working day%'
    BEGIN SET @fails += 1; RAISERROR('06: overtime after the termination was not refused (%s).', 16, 1, @msg); END

IF @@TRANCOUNT > 0 ROLLBACK TRAN;
IF @fails = 0 PRINT 'ok 06_exit_permissions';
