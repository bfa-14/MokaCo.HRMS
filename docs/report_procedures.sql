/* ============================================================================
   REPORT PROCEDURES  (attendance-based, no payroll engine required)
   MokaCo_HRMS
   ----------------------------------------------------------------------------
   Three printable reports that can be built TODAY from attendance + HR data:
     1. Monthly Attendance Summary   - the payroll-input review sheet
     2. Daily Attendance Sheet       - per-branch, who was in/late/absent
     3. Leave Balance Report         - accrued / used / remaining per employee

   Each proc returns a HEADER result set (for the report title block) followed by
   the DETAIL rows, so the frontend can render a proper printable report.
   Re-runnable (DROP + CREATE). Reads only; changes nothing.
   ============================================================================ */
USE MokaCo_HRMS;
GO

DROP PROCEDURE IF EXISTS report.usp_Report_LeaveBalance;
DROP PROCEDURE IF EXISTS report.usp_Report_DailyAttendance;
DROP PROCEDURE IF EXISTS report.usp_Report_MonthlyAttendance;
GO
IF SCHEMA_ID('report') IS NULL EXEC('CREATE SCHEMA report');
GO

/* ----------------------------------------------------------------------------
   1. MONTHLY ATTENDANCE SUMMARY
   The sheet HR reviews before running payroll. One row per employee for the
   period, with the numbers payroll turns into pay lines. Optional branch filter.
   Result set 1 = report header ; result set 2 = the per-employee rows.
   ---------------------------------------------------------------------------- */
CREATE PROCEDURE report.usp_Report_MonthlyAttendance
    @PeriodYearMonth CHAR(7),          -- 'YYYY-MM'
    @BranchId        INT = NULL        -- NULL = all branches
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @from DATE = CAST(@PeriodYearMonth + '-01' AS DATE);
    DECLARE @to   DATE = EOMONTH(@from);

    /* header */
    SELECT
        'Monthly Attendance Summary' AS ReportTitle,
        @PeriodYearMonth             AS Period,
        @from                        AS PeriodStart,
        @to                          AS PeriodEnd,
        CASE WHEN @BranchId IS NULL THEN 'All branches'
             ELSE (SELECT Name FROM hr.BRANCH WHERE BranchId = @BranchId) END AS BranchName,
        SYSUTCDATETIME()             AS GeneratedUtc;

    /* detail */
    ;WITH leave_used AS (
        SELECT EmployeeId, SUM(-Days) AS ApprovedLeaveDays
        FROM hr.LEAVE_LEDGER
        WHERE PeriodYearMonth = @PeriodYearMonth AND MovementType = 'Usage'
        GROUP BY EmployeeId
    ),
    att AS (
        SELECT a.EmployeeId,
               SUM(a.DayFraction)      AS DaysWorked,
               SUM(CASE WHEN a.IsFullDay = 1 THEN 1 ELSE 0 END)        AS FullDaysWorked,
               SUM(CASE WHEN a.[Status]='Present' THEN 1 ELSE 0 END)   AS PresentDays,
               SUM(CASE WHEN a.[Status]='Absent'  THEN 1 ELSE 0 END)   AS AbsentDays,
               SUM(CASE WHEN a.[Status]='RestDay' THEN 1 ELSE 0 END)   AS RestDays,
               SUM(CASE WHEN a.[Status]='Leave'   THEN 1 ELSE 0 END)   AS LeaveDays,
               SUM(a.LateMinutes)      AS LateMinutes,
               SUM(a.OvertimeMinutes)  AS OvertimeMinutes,
               SUM(a.WorkedMinutes)    AS WorkedMinutes,
               SUM(a.ExitLeaveMinutes) AS ExitLeaveMinutes
        FROM attendance.ATTENDANCE_RECORD a
        WHERE a.WorkDate BETWEEN @from AND @to
        GROUP BY a.EmployeeId
    )
    SELECT
        e.EmployeeId, e.FullName,
        b.Name  AS BranchName,
        d.Name  AS DepartmentName,
        ISNULL(att.DaysWorked, 0)        AS DaysWorked,
        ISNULL(att.FullDaysWorked, 0)    AS FullDaysWorked,
        ISNULL(att.PresentDays, 0)       AS PresentDays,
        ISNULL(att.AbsentDays, 0)        AS AbsentDays,
        ISNULL(att.LeaveDays, 0)         AS LeaveDays,
        ISNULL(att.RestDays, 0)          AS RestDays,
        ISNULL(att.LateMinutes, 0)       AS LateMinutes,
        ISNULL(att.OvertimeMinutes, 0)   AS OvertimeMinutes,
        CAST(ISNULL(att.WorkedMinutes,0) / 60.0 AS DECIMAL(8,2)) AS WorkedHours,
        core.fn_MinutesToLeaveDays(ISNULL(att.ExitLeaveMinutes,0)) AS ExitLeaveDays,
        ISNULL(leave_used.ApprovedLeaveDays, 0) AS ApprovedLeaveDays,
        CASE WHEN ISNULL(att.AbsentDays,0) - ISNULL(leave_used.ApprovedLeaveDays,0) > 0
             THEN ISNULL(att.AbsentDays,0) - ISNULL(leave_used.ApprovedLeaveDays,0)
             ELSE 0 END                  AS UnpaidAbsenceDays
    FROM hr.EMPLOYEE e
    JOIN hr.BRANCH b        ON b.BranchId = e.BranchId
    JOIN hr.DEPARTMENT d    ON d.DepartmentId = e.DepartmentId
    LEFT JOIN att           ON att.EmployeeId = e.EmployeeId
    LEFT JOIN leave_used    ON leave_used.EmployeeId = e.EmployeeId
    WHERE e.IsDeleted = 0
      AND e.HireDate <= @to
      AND (e.TerminationDate IS NULL OR e.TerminationDate >= @from)
      AND (@BranchId IS NULL OR e.BranchId = @BranchId)
    ORDER BY b.Name, e.FullName;
END;
GO

/* ----------------------------------------------------------------------------
   2. DAILY ATTENDANCE SHEET
   For a branch manager: on a given day, who was present, late, absent or off.
   One row per rostered/recorded employee for the date. Optional branch filter.
   Result set 1 = header ; result set 2 = the per-employee rows.
   ---------------------------------------------------------------------------- */
CREATE PROCEDURE report.usp_Report_DailyAttendance
    @WorkDate DATE,
    @BranchId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        'Daily Attendance Sheet' AS ReportTitle,
        @WorkDate                AS WorkDate,
        CASE WHEN @BranchId IS NULL THEN 'All branches'
             ELSE (SELECT Name FROM hr.BRANCH WHERE BranchId = @BranchId) END AS BranchName,
        SYSUTCDATETIME()         AS GeneratedUtc;

    SELECT
        e.EmployeeId, e.FullName,
        b.Name AS BranchName,
        s.Name AS ShiftName,
        a.FirstInUtc, a.LastOutUtc,
        a.LateMinutes,
        CAST(ISNULL(a.WorkedMinutes,0) / 60.0 AS DECIMAL(6,2)) AS WorkedHours,
        a.OvertimeMinutes,
        a.ExitActualMinutes,
        a.DayFraction,
        a.[Status],
        a.HasAnomaly,
        a.[Source]
    FROM attendance.ATTENDANCE_RECORD a
    JOIN hr.EMPLOYEE e            ON e.EmployeeId = a.EmployeeId
    JOIN hr.BRANCH b              ON b.BranchId = e.BranchId
    LEFT JOIN attendance.SHIFT_ASSIGNMENT sa ON sa.ShiftAssignmentId = a.ShiftAssignmentId
    LEFT JOIN attendance.SHIFT s  ON s.ShiftId = sa.ShiftId
    WHERE a.WorkDate = @WorkDate
      AND e.IsDeleted = 0
      AND (@BranchId IS NULL OR e.BranchId = @BranchId)
    ORDER BY b.Name, a.[Status], e.FullName;
END;
GO

/* ----------------------------------------------------------------------------
   3. LEAVE BALANCE REPORT
   Per employee per leave type: accrued, carried over, used, remaining - as of the
   end of a chosen period (inclusive). Reads the derived hr.vw_LEAVE_BALANCE, so the
   balance can never drift from the ledger. Optional single-employee filter.
   Result set 1 = header ; result set 2 = the balance rows.
   ---------------------------------------------------------------------------- */
CREATE PROCEDURE report.usp_Report_LeaveBalance
    @AsOfYearMonth CHAR(7),            -- include all periods up to and incl. this one
    @EmployeeId    INT = NULL,
    @BranchId      INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        'Leave Balance Report' AS ReportTitle,
        @AsOfYearMonth         AS AsOfPeriod,
        CASE WHEN @BranchId IS NULL THEN 'All branches'
             ELSE (SELECT Name FROM hr.BRANCH WHERE BranchId = @BranchId) END AS BranchName,
        SYSUTCDATETIME()       AS GeneratedUtc;

    /* Sum every ledger movement up to the chosen period into one balance per
       employee + leave type. vw_LEAVE_BALANCE is per-period; roll it up to as-of. */
    ;WITH bal AS (
        SELECT EmployeeId, LeaveTypeId,
               SUM(Accrued)     AS Accrued,
               SUM(CarriedOver) AS CarriedOver,
               SUM(Used)        AS Used,
               SUM(Remaining)   AS Remaining
        FROM hr.vw_LEAVE_BALANCE
        WHERE PeriodYearMonth <= @AsOfYearMonth
        GROUP BY EmployeeId, LeaveTypeId
    )
    SELECT
        e.EmployeeId, e.FullName,
        b.Name  AS BranchName,
        lt.Name AS LeaveType,
        lt.IsPaid,
        ISNULL(bal.Accrued, 0)     AS Accrued,
        ISNULL(bal.CarriedOver, 0) AS CarriedOver,
        ISNULL(bal.Used, 0)        AS Used,
        ISNULL(bal.Remaining, 0)   AS Remaining
    FROM hr.EMPLOYEE e
    JOIN hr.BRANCH b       ON b.BranchId = e.BranchId
    CROSS JOIN hr.LEAVE_TYPE lt
    LEFT JOIN bal          ON bal.EmployeeId = e.EmployeeId AND bal.LeaveTypeId = lt.LeaveTypeId
    WHERE e.IsDeleted = 0
      AND (@EmployeeId IS NULL OR e.EmployeeId = @EmployeeId)
      AND (@BranchId  IS NULL OR e.BranchId  = @BranchId)
      AND (bal.Remaining IS NOT NULL OR lt.AccrualPerMonth > 0)   -- skip irrelevant type/emp combos
    ORDER BY b.Name, e.FullName, lt.Name;
END;
GO

/* quick check
EXEC report.usp_Report_MonthlyAttendance @PeriodYearMonth = '2026-06';
EXEC report.usp_Report_DailyAttendance   @WorkDate = '2026-06-10';
EXEC report.usp_Report_LeaveBalance      @AsOfYearMonth = '2026-06';
*/
