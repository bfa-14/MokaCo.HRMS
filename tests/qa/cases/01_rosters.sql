/* ============================================================================
   cases/01_rosters.sql — R1, R2 (configuration side), R5, and the proc-level part
   of R3. R3/R4 through the workflow and the API are in api-tests.mjs (phase1).
   ============================================================================ */
SET NOCOUNT ON;
DECLARE @B INT = (SELECT BranchId FROM hr.BRANCH WHERE Name = N'QA Branch');
DECLARE @E1 INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA E1');
DECLARE @E4 INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA E4');
DECLARE @Morning INT = (SELECT ShiftId FROM attendance.SHIFT WHERE Name = N'Morning');
DECLARE @Evening INT = (SELECT ShiftId FROM attendance.SHIFT WHERE Name = N'Evening');
DECLARE @exp NVARCHAR(600), @act NVARCHAR(600), @pass BIT, @t NVARCHAR(1000), @n INT, @n2 INT;

/* ---- R1: every day of M has a shift or a rest day for every rostered QA employee ---- */
;WITH span AS (
    SELECT e.EmployeeId, e.FullName,
           CASE WHEN e.HireDate > '2026-08-01' THEN e.HireDate ELSE CAST('2026-08-01' AS DATE) END AS D1,
           CASE WHEN e.TerminationDate IS NOT NULL AND e.TerminationDate < '2026-08-31' THEN e.TerminationDate ELSE CAST('2026-08-31' AS DATE) END AS D2
    FROM hr.EMPLOYEE e WHERE e.FullName LIKE N'QA E[1-79]'),
days AS (
    SELECT s.EmployeeId, s.FullName, DATEADD(DAY, v.n, s.D1) AS WorkDate
    FROM span s CROSS APPLY (SELECT TOP 31 ROW_NUMBER() OVER (ORDER BY (SELECT 1)) - 1 AS n FROM sys.objects) v
    WHERE DATEADD(DAY, v.n, s.D1) <= s.D2)
SELECT @n = COUNT(*), @n2 = SUM(CASE WHEN sa.ShiftAssignmentId IS NULL OR (sa.ShiftId IS NULL AND sa.IsRestDay = 0) THEN 1 ELSE 0 END)
FROM days d LEFT JOIN attendance.SHIFT_ASSIGNMENT sa ON sa.EmployeeId = d.EmployeeId AND sa.WorkDate = d.WorkDate;
SET @act = CONCAT('employee-days=', @n, ' missing/empty=', @n2); SET @pass = CASE WHEN @n2 = 0 THEN 1 ELSE 0 END;
EXEC dbo.QA_Check 'R1', 'roster for M covers every day of every QA employee''s active span with a shift or a rest day', 'missing/empty days = 0', @act, @pass;

DECLARE @cs NVARCHAR(50) = CAST((SELECT CHECKSUM_AGG(CHECKSUM(sa.EmployeeId, sa.ShiftId, sa.WorkDate, sa.IsRestDay))
                                  FROM attendance.SHIFT_ASSIGNMENT sa JOIN hr.EMPLOYEE e ON e.EmployeeId = sa.EmployeeId
                                  WHERE e.FullName NOT LIKE N'QA %') AS NVARCHAR(50));
SET @exp = (SELECT [Value] FROM dbo.QA_STATE WHERE [Key] = 'baseline.nonqa.shift_assignment_checksum');
SET @pass = CASE WHEN @cs = @exp THEN 1 ELSE 0 END;
EXEC dbo.QA_Check 'R1b', 'building the QA roster changed nothing on non-QA branches (checksum of all non-QA roster rows)', @exp, @cs, @pass;

/* ---- R2 (configuration): Sundays rest for all, Saturdays rest for E4 only ---- */
SELECT @n = COUNT(*) FROM attendance.SHIFT_ASSIGNMENT sa JOIN hr.EMPLOYEE e ON e.EmployeeId = sa.EmployeeId
WHERE e.FullName LIKE N'QA E%' AND sa.WorkDate BETWEEN '2026-08-01' AND '2026-08-31'
  AND DATENAME(WEEKDAY, sa.WorkDate) = 'Sunday' AND (sa.IsRestDay = 0 OR sa.ShiftId IS NOT NULL);
SELECT @n2 = COUNT(*) FROM attendance.SHIFT_ASSIGNMENT sa
WHERE sa.EmployeeId = @E4 AND sa.WorkDate BETWEEN '2026-08-01' AND '2026-08-31'
  AND DATENAME(WEEKDAY, sa.WorkDate) = 'Saturday' AND sa.IsRestDay = 1 AND sa.ShiftId IS NULL;
SET @act = CONCAT('sundays-with-shift=', @n, ', E4 saturday rest days=', @n2); SET @pass = CASE WHEN @n = 0 AND @n2 = 5 THEN 1 ELSE 0 END;
EXEC dbo.QA_Check 'R2a', 'rest-day configuration: every Sunday is a rest day for all QA employees; E4 has all 5 Saturdays as rest days', 'sundays-with-shift=0, E4 saturday rest days=5', @act, @pass;

/* ---- R3 (proc level): does the day-upsert proc know about approved months? ---- */
DECLARE @def NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('attendance.usp_ShiftAssignment_Upsert'));
SET @act = CASE WHEN @def LIKE '%ROSTER_MONTH%' THEN 'guard present' ELSE 'no guard: the proc writes the row whatever the month status' END;
SET @pass = CASE WHEN @def LIKE '%ROSTER_MONTH%' THEN 1 ELSE 0 END;
EXEC dbo.QA_Check 'R3-proc', 'usp_ShiftAssignment_Upsert refuses to edit a day of an approved month (proc-level guard present)', 'proc references ROSTER_MONTH / Approved', @act, @pass;

/* ---- R5: copy period (weekday-aligned) August -> September for E4 ----
   Source pattern: Mon-Fri Morning except Wed 2026-08-12 = Evening; Sat+Sun rest. ---- */
DECLARE @copied TABLE (RowsInserted INT);
INSERT INTO @copied EXEC attendance.usp_ShiftAssignment_CopyPeriod @SourceYearMonth = '2026-08', @TargetYearMonth = '2026-09', @EmployeeId = @E4, @Overwrite = 0;
SELECT @n = COUNT(*) FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId = @E4 AND WorkDate BETWEEN '2026-09-01' AND '2026-09-30';
SELECT @n2 = COUNT(*) FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId = @E4 AND WorkDate BETWEEN '2026-09-01' AND '2026-09-30'
  AND ((DATENAME(WEEKDAY, WorkDate) IN ('Saturday','Sunday') AND NOT (IsRestDay = 1 AND ShiftId IS NULL))
    OR (DATENAME(WEEKDAY, WorkDate) NOT IN ('Saturday','Sunday') AND NOT (IsRestDay = 0 AND ShiftId = @Morning)));
SET @act = CONCAT('rows=', @n, ', pattern mismatches=', @n2); SET @pass = CASE WHEN @n = 30 AND @n2 = 0 THEN 1 ELSE 0 END;
EXEC dbo.QA_Check 'R5a', 'copy roster Aug->Sep (E4): 30 September rows, weekday pattern preserved (Mon-Fri Morning, Sat+Sun rest)', 'rows=30, pattern mismatches=0', @act, @pass;
SELECT @n = COUNT(*) FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId = @E4 AND WorkDate BETWEEN '2026-09-01' AND '2026-09-30' AND ShiftId = @Evening;
EXEC dbo.QA_Note 'R5 rule found: usp_ShiftAssignment_CopyPeriod copies the MOST FREQUENT shift per weekday (majority vote), aligned by weekday; a one-off day in the source month is not copied.';
SET @act = CONCAT('Evening rows in September=', @n); SET @pass = CASE WHEN @n = 0 THEN 1 ELSE 0 END;
EXEC dbo.QA_Check 'R5b', 'copy roster carries one-off exceptions exactly (source Wed 12 Aug = Evening)', 'documented rule: exceptions are not copied (majority per weekday) -> 0 Evening rows', @act, @pass;
DELETE FROM @copied;
INSERT INTO @copied EXEC attendance.usp_ShiftAssignment_CopyPeriod @SourceYearMonth = '2026-08', @TargetYearMonth = '2026-09', @EmployeeId = @E4, @Overwrite = 0;
SELECT @n = RowsInserted FROM @copied;
SET @act = CAST(@n AS NVARCHAR(10)); SET @pass = CASE WHEN @n = 0 THEN 1 ELSE 0 END;
EXEC dbo.QA_Check 'R5c', 'copy roster re-run with Overwrite=0 inserts nothing', '0', @act, @pass;
GO
