/* ============================================================================
   tests/qa/cleanup.sql — removes everything the QA suite created ("QA " prefix,
   qa.* users, the QA branch/device/room, QA requests, QA payroll adjustments) and
   restores the two settings seed.sql changed. Then compares every real table's row
   count with the baseline captured by seed.sql and prints PASS/FAIL lines.
   Safe to run at any time; it never touches rows that are not QA rows.
   ============================================================================ */
SET NOCOUNT ON;
GO
DECLARE @Emp TABLE (EmployeeId INT PRIMARY KEY);
INSERT INTO @Emp SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName LIKE N'QA %';
DECLARE @Usr TABLE (UserId INT PRIMARY KEY);
INSERT INTO @Usr SELECT UserId FROM security.[USER] WHERE Username LIKE N'qa.%';
DECLARE @Req TABLE (RequestInstanceId INT PRIMARY KEY);
INSERT INTO @Req
SELECT RequestInstanceId FROM workflow.REQUEST_INSTANCE
WHERE EmployeeId IN (SELECT EmployeeId FROM @Emp) OR RaisedByUserId IN (SELECT UserId FROM @Usr);
DECLARE @Dev TABLE (DeviceId INT PRIMARY KEY);
INSERT INTO @Dev SELECT DeviceId FROM attendance.DEVICE WHERE SerialNumber LIKE 'QA-%';
DECLARE @Room TABLE (RoomId INT PRIMARY KEY);
INSERT INTO @Room SELECT RoomId FROM booking.ROOM WHERE Code = 'qa-room';
DECLARE @Bk TABLE (BookingId INT PRIMARY KEY);
INSERT INTO @Bk SELECT BookingId FROM booking.BOOKING WHERE GuestName LIKE N'QA %' OR RoomId IN (SELECT RoomId FROM @Room);

/* ---- workflow ---- */
UPDATE attendance.ATTENDANCE_RECORD SET ExitPermissionId = NULL WHERE ExitPermissionId IN (SELECT ep.ExitPermissionId FROM workflow.EXIT_PERMISSION ep WHERE ep.RequestInstanceId IN (SELECT RequestInstanceId FROM @Req) OR ep.EmployeeId IN (SELECT EmployeeId FROM @Emp));
UPDATE attendance.ATTENDANCE_RECORD SET OvertimeRequestId = NULL WHERE OvertimeRequestId IN (SELECT o.OvertimeRequestId FROM workflow.OVERTIME_REQUEST o WHERE o.RequestInstanceId IN (SELECT RequestInstanceId FROM @Req));
DELETE FROM core.EMAIL_OUTBOX WHERE RequestInstanceId IN (SELECT RequestInstanceId FROM @Req);
DELETE FROM workflow.WORKFLOW_SIGNATURE WHERE RequestInstanceId IN (SELECT RequestInstanceId FROM @Req);
DELETE FROM workflow.REQUEST_ATTACHMENT WHERE RequestInstanceId IN (SELECT RequestInstanceId FROM @Req);
DELETE FROM workflow.REQUEST_NOTE WHERE RequestInstanceId IN (SELECT RequestInstanceId FROM @Req);
DELETE FROM workflow.REQUEST_REVERSAL WHERE RequestInstanceId IN (SELECT RequestInstanceId FROM @Req);
DELETE FROM workflow.DECISION_DETAIL WHERE RequestInstanceId IN (SELECT RequestInstanceId FROM @Req);
DELETE FROM workflow.REQUEST_STEP_INSTANCE WHERE RequestInstanceId IN (SELECT RequestInstanceId FROM @Req);
DELETE FROM workflow.LEAVE_REQUEST WHERE RequestInstanceId IN (SELECT RequestInstanceId FROM @Req) OR EmployeeId IN (SELECT EmployeeId FROM @Emp);
DELETE FROM workflow.EXIT_PERMISSION WHERE RequestInstanceId IN (SELECT RequestInstanceId FROM @Req) OR EmployeeId IN (SELECT EmployeeId FROM @Emp);
DELETE FROM workflow.ROSTER_APPROVAL WHERE RequestInstanceId IN (SELECT RequestInstanceId FROM @Req);
DELETE FROM workflow.OVERTIME_REQUEST WHERE RequestInstanceId IN (SELECT RequestInstanceId FROM @Req);
DELETE FROM workflow.EXPENSE_REIMBURSEMENT WHERE RequestInstanceId IN (SELECT RequestInstanceId FROM @Req);
DELETE FROM workflow.SALARY_ADVANCE_REQUEST WHERE RequestInstanceId IN (SELECT RequestInstanceId FROM @Req);
DELETE FROM workflow.PAYROLL_ADJUSTMENT_REQUEST WHERE RequestInstanceId IN (SELECT RequestInstanceId FROM @Req);
DELETE FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId IN (SELECT RequestInstanceId FROM @Req);

/* ---- leave ---- */
DELETE FROM hr.LEAVE_LEDGER WHERE EmployeeId IN (SELECT EmployeeId FROM @Emp);

/* ---- attendance ---- */
DELETE i FROM attendance.ATTENDANCE_INTERVAL i JOIN attendance.ATTENDANCE_RECORD a ON a.AttendanceId = i.AttendanceId WHERE a.EmployeeId IN (SELECT EmployeeId FROM @Emp);
DELETE c FROM attendance.ATTENDANCE_CORRECTION c JOIN attendance.ATTENDANCE_RECORD a ON a.AttendanceId = c.AttendanceId WHERE a.EmployeeId IN (SELECT EmployeeId FROM @Emp);
DELETE FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId IN (SELECT EmployeeId FROM @Emp);
DELETE FROM attendance.RAW_DEVICE_LOG WHERE [Source] = 'QA' OR DeviceId IN (SELECT DeviceId FROM @Dev) OR EmployeeId IN (SELECT EmployeeId FROM @Emp);
DELETE FROM attendance.EMPLOYEE_DEVICE WHERE DeviceId IN (SELECT DeviceId FROM @Dev) OR EmployeeId IN (SELECT EmployeeId FROM @Emp);
DELETE FROM attendance.DEVICE WHERE DeviceId IN (SELECT DeviceId FROM @Dev);
DELETE FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId IN (SELECT EmployeeId FROM @Emp);
DELETE FROM attendance.EMPLOYEE_SHIFT_PATTERN WHERE EmployeeId IN (SELECT EmployeeId FROM @Emp);
DELETE FROM attendance.ROSTER_MONTH WHERE BranchId IN (SELECT BranchId FROM hr.BRANCH WHERE Name = N'QA Branch');

/* ---- payroll ---- */
DECLARE @QaRuns TABLE (PayrollRunId INT PRIMARY KEY);
INSERT INTO @QaRuns SELECT PayrollRunId FROM payroll.PAYROLL_RUN WHERE Notes LIKE N'QA %';
DELETE l FROM payroll.PAYSLIP_LINE l JOIN payroll.PAYSLIP p ON p.PayslipId = l.PayslipId
WHERE p.EmployeeId IN (SELECT EmployeeId FROM @Emp) OR p.PayrollRunId IN (SELECT PayrollRunId FROM @QaRuns);
UPDATE payroll.PAYROLL_ADJUSTMENT SET AppliedToPayslipId = NULL
WHERE AppliedToPayslipId IN (SELECT PayslipId FROM payroll.PAYSLIP WHERE EmployeeId IN (SELECT EmployeeId FROM @Emp) OR PayrollRunId IN (SELECT PayrollRunId FROM @QaRuns));
DELETE FROM payroll.PAYSLIP WHERE EmployeeId IN (SELECT EmployeeId FROM @Emp) OR PayrollRunId IN (SELECT PayrollRunId FROM @QaRuns);
DELETE FROM payroll.PAYROLL_RUN_EVENT WHERE PayrollRunId IN (SELECT PayrollRunId FROM @QaRuns);
DELETE FROM payroll.PAYROLL_RUN_RATE WHERE PayrollRunId IN (SELECT PayrollRunId FROM @QaRuns);
DELETE FROM payroll.PAYROLL_RUN WHERE PayrollRunId IN (SELECT PayrollRunId FROM @QaRuns);
DELETE FROM payroll.PAYROLL_ADJUSTMENT WHERE EmployeeId IN (SELECT EmployeeId FROM @Emp) OR Reason LIKE N'QA %';
DELETE FROM payroll.SALARY_ADVANCE WHERE EmployeeId IN (SELECT EmployeeId FROM @Emp);
DELETE FROM hr.SALARY_COMPONENT WHERE EmployeeId IN (SELECT EmployeeId FROM @Emp);
DELETE FROM hr.DOCUMENT WHERE EmployeeId IN (SELECT EmployeeId FROM @Emp);
DELETE FROM core.EXCHANGE_RATE WHERE FromCurrency = 'EUR' AND ToCurrency = 'USD' AND RateType = 'NonOfficial' AND Rate = 1.2345;

/* ---- bookings ---- */
DELETE FROM core.EMAIL_OUTBOX WHERE BookingId IN (SELECT BookingId FROM @Bk);
DELETE FROM booking.BOOKING_PAYMENT WHERE BookingId IN (SELECT BookingId FROM @Bk);
DELETE FROM booking.BOOKING_ADDON WHERE BookingId IN (SELECT BookingId FROM @Bk);
DELETE FROM booking.BOOKING WHERE BookingId IN (SELECT BookingId FROM @Bk);
DELETE FROM booking.BOOKING_BLOCK WHERE RoomId IN (SELECT RoomId FROM @Room);
DELETE FROM booking.ROOM_ADDON WHERE RoomId IN (SELECT RoomId FROM @Room);
DELETE FROM booking.ROOM_DISCOUNT WHERE RoomId IN (SELECT RoomId FROM @Room);
DELETE FROM booking.ROOM_HOURS WHERE RoomId IN (SELECT RoomId FROM @Room);
DELETE FROM booking.ROOM WHERE RoomId IN (SELECT RoomId FROM @Room);

/* ---- people ---- */
UPDATE hr.BRANCH SET ManagerEmployeeId = NULL WHERE ManagerEmployeeId IN (SELECT EmployeeId FROM @Emp);
UPDATE hr.EMPLOYEE SET ReportsToEmployeeId = NULL WHERE ReportsToEmployeeId IN (SELECT EmployeeId FROM @Emp);
DELETE FROM hr.EMPLOYEE WHERE EmployeeId IN (SELECT EmployeeId FROM @Emp);
DELETE FROM hr.BRANCH WHERE Name = N'QA Branch';
DELETE FROM security.REFRESH_TOKEN WHERE UserId IN (SELECT UserId FROM @Usr);
DELETE FROM security.USER_SIGNATURE WHERE UserId IN (SELECT UserId FROM @Usr);
DELETE FROM security.USER_ROLE WHERE UserId IN (SELECT UserId FROM @Usr);
DELETE FROM security.[USER] WHERE UserId IN (SELECT UserId FROM @Usr);
GO

/* ---- restore settings ---- */
IF OBJECT_ID('dbo.QA_STATE') IS NOT NULL
BEGIN
    UPDATE s SET s.SettingValue = q.[Value]
    FROM core.SETTING s JOIN dbo.QA_STATE q ON q.[Key] = 'setting.' + s.SettingKey
    WHERE q.[Value] IS NOT NULL;
END
GO

/* ---- compare row counts with the baseline captured by seed.sql ---- */
IF OBJECT_ID('dbo.QA_STATE') IS NOT NULL
BEGIN
    DECLARE @bad INT = 0, @lines NVARCHAR(MAX) = N'';
    ;WITH now AS (
        SELECT 'baseline.' + s.name + '.' + t.name AS [Key], SUM(p.rows) AS n
        FROM sys.tables t JOIN sys.schemas s ON s.schema_id = t.schema_id
        JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0,1)
        WHERE t.name NOT LIKE 'QA[_]%'
        GROUP BY s.name, t.name)
    SELECT @bad = COUNT(*),
           @lines = STRING_AGG(CONCAT(q.[Key], ' baseline=', q.[Value], ' now=', now.n), CHAR(10))
    FROM dbo.QA_STATE q JOIN now ON now.[Key] = q.[Key]
    WHERE q.[Key] LIKE 'baseline.%.%' AND CAST(q.[Value] AS BIGINT) <> now.n;
    PRINT CONCAT(CASE WHEN @bad = 0 THEN 'PASS' ELSE 'FAIL' END,
                 ' | CLEANUP | real-data row counts unchanged after cleanup | expected=all tables equal baseline | actual=',
                 CASE WHEN @bad = 0 THEN 'all equal' ELSE CONCAT(@bad, ' table(s) differ: ', CHAR(10), @lines) END);
    DECLARE @cs NVARCHAR(50) = CAST((SELECT CHECKSUM_AGG(CHECKSUM(EmployeeId, ShiftId, WorkDate, IsRestDay)) FROM attendance.SHIFT_ASSIGNMENT) AS NVARCHAR(50));
    DECLARE @cs0 NVARCHAR(50) = (SELECT [Value] FROM dbo.QA_STATE WHERE [Key] = 'baseline.nonqa.shift_assignment_checksum');
    PRINT CONCAT(CASE WHEN @cs = @cs0 THEN 'PASS' ELSE 'FAIL' END,
                 ' | CLEANUP | non-QA roster rows unchanged (checksum) | expected=', @cs0, ' | actual=', @cs);
END
GO
DROP PROCEDURE IF EXISTS dbo.QA_Check;
DROP PROCEDURE IF EXISTS dbo.QA_Note;
DROP TABLE IF EXISTS dbo.QA_RESULT;
DROP TABLE IF EXISTS dbo.QA_STATE;
PRINT 'CLEANUP DONE';
GO
