/* ============================================================================
   109_payslip_short_days.sql - THE DAYS BEHIND "N DAY(S) SHORT" ON A PAYSLIP.

   A payslip deducts short days as ONE line: "2.25 day(s) short across 4 date(s)" (payroll.usp_PayrollRun_Generate,
   section D, reading payroll.fn_ShortDays, script 103). Nobody could see WHICH dates. This script lists them, by the
   same rule, for one payslip. It changes nothing that pays: Generate, fn_ShortDays and every line stay as they are.

   1  payroll.fn_ShortDayList(@From, @To) - the same predicate as payroll.fn_ShortDays, one row per day instead of
      one total per employee (the scenario tests/qa3/payroll/109_short_day_list.sql checks the two agree, employee by
      employee, so the predicates cannot drift apart unseen).
   2  payroll.usp_Payslip_ShortDays @PayslipId - the days of that payslip: its employee, its run's period, up to the
      last day the run counted (PAYROLL_RUN.GeneratedUpTo; a run generated before that column existed: the day before
      it was generated, never past the month's end). Only for a payslip that carries the short-days line (component
      LATE, source Attendance). Read-only. Access is the API's: the same rule as opening the payslip itself.
      If attendance changed after the run was generated (a correction, an excuse), the list shows attendance as it is
      now and its total differs from the line; the page says so, and regenerating the run makes them agree.

   Needs script 103. Idempotent (CREATE OR ALTER). Marker (deploy guard): payroll.usp_Payslip_ShortDays.
   Apply: sqlcmd -C -I -b -d <database> -i docs/109_payslip_short_days.sql
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF OBJECT_ID('payroll.fn_ShortDays') IS NULL OR OBJECT_ID('hr.fn_EmployeeBranchOn') IS NULL
   OR COL_LENGTH('payroll.PAYROLL_RUN', 'GeneratedUpTo') IS NULL
BEGIN RAISERROR('109_payslip_short_days.sql needs script 103 (payroll.fn_ShortDays, hr.fn_EmployeeBranchOn, payroll.PAYROLL_RUN.GeneratedUpTo). Nothing was applied.', 16, 1); SET NOEXEC ON; END
GO

/* ------------------------- 1. the short days, one row per day -------------------------
   KEEP IN STEP WITH payroll.fn_ShortDays (script 103): same joins, same WHERE, MissingDays per day. */
CREATE OR ALTER FUNCTION payroll.fn_ShortDayList (@From DATE, @To DATE)
RETURNS TABLE
AS RETURN
SELECT a.EmployeeId,
       a.WorkDate,
       a.[Status],
       a.FirstInUtc,
       a.LastOutUtc,
       a.WorkedMinutes,
       a.StandardMinutes,
       a.ShortfallMinutes,
       a.LateMinutes,
       a.DayFraction,
       CAST(CASE WHEN a.ShortfallMinutes > 0 AND a.StandardMinutes > 0
                 THEN CAST(a.ShortfallMinutes AS DECIMAL(18,8)) / a.StandardMinutes
                 ELSE CAST(1 - a.DayFraction AS DECIMAL(18,8)) END AS DECIMAL(18,8)) AS MissingDays
FROM attendance.ATTENDANCE_RECORD a
JOIN hr.EMPLOYEE e ON e.EmployeeId = a.EmployeeId
WHERE a.WorkDate BETWEEN @From AND @To
  AND a.WorkDate >= e.HireDate AND (e.TerminationDate IS NULL OR a.WorkDate <= e.TerminationDate)
  AND a.[Status] NOT IN ('RestDay', 'Leave', 'Holiday')
  AND a.DayFraction IS NOT NULL
  AND a.DayFraction < 1
  AND EXISTS (SELECT 1
              FROM attendance.SHIFT_ASSIGNMENT sa
              JOIN attendance.ROSTER_MONTH rm
                ON rm.BranchId = hr.fn_EmployeeBranchOn(a.EmployeeId, a.WorkDate)
               AND rm.MonthDate = DATEFROMPARTS(YEAR(a.WorkDate), MONTH(a.WorkDate), 1)
               AND rm.[Status] = 'Approved'
              WHERE sa.EmployeeId = a.EmployeeId AND sa.WorkDate = a.WorkDate
                AND sa.IsRestDay = 0 AND sa.ShiftId IS NOT NULL)
  AND NOT EXISTS (SELECT 1 FROM workflow.LEAVE_REQUEST lr
                  JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = lr.RequestInstanceId
                  WHERE ri.[Status] = 'Approved' AND lr.EmployeeId = a.EmployeeId
                    AND lr.HalfDay IS NULL
                    AND a.WorkDate BETWEEN lr.FromDate AND ISNULL(lr.ApprovedToDate, lr.ToDate));
GO

/* ------------------------- 2. the days of one payslip -------------------------
   Result (one row per day, oldest first): WorkDate, Status, FirstInUtc, LastOutUtc, WorkedMinutes, StandardMinutes,
   ShortfallMinutes, LateMinutes, DayFraction, MissingDays (4 decimals), CountedFrom, CountedUpTo, LineQuantity (what
   the payslip line deducts, in days). No row = the payslip has no short-days line, or nothing is short any more. */
CREATE OR ALTER PROCEDURE payroll.usp_Payslip_ShortDays
    @PayslipId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Emp INT, @Start DATE, @End DATE, @UpTo DATE, @Gen DATETIME2, @Line DECIMAL(18,4);

    SELECT @Emp = ps.EmployeeId, @Start = r.PeriodStart, @End = r.PeriodEnd, @UpTo = r.GeneratedUpTo, @Gen = r.GeneratedAt
    FROM payroll.PAYSLIP ps
    JOIN payroll.PAYROLL_RUN r ON r.PayrollRunId = ps.PayrollRunId
    WHERE ps.PayslipId = @PayslipId;

    SELECT @Line = SUM(pl.Quantity)
    FROM payroll.PAYSLIP_LINE pl
    JOIN hr.COMPONENT_TYPE ct ON ct.ComponentTypeId = pl.ComponentTypeId
    WHERE pl.PayslipId = @PayslipId AND ct.SystemCode = 'LATE' AND pl.SourceType = 'Attendance';

    -- A run generated before GeneratedUpTo existed: the completed days as of the day it was generated (Beirut).
    IF @UpTo IS NULL AND @Gen IS NOT NULL
    BEGIN
        DECLARE @GenDay DATE = CAST((@Gen AT TIME ZONE 'UTC') AT TIME ZONE 'Middle East Standard Time' AS DATE);
        SET @UpTo = CASE WHEN DATEADD(DAY, -1, @GenDay) < @End THEN DATEADD(DAY, -1, @GenDay) ELSE @End END;
    END
    IF @UpTo > @End SET @UpTo = @End;

    SELECT d.WorkDate, d.[Status], d.FirstInUtc, d.LastOutUtc, d.WorkedMinutes, d.StandardMinutes, d.ShortfallMinutes,
           d.LateMinutes, d.DayFraction, CAST(ROUND(d.MissingDays, 4) AS DECIMAL(9,4)) AS MissingDays,
           @Start AS CountedFrom, @UpTo AS CountedUpTo, @Line AS LineQuantity
    FROM payroll.fn_ShortDayList(@Start, @UpTo) d
    WHERE d.EmployeeId = @Emp
      AND @Line IS NOT NULL
      AND d.MissingDays > 0
    ORDER BY d.WorkDate;
END;
GO

PRINT '109_payslip_short_days.sql: the days behind a payslip''s short-days line can be listed - in place.';
GO

SET NOEXEC OFF;
GO
