/* ============================================================================
   113_worked_time_report.sql - THE WORKED TIME REPORT'S CALENDAR (Reports > Worked time).

   The report shows, per employee and for any period, the days and hours worked and the progress against the
   company's standard month - with or without a roster. Its worked time comes from the attendance days the system
   already builds from the punches (the same days as Daily attendance and payroll: paired, double presses removed,
   HR corrections included); this script adds only what those days cannot say: which days each person was employed,
   in which branch, and which of them were public holidays. That is the "expected" side of the progress.

   report.usp_Report_WorkedTime_Days @From, @To, @BranchId NULL, @EmployeeId NULL
     result 1: StandardDayMinutes (core.fn_StandardDayMinutes, the setting StandardWorkDayHours) and
               StandardDaysPerMonth (setting StandardWorkingDaysPerMonth, 26 when missing - the same reads as payroll)
     result 2: one row per employee per day of the period inside the employment (hire to termination, both included):
               EmployeeId, FullName, DepartmentName, WorkDate, BranchId and BranchName (the branch ON that day,
               hr.fn_EmployeeBranchOn), HolidayName / HolidayNameAr (a public holiday of that branch that day, else NULL),
               and HasRosterShift: the day has a working shift on its branch's APPROVED roster - the same test
               attendance.usp_Attendance_ComputeDay makes. On such a day the attendance day's WorkedMinutes is the
               shift window and the time after it is OvertimeMinutes; on any other day WorkedMinutes is first in to
               last out. The report adds the two on shift days so worked time means the same thing either way.
               @BranchId keeps the days spent in that branch; @EmployeeId one person. A removed (soft-deleted) employee
               is listed only for a period in which they have attendance days (they were still paid for it).
   Read-only. At most 366 days.

   Idempotent. Apply: sqlcmd -C -I -b -d <database> -i docs/113_worked_time_report.sql
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF SCHEMA_ID('report') IS NULL OR OBJECT_ID('hr.fn_EmployeeBranchOn') IS NULL OR OBJECT_ID('core.fn_StandardDayMinutes') IS NULL
   OR OBJECT_ID('attendance.ROSTER_MONTH') IS NULL OR COL_LENGTH('core.HOLIDAY', 'NameAr') IS NULL
BEGIN RAISERROR('113_worked_time_report.sql: the report schema, hr.fn_EmployeeBranchOn (script 82), core.fn_StandardDayMinutes, attendance.ROSTER_MONTH or core.HOLIDAY.NameAr is missing. Nothing was applied.', 16, 1); SET NOEXEC ON; END
GO

CREATE OR ALTER PROCEDURE report.usp_Report_WorkedTime_Days
    @From       DATE,
    @To         DATE,
    @BranchId   INT = NULL,
    @EmployeeId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @From IS NULL OR @To IS NULL OR @To < @From
    BEGIN RAISERROR('Choose the first and the last day of the period (the last on or after the first).', 16, 1); RETURN; END
    IF DATEDIFF(DAY, @From, @To) >= 366
    BEGIN RAISERROR('Choose at most a year at a time.', 16, 1); RETURN; END

    SELECT core.fn_StandardDayMinutes() AS StandardDayMinutes,
           ISNULL(NULLIF(TRY_CAST((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'StandardWorkingDaysPerMonth')
                                  AS DECIMAL(6,2)), 0), 26) AS StandardDaysPerMonth;

    ;WITH n AS (
        SELECT TOP (DATEDIFF(DAY, @From, @To) + 1) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS i
        FROM sys.all_objects
    ),
    days AS (SELECT DATEADD(DAY, n.i, @From) AS D FROM n),
    employed AS (
        SELECT e.EmployeeId, e.FullName, dep.Name AS DepartmentName, days.D AS WorkDate,
               hr.fn_EmployeeBranchOn(e.EmployeeId, days.D) AS BranchId
        FROM hr.EMPLOYEE e
        JOIN days ON days.D >= CAST(e.HireDate AS DATE)
                 AND (e.TerminationDate IS NULL OR days.D <= CAST(e.TerminationDate AS DATE))
        LEFT JOIN hr.DEPARTMENT dep ON dep.DepartmentId = e.DepartmentId
        WHERE (e.IsDeleted = 0
               OR EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD a
                          WHERE a.EmployeeId = e.EmployeeId AND a.WorkDate BETWEEN @From AND @To))
          AND (@EmployeeId IS NULL OR e.EmployeeId = @EmployeeId)
    )
    SELECT em.EmployeeId, em.FullName, ISNULL(em.DepartmentName, N'') AS DepartmentName, em.WorkDate,
           em.BranchId, b.Name AS BranchName, hol.Name AS HolidayName, hol.NameAr AS HolidayNameAr,
           CAST(CASE WHEN EXISTS (SELECT 1 FROM attendance.SHIFT_ASSIGNMENT sa
                                  JOIN attendance.ROSTER_MONTH rm
                                    ON rm.BranchId = em.BranchId
                                   AND rm.MonthDate = DATEFROMPARTS(YEAR(em.WorkDate), MONTH(em.WorkDate), 1)
                                   AND rm.[Status] = 'Approved'
                                  WHERE sa.EmployeeId = em.EmployeeId AND sa.WorkDate = em.WorkDate
                                    AND ISNULL(sa.IsRestDay, 0) = 0 AND sa.ShiftId IS NOT NULL)
                     THEN 1 ELSE 0 END AS BIT) AS HasRosterShift
    FROM employed em
    JOIN hr.BRANCH b ON b.BranchId = em.BranchId
    OUTER APPLY (SELECT TOP 1 h.Name, h.NameAr FROM core.HOLIDAY h
                 WHERE h.HolidayDate = em.WorkDate AND (h.BranchId IS NULL OR h.BranchId = em.BranchId)
                 ORDER BY h.BranchId DESC) hol
    WHERE @BranchId IS NULL OR em.BranchId = @BranchId
    ORDER BY em.FullName, em.EmployeeId, em.WorkDate;
END;
GO

PRINT '113_worked_time_report.sql: report.usp_Report_WorkedTime_Days - in place.';
GO

SET NOEXEC OFF;
GO
