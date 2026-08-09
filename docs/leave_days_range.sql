/* ============================================================================
   LEAVE DAYS IN A RANGE  -  RE-RUNNABLE
   SQL Server 2025  -  database MokaCo_HRMS
   ----------------------------------------------------------------------------
   Run AFTER docs/core_hr_schema_and_procedures.sql. Adds ONE read-only procedure.
   It creates no tables and writes nothing.

   WHY IT EXISTS
     The roster must not put a working shift on a day somebody is on leave. To know
     that, the roster page needs "who is on leave between these two dates" — for
     EVERYONE at once. The ledger can currently only be read one employee at a time
     (hr.usp_LeaveLedger_GetByEmployee), which would mean one round trip per person
     per month just to draw a calendar.

   WHAT COUNTS AS A LEAVE DAY, AND WHY THIS DEFINITION
     A 'Usage' movement whose EffectiveDate falls in the range. This is NOT a new
     rule invented here — it is exactly the definition
     attendance.usp_Attendance_MarkLeaveDays already uses to decide that an absence
     was covered by approved leave:

         JOIN hr.LEAVE_LEDGER l
           ON l.EmployeeId    = a.EmployeeId
          AND l.MovementType  = 'Usage'
          AND l.EffectiveDate = a.WorkDate

     Using the same rule in both places is the point: the roster and the processor
     must never disagree about who was on leave.

   THE LIMITATION, STATED PLAINLY
     The ledger records leave as MOVEMENTS on a single EffectiveDate, not as a
     request spanning FromDate..ToDate. A five-day holiday booked as ONE ledger row
     therefore looks like ONE leave day here, not five. A proper
     workflow.LEAVE_REQUEST table (with a date range to expand) belongs to the
     workflow stage and does not exist yet.

     When it arrives, THIS PROCEDURE is the thing to rewrite — expand the request's
     range into days and UNION it with (or replace) the ledger rows below. Nothing
     that calls it needs to change: the contract is, and stays, one row per
     employee-day on leave.

   DaysOnLeave is returned so a caller can tell a HALF day from a whole one. Leave is
   stored as a negative movement (- credit used), so it is negated back to a positive
   number of days here — a caller should not have to know the ledger's sign convention.
   ============================================================================ */
USE MokaCo_HRMS;
GO

CREATE OR ALTER PROCEDURE hr.usp_LeaveLedger_GetDaysInRange
    @FromDate DATE,
    @ToDate   DATE
AS
BEGIN
    SET NOCOUNT ON;

    /* Grouped, because a day can carry more than one usage row (two leave types, or a
       correction posted alongside the original). The roster asks "is this person on
       leave on this date", which must have exactly one answer per employee-day. */
    SELECT
        l.EmployeeId,
        l.EffectiveDate           AS [Date],
        CAST(-SUM(l.Days) AS DECIMAL(6,2)) AS DaysOnLeave
    FROM hr.LEAVE_LEDGER l
    JOIN hr.EMPLOYEE e ON e.EmployeeId = l.EmployeeId AND e.IsDeleted = 0
    WHERE l.MovementType = 'Usage'
      AND l.EffectiveDate BETWEEN @FromDate AND @ToDate
    GROUP BY l.EmployeeId, l.EffectiveDate
    /* A day whose usage nets to zero or less (a booking and its reversal) is NOT leave.
       Without this, a cancelled day would still block the roster. */
    HAVING -SUM(l.Days) > 0
    ORDER BY l.EffectiveDate, l.EmployeeId;
END;
GO

/* -- verify -- */
EXEC hr.usp_LeaveLedger_GetDaysInRange @FromDate = '2026-06-01', @ToDate = '2026-06-30';
GO
