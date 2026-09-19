/* ============================================================================
   tests/qa2/cleanup.sql — removes everything the QA2 suite created ("QA2 " prefix, qa2.* users, the two
   QA2 branches, shifts, device, holidays, requests, payroll rows). Then compares every real table's row
   count — and checksums of the rosters, the attendance records and the leave ledger — with the baseline
   captured by seed.sql, and prints PASS/FAIL lines.
   Safe to run at any time; it never touches a row that is not a QA2 row. Objects that a later script adds
   (core.HOLIDAY, hr.EMPLOYEE_BRANCH_HISTORY) are cleaned when they exist.
   ============================================================================ */
SET NOCOUNT ON;
GO
DECLARE @Emp TABLE (EmployeeId INT PRIMARY KEY);
INSERT INTO @Emp SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName LIKE N'QA2 %';
DECLARE @Usr TABLE (UserId INT PRIMARY KEY);
INSERT INTO @Usr SELECT UserId FROM security.[USER] WHERE Username LIKE N'qa2.%';
DECLARE @Br TABLE (BranchId INT PRIMARY KEY);
INSERT INTO @Br SELECT BranchId FROM hr.BRANCH WHERE Name LIKE N'QA2 %';
DECLARE @Req TABLE (RequestInstanceId INT PRIMARY KEY);
INSERT INTO @Req
SELECT RequestInstanceId FROM workflow.REQUEST_INSTANCE
WHERE EmployeeId IN (SELECT EmployeeId FROM @Emp) OR RaisedByUserId IN (SELECT UserId FROM @Usr);
DECLARE @Dev TABLE (DeviceId INT PRIMARY KEY);
INSERT INTO @Dev SELECT DeviceId FROM attendance.DEVICE WHERE SerialNumber LIKE 'QA2-%';

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
DELETE FROM hr.LEAVE_LEDGER WHERE EmployeeId IN (SELECT EmployeeId FROM @Emp);
DELETE FROM workflow.LEAVE_REQUEST WHERE RequestInstanceId IN (SELECT RequestInstanceId FROM @Req) OR EmployeeId IN (SELECT EmployeeId FROM @Emp);
DELETE FROM workflow.EXIT_PERMISSION WHERE RequestInstanceId IN (SELECT RequestInstanceId FROM @Req) OR EmployeeId IN (SELECT EmployeeId FROM @Emp);
DELETE FROM workflow.ROSTER_APPROVAL WHERE RequestInstanceId IN (SELECT RequestInstanceId FROM @Req);
DELETE FROM workflow.OVERTIME_REQUEST WHERE RequestInstanceId IN (SELECT RequestInstanceId FROM @Req) OR EmployeeId IN (SELECT EmployeeId FROM @Emp);
DELETE FROM workflow.SHIFT_SWAP WHERE RequestInstanceId IN (SELECT RequestInstanceId FROM @Req) OR RequesterEmployeeId IN (SELECT EmployeeId FROM @Emp) OR CounterpartEmployeeId IN (SELECT EmployeeId FROM @Emp);
DELETE FROM workflow.SEPARATION WHERE RequestInstanceId IN (SELECT RequestInstanceId FROM @Req) OR EmployeeId IN (SELECT EmployeeId FROM @Emp);
DELETE FROM workflow.EXPENSE_REIMBURSEMENT WHERE RequestInstanceId IN (SELECT RequestInstanceId FROM @Req);
DELETE FROM workflow.SALARY_ADVANCE_REQUEST WHERE RequestInstanceId IN (SELECT RequestInstanceId FROM @Req) OR EmployeeId IN (SELECT EmployeeId FROM @Emp);
DELETE FROM workflow.PAYROLL_ADJUSTMENT_REQUEST WHERE RequestInstanceId IN (SELECT RequestInstanceId FROM @Req) OR EmployeeId IN (SELECT EmployeeId FROM @Emp);

/* ---- payroll ---- */
DECLARE @QaRuns TABLE (PayrollRunId INT PRIMARY KEY);
INSERT INTO @QaRuns SELECT PayrollRunId FROM payroll.PAYROLL_RUN WHERE Notes LIKE N'QA2 %';
DELETE l FROM payroll.PAYSLIP_LINE l JOIN payroll.PAYSLIP p ON p.PayslipId = l.PayslipId
WHERE p.EmployeeId IN (SELECT EmployeeId FROM @Emp) OR p.PayrollRunId IN (SELECT PayrollRunId FROM @QaRuns);
UPDATE payroll.PAYROLL_ADJUSTMENT SET AppliedToPayslipId = NULL
WHERE AppliedToPayslipId IN (SELECT PayslipId FROM payroll.PAYSLIP WHERE EmployeeId IN (SELECT EmployeeId FROM @Emp) OR PayrollRunId IN (SELECT PayrollRunId FROM @QaRuns));
DELETE FROM payroll.PAYSLIP WHERE EmployeeId IN (SELECT EmployeeId FROM @Emp) OR PayrollRunId IN (SELECT PayrollRunId FROM @QaRuns);
DELETE FROM payroll.PAYROLL_RUN_EVENT WHERE PayrollRunId IN (SELECT PayrollRunId FROM @QaRuns);
DELETE FROM payroll.PAYROLL_RUN_RATE WHERE PayrollRunId IN (SELECT PayrollRunId FROM @QaRuns);
DELETE FROM payroll.PAYROLL_RUN WHERE PayrollRunId IN (SELECT PayrollRunId FROM @QaRuns);
DELETE FROM payroll.PAYROLL_ADJUSTMENT WHERE EmployeeId IN (SELECT EmployeeId FROM @Emp) OR Reason LIKE N'QA2 %';
DELETE FROM payroll.SALARY_ADVANCE WHERE EmployeeId IN (SELECT EmployeeId FROM @Emp);
DELETE FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId IN (SELECT RequestInstanceId FROM @Req);
DELETE FROM hr.SALARY_COMPONENT WHERE EmployeeId IN (SELECT EmployeeId FROM @Emp);
DELETE FROM hr.DOCUMENT WHERE EmployeeId IN (SELECT EmployeeId FROM @Emp);

/* ---- attendance ---- */
DELETE FROM attendance.ATTENDANCE_ANOMALY WHERE EmployeeId IN (SELECT EmployeeId FROM @Emp);
DELETE i FROM attendance.ATTENDANCE_INTERVAL i JOIN attendance.ATTENDANCE_RECORD a ON a.AttendanceId = i.AttendanceId WHERE a.EmployeeId IN (SELECT EmployeeId FROM @Emp);
DELETE c FROM attendance.ATTENDANCE_CORRECTION c JOIN attendance.ATTENDANCE_RECORD a ON a.AttendanceId = c.AttendanceId WHERE a.EmployeeId IN (SELECT EmployeeId FROM @Emp);
DELETE FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId IN (SELECT EmployeeId FROM @Emp);
DELETE FROM attendance.RAW_DEVICE_LOG WHERE [Source] = 'QA2' OR DeviceId IN (SELECT DeviceId FROM @Dev) OR EmployeeId IN (SELECT EmployeeId FROM @Emp);
DELETE FROM attendance.EMPLOYEE_DEVICE WHERE DeviceId IN (SELECT DeviceId FROM @Dev) OR EmployeeId IN (SELECT EmployeeId FROM @Emp);
DELETE FROM attendance.DEVICE WHERE DeviceId IN (SELECT DeviceId FROM @Dev);
DELETE FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId IN (SELECT EmployeeId FROM @Emp);
DELETE FROM attendance.EMPLOYEE_SHIFT_PATTERN WHERE EmployeeId IN (SELECT EmployeeId FROM @Emp);
DELETE FROM attendance.ROSTER_MONTH WHERE BranchId IN (SELECT BranchId FROM @Br);
DELETE FROM attendance.SHIFT WHERE Name LIKE N'QA2 %';

/* ---- objects added by the QA2 feature scripts, when they exist ---- */
IF OBJECT_ID('core.HOLIDAY') IS NOT NULL
    EXEC sp_executesql N'DELETE FROM core.HOLIDAY WHERE Name LIKE N''QA2 %'' OR BranchId IN (SELECT BranchId FROM hr.BRANCH WHERE Name LIKE N''QA2 %'')';
IF OBJECT_ID('hr.EMPLOYEE_BRANCH_HISTORY') IS NOT NULL
    EXEC sp_executesql N'DELETE FROM hr.EMPLOYEE_BRANCH_HISTORY WHERE EmployeeId IN (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName LIKE N''QA2 %'') OR BranchId IN (SELECT BranchId FROM hr.BRANCH WHERE Name LIKE N''QA2 %'')';

/* ---- people ---- */
UPDATE hr.BRANCH SET ManagerEmployeeId = NULL WHERE ManagerEmployeeId IN (SELECT EmployeeId FROM @Emp);
UPDATE hr.EMPLOYEE SET ReportsToEmployeeId = NULL WHERE ReportsToEmployeeId IN (SELECT EmployeeId FROM @Emp);
DELETE FROM hr.EMPLOYEE WHERE EmployeeId IN (SELECT EmployeeId FROM @Emp);
DELETE FROM hr.BRANCH WHERE BranchId IN (SELECT BranchId FROM @Br);
DELETE FROM security.REFRESH_TOKEN WHERE UserId IN (SELECT UserId FROM @Usr);
DELETE FROM security.USER_SIGNATURE WHERE UserId IN (SELECT UserId FROM @Usr);
DELETE FROM security.USER_ROLE WHERE UserId IN (SELECT UserId FROM @Usr);
DELETE FROM security.[USER] WHERE UserId IN (SELECT UserId FROM @Usr);
GO

/* ---- compare with the baseline captured by seed.sql ---- */
IF OBJECT_ID('dbo.QA2_STATE') IS NOT NULL
BEGIN
    DECLARE @bad INT = 0, @lines NVARCHAR(MAX) = N'';
    ;WITH now AS (
        SELECT 'baseline.' + s.name + '.' + t.name AS [Key], SUM(p.rows) AS n
        FROM sys.tables t JOIN sys.schemas s ON s.schema_id = t.schema_id
        JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0,1)
        WHERE t.name NOT LIKE 'QA2[_]%' AND t.name NOT LIKE 'QA[_]%'
        GROUP BY s.name, t.name)
    SELECT @bad = COUNT(*),
           @lines = STRING_AGG(CONCAT(q.[Key], ' baseline=', q.[Value], ' now=', now.n), CHAR(10))
    FROM dbo.QA2_STATE q JOIN now ON now.[Key] = q.[Key]
    WHERE q.[Key] LIKE 'baseline.%.%' AND q.[Key] NOT LIKE 'baseline.nonqa.%' AND CAST(q.[Value] AS BIGINT) <> now.n;
    PRINT CONCAT(CASE WHEN @bad = 0 THEN 'PASS' ELSE 'FAIL' END,
                 ' | CLEANUP | real-data row counts unchanged after cleanup | expected=all tables equal baseline | actual=',
                 CASE WHEN @bad = 0 THEN 'all equal' ELSE CONCAT(@bad, ' table(s) differ: ', CHAR(10), @lines) END);

    DECLARE @c1 NVARCHAR(50) = CAST((SELECT CHECKSUM_AGG(CHECKSUM(EmployeeId, ShiftId, WorkDate, IsRestDay)) FROM attendance.SHIFT_ASSIGNMENT) AS NVARCHAR(50));
    DECLARE @c2 NVARCHAR(50) = CAST((SELECT CHECKSUM_AGG(CHECKSUM(EmployeeId, WorkDate, [Status], WorkedMinutes, DayFraction)) FROM attendance.ATTENDANCE_RECORD) AS NVARCHAR(50));
    DECLARE @c3 NVARCHAR(50) = CAST((SELECT CHECKSUM_AGG(CHECKSUM(EmployeeId, LeaveTypeId, MovementType, Days, EffectiveDate)) FROM hr.LEAVE_LEDGER) AS NVARCHAR(50));
    DECLARE @b1 NVARCHAR(50) = (SELECT [Value] FROM dbo.QA2_STATE WHERE [Key] = 'baseline.nonqa.shift_assignment_checksum');
    DECLARE @b2 NVARCHAR(50) = (SELECT [Value] FROM dbo.QA2_STATE WHERE [Key] = 'baseline.nonqa.attendance_checksum');
    DECLARE @b3 NVARCHAR(50) = (SELECT [Value] FROM dbo.QA2_STATE WHERE [Key] = 'baseline.nonqa.ledger_checksum');
    PRINT CONCAT(CASE WHEN ISNULL(@c1,'') = ISNULL(@b1,'') THEN 'PASS' ELSE 'FAIL' END, ' | CLEANUP | real roster rows unchanged (checksum) | expected=', @b1, ' | actual=', @c1);
    PRINT CONCAT(CASE WHEN ISNULL(@c2,'') = ISNULL(@b2,'') THEN 'PASS' ELSE 'FAIL' END, ' | CLEANUP | real attendance records unchanged (checksum) | expected=', @b2, ' | actual=', @c2);
    PRINT CONCAT(CASE WHEN ISNULL(@c3,'') = ISNULL(@b3,'') THEN 'PASS' ELSE 'FAIL' END, ' | CLEANUP | real leave ledger unchanged (checksum) | expected=', @b3, ' | actual=', @c3);
END
GO
DROP PROCEDURE IF EXISTS dbo.QA2_Check;
DROP PROCEDURE IF EXISTS dbo.QA2_Note;
DROP PROCEDURE IF EXISTS dbo.QA2_Punch;
DROP PROCEDURE IF EXISTS dbo.QA2_Approve;
DROP PROCEDURE IF EXISTS dbo.QA2_Process;
DROP PROCEDURE IF EXISTS dbo.QA2_ApprovedOvertime;
DROP FUNCTION IF EXISTS dbo.QA2_Emp;
DROP FUNCTION IF EXISTS dbo.QA2_User;
DROP FUNCTION IF EXISTS dbo.QA2_Date;
DROP FUNCTION IF EXISTS dbo.QA2_At;
DROP FUNCTION IF EXISTS dbo.QA2_LastRequest;
DROP TABLE IF EXISTS dbo.QA2_RESULT;
DROP TABLE IF EXISTS dbo.QA2_DAY;
DROP TABLE IF EXISTS dbo.QA2_STATE;
PRINT 'QA2 CLEANUP DONE';
GO
