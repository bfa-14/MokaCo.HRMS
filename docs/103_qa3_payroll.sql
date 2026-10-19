/* ============================================================================
   103_qa3_payroll.sql - QA3 payroll fixes (unit E). Needs 98 (security) and 99 (leave: LEAVE_REQUEST.ApprovedToDate
   and PaidSnapshot). Apply with sqlcmd -C -I -b, after 99-102.

   WHAT CHANGES, BY QA3 ID
   PAY-6 / REL-2  A salary row is SUPERSEDED by a later-starting row of the same employee, type and currency: section A pays
                  each row only up to the day before the next one starts, so a raise from the 16th pays 15/30 + 15/30 even
                  when the old row was never closed. The raw POST/PUT/DELETE /api/salary-components are retired in the API
                  (the Salary tab uses the history-preserving Set/End procedures). Data repair: overlapping standing rows
                  are closed (see section 13).
   CON-9 / item 2 core.EXCHANGE_RATE.Rate is widened from DECIMAL(18,4) to DECIMAL(28,12) (1/89,500 was stored 0.0000),
                  CHECK (Rate > 0) is added when no row violates it, and two NEW procedures with DECIMAL(28,12) parameters
                  take the writes (core.usp_ExchangeRate_Add keeps the one-rate-per-pair-type-date refusal; _SetRate
                  corrects a figure). The live usp_ExchangeRate_Create/_Update are left as they are (CON-7).
                  A rate of 0 is never snapshotted into a run.
   REL-1 / ROS-1  Deductions (short days, holiday work, the unpaid-holiday line, exit permissions, unpaid and sick leave) and
                  overtime count only days from HireDate to TerminationDate; readiness MissingDays the same.
   PAY-5 / REL-3 / ATT-11  Generate records a FINGERPRINT of every input of every payslip (attendance, roster, leave, salary,
                  overtime, tips, expenses, adjustments, advances, separations, the leave payout, the employee row) and of
                  the run's settings; Approve refuses a run whose inputs changed since ("Regenerate the run"), and
                  GET .../staleness names them for the run page. Expenses held by another open primary of an earlier
                  period are left out (G). Readiness and generation count COMPLETED days only (up to yesterday, Beirut).
   PAY-4          Readiness is checked in Generate (primary) and Approve as well as Create, with the same sentences.
                  Unresolved PIN punches are counted from the quarantine view (script 83), which leaves out the punches
                  HR set aside once script 100 (unit B) is applied.
   Holidays       (script 100, unit B: leave > public holiday > rest day) a public holiday on a rest day is a 'Holiday'
                  day: worked, it earns the holiday premium (D2, by status); unpaid, it is never deducted (the unpaid-
                  holiday line counts rostered WORKING days only). No change was needed here; scenario 06 checks it.
   PAY-11         Approve claims the run first (UPDATE ... WHERE Status = 'Review' AND GeneratedAt unchanged, row count
                  checked), so two approvals cannot both apply the lock effects.
   PAY-3          A primary is not locked before its last day is over unless the Owner asks for an early lock
                  (@AllowEarlyLock = 1; the API flag allowEarlyLock).
   PAY-2 / REL-14 / LEV-8  A separation settlement or a termination leave payout not paid by the leaving month is paid by the
                  next open primary (settlement-only payslip for a leaver of an earlier month). Approve stamps
                  SEPARATION.PaidInPayslipId and posts a "TerminationPayout" ledger adjustment that zeroes the balance
                  paid (by the payout line or by the separation's unused-leave line). The payout balance is the ledger AS
                  OF the termination date (usage dated after it is ignored) and is skipped when a separation of the same
                  employment pays the leave, or an approved payslip of this employment already paid it.
   PAY-8 / LEV-16 / LEV-17  Unpaid leave and the leave exclusions use ISNULL(ApprovedToDate, ToDate) and
                  ISNULL(PaidSnapshot, IsPaid); the payslip's paid/unpaid leave days are working days of the approved
                  span (half day 0.5); sick pay is numbered DAY BY DAY across the year, so a leave crossing a month end
                  costs each month its own days.
   PAY-10 / REL-7 / LEV-13  hr.COMPONENT_TYPE.SystemCode: the generator finds its types by code; system types cannot be
                  renamed, re-categorised, deactivated or deleted; Generate refuses when one is missing. Sick-pay tiers are
                  keyed on the leave type's id (a type with LEAVE_PAY_TIER rows), not on the name 'Sick'.
   PAY-9          One NSSF / tax version per scheme per month: the one in force at the period end. Triggers close the
                  previous version the day before a new one starts and refuse overlaps; existing overlaps are closed.
   REL-11         While a run is Draft, Generate re-reads the rates as of the period end; from Review on the snapshot is
                  frozen (a currency missing from it is added). A line in a currency with no rate is refused.
   PAY-12 / WEB-4 PAYROLL_VIEW and REPORT_VIEW are seeded and granted to every role holding PAYROLL_RUN / PAYROLL_APPROVE
                  (resp. ATTENDANCE_VIEW).
   PAY-13         Sick-pay tiers by WHOLE years of service. PAY-14 / REL-16: the hour rate reads StandardWorkDayHours.
   PAY-15         The payslip's branch is the branch of the period (hr.fn_EmployeeBranchOn on the last day in the period).
   REL-5          A soft-deleted employee with attendance or an adjustment in the period is still paid.
   Suspicions fixed: the unpaid-holiday line counts approved roster months only; tips are one line per distribution
                  (SourceId = that distribution); unpaid deductions are capped at the basic paid for the month.

   DATA REPAIRS (section 13, idempotent, never a locked run's figures): overlapping standing salary rows closed (only from
   days not yet paid for that employee); SEPARATION.PaidInPayslipId and the payout ledger settlement back-filled for runs
   already approved; overlapping NSSF / tax versions closed. Rows the owner must check are PRINTed.

   Runs generated before this script carry no fingerprint: Approve asks for one regenerate. Idempotent.
   ============================================================================ */
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET XACT_ABORT ON;
GO

/* ------------------------- 0. prerequisites ------------------------- */
IF COL_LENGTH('workflow.LEAVE_REQUEST', 'ApprovedToDate') IS NULL
    RAISERROR('103_qa3_payroll.sql needs workflow.LEAVE_REQUEST.ApprovedToDate - apply 99_qa3_leave.sql first.', 16, 1);
GO
IF COL_LENGTH('workflow.LEAVE_REQUEST', 'PaidSnapshot') IS NULL
    RAISERROR('103_qa3_payroll.sql needs workflow.LEAVE_REQUEST.PaidSnapshot - apply 99_qa3_leave.sql first.', 16, 1);
GO
IF OBJECT_ID('payroll.fn_IsPeriodPaid') IS NULL OR OBJECT_ID('hr.fn_LeaveDays') IS NULL OR OBJECT_ID('hr.fn_EmployeeBranchOn') IS NULL
    RAISERROR('103_qa3_payroll.sql needs scripts 82-86 (fn_IsPeriodPaid, fn_LeaveDays, fn_EmployeeBranchOn).', 16, 1);
GO

/* ------------------------- 1. exchange rates at full precision (CON-9, handoff trap 4) ------------------------- */
IF EXISTS (SELECT 1 FROM sys.columns c WHERE c.object_id = OBJECT_ID('core.EXCHANGE_RATE') AND c.name = 'Rate'
           AND NOT (c.precision = 28 AND c.scale = 12))
BEGIN
    /* auto-created statistics on the column would block the ALTER; they are rebuilt on demand */
    DECLARE @drop NVARCHAR(MAX) = N'';
    SELECT @drop = @drop + N'DROP STATISTICS core.EXCHANGE_RATE.' + QUOTENAME(s.name) + N';'
    FROM sys.stats s
    JOIN sys.stats_columns sc ON sc.object_id = s.object_id AND sc.stats_id = s.stats_id
    JOIN sys.columns c ON c.object_id = sc.object_id AND c.column_id = sc.column_id
    WHERE s.object_id = OBJECT_ID('core.EXCHANGE_RATE') AND c.name = 'Rate' AND s.auto_created = 1;
    IF @drop <> N'' EXEC (@drop);
    ALTER TABLE core.EXCHANGE_RATE ALTER COLUMN Rate DECIMAL(28,12) NOT NULL;
    PRINT 'core.EXCHANGE_RATE.Rate widened to DECIMAL(28,12).';
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_EXCHANGE_RATE_RatePositive' AND parent_object_id = OBJECT_ID('core.EXCHANGE_RATE'))
BEGIN
    IF EXISTS (SELECT 1 FROM core.EXCHANGE_RATE WHERE Rate <= 0)
    BEGIN
        DECLARE @bad NVARCHAR(MAX) = (SELECT STRING_AGG(CONCAT(ExchangeRateId, N' (', FromCurrency, N'->', ToCurrency, N' ', RateType, N' ', CONVERT(CHAR(10), EffectiveDate, 23), N')'), N', ')
                                      FROM core.EXCHANGE_RATE WHERE Rate <= 0);
        PRINT CONCAT('OWNER CHECK: exchange rate rows stored as 0 (lost to the old 4-decimal column) - correct them on Exchange rates; ',
                     'CHECK (Rate > 0) is added once none is left: ', @bad);
    END
    ELSE
    BEGIN
        ALTER TABLE core.EXCHANGE_RATE WITH CHECK ADD CONSTRAINT CK_EXCHANGE_RATE_RatePositive CHECK (Rate > 0);
        PRINT 'CHECK (Rate > 0) added to core.EXCHANGE_RATE.';
    END
END
GO

/* ------------------------- 2. schema: codes, stamps, fingerprints ------------------------- */
IF COL_LENGTH('hr.COMPONENT_TYPE', 'SystemCode') IS NULL
    ALTER TABLE hr.COMPONENT_TYPE ADD SystemCode VARCHAR(30) NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_COMPONENT_TYPE_SystemCode' AND object_id = OBJECT_ID('hr.COMPONENT_TYPE'))
    CREATE UNIQUE INDEX UX_COMPONENT_TYPE_SystemCode ON hr.COMPONENT_TYPE (SystemCode) WHERE SystemCode IS NOT NULL;
GO
IF COL_LENGTH('workflow.SEPARATION', 'PaidInPayslipId') IS NULL
    ALTER TABLE workflow.SEPARATION ADD PaidInPayslipId INT NULL;   -- soft reference: the locked payslip that paid it
GO
IF COL_LENGTH('payroll.PAYROLL_RUN', 'GeneratedUpTo') IS NULL
    ALTER TABLE payroll.PAYROLL_RUN ADD GeneratedUpTo DATE NULL;              -- the last completed day the generation counted
GO
IF COL_LENGTH('payroll.PAYROLL_RUN', 'InputsFingerprint') IS NULL
    ALTER TABLE payroll.PAYROLL_RUN ADD InputsFingerprint VARBINARY(32) NULL; -- the run-wide inputs (settings, NSSF/tax, types, holidays, rosters, rates)
GO
IF COL_LENGTH('payroll.PAYROLL_RUN', 'LockedEarly') IS NULL
    ALTER TABLE payroll.PAYROLL_RUN ADD LockedEarly BIT NULL;                 -- 1 = the Owner locked it before the period was over
GO
IF OBJECT_ID('payroll.PAYSLIP_INPUT') IS NULL
    CREATE TABLE payroll.PAYSLIP_INPUT (
        PayslipId   INT           NOT NULL CONSTRAINT FK_PAYSLIP_INPUT_Payslip REFERENCES payroll.PAYSLIP (PayslipId) ON DELETE CASCADE,
        Source      VARCHAR(20)   NOT NULL,
        RowsCount   INT           NOT NULL,
        Fingerprint VARBINARY(32) NOT NULL,
        CONSTRAINT PK_PAYSLIP_INPUT PRIMARY KEY (PayslipId, Source));
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_PAYSLIP_LINE_Source' AND object_id = OBJECT_ID('payroll.PAYSLIP_LINE'))
    CREATE INDEX IX_PAYSLIP_LINE_Source ON payroll.PAYSLIP_LINE (SourceType, SourceId) INCLUDE (PayslipId);
GO

/* the component types payroll writes, by code (PAY-10). An existing row is claimed by its current name (the generator's
   old lookup); a missing one is created. */
DECLARE @sys TABLE (Code VARCHAR(30) PRIMARY KEY, Name NVARCHAR(60), Category VARCHAR(20), [Sign] SMALLINT, IsStanding BIT, IsBasic BIT);
INSERT INTO @sys VALUES
 ('BASIC',           N'Basic Salary',             'Earning',      1, 1, 1),
 ('OVERTIME',        N'Overtime',                 'Earning',      1, 0, 0),
 ('HOLIDAY_WORK',    N'Holiday Work',             'Earning',      1, 0, 0),
 ('LATE',            N'Late Deduction',           'Deduction',   -1, 0, 0),
 ('UNPAID_LEAVE',    N'Unpaid Leave Deduction',   'Deduction',   -1, 0, 0),
 ('ABSENCE',         N'Absence Deduction',        'Deduction',   -1, 0, 0),
 ('TIPS',            N'Tips',                     'Earning',      1, 0, 0),
 ('EXPENSE',         N'Expense Reimbursement',    'Earning',      1, 0, 0),
 ('ADVANCE',         N'Advance Repayment',        'Deduction',   -1, 0, 0),
 ('UNUSED_LEAVE',    N'Unused Leave Payout',      'Earning',      1, 0, 0),
 ('INDEMNITY',       N'End-of-Service Indemnity', 'Earning',      1, 0, 0),
 ('LEAVE_PAYOUT',    N'Leave Balance Payout',     'Earning',      1, 0, 0),
 ('LEAVE_DEDUCTION', N'Leave Balance Deduction',  'Deduction',   -1, 0, 0),
 ('NSSF_EMPLOYEE',   N'NSSF Employee Share',      'Deduction',   -1, 0, 0),
 ('NSSF_EMPLOYER',   N'NSSF Employer Share',      'EmployerCost', 1, 0, 0),
 ('INCOME_TAX',      N'Income Tax',               'Deduction',   -1, 0, 0);
/* by name, the lowest id when a name is duplicated */
UPDATE ct SET SystemCode = s.Code
FROM @sys s
JOIN hr.COMPONENT_TYPE ct ON ct.ComponentTypeId = (SELECT MIN(c2.ComponentTypeId) FROM hr.COMPONENT_TYPE c2 WHERE c2.Name = s.Name AND c2.SystemCode IS NULL)
WHERE NOT EXISTS (SELECT 1 FROM hr.COMPONENT_TYPE x WHERE x.SystemCode = s.Code);
/* the basic salary may have been renamed already: the single type flagged IsBasicSalary */
IF NOT EXISTS (SELECT 1 FROM hr.COMPONENT_TYPE WHERE SystemCode = 'BASIC')
   AND (SELECT COUNT(*) FROM hr.COMPONENT_TYPE WHERE IsBasicSalary = 1 AND SystemCode IS NULL) = 1
    UPDATE hr.COMPONENT_TYPE SET SystemCode = 'BASIC' WHERE IsBasicSalary = 1 AND SystemCode IS NULL;
INSERT INTO hr.COMPONENT_TYPE (Name, Category, [Sign], IsStanding, IsBasicSalary, IsActive, SystemCode)
SELECT s.Name, s.Category, s.[Sign], s.IsStanding, s.IsBasic, 1, s.Code
FROM @sys s
WHERE NOT EXISTS (SELECT 1 FROM hr.COMPONENT_TYPE x WHERE x.SystemCode = s.Code);
GO

/* ------------------------- 3. readiness: completed days, employment (PAY-4, ATT-11, REL-1) -------------------------
   The day rule's gate as a FUNCTION, so the run procedures can ask it without INSERT ... EXEC (they are themselves
   called through INSERT ... EXEC, which cannot nest). @AsOfDate is the clock: "today" (NULL = Beirut today). Only
   COMPLETED days count - up to yesterday, never past the month's end: today's shifts are still in progress. */
CREATE OR ALTER FUNCTION attendance.fn_PayrollReadiness (@PeriodYearMonth CHAR(7), @AsOfDate DATE)
RETURNS TABLE
AS RETURN
WITH p AS (
    SELECT CAST(@PeriodYearMonth + '-01' AS DATE) AS PeriodStart,
           EOMONTH(CAST(@PeriodYearMonth + '-01' AS DATE)) AS PeriodEnd,
           DATEADD(DAY, -1, ISNULL(@AsOfDate, CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE))) AS Yesterday
), q AS (
    SELECT PeriodStart, PeriodEnd, CASE WHEN Yesterday < PeriodEnd THEN Yesterday ELSE PeriodEnd END AS UpTo FROM p
), c AS (
    SELECT q.PeriodStart, q.PeriodEnd, q.UpTo,
        (SELECT COUNT(*) FROM attendance.RAW_DEVICE_LOG
         WHERE IsProcessed = 0 AND EmployeeId IS NOT NULL AND CAST(PunchTimeUtc AS DATE) BETWEEN q.PeriodStart AND q.UpTo) AS UnprocessedPunches,
        /* the punches still WAITING for an owner: script 83's quarantine view, which (script 100, unit B) leaves out
           the punches HR set aside - so the "Set aside" button unblocks payroll */
        (SELECT COUNT(*) FROM attendance.DEVICE_PUNCH_QUARANTINE pq
         WHERE CAST(pq.PunchTime AS DATE) BETWEEN q.PeriodStart AND q.UpTo) AS UnresolvedPinPunches,
        (SELECT COUNT(*) FROM attendance.ATTENDANCE_RECORD
         WHERE HasAnomaly = 1 AND WorkDate BETWEEN q.PeriodStart AND q.UpTo) AS OpenAnomalies,
        (SELECT COUNT(*) FROM attendance.ATTENDANCE_CORRECTION cr
         JOIN attendance.ATTENDANCE_RECORD a ON a.AttendanceId = cr.AttendanceId
         WHERE cr.ApprovalStatus = 'Pending' AND a.WorkDate BETWEEN q.PeriodStart AND q.UpTo) AS PendingCorrections,
        /* a rostered day of an APPROVED roster month (the branch of the day), inside the employment (QA3 REL-1) */
        (SELECT COUNT(*) FROM attendance.SHIFT_ASSIGNMENT sa
         JOIN hr.EMPLOYEE e ON e.EmployeeId = sa.EmployeeId AND e.IsDeleted = 0
         WHERE sa.WorkDate BETWEEN q.PeriodStart AND q.UpTo
           AND sa.WorkDate >= e.HireDate AND (e.TerminationDate IS NULL OR sa.WorkDate <= e.TerminationDate)
           AND EXISTS (SELECT 1 FROM attendance.ROSTER_MONTH rm
                       WHERE rm.BranchId = hr.fn_EmployeeBranchOn(sa.EmployeeId, sa.WorkDate)
                         AND rm.MonthDate = DATEFROMPARTS(YEAR(sa.WorkDate), MONTH(sa.WorkDate), 1)
                         AND rm.[Status] = 'Approved')
           AND NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD a
                           WHERE a.EmployeeId = sa.EmployeeId AND a.WorkDate = sa.WorkDate)) AS RosteredDaysWithNoRecord,
        (SELECT COUNT(*) FROM attendance.ATTENDANCE_RECORD
         WHERE WorkDate BETWEEN q.PeriodStart AND q.UpTo AND ExitVarianceMinutes > 0 AND ExitVarianceDisposition IS NULL) AS UndecidedExitVariances,
        (SELECT COUNT(*) FROM attendance.ATTENDANCE_ANOMALY
         WHERE WorkDate BETWEEN q.PeriodStart AND q.UpTo AND Decision IS NULL) AS UndecidedAnomalies
    FROM q
)
SELECT @PeriodYearMonth AS PeriodYearMonth, c.PeriodStart, c.PeriodEnd,
       c.UnprocessedPunches, c.UnresolvedPinPunches, c.OpenAnomalies, c.PendingCorrections,
       c.RosteredDaysWithNoRecord, c.UndecidedExitVariances, c.UndecidedAnomalies,
       CAST(CASE WHEN c.UnprocessedPunches = 0 AND c.UnresolvedPinPunches = 0 AND c.OpenAnomalies = 0 AND c.PendingCorrections = 0
                  AND c.RosteredDaysWithNoRecord = 0 AND c.UndecidedExitVariances = 0 AND c.UndecidedAnomalies = 0
                 THEN 1 ELSE 0 END AS BIT) AS IsReady,
       c.UpTo AS CountedUpTo
FROM c;
GO

/* The readiness check (unchanged 11-column shape for its INSERT ... EXEC callers): now from the function. */
CREATE OR ALTER PROCEDURE attendance.usp_Attendance_PayrollReadiness
    @PeriodYearMonth CHAR(7),
    @AsOfDate DATE = NULL      -- the clock. NULL = today in Beirut; a caller passes a date only to test the rule
AS
BEGIN
    SET NOCOUNT ON;
    SELECT PeriodYearMonth, PeriodStart, PeriodEnd, UnprocessedPunches, UnresolvedPinPunches, OpenAnomalies,
           PendingCorrections, RosteredDaysWithNoRecord, UndecidedExitVariances, UndecidedAnomalies, IsReady
    FROM attendance.fn_PayrollReadiness(@PeriodYearMonth, @AsOfDate);
END;
GO

/* The gate itself, shared by Create, Generate and Approve (PAY-4): the same two sentences everywhere. Returns 1 after
   raising the refusal, 0 when the period's completed days are ready. */
CREATE OR ALTER PROCEDURE payroll.usp_PayrollRun_AssertReady
    @PeriodYearMonth CHAR(7), @AsOfDate DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Undecided INT, @IsReady BIT, @UpTo DATE;
    SELECT @Undecided = UndecidedAnomalies, @IsReady = IsReady, @UpTo = CountedUpTo
    FROM attendance.fn_PayrollReadiness(@PeriodYearMonth, @AsOfDate);
    DECLARE @P CHAR(7) = @PeriodYearMonth, @UpToText VARCHAR(10) = CONVERT(VARCHAR(10), @UpTo, 23);
    IF @Undecided > 0
    BEGIN
        DECLARE @Plural VARCHAR(3) = CASE WHEN @Undecided = 1 THEN 'y' ELSE 'ies' END;
        RAISERROR('Attendance for %s has %d undecided anomal%s up to %s (late arrival, early departure or missing punch). Decide them in Attendance > Anomalies before running payroll.', 16, 1, @P, @Undecided, @Plural, @UpToText);
        RETURN 1;
    END
    IF @IsReady = 0
    BEGIN
        RAISERROR('Attendance for %s is not ready for payroll up to %s. Open the readiness check and clear the counts.', 16, 1, @P, @UpToText);
        RETURN 1;
    END
    RETURN 0;
END;
GO

/* ------------------------- 4. what a run pays besides the month's own figures -------------------------
   "Earlier open primary": a Draft / Review primary of an EARLIER period holds an item on its lines - the earlier month
   pays it. A later run that also carries it goes stale (its inputs changed) and drops it when regenerated.
   SettleFrom: settlements are caught up from the first period the system paid (the earliest approved primary before
   this one), so a leaver settled before the system's payroll went live is never paid a second time. */

/* G. expenses: approved, never reimbursed, not held by an earlier open primary (QA3 PAY-5) */
CREATE OR ALTER FUNCTION payroll.fn_RunExpenses (@PayrollRunId INT)
RETURNS TABLE
AS RETURN
SELECT er.ExpenseReimbursementId, er.EmployeeId
FROM payroll.PAYROLL_RUN r
JOIN workflow.EXPENSE_REIMBURSEMENT er ON er.ReimbursedInPayrollAt IS NULL
JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = er.RequestInstanceId AND ri.[Status] = 'Approved'
WHERE r.PayrollRunId = @PayrollRunId
  AND NOT EXISTS (SELECT 1 FROM payroll.PAYSLIP_LINE l
                  JOIN payroll.PAYSLIP ps ON ps.PayslipId = l.PayslipId
                  JOIN payroll.PAYROLL_RUN o ON o.PayrollRunId = ps.PayrollRunId
                  WHERE l.SourceType = 'Expense' AND l.SourceId = er.ExpenseReimbursementId
                    AND o.PayrollRunId <> r.PayrollRunId AND o.RunType = 'Primary' AND o.[Status] IN ('Draft','Review')
                    AND o.PeriodStart < r.PeriodStart);
GO

/* I. adjustments targeted at the period, unconsumed, not held by an open supplemental (script 81's rule) */
CREATE OR ALTER FUNCTION payroll.fn_RunAdjustments (@PayrollRunId INT)
RETURNS TABLE
AS RETURN
SELECT adj.PayrollAdjustmentId, adj.EmployeeId
FROM payroll.PAYROLL_RUN r
JOIN payroll.PAYROLL_ADJUSTMENT adj ON adj.TargetPeriod = r.PeriodYearMonth AND adj.AppliedToPayslipId IS NULL
WHERE r.PayrollRunId = @PayrollRunId
  AND NOT EXISTS (SELECT 1 FROM payroll.PAYSLIP_LINE sl
                  JOIN payroll.PAYSLIP sp ON sp.PayslipId = sl.PayslipId
                  JOIN payroll.PAYROLL_RUN sr ON sr.PayrollRunId = sp.PayrollRunId
                  WHERE sl.SourceType = 'Adjustment' AND sl.SourceId = adj.PayrollAdjustmentId
                    AND sr.PayrollRunId <> r.PayrollRunId AND sr.RunType = 'Supplemental' AND sr.[Status] IN ('Draft','Review'));
GO

/* J. separation settlements this run pays: approved and prepared, never paid, last working day from SettleFrom to the
   period end (QA3 PAY-2: one recorded after its month was locked is paid by the next open primary) */
CREATE OR ALTER FUNCTION payroll.fn_RunSeparations (@PayrollRunId INT)
RETURNS TABLE
AS RETURN
WITH r AS (
    SELECT r0.PayrollRunId, r0.PeriodStart, r0.PeriodEnd,
           ISNULL((SELECT MIN(o.PeriodStart) FROM payroll.PAYROLL_RUN o
                   WHERE o.RunType = 'Primary' AND o.[Status] = 'Approved' AND o.PayrollRunId <> r0.PayrollRunId
                     AND o.PeriodStart < r0.PeriodStart), r0.PeriodStart) AS SettleFrom
    FROM payroll.PAYROLL_RUN r0 WHERE r0.PayrollRunId = @PayrollRunId)
SELECT s.SeparationId, s.EmployeeId
FROM r
JOIN workflow.SEPARATION s ON s.LastWorkingDate BETWEEN r.SettleFrom AND r.PeriodEnd
JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = s.RequestInstanceId AND ri.[Status] = 'Approved'
WHERE s.PreparedAt IS NOT NULL AND s.PaidInPayslipId IS NULL
  AND NOT EXISTS (SELECT 1 FROM payroll.PAYSLIP_LINE l
                  JOIN payroll.PAYSLIP ps ON ps.PayslipId = l.PayslipId
                  JOIN payroll.PAYROLL_RUN o ON o.PayrollRunId = ps.PayrollRunId
                  WHERE l.SourceType = 'Separation' AND l.SourceId = s.SeparationId AND o.PayrollRunId <> r.PayrollRunId
                    AND (o.[Status] = 'Approved'
                         OR (o.RunType = 'Primary' AND o.[Status] IN ('Draft','Review') AND o.PeriodStart < r.PeriodStart)));
GO

/* J2. the leave balance on termination this run settles (QA3 PAY-2 / REL-14 / LEV-8): the ledger AS OF the termination
   date (usage, openings or year-close rows dated after it do not count), paid accruing types; not when a separation of
   the same employment pays the leave, not when an approved payslip of this employment already paid it, not when an
   earlier open primary holds it. */
CREATE OR ALTER FUNCTION payroll.fn_RunLeavePayouts (@PayrollRunId INT)
RETURNS TABLE
AS RETURN
WITH r AS (
    SELECT r0.PayrollRunId, r0.PeriodStart, r0.PeriodEnd,
           ISNULL((SELECT MIN(o.PeriodStart) FROM payroll.PAYROLL_RUN o
                   WHERE o.RunType = 'Primary' AND o.[Status] = 'Approved' AND o.PayrollRunId <> r0.PayrollRunId
                     AND o.PeriodStart < r0.PeriodStart), r0.PeriodStart) AS SettleFrom
    FROM payroll.PAYROLL_RUN r0 WHERE r0.PayrollRunId = @PayrollRunId)
SELECT e.EmployeeId, e.TerminationDate, b.Balance
FROM r
JOIN hr.EMPLOYEE e ON e.TerminationDate BETWEEN r.SettleFrom AND r.PeriodEnd
CROSS APPLY (SELECT CAST(SUM(l.Days) AS DECIMAL(9,2)) AS Balance
             FROM hr.LEAVE_LEDGER l
             JOIN hr.LEAVE_TYPE lt ON lt.LeaveTypeId = l.LeaveTypeId AND lt.IsPaid = 1
             WHERE l.EmployeeId = e.EmployeeId AND l.EffectiveDate <= e.TerminationDate
               AND EXISTS (SELECT 1 FROM hr.LEAVE_ACCRUAL_TIER t WHERE t.LeaveTypeId = l.LeaveTypeId)) b
WHERE ISNULL((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'LeavePayoutOnTermination'), '1') = '1'
  AND b.Balance IS NOT NULL AND b.Balance <> 0
  AND NOT EXISTS (SELECT 1 FROM workflow.SEPARATION s
                  JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = s.RequestInstanceId
                  WHERE s.EmployeeId = e.EmployeeId AND ri.[Status] = 'Approved' AND s.PreparedAt IS NOT NULL
                    AND ISNULL(s.UnusedLeaveAmount, 0) > 0 AND s.LastWorkingDate >= e.HireDate)
  AND NOT EXISTS (SELECT 1 FROM payroll.PAYSLIP_LINE l
                  JOIN payroll.PAYSLIP ps ON ps.PayslipId = l.PayslipId
                  JOIN payroll.PAYROLL_RUN o ON o.PayrollRunId = ps.PayrollRunId
                  WHERE l.SourceType = 'LeavePayout' AND ps.EmployeeId = e.EmployeeId AND o.PayrollRunId <> r.PayrollRunId
                    AND ((o.[Status] = 'Approved' AND o.PeriodEnd >= e.HireDate)
                         OR (o.RunType = 'Primary' AND o.[Status] IN ('Draft','Review') AND o.PeriodStart < r.PeriodStart)));
GO

/* WHO GETS A PAYSLIP: everyone employed during part of the period - a soft-deleted employee too when the period holds
   their attendance or an adjustment for them (QA3 REL-5) - and a leaver of an earlier month whose settlement or leave
   payout this run pays (QA3 PAY-2: a settlement-only payslip). */
CREATE OR ALTER FUNCTION payroll.fn_RunEmployees (@PayrollRunId INT)
RETURNS TABLE
AS RETURN
WITH r AS (SELECT PayrollRunId, PeriodStart, PeriodEnd, PeriodYearMonth FROM payroll.PAYROLL_RUN WHERE PayrollRunId = @PayrollRunId)
SELECT e.EmployeeId, CAST(0 AS BIT) AS SettlementOnly
FROM r
JOIN hr.EMPLOYEE e ON e.HireDate <= r.PeriodEnd AND (e.TerminationDate IS NULL OR e.TerminationDate >= r.PeriodStart)
WHERE e.IsDeleted = 0
   OR EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD a WHERE a.EmployeeId = e.EmployeeId AND a.WorkDate BETWEEN r.PeriodStart AND r.PeriodEnd)
   OR EXISTS (SELECT 1 FROM payroll.PAYROLL_ADJUSTMENT adj WHERE adj.EmployeeId = e.EmployeeId AND adj.TargetPeriod = r.PeriodYearMonth AND adj.AppliedToPayslipId IS NULL)
UNION ALL
SELECT e.EmployeeId, CAST(1 AS BIT)
FROM r
JOIN hr.EMPLOYEE e ON e.TerminationDate < r.PeriodStart
WHERE EXISTS (SELECT 1 FROM payroll.fn_RunSeparations(@PayrollRunId) s WHERE s.EmployeeId = e.EmployeeId)
   OR EXISTS (SELECT 1 FROM payroll.fn_RunLeavePayouts(@PayrollRunId) p WHERE p.EmployeeId = e.EmployeeId);
GO

/* ------------------------- 5. what a payslip was computed from (QA3 PAY-5 / REL-3 / ATT-11) -------------------------
   One fingerprint per SOURCE of one employee's payslip: a hash of the rows the generator reads, values only (a day that
   is reprocessed to the same figures does not count as a change; a row added, removed or changed does). Generate stores
   them; Approve and the run page compare them with the data as it stands. Pending requests are left out - they pay
   nothing - so only a change that can move money makes a run stale. */
CREATE OR ALTER FUNCTION payroll.fn_PayslipInputs (@PayrollRunId INT, @EmployeeId INT)
RETURNS TABLE
AS RETURN
WITH r AS (SELECT PeriodStart, PeriodEnd, PeriodYearMonth, DATEFROMPARTS(YEAR(PeriodStart), 1, 1) AS YearStart
           FROM payroll.PAYROLL_RUN WHERE PayrollRunId = @PayrollRunId),
k AS (
    SELECT 'Employee' AS Source, CONCAT('E|', e.HireDate, '|', ISNULL(CONVERT(VARCHAR(10), e.TerminationDate, 23), '~'), '|', e.IsDeleted,
                                        '|', ISNULL(CONVERT(VARCHAR(12), e.PositionId), '~'), '|', ISNULL(CONVERT(VARCHAR(12), e.BranchId), '~')) AS K
    FROM hr.EMPLOYEE e WHERE e.EmployeeId = @EmployeeId
    UNION ALL
    SELECT 'Employee', CONCAT('B|', h.EffectiveFrom, '|', h.BranchId) FROM hr.EMPLOYEE_BRANCH_HISTORY h WHERE h.EmployeeId = @EmployeeId
    UNION ALL
    SELECT 'Salary', CONCAT(sc.SalaryComponentId, '|', sc.ComponentTypeId, '|', sc.Amount, '|', sc.CurrencyCode, '|', sc.EffectiveFrom,
                            '|', ISNULL(CONVERT(VARCHAR(10), sc.EffectiveTo, 23), '~'))
    FROM hr.SALARY_COMPONENT sc CROSS JOIN r WHERE sc.EmployeeId = @EmployeeId AND sc.EffectiveFrom <= r.PeriodEnd
    UNION ALL
    SELECT 'Attendance', CONCAT(a.WorkDate, '|', a.[Status], '|', ISNULL(CONVERT(VARCHAR(20), a.DayFraction), '~'), '|',
                                ISNULL(CONVERT(VARCHAR(20), a.ShortfallMinutes), '~'), '|', ISNULL(CONVERT(VARCHAR(20), a.StandardMinutes), '~'), '|',
                                ISNULL(CONVERT(VARCHAR(20), a.WorkedMinutes), '~'), '|', ISNULL(CONVERT(VARCHAR(20), a.OvertimeMinutes), '~'), '|',
                                ISNULL(CONVERT(VARCHAR(20), a.ExitUnpaidDays), '~'))
    FROM attendance.ATTENDANCE_RECORD a CROSS JOIN r WHERE a.EmployeeId = @EmployeeId AND a.WorkDate BETWEEN r.PeriodStart AND r.PeriodEnd
    UNION ALL
    SELECT 'Roster', CONCAT(sa.ShiftAssignmentId, '|', sa.WorkDate, '|', ISNULL(CONVERT(VARCHAR(12), sa.ShiftId), '~'), '|', sa.IsRestDay)
    FROM attendance.SHIFT_ASSIGNMENT sa CROSS JOIN r WHERE sa.EmployeeId = @EmployeeId AND sa.WorkDate BETWEEN r.PeriodStart AND r.PeriodEnd
    UNION ALL
    SELECT 'Leave', CONCAT(lr.LeaveRequestId, '|', lr.LeaveTypeId, '|', lr.FromDate, '|', lr.ToDate, '|', ISNULL(CONVERT(VARCHAR(10), lr.ApprovedToDate, 23), '~'),
                           '|', ISNULL(CONVERT(VARCHAR(20), lr.DaysApproved), '~'), '|', ISNULL(CONVERT(VARCHAR(20), lr.DaysRequested), '~'),
                           '|', ISNULL(lr.HalfDay, '~'), '|', ISNULL(CONVERT(VARCHAR(1), lr.PaidSnapshot), '~'))
    FROM workflow.LEAVE_REQUEST lr
    JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = lr.RequestInstanceId AND ri.[Status] = 'Approved'
    CROSS JOIN r
    WHERE lr.EmployeeId = @EmployeeId AND lr.FromDate <= r.PeriodEnd AND ISNULL(lr.ApprovedToDate, lr.ToDate) >= r.YearStart
    UNION ALL
    SELECT 'Overtime', CONCAT(o.OvertimeRequestId, '|', o.WorkDate, '|', ISNULL(CONVERT(VARCHAR(12), o.ApprovedMinutes), '~'), '|', o.RateMultiplier)
    FROM workflow.OVERTIME_REQUEST o
    JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = o.RequestInstanceId AND ri.[Status] = 'Approved'
    CROSS JOIN r
    WHERE o.EmployeeId = @EmployeeId AND o.WorkDate BETWEEN r.PeriodStart AND r.PeriodEnd
    UNION ALL
    SELECT 'Tips', CONCAT(l.TipDistributionId, '|', l.CurrencyCode, '|', l.Amount)
    FROM workflow.TIP_DISTRIBUTION_LINE l
    JOIN workflow.TIP_DISTRIBUTION td ON td.TipDistributionId = l.TipDistributionId
    CROSS JOIN r
    WHERE l.EmployeeId = @EmployeeId AND td.FinalizedAt IS NOT NULL AND td.ShiftDate BETWEEN r.PeriodStart AND r.PeriodEnd
    UNION ALL
    SELECT 'Expenses', CONCAT(er.ExpenseReimbursementId, '|', er.Amount, '|', ISNULL(CONVERT(VARCHAR(30), er.ApprovedAmount), '~'), '|', er.CurrencyCode)
    FROM payroll.fn_RunExpenses(@PayrollRunId) x
    JOIN workflow.EXPENSE_REIMBURSEMENT er ON er.ExpenseReimbursementId = x.ExpenseReimbursementId
    WHERE x.EmployeeId = @EmployeeId
    UNION ALL
    SELECT 'Adjustments', CONCAT(adj.PayrollAdjustmentId, '|', adj.ComponentTypeId, '|', adj.Amount, '|', adj.CurrencyCode)
    FROM payroll.fn_RunAdjustments(@PayrollRunId) x
    JOIN payroll.PAYROLL_ADJUSTMENT adj ON adj.PayrollAdjustmentId = x.PayrollAdjustmentId
    WHERE x.EmployeeId = @EmployeeId
    UNION ALL
    SELECT 'Advances', CONCAT(a.SalaryAdvanceId, '|', a.RemainingAmount, '|', a.MonthlyDeduction, '|', a.CurrencyCode)
    FROM payroll.SALARY_ADVANCE a CROSS JOIN r
    WHERE a.EmployeeId = @EmployeeId AND a.IsSettled = 0 AND a.RemainingAmount > 0 AND a.FirstDeductionPeriod <= r.PeriodYearMonth
    UNION ALL
    SELECT 'Separation', CONCAT(s.SeparationId, '|', s.CurrencyCode, '|', s.LastWorkingDate, '|', ISNULL(CONVERT(VARCHAR(30), s.UnusedLeaveAmount), '~'),
                                '|', ISNULL(CONVERT(VARCHAR(30), s.IndemnityAmount), '~'), '|', ISNULL(CONVERT(VARCHAR(30), s.OtherDues), '~'),
                                '|', ISNULL(CONVERT(VARCHAR(30), s.Deductions), '~'), '|', ISNULL(CONVERT(VARCHAR(30), s.NoticePayAmount), '~'))
    FROM payroll.fn_RunSeparations(@PayrollRunId) x
    JOIN workflow.SEPARATION s ON s.SeparationId = x.SeparationId
    WHERE x.EmployeeId = @EmployeeId
    UNION ALL
    SELECT 'Payout', CONCAT(p.TerminationDate, '|', p.Balance) FROM payroll.fn_RunLeavePayouts(@PayrollRunId) p WHERE p.EmployeeId = @EmployeeId
), g AS (
    SELECT k.Source, COUNT(*) AS RowsCount,
           HASHBYTES('SHA2_256', STRING_AGG(CAST(k.K AS NVARCHAR(MAX)), N';') WITHIN GROUP (ORDER BY k.K)) AS Fingerprint
    FROM k GROUP BY k.Source
)
SELECT CAST(s.Source AS VARCHAR(20)) AS Source, ISNULL(g.RowsCount, 0) AS RowsCount,
       CAST(ISNULL(g.Fingerprint, 0x00) AS VARBINARY(32)) AS Fingerprint
FROM (VALUES ('Employee'), ('Salary'), ('Attendance'), ('Roster'), ('Leave'), ('Overtime'), ('Tips'), ('Expenses'),
             ('Adjustments'), ('Advances'), ('Separation'), ('Payout')) s(Source)
LEFT JOIN g ON g.Source = s.Source;
GO

/* The run-wide inputs: the settings payroll reads, the NSSF / tax versions in force at the period end, the component and
   leave types and their tiers, the period's holidays and roster months, and the run's own rates. */
CREATE OR ALTER FUNCTION payroll.fn_RunConfig (@PayrollRunId INT)
RETURNS TABLE
AS RETURN
WITH r AS (SELECT PeriodStart, PeriodEnd FROM payroll.PAYROLL_RUN WHERE PayrollRunId = @PayrollRunId),
k AS (
    SELECT CONCAT('s|', st.SettingKey, '=', ISNULL(st.SettingValue, N'~')) AS K FROM core.SETTING st
    WHERE st.SettingKey IN ('StandardWorkingDaysPerMonth', 'StandardWorkDayHours', 'NssfCeilingUsd', 'TaxFamilyDeductionAnnualUsd', 'HolidayWorkRate',
                            'LeavePayoutOnTermination', 'LeaveCountsRestDays', 'PayrollRateType', 'PayrollPrimaryCurrency')
    UNION ALL
    SELECT CONCAT('n|', nr.NssfRateId, '|', nr.EmployeeRate, '|', nr.EmployerRate, '|', nr.IsCeilinged, '|', ISNULL(CONVERT(VARCHAR(30), nr.CeilingAmount), '~'),
                  '|', nr.EffectiveFrom, '|', ISNULL(CONVERT(VARCHAR(10), nr.EffectiveTo, 23), '~'))
    FROM hr.NSSF_RATE nr CROSS JOIN r WHERE nr.EffectiveFrom <= r.PeriodEnd AND (nr.EffectiveTo IS NULL OR nr.EffectiveTo >= r.PeriodEnd)
    UNION ALL
    SELECT CONCAT('x|', b.TaxBracketId, '|', b.MinAnnual, '|', ISNULL(CONVERT(VARCHAR(30), b.MaxAnnual), '~'), '|', b.Rate, '|', b.EffectiveFrom,
                  '|', ISNULL(CONVERT(VARCHAR(10), b.EffectiveTo, 23), '~'))
    FROM hr.TAX_BRACKET b CROSS JOIN r WHERE b.EffectiveFrom <= r.PeriodEnd AND (b.EffectiveTo IS NULL OR b.EffectiveTo >= r.PeriodEnd)
    UNION ALL
    SELECT CONCAT('c|', ct.ComponentTypeId, '|', ISNULL(ct.SystemCode, '~'), '|', ct.Name, '|', ct.Category, '|', ct.[Sign], '|', ct.IsStanding) FROM hr.COMPONENT_TYPE ct
    UNION ALL
    SELECT CONCAT('t|', lt.LeaveTypeId, '|', lt.IsPaid) FROM hr.LEAVE_TYPE lt
    UNION ALL
    SELECT CONCAT('p|', pt.LeaveTypeId, '|', pt.MinServiceYears, '|', pt.FullPayDays, '|', pt.HalfPayDays) FROM hr.LEAVE_PAY_TIER pt
    UNION ALL
    SELECT CONCAT('a|', t.LeaveTypeId, '|', t.MinServiceYears) FROM hr.LEAVE_ACCRUAL_TIER t
    UNION ALL
    SELECT CONCAT('h|', h.HolidayDate, '|', h.IsPaid, '|', ISNULL(CONVERT(VARCHAR(12), h.BranchId), '~'))
    FROM core.HOLIDAY h CROSS JOIN r WHERE h.HolidayDate BETWEEN r.PeriodStart AND r.PeriodEnd
    UNION ALL
    SELECT CONCAT('m|', rm.BranchId, '|', rm.[Status]) FROM attendance.ROSTER_MONTH rm CROSS JOIN r WHERE rm.MonthDate = r.PeriodStart
    UNION ALL
    SELECT CONCAT('r|', rr.FromCurrency, '|', rr.ToCurrency, '|', rr.Rate) FROM payroll.PAYROLL_RUN_RATE rr WHERE rr.PayrollRunId = @PayrollRunId
)
SELECT COUNT(*) AS RowsCount,
       CAST(ISNULL(HASHBYTES('SHA2_256', STRING_AGG(CAST(k.K AS NVARCHAR(MAX)), N';') WITHIN GROUP (ORDER BY k.K)), 0x00) AS VARBINARY(32)) AS Fingerprint
FROM k;
GO

/* WHAT CHANGED SINCE THE RUN WAS GENERATED - one row per employee and source ('Missing' = belongs in the run now and has
   no payslip, 'NotInRun' = has a payslip and no longer belongs, 'Settings' = a run-wide input, EmployeeId NULL).
   Primary runs; a run generated before script 103 has no fingerprints and reads as entirely changed. */
CREATE OR ALTER FUNCTION payroll.fn_RunStaleness (@PayrollRunId INT)
RETURNS TABLE
AS RETURN
WITH ps AS (SELECT p.PayslipId, p.EmployeeId, p.EmployeeName FROM payroll.PAYSLIP p WHERE p.PayrollRunId = @PayrollRunId),
cur AS (SELECT ps.PayslipId, i.Source, i.RowsCount, i.Fingerprint FROM ps CROSS APPLY payroll.fn_PayslipInputs(@PayrollRunId, ps.EmployeeId) i),
sto AS (SELECT pi.PayslipId, pi.Source, pi.RowsCount, pi.Fingerprint FROM payroll.PAYSLIP_INPUT pi JOIN ps ON ps.PayslipId = pi.PayslipId),
d AS (SELECT ISNULL(c.PayslipId, s.PayslipId) AS PayslipId, ISNULL(c.Source, s.Source) AS Source
      FROM cur c FULL JOIN sto s ON s.PayslipId = c.PayslipId AND s.Source = c.Source
      WHERE c.PayslipId IS NULL OR s.PayslipId IS NULL OR c.RowsCount <> s.RowsCount OR c.Fingerprint <> s.Fingerprint)
SELECT ps.EmployeeId, ps.EmployeeName, CAST(d.Source AS VARCHAR(20)) AS Source
FROM d JOIN ps ON ps.PayslipId = d.PayslipId
UNION ALL
SELECT re.EmployeeId, e.FullName, CAST('Missing' AS VARCHAR(20))
FROM payroll.fn_RunEmployees(@PayrollRunId) re
JOIN hr.EMPLOYEE e ON e.EmployeeId = re.EmployeeId
WHERE NOT EXISTS (SELECT 1 FROM ps WHERE ps.EmployeeId = re.EmployeeId)
UNION ALL
SELECT ps.EmployeeId, ps.EmployeeName, CAST('NotInRun' AS VARCHAR(20))
FROM ps
WHERE NOT EXISTS (SELECT 1 FROM payroll.fn_RunEmployees(@PayrollRunId) re WHERE re.EmployeeId = ps.EmployeeId)
UNION ALL
SELECT NULL, NULL, CAST('Settings' AS VARCHAR(20))
FROM payroll.PAYROLL_RUN rr
CROSS APPLY payroll.fn_RunConfig(@PayrollRunId) c
WHERE rr.PayrollRunId = @PayrollRunId AND (rr.InputsFingerprint IS NULL OR rr.InputsFingerprint <> c.Fingerprint);
GO

/* ------------------------- 6. create: readiness of the completed days; rates above zero -------------------------
   Body of script 81 with: the gate through usp_PayrollRun_AssertReady (completed days only, QA3 PAY-4 / ATT-11) and a
   rate of 0 never snapshotted (CON-9). */
CREATE OR ALTER PROCEDURE payroll.usp_PayrollRun_Create
    @PeriodYearMonth CHAR(7), @CreatedByUserId INT,
    @Notes NVARCHAR(500)=NULL, @RunType VARCHAR(12)='Primary',
    @AsOfDate DATE = NULL      -- script 81: the clock. NULL = today in Beirut; a caller passes a date only to test the rule
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;

    /* script 78 (BUG-18): an explicit NULL or blank from the API means "the default", i.e. Primary. */
    SET @RunType = ISNULL(NULLIF(LTRIM(RTRIM(@RunType)), ''), 'Primary');

    IF payroll.fn_UserHasRole(@CreatedByUserId, N'HR') = 0
       AND payroll.fn_UserHasRole(@CreatedByUserId, N'Admin') = 0
    BEGIN RAISERROR('Payroll runs are prepared by HR.',16,1); RETURN 1; END
    IF @RunType NOT IN ('Primary','Supplemental')
    BEGIN RAISERROR('RunType is Primary or Supplemental.',16,1); RETURN 1; END
    IF @PeriodYearMonth NOT LIKE '[12][0-9][0-9][0-9]-[01][0-9]' OR TRY_CAST(@PeriodYearMonth + '-01' AS DATE) IS NULL
    BEGIN RAISERROR('The period must look like 2026-08.',16,1); RETURN 1; END

    DECLARE @Start DATE = CAST(@PeriodYearMonth + '-01' AS DATE);
    DECLARE @End   DATE = EOMONTH(@Start);
    DECLARE @Today DATE = ISNULL(@AsOfDate, CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE));
    DECLARE @UpTo  DATE = CASE WHEN DATEADD(DAY, -1, @Today) < @End THEN DATEADD(DAY, -1, @Today) ELSE @End END;   -- completed days
    DECLARE @rc INT;

    IF @RunType = 'Primary'
    BEGIN
        IF EXISTS (SELECT 1 FROM payroll.PAYROLL_RUN
                   WHERE PeriodYearMonth=@PeriodYearMonth AND RunType='Primary' AND [Status] <> 'Cancelled')
        BEGIN
            DECLARE @P1 CHAR(7)=@PeriodYearMonth;
            RAISERROR('A primary run for %s already exists. Cancel it first if it must be redone.',16,1,@P1);
            RETURN 1;
        END
        /* script 81: a primary may be created on ANY DAY OF ITS PERIOD - from the 1st on, not before */
        IF @Start > @Today
        BEGIN
            DECLARE @P0 CHAR(7)=@PeriodYearMonth; DECLARE @P0d VARCHAR(10)=CONVERT(VARCHAR(10),@Start,23);
            RAISERROR('The period %s has not started yet. Its primary run can be created from %s.',16,1,@P0,@P0d);
            RETURN 1;
        END
        EXEC @rc = payroll.usp_PayrollRun_AssertReady @PeriodYearMonth = @PeriodYearMonth, @AsOfDate = @Today;
        IF @rc <> 0 RETURN 1;
    END
    ELSE
    BEGIN
        IF EXISTS (SELECT 1 FROM payroll.PAYROLL_RUN
                   WHERE PeriodYearMonth=@PeriodYearMonth AND RunType='Supplemental' AND [Status] IN ('Draft','Review'))
        BEGIN RAISERROR('An open supplemental for this period already exists. Finish or cancel it first.',16,1); RETURN 1; END
        IF NOT EXISTS (SELECT 1 FROM payroll.PAYROLL_ADJUSTMENT
                       WHERE TargetPeriod=@PeriodYearMonth AND AppliedToPayslipId IS NULL)
        BEGIN
            DECLARE @P3 CHAR(7)=@PeriodYearMonth;
            RAISERROR('No approved, unpaid adjustments target %s. There is nothing for a supplemental to pay.',16,1,@P3);
            RETURN 1;
        END
    END

    DECLARE @Primary CHAR(3) = ISNULL((SELECT SettingValue FROM core.SETTING WHERE SettingKey='PayrollPrimaryCurrency'),'USD');
    DECLARE @RateType VARCHAR(20) = ISNULL((SELECT SettingValue FROM core.SETTING WHERE SettingKey='PayrollRateType'),'Official');

    BEGIN TRAN;
    INSERT INTO payroll.PAYROLL_RUN
        (PeriodYearMonth,PeriodStart,PeriodEnd,PrimaryCurrency,Notes,CreatedByUserId,RunType)
    VALUES (@PeriodYearMonth,@Start,@End,@Primary,@Notes,@CreatedByUserId,@RunType);
    DECLARE @RunId INT = SCOPE_IDENTITY();

    ;WITH ccy AS (
        SELECT DISTINCT CurrencyCode FROM hr.SALARY_COMPONENT WHERE EffectiveTo IS NULL
        UNION SELECT CurrencyCode FROM workflow.TIP_DISTRIBUTION_AMOUNT
        UNION SELECT CurrencyCode FROM workflow.EXPENSE_REIMBURSEMENT
        UNION SELECT CurrencyCode FROM payroll.SALARY_ADVANCE WHERE IsSettled=0
        UNION SELECT CurrencyCode FROM payroll.PAYROLL_ADJUSTMENT WHERE AppliedToPayslipId IS NULL
        UNION SELECT @Primary
    )
    INSERT INTO payroll.PAYROLL_RUN_RATE
        (PayrollRunId,FromCurrency,ToCurrency,Rate,RateType,SourceEffectiveDate)
    SELECT @RunId, c.CurrencyCode, @Primary, x.Rate, x.RateType, x.EffectiveDate
    FROM ccy c
    CROSS APPLY (
        SELECT TOP 1
               CAST(CASE WHEN er.FromCurrency=c.CurrencyCode THEN er.Rate ELSE 1.0/er.Rate END AS DECIMAL(28,12)) AS Rate,
               er.RateType, er.EffectiveDate
        FROM core.EXCHANGE_RATE er
        WHERE ((er.FromCurrency=c.CurrencyCode AND er.ToCurrency=@Primary)
            OR (er.FromCurrency=@Primary AND er.ToCurrency=c.CurrencyCode))
          AND er.RateType=@RateType AND er.EffectiveDate <= @End
          AND er.Rate > 0                                   -- QA3 CON-9: a rate lost to rounding (0) is never used
        ORDER BY er.EffectiveDate DESC, er.ExchangeRateId DESC
    ) x
    WHERE c.CurrencyCode <> @Primary;

    IF @RunType='Primary'
    BEGIN
        DECLARE @NoRate CHAR(3) = (
            SELECT TOP 1 sc.CurrencyCode FROM hr.SALARY_COMPONENT sc
            WHERE sc.EffectiveTo IS NULL AND sc.CurrencyCode <> @Primary
              AND NOT EXISTS (SELECT 1 FROM payroll.PAYROLL_RUN_RATE r
                              WHERE r.PayrollRunId=@RunId AND r.FromCurrency=sc.CurrencyCode));
        IF @NoRate IS NOT NULL
        BEGIN
            ROLLBACK TRAN;
            DECLARE @P4 CHAR(3)=@NoRate; DECLARE @P5 VARCHAR(20)=@RateType;
            RAISERROR('No %s rate of type %s is on file. Add the rate, then create the run.',16,1,@P4,@P5);
            RETURN 1;
        END
    END

    INSERT INTO payroll.PAYROLL_RUN_EVENT (PayrollRunId,[Action],ActedByUserId,Detail)
    VALUES (@RunId,'Created',@CreatedByUserId,
            CONCAT(@RunType,N' run for ',@PeriodYearMonth,N', rates read as of the period end (re-read while Draft, frozen from Review)',
                   CASE WHEN @RunType='Primary' AND @UpTo < @End
                        THEN CONCAT(N'; created on ',CONVERT(NVARCHAR(10),@Today,23),N', attendance checked up to ',CONVERT(NVARCHAR(10),@UpTo,23)) ELSE N'' END));
    COMMIT TRAN;

    SELECT @RunId AS PayrollRunId, @PeriodYearMonth AS PeriodYearMonth,
           'Draft' AS [Status], @Primary AS PrimaryCurrency, @RunType AS RunType;
END;
GO

/* ------------------------- 7. the primary generator -------------------------
   Body of script 86 with the QA3 changes named in place. Section letters as in 86 (the handoff's A-I differ). */
CREATE OR ALTER PROCEDURE payroll.usp_PayrollRun_Generate
    @PayrollRunId INT, @ActedByUserId INT,
    @AsOfDate DATE = NULL      -- script 81: the clock. NULL = today in Beirut; a caller passes a date only to test the rule
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;

    DECLARE @Status VARCHAR(12), @Start DATE, @End DATE, @Primary CHAR(3), @Period CHAR(7), @RunType VARCHAR(12);
    SELECT @Status=[Status], @Start=PeriodStart, @End=PeriodEnd, @Primary=PrimaryCurrency, @Period=PeriodYearMonth, @RunType=RunType
    FROM payroll.PAYROLL_RUN WHERE PayrollRunId=@PayrollRunId;
    IF @Status IS NULL BEGIN RAISERROR('No such payroll run.',16,1); RETURN 1; END
    IF @Status NOT IN ('Draft','Review')
    BEGIN RAISERROR('This run is locked. A locked run is never regenerated - corrections go to the next period.',16,1); RETURN 1; END
    IF @RunType = 'Supplemental'
    BEGIN RAISERROR('A supplemental run pays its signed adjustments only - it has its own generator (usp_PayrollRun_GenerateSupplemental).',16,1); RETURN 1; END

    /* QA3 ATT-11: COMPLETED days only - up to yesterday in Beirut, never past the period's end. Today and later days are
       paid as scheduled: their shifts are still running. */
    DECLARE @Today DATE = ISNULL(@AsOfDate, CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE));
    DECLARE @UpTo  DATE = CASE WHEN DATEADD(DAY, -1, @Today) < @End THEN DATEADD(DAY, -1, @Today) ELSE @End END;

    /* QA3 PAY-4: the readiness gate of Create, asked again for the days that are complete now */
    DECLARE @rc INT;
    EXEC @rc = payroll.usp_PayrollRun_AssertReady @PeriodYearMonth = @Period, @AsOfDate = @Today;
    IF @rc <> 0 RETURN 1;

    /* QA3 PAY-10: the types payroll writes are found by their SYSTEM CODE - a rename on the Component types page no longer
       silently drops a line */
    SELECT SystemCode AS Code, ComponentTypeId, Name, Category, [Sign] INTO #CT FROM hr.COMPONENT_TYPE WHERE SystemCode IS NOT NULL;
    DECLARE @MissingCode VARCHAR(30) = (
        SELECT TOP 1 v.Code FROM (VALUES ('BASIC'),('OVERTIME'),('HOLIDAY_WORK'),('LATE'),('UNPAID_LEAVE'),('ABSENCE'),('TIPS'),('EXPENSE'),
                                         ('ADVANCE'),('UNUSED_LEAVE'),('INDEMNITY'),('LEAVE_PAYOUT'),('LEAVE_DEDUCTION'),
                                         ('NSSF_EMPLOYEE'),('NSSF_EMPLOYER'),('INCOME_TAX')) v(Code)
        WHERE NOT EXISTS (SELECT 1 FROM #CT c WHERE c.Code = v.Code) ORDER BY v.Code);
    IF @MissingCode IS NOT NULL
    BEGIN
        RAISERROR('Payroll needs the system component type %s and it is missing. Restore it on the Component types page (or re-apply script 103), then generate.',16,1,@MissingCode);
        RETURN 1;
    END

    DECLARE @DaysPerMonth DECIMAL(6,2) = ISNULL(NULLIF(TRY_CAST((SELECT SettingValue FROM core.SETTING
        WHERE SettingKey='StandardWorkingDaysPerMonth') AS DECIMAL(6,2)),0),26);
    /* QA3 PAY-14 / REL-16: the hour rate reads StandardWorkDayHours (the key on the Settings page). The old key
       StandardHoursPerDay does not exist, so the rate was always taken over 8 hours. */
    DECLARE @HoursPerDay DECIMAL(6,2) = ISNULL(NULLIF(TRY_CAST((SELECT SettingValue FROM core.SETTING
        WHERE SettingKey='StandardWorkDayHours') AS DECIMAL(6,2)),0),8);
    DECLARE @Ceiling DECIMAL(18,2) = ISNULL(TRY_CAST((SELECT SettingValue FROM core.SETTING
        WHERE SettingKey='NssfCeilingUsd') AS DECIMAL(18,2)),999999);
    DECLARE @FamilyDed DECIMAL(18,2) = ISNULL(TRY_CAST((SELECT SettingValue FROM core.SETTING
        WHERE SettingKey='TaxFamilyDeductionAnnualUsd') AS DECIMAL(18,2)),0);
    DECLARE @HolidayRate DECIMAL(6,2) = ISNULL(TRY_CAST((SELECT SettingValue FROM core.SETTING WHERE SettingKey='HolidayWorkRate') AS DECIMAL(6,2)), 2.0);
    DECLARE @RateType VARCHAR(20) = ISNULL((SELECT SettingValue FROM core.SETTING WHERE SettingKey='PayrollRateType'),'Official');
    DECLARE @DaysInMonth INT = DAY(@End);
    DECLARE @YearStart DATE = DATEFROMPARTS(YEAR(@Start), 1, 1);
    /* QA3 PAY-9: ONE tax table per month - the version in force on the period's last day */
    DECLARE @TaxFrom DATE = (SELECT MAX(EffectiveFrom) FROM hr.TAX_BRACKET
                             WHERE EffectiveFrom <= @End AND (EffectiveTo IS NULL OR EffectiveTo >= @End));

    BEGIN TRAN;

    /* QA3 REL-11: while the run is a Draft its rates are re-read as of the period end (a rate corrected or a currency first
       used after Create is picked up); from Review on the snapshot is frozen (a currency missing from it is added below). */
    IF @Status = 'Draft'
    BEGIN
        DELETE FROM payroll.PAYROLL_RUN_RATE WHERE PayrollRunId=@PayrollRunId;
        INSERT INTO payroll.PAYROLL_RUN_RATE (PayrollRunId,FromCurrency,ToCurrency,Rate,RateType,SourceEffectiveDate)
        SELECT @PayrollRunId, c.CurrencyCode, @Primary, x.Rate, x.RateType, x.EffectiveDate
        FROM core.CURRENCY c
        CROSS APPLY (SELECT TOP 1 CAST(CASE WHEN er.FromCurrency=c.CurrencyCode THEN er.Rate ELSE 1.0/er.Rate END AS DECIMAL(28,12)) AS Rate,
                            er.RateType, er.EffectiveDate
                     FROM core.EXCHANGE_RATE er
                     WHERE ((er.FromCurrency=c.CurrencyCode AND er.ToCurrency=@Primary) OR (er.FromCurrency=@Primary AND er.ToCurrency=c.CurrencyCode))
                       AND er.RateType=@RateType AND er.EffectiveDate <= @End AND er.Rate > 0
                     ORDER BY er.EffectiveDate DESC, er.ExchangeRateId DESC) x
        WHERE c.CurrencyCode <> @Primary;
    END

    DELETE FROM payroll.PAYSLIP WHERE PayrollRunId=@PayrollRunId;   -- lines and fingerprints cascade

    /* -- payslip shells (QA3 REL-5 soft-deleted with activity, PAY-2 settlement-only leavers); the branch is the branch
          OF THE PERIOD - on the employee's last day in it (QA3 PAY-15); no position is no reason to drop a payslip -- */
    INSERT INTO payroll.PAYSLIP
        (PayrollRunId,EmployeeId,EmployeeName,PositionTitle,BranchName,NssfNumber,HireDate)
    SELECT @PayrollRunId, e.EmployeeId, e.FullName, p.Title, b.Name, e.NssfNumber, e.HireDate
    FROM payroll.fn_RunEmployees(@PayrollRunId) re
    JOIN hr.EMPLOYEE e ON e.EmployeeId=re.EmployeeId
    LEFT JOIN hr.[POSITION] p ON p.PositionId=e.PositionId
    LEFT JOIN hr.BRANCH b ON b.BranchId = hr.fn_EmployeeBranchOn(e.EmployeeId,
                               CASE WHEN e.TerminationDate IS NOT NULL AND e.TerminationDate < @End THEN e.TerminationDate ELSE @End END);

    /* the employment inside the period (QA3 REL-1): EmpFrom..EmpTo; attendance counts EmpFrom..AttTo (completed days).
       A settlement-only payslip has EmpTo < EmpFrom: nothing of the month is paid or deducted on it. */
    SELECT ps.PayslipId, ps.EmployeeId, e.HireDate, e.TerminationDate,
           CASE WHEN e.HireDate > @Start THEN e.HireDate ELSE @Start END AS EmpFrom,
           CASE WHEN e.TerminationDate IS NOT NULL AND e.TerminationDate < @End THEN e.TerminationDate ELSE @End END AS EmpTo,
           CASE WHEN e.TerminationDate IS NOT NULL AND e.TerminationDate < @UpTo THEN e.TerminationDate ELSE @UpTo END AS AttTo,
           /* QA3 PAY-13: WHOLE years of service at the period start (DATEDIFF(YEAR) counted calendar boundaries) */
           (DATEDIFF(MONTH, e.HireDate, @Start) - CASE WHEN DAY(e.HireDate) > DAY(@Start) THEN 1 ELSE 0 END) / 12 AS ServiceYears
    INTO #Emp
    FROM payroll.PAYSLIP ps
    JOIN hr.EMPLOYEE e ON e.EmployeeId=ps.EmployeeId
    WHERE ps.PayrollRunId=@PayrollRunId;

    /* -- A. standing components, prorated by the days EACH ONE was in force (script 86, QA2-20) --
          QA3 PAY-6 / REL-2: a row is SUPERSEDED from the day a later-starting row of the same employee, type and currency
          starts - so a raise added without closing the old row (the retired raw path) pays 15/30 + 15/30, never both in
          full. Two rows starting the same day: the later one (higher id) stands. -- */
    INSERT INTO payroll.PAYSLIP_LINE
        (PayslipId,ComponentTypeId,ComponentName,Category,[Sign],Amount,CurrencyCode,
         SourceType,SourceId,Quantity,UnitAmount,Note,SortOrder)
    SELECT x.PayslipId, ct.ComponentTypeId, ct.Name, ct.Category, ct.[Sign],
           ROUND(sc.Amount * w.CoverDays / @DaysInMonth, 2), sc.CurrencyCode,
           'Salary', sc.SalaryComponentId, NULL, NULL,
           CASE WHEN w.CoverDays < @DaysInMonth
                THEN CONCAT(N'Prorated ', CAST(w.CoverDays AS INT), N'/', @DaysInMonth, N' of the month (', FORMAT(CAST(w.CoverDays AS DECIMAL(9,4)) / @DaysInMonth, '0.00'),
                            N'): ', CONVERT(NVARCHAR(10), w.FromD, 23), N' to ', CONVERT(NVARCHAR(10), w.ToD, 23)) END,
           10
    FROM #Emp x
    JOIN hr.SALARY_COMPONENT sc ON sc.EmployeeId=x.EmployeeId
    JOIN hr.COMPONENT_TYPE ct ON ct.ComponentTypeId=sc.ComponentTypeId AND ct.IsStanding=1
    OUTER APPLY (SELECT MIN(s2.EffectiveFrom) AS NextFrom
                 FROM hr.SALARY_COMPONENT s2
                 WHERE s2.EmployeeId=sc.EmployeeId AND s2.ComponentTypeId=sc.ComponentTypeId AND s2.CurrencyCode=sc.CurrencyCode
                   AND (s2.EffectiveFrom > sc.EffectiveFrom OR (s2.EffectiveFrom = sc.EffectiveFrom AND s2.SalaryComponentId > sc.SalaryComponentId))) nx
    CROSS APPLY (SELECT FromD = (SELECT MAX(v) FROM (VALUES (@Start), (x.HireDate), (sc.EffectiveFrom)) f(v)),
                        ToD   = (SELECT MIN(v) FROM (VALUES (@End), (ISNULL(x.TerminationDate, @End)), (ISNULL(sc.EffectiveTo, @End)),
                                                            (ISNULL(DATEADD(DAY, -1, nx.NextFrom), @End))) t(v))) r0
    CROSS APPLY (SELECT r0.FromD, r0.ToD, CAST(DATEDIFF(DAY, r0.FromD, r0.ToD) + 1 AS DECIMAL(9,4)) AS CoverDays) w
    WHERE sc.EffectiveFrom <= @End AND (sc.EffectiveTo IS NULL OR sc.EffectiveTo >= @Start)
      AND w.CoverDays > 0;

    /* day and hour rates, per employee: ONE basic row (code BASIC) - the one in force on the employee's last day in the
       period (script 86); for a settlement-only payslip, the one in force on the termination date */
    SELECT x.PayslipId, x.EmployeeId, sc.CurrencyCode,
           CAST(sc.Amount / @DaysPerMonth AS DECIMAL(18,4)) AS DayRate,
           CAST(sc.Amount / @DaysPerMonth / @HoursPerDay AS DECIMAL(18,4)) AS HourRate
    INTO #Rate
    FROM #Emp x
    CROSS APPLY (SELECT TOP 1 s2.Amount, s2.CurrencyCode
                 FROM hr.SALARY_COMPONENT s2
                 JOIN #CT c ON c.ComponentTypeId=s2.ComponentTypeId AND c.Code='BASIC'
                 WHERE s2.EmployeeId=x.EmployeeId AND s2.EffectiveFrom <= x.EmpTo
                   AND (s2.EffectiveTo IS NULL OR s2.EffectiveTo >= CASE WHEN x.EmpTo < @Start THEN x.EmpTo ELSE @Start END)
                 ORDER BY CASE WHEN s2.EffectiveTo IS NULL OR s2.EffectiveTo >= x.EmpTo THEN 0 ELSE 1 END,
                          s2.EffectiveFrom DESC, s2.SalaryComponentId DESC) sc;

    /* -- B. unpaid leave: the WORKING days of the APPROVED span inside the period and the employment
          (QA3 PAY-8: ISNULL(ApprovedToDate, ToDate) - a partial approval keeps the first days; ISNULL(PaidSnapshot, IsPaid)
          - flipping the type later never re-prices an approved leave); half a day for a half-day request -- */
    INSERT INTO payroll.PAYSLIP_LINE
        (PayslipId,ComponentTypeId,ComponentName,Category,[Sign],Amount,CurrencyCode,
         SourceType,SourceId,Quantity,UnitAmount,Note,SortOrder)
    SELECT r.PayslipId, ct.ComponentTypeId, ct.Name, ct.Category, ct.[Sign],
           ROUND(d.DaysInPeriod * r.DayRate, 2), r.CurrencyCode,
           'Leave', d.LeaveRequestId, d.DaysInPeriod, r.DayRate,
           CONCAT(d.DaysInPeriod, N' unpaid day(s)'), 20
    FROM #Rate r
    JOIN #Emp x ON x.PayslipId=r.PayslipId
    CROSS APPLY (
        SELECT lr.LeaveRequestId,
               CAST((SELECT CASE WHEN lr.HalfDay IS NOT NULL THEN 0.5 * ISNULL(MAX(CAST(ld.Counts AS INT)), 0)
                                 ELSE ISNULL(SUM(CAST(ld.Counts AS INT)), 0) END
                     FROM hr.fn_LeaveDays(lr.EmployeeId, w.F, w.T) ld) AS DECIMAL(6,2)) AS DaysInPeriod
        FROM workflow.LEAVE_REQUEST lr
        JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId=lr.RequestInstanceId AND ri.[Status]='Approved'
        JOIN hr.LEAVE_TYPE lt ON lt.LeaveTypeId=lr.LeaveTypeId
        CROSS APPLY (SELECT CASE WHEN lr.FromDate > x.EmpFrom THEN lr.FromDate ELSE x.EmpFrom END AS F,
                            CASE WHEN ISNULL(lr.ApprovedToDate, lr.ToDate) < x.EmpTo THEN ISNULL(lr.ApprovedToDate, lr.ToDate) ELSE x.EmpTo END AS T) w
        WHERE lr.EmployeeId=r.EmployeeId AND ISNULL(lr.PaidSnapshot, lt.IsPaid)=0 AND w.F <= w.T
    ) d
    JOIN #CT ct ON ct.Code='UNPAID_LEAVE'
    WHERE d.DaysInPeriod > 0;

    /* -- C. sick pay tiers (QA3 LEV-16 / LEV-13 / PAY-13): the counted days of the approved leaves of every TIERED type (a
          type with LEAVE_PAY_TIER rows - keyed on its id, not on the name 'Sick') are numbered DAY BY DAY across the year;
          a day inside the full-pay band costs nothing, inside the half-pay band half a day, beyond it a whole day. Each
          period pays for its own days, so a leave crossing a month end is split by day. Tier = whole years of service. -- */
    ;WITH sreq AS (
        SELECT lr.LeaveRequestId, lr.EmployeeId, lr.LeaveTypeId, lr.HalfDay,
               CASE WHEN lr.FromDate > @YearStart THEN lr.FromDate ELSE @YearStart END AS F,
               CASE WHEN ISNULL(lr.ApprovedToDate, lr.ToDate) < x.EmpTo THEN ISNULL(lr.ApprovedToDate, lr.ToDate) ELSE x.EmpTo END AS T
        FROM workflow.LEAVE_REQUEST lr
        JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId=lr.RequestInstanceId AND ri.[Status]='Approved'
        JOIN #Emp x ON x.EmployeeId=lr.EmployeeId
        WHERE EXISTS (SELECT 1 FROM hr.LEAVE_PAY_TIER pt WHERE pt.LeaveTypeId=lr.LeaveTypeId)
          AND lr.FromDate <= @End AND ISNULL(lr.ApprovedToDate, lr.ToDate) >= @YearStart
    ), sday AS (
        SELECT s.LeaveRequestId, s.EmployeeId, s.LeaveTypeId, ld.WorkDate,
               CAST(CASE WHEN s.HalfDay IS NOT NULL THEN 0.5 ELSE 1.0 END AS DECIMAL(9,2)) AS U
        FROM sreq s
        CROSS APPLY hr.fn_LeaveDays(s.EmployeeId, s.F, s.T) ld
        WHERE s.F <= s.T AND ld.Counts = 1
    ), numbered AS (
        SELECT d.LeaveRequestId, d.EmployeeId, d.LeaveTypeId, d.WorkDate, d.U,
               SUM(d.U) OVER (PARTITION BY d.EmployeeId, d.LeaveTypeId ORDER BY d.WorkDate, d.LeaveRequestId ROWS UNBOUNDED PRECEDING) - d.U AS Before
        FROM sday d
    ), costed AS (
        SELECT n.EmployeeId, n.LeaveRequestId,
               /* half-pay band [Full, Full+Half): 0.5 a day; beyond it: 1.0 a day - the overlap of [Before, Before+U) with each */
               0.5 * (CASE WHEN (CASE WHEN n.Before + n.U < t.FullPlusHalf THEN n.Before + n.U ELSE t.FullPlusHalf END)
                                - (CASE WHEN n.Before > t.FullPayDays THEN n.Before ELSE t.FullPayDays END) > 0
                           THEN (CASE WHEN n.Before + n.U < t.FullPlusHalf THEN n.Before + n.U ELSE t.FullPlusHalf END)
                                - (CASE WHEN n.Before > t.FullPayDays THEN n.Before ELSE t.FullPayDays END) ELSE 0 END)
             + 1.0 * (CASE WHEN n.Before + n.U - (CASE WHEN n.Before > t.FullPlusHalf THEN n.Before ELSE t.FullPlusHalf END) > 0
                           THEN n.Before + n.U - (CASE WHEN n.Before > t.FullPlusHalf THEN n.Before ELSE t.FullPlusHalf END) ELSE 0 END) AS CostDays
        FROM numbered n
        JOIN #Emp x ON x.EmployeeId=n.EmployeeId
        CROSS APPLY (SELECT TOP 1 pt.FullPayDays, pt.FullPayDays + pt.HalfPayDays AS FullPlusHalf
                     FROM hr.LEAVE_PAY_TIER pt
                     WHERE pt.LeaveTypeId=n.LeaveTypeId AND pt.MinServiceYears <= x.ServiceYears
                     ORDER BY pt.MinServiceYears DESC) t
        WHERE n.WorkDate BETWEEN @Start AND @End
    )
    INSERT INTO payroll.PAYSLIP_LINE
        (PayslipId,ComponentTypeId,ComponentName,Category,[Sign],Amount,CurrencyCode,
         SourceType,SourceId,Quantity,UnitAmount,Note,SortOrder)
    SELECT r.PayslipId, ct.ComponentTypeId, ct.Name, ct.Category, ct.[Sign],
           ROUND(c.CostDays * r.DayRate, 2), r.CurrencyCode,
           'Leave', c.LeaveRequestId, c.CostDays, r.DayRate,
           CONCAT(N'Sick pay tiers: ',FORMAT(c.CostDays,'0.##'),N' day(s) unpaid portion'), 21
    FROM (SELECT EmployeeId, LeaveRequestId, CAST(SUM(CostDays) AS DECIMAL(6,2)) AS CostDays FROM costed GROUP BY EmployeeId, LeaveRequestId) c
    JOIN #Rate r ON r.EmployeeId=c.EmployeeId
    JOIN #CT ct ON ct.Code='ABSENCE'
    WHERE c.CostDays > 0;

    /* -- D. short days (script 78 BUG-06, script 86 QA2-22): a worked or absent day on a rostered shift of an approved
          roster month, not covered by an approved full-day leave (ISNULL(ApprovedToDate, ToDate), QA3 PAY-8), from the
          first day employed to the last COMPLETED day employed (QA3 REL-1, ATT-11) -- */
    INSERT INTO payroll.PAYSLIP_LINE
        (PayslipId,ComponentTypeId,ComponentName,Category,[Sign],Amount,CurrencyCode,
         SourceType,SourceId,Quantity,UnitAmount,Note,SortOrder)
    SELECT r.PayslipId, ct.ComponentTypeId, ct.Name, ct.Category, ct.[Sign],
           ROUND(sh.MissingDays * r.DayRate, 2), r.CurrencyCode,
           'Attendance', NULL, sh.MissingDays, r.DayRate,
           CONCAT(FORMAT(sh.MissingDays,'0.##'),N' day(s) short across ',sh.DaysAffected,N' date(s)'), 22
    FROM #Rate r
    JOIN (
        SELECT a.EmployeeId,
               SUM(CASE WHEN a.ShortfallMinutes > 0 AND a.StandardMinutes > 0
                        THEN CAST(a.ShortfallMinutes AS DECIMAL(18,8)) / a.StandardMinutes
                        ELSE CAST(1 - a.DayFraction AS DECIMAL(18,8)) END) AS MissingDays,
               COUNT(*) AS DaysAffected
        FROM attendance.ATTENDANCE_RECORD a
        JOIN #Emp x ON x.EmployeeId=a.EmployeeId
        WHERE a.WorkDate BETWEEN x.EmpFrom AND x.AttTo
          AND a.[Status] NOT IN ('RestDay','Leave','Holiday')
          AND a.DayFraction IS NOT NULL
          AND a.DayFraction < 1
          AND EXISTS (SELECT 1
                      FROM attendance.SHIFT_ASSIGNMENT sa
                      JOIN attendance.ROSTER_MONTH rm
                        ON rm.BranchId=hr.fn_EmployeeBranchOn(a.EmployeeId, a.WorkDate)
                       AND rm.MonthDate=DATEFROMPARTS(YEAR(a.WorkDate),MONTH(a.WorkDate),1)
                       AND rm.[Status]='Approved'
                      WHERE sa.EmployeeId=a.EmployeeId AND sa.WorkDate=a.WorkDate
                        AND sa.IsRestDay=0 AND sa.ShiftId IS NOT NULL)
          AND NOT EXISTS (SELECT 1 FROM workflow.LEAVE_REQUEST lr
                          JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId=lr.RequestInstanceId
                          WHERE ri.[Status]='Approved' AND lr.EmployeeId=a.EmployeeId
                            AND lr.HalfDay IS NULL
                            AND a.WorkDate BETWEEN lr.FromDate AND ISNULL(lr.ApprovedToDate, lr.ToDate))
        GROUP BY a.EmployeeId
        HAVING SUM(CASE WHEN a.ShortfallMinutes > 0 AND a.StandardMinutes > 0
                        THEN CAST(a.ShortfallMinutes AS DECIMAL(18,8)) / a.StandardMinutes
                        ELSE CAST(1 - a.DayFraction AS DECIMAL(18,8)) END) > 0.0005
    ) sh ON sh.EmployeeId=r.EmployeeId
    JOIN #CT ct ON ct.Code='LATE';

    /* -- D2. HOLIDAY WORK (script 86, D1): worked minutes on a public holiday x (day rate / the day's standard) x
          (HolidayWorkRate - 1), inside the employment and the completed days (QA3 REL-1) -- */
    IF @HolidayRate > 1
        INSERT INTO payroll.PAYSLIP_LINE
            (PayslipId,ComponentTypeId,ComponentName,Category,[Sign],Amount,CurrencyCode,
             SourceType,SourceId,Quantity,UnitAmount,Note,SortOrder)
        SELECT r.PayslipId, ct.ComponentTypeId, ct.Name, ct.Category, ct.[Sign],
               ROUND(hw.PaidShare * r.DayRate * (@HolidayRate - 1), 2), r.CurrencyCode,
               'Attendance', NULL, hw.Minutes, r.DayRate,
               CONCAT(hw.Minutes, N' min worked on ', hw.DaysWorked, N' public holiday(s), premium ', FORMAT(@HolidayRate - 1, '0.##'), N' ', NCHAR(215), N' the day rate'), 23
        FROM #Rate r
        JOIN (SELECT a.EmployeeId, SUM(a.WorkedMinutes) AS Minutes, COUNT(*) AS DaysWorked,
                     SUM(CAST(a.WorkedMinutes AS DECIMAL(18,8)) / CASE WHEN a.StandardMinutes > 0 THEN a.StandardMinutes ELSE core.fn_StandardDayMinutes() END) AS PaidShare
              FROM attendance.ATTENDANCE_RECORD a
              JOIN #Emp x ON x.EmployeeId=a.EmployeeId
              WHERE a.WorkDate BETWEEN x.EmpFrom AND x.AttTo AND a.[Status] = 'Holiday' AND a.WorkedMinutes > 0
              GROUP BY a.EmployeeId) hw ON hw.EmployeeId = r.EmployeeId
        JOIN #CT ct ON ct.Code='HOLIDAY_WORK';

    /* an UNPAID public holiday: whoever was rostered to work it - in an APPROVED roster month of the branch of the day
       (QA3: unapproved months no longer count), inside the employment and the completed days - loses the day */
    INSERT INTO payroll.PAYSLIP_LINE
        (PayslipId,ComponentTypeId,ComponentName,Category,[Sign],Amount,CurrencyCode,
         SourceType,SourceId,Quantity,UnitAmount,Note,SortOrder)
    SELECT r.PayslipId, ct.ComponentTypeId, ct.Name, ct.Category, ct.[Sign],
           ROUND(uh.Days * r.DayRate, 2), r.CurrencyCode, 'Attendance', NULL, uh.Days, r.DayRate,
           CONCAT(uh.Days, N' unpaid public holiday(s)'), 24
    FROM #Rate r
    JOIN (SELECT sa.EmployeeId, CAST(COUNT(*) AS DECIMAL(6,2)) AS Days
          FROM attendance.SHIFT_ASSIGNMENT sa
          JOIN #Emp x ON x.EmployeeId = sa.EmployeeId
          JOIN core.HOLIDAY h ON h.HolidayDate = sa.WorkDate AND h.IsPaid = 0
                             AND (h.BranchId IS NULL OR h.BranchId = hr.fn_EmployeeBranchOn(sa.EmployeeId, sa.WorkDate))
          WHERE sa.WorkDate BETWEEN x.EmpFrom AND x.AttTo AND sa.IsRestDay = 0 AND sa.ShiftId IS NOT NULL
            AND EXISTS (SELECT 1 FROM attendance.ROSTER_MONTH rm
                        WHERE rm.BranchId = hr.fn_EmployeeBranchOn(sa.EmployeeId, sa.WorkDate)
                          AND rm.MonthDate = DATEFROMPARTS(YEAR(sa.WorkDate), MONTH(sa.WorkDate), 1) AND rm.[Status] = 'Approved')
            AND NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD a WHERE a.EmployeeId = sa.EmployeeId AND a.WorkDate = sa.WorkDate AND a.WorkedMinutes > 0)
          GROUP BY sa.EmployeeId) uh ON uh.EmployeeId = r.EmployeeId
    JOIN #CT ct ON ct.Code='ABSENCE';

    /* -- D3. exit permissions beyond the leave balance (script 86), inside the employment -- */
    INSERT INTO payroll.PAYSLIP_LINE
        (PayslipId,ComponentTypeId,ComponentName,Category,[Sign],Amount,CurrencyCode,
         SourceType,SourceId,Quantity,UnitAmount,Note,SortOrder)
    SELECT r.PayslipId, ct.ComponentTypeId, ct.Name, ct.Category, ct.[Sign],
           ROUND(xu.Days * r.DayRate, 2), r.CurrencyCode, 'ExitPermission', NULL, xu.Days, r.DayRate,
           CONCAT(FORMAT(xu.Days, '0.##'), N' day(s) of exit permissions beyond the leave balance'), 25
    FROM #Rate r
    JOIN (SELECT a.EmployeeId, CAST(SUM(a.ExitUnpaidDays) AS DECIMAL(6,2)) AS Days
          FROM attendance.ATTENDANCE_RECORD a
          JOIN #Emp x ON x.EmployeeId = a.EmployeeId
          WHERE a.WorkDate BETWEEN x.EmpFrom AND x.EmpTo AND a.ExitUnpaidDays > 0
          GROUP BY a.EmployeeId) xu ON xu.EmployeeId = r.EmployeeId
    JOIN #CT ct ON ct.Code='UNPAID_LEAVE'
    WHERE xu.Days > 0;

    /* -- the unpaid deductions never take more than the basic paid for the month (QA3 decision): a month with more
          working days than StandardWorkingDaysPerMonth would otherwise deduct more than it paid. The lines are cut in
          their order, the line says so. -- */
    ;WITH ded AS (
        SELECT l.PayslipLineId, l.Amount,
               cap.Basic,
               SUM(l.Amount) OVER (PARTITION BY l.PayslipId ORDER BY l.SortOrder, l.PayslipLineId ROWS UNBOUNDED PRECEDING) - l.Amount AS Before
        FROM payroll.PAYSLIP_LINE l
        JOIN #Rate r ON r.PayslipId = l.PayslipId AND r.CurrencyCode = l.CurrencyCode
        CROSS APPLY (SELECT ISNULL(SUM(b.Amount), 0) AS Basic
                     FROM payroll.PAYSLIP_LINE b JOIN #CT c ON c.ComponentTypeId = b.ComponentTypeId AND c.Code = 'BASIC'
                     WHERE b.PayslipId = l.PayslipId AND b.SourceType = 'Salary' AND b.CurrencyCode = l.CurrencyCode) cap
        WHERE l.SourceType IN ('Leave','Attendance','ExitPermission') AND l.Category = 'Deduction'
    )
    UPDATE l SET Amount = CASE WHEN d.Basic - d.Before > 0 THEN d.Basic - d.Before ELSE 0 END,
                 Note = LEFT(CONCAT(l.Note, N' - capped: the month''s unpaid deductions never exceed the basic paid for it'), 400)
    FROM payroll.PAYSLIP_LINE l
    JOIN ded d ON d.PayslipLineId = l.PayslipLineId
    WHERE d.Before + d.Amount > d.Basic;

    /* -- E. overtime: payable = LEAST(cap, detected), at the request's multiplier, inside the employment -- */
    INSERT INTO payroll.PAYSLIP_LINE
        (PayslipId,ComponentTypeId,ComponentName,Category,[Sign],Amount,CurrencyCode,
         SourceType,SourceId,Quantity,UnitAmount,Note,SortOrder)
    SELECT r.PayslipId, ct.ComponentTypeId, ct.Name, ct.Category, ct.[Sign],
           ROUND(ot.PayMinutes / 60.0 * r.HourRate * ot.RateMultiplier, 2), r.CurrencyCode,
           'Overtime', ot.OvertimeRequestId, ot.PayMinutes, r.HourRate,
           CONCAT(ot.PayMinutes, N' min at ', FORMAT(ot.RateMultiplier,'0.0#'), N'x'), 30
    FROM #Rate r
    JOIN #Emp x ON x.PayslipId = r.PayslipId
    JOIN (
        SELECT o.EmployeeId, o.OvertimeRequestId, o.RateMultiplier, o.WorkDate,
               CASE WHEN ISNULL(a.OvertimeMinutes,0) < o.ApprovedMinutes
                    THEN ISNULL(a.OvertimeMinutes,0) ELSE o.ApprovedMinutes END AS PayMinutes
        FROM workflow.OVERTIME_REQUEST o
        JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId=o.RequestInstanceId
        LEFT JOIN attendance.ATTENDANCE_RECORD a
               ON a.EmployeeId=o.EmployeeId AND a.WorkDate=o.WorkDate
        WHERE ri.[Status]='Approved' AND o.ApprovedMinutes IS NOT NULL
          AND o.WorkDate BETWEEN @Start AND @End
    ) ot ON ot.EmployeeId=r.EmployeeId AND ot.WorkDate BETWEEN x.EmpFrom AND x.EmpTo
    JOIN #CT ct ON ct.Code='OVERTIME'
    WHERE ot.PayMinutes > 0;

    /* -- F. tips: finalized distributions dated in the period - ONE LINE PER DISTRIBUTION and currency, so the line
          names the request that paid it (QA3: one line per currency carried only the lowest distribution id) -- */
    INSERT INTO payroll.PAYSLIP_LINE
        (PayslipId,ComponentTypeId,ComponentName,Category,[Sign],Amount,CurrencyCode,
         SourceType,SourceId,Quantity,UnitAmount,Note,SortOrder)
    SELECT x.PayslipId, ct.ComponentTypeId, ct.Name, ct.Category, ct.[Sign],
           t.Amount, t.CurrencyCode, 'Tip', t.TipDistributionId,
           NULL, NULL, CONCAT(N'Tips of ', CONVERT(NVARCHAR(10), t.ShiftDate, 23)), 40
    FROM #Emp x
    JOIN (
        SELECT l.EmployeeId, l.CurrencyCode, td.TipDistributionId, td.ShiftDate, SUM(l.Amount) AS Amount
        FROM workflow.TIP_DISTRIBUTION_LINE l
        JOIN workflow.TIP_DISTRIBUTION td ON td.TipDistributionId=l.TipDistributionId
        WHERE td.FinalizedAt IS NOT NULL AND td.ShiftDate BETWEEN @Start AND @End
        GROUP BY l.EmployeeId, l.CurrencyCode, td.TipDistributionId, td.ShiftDate
    ) t ON t.EmployeeId=x.EmployeeId
    JOIN #CT ct ON ct.Code='TIPS'
    WHERE t.Amount <> 0;

    /* -- G. expenses: approved and never reimbursed, not held by an earlier open primary (QA3 PAY-5) -- */
    INSERT INTO payroll.PAYSLIP_LINE
        (PayslipId,ComponentTypeId,ComponentName,Category,[Sign],Amount,CurrencyCode,
         SourceType,SourceId,Quantity,UnitAmount,Note,SortOrder)
    SELECT x.PayslipId, ct.ComponentTypeId, ct.Name, ct.Category, ct.[Sign],
           ISNULL(er.ApprovedAmount, er.Amount), er.CurrencyCode,
           'Expense', er.ExpenseReimbursementId, NULL, NULL,
           CONCAT(er.Category, N' ', CONVERT(char(10),er.ExpenseDate,23)), 45
    FROM #Emp x
    JOIN payroll.fn_RunExpenses(@PayrollRunId) fx ON fx.EmployeeId=x.EmployeeId
    JOIN workflow.EXPENSE_REIMBURSEMENT er ON er.ExpenseReimbursementId=fx.ExpenseReimbursementId
    JOIN #CT ct ON ct.Code='EXPENSE';

    /* -- I. adjustments targeted at this period, not yet applied, not claimed by an open supplemental (script 81) -- */
    INSERT INTO payroll.PAYSLIP_LINE
        (PayslipId,ComponentTypeId,ComponentName,Category,[Sign],Amount,CurrencyCode,
         SourceType,SourceId,Quantity,UnitAmount,Note,SortOrder)
    SELECT x.PayslipId, ct.ComponentTypeId, ct.Name, ct.Category, ct.[Sign],
           adj.Amount, adj.CurrencyCode, 'Adjustment', adj.PayrollAdjustmentId,
           NULL, NULL, adj.Reason, 55
    FROM #Emp x
    JOIN payroll.fn_RunAdjustments(@PayrollRunId) fa ON fa.EmployeeId=x.EmployeeId
    JOIN payroll.PAYROLL_ADJUSTMENT adj ON adj.PayrollAdjustmentId=fa.PayrollAdjustmentId
    JOIN hr.COMPONENT_TYPE ct ON ct.ComponentTypeId=adj.ComponentTypeId;

    /* -- J. separation settlements this run pays (QA3 PAY-2: also one whose month was locked before it was prepared) -- */
    INSERT INTO payroll.PAYSLIP_LINE
        (PayslipId,ComponentTypeId,ComponentName,Category,[Sign],Amount,CurrencyCode,
         SourceType,SourceId,Quantity,UnitAmount,Note,SortOrder)
    SELECT x.PayslipId, ct.ComponentTypeId, ct.Name, ct.Category, ct.[Sign],
           v.Amount, s.CurrencyCode, 'Separation', s.SeparationId,
           NULL, NULL, v.Note, 60
    FROM #Emp x
    JOIN payroll.fn_RunSeparations(@PayrollRunId) fs ON fs.EmployeeId=x.EmployeeId
    JOIN workflow.SEPARATION s ON s.SeparationId=fs.SeparationId
    CROSS APPLY (VALUES
        ('UNUSED_LEAVE', s.UnusedLeaveAmount, CONCAT(FORMAT(s.UnusedLeaveDays,'0.##'),N' day(s)')),
        ('INDEMNITY',    s.IndemnityAmount,   CONCAT(FORMAT(s.ServiceYears,'0.##'),N' year(s) of service')),
        ('EXPENSE',      s.OtherDues,         N'Other dues on separation'),
        ('ABSENCE',      s.Deductions,        N'Deductions on separation')
    ) v(Code, Amount, Note)
    JOIN #CT ct ON ct.Code=v.Code
    WHERE v.Amount IS NOT NULL AND v.Amount > 0;
    /* notice pay in lieu, its own line */
    INSERT INTO payroll.PAYSLIP_LINE
        (PayslipId,ComponentTypeId,ComponentName,Category,[Sign],Amount,CurrencyCode,
         SourceType,SourceId,Quantity,UnitAmount,Note,SortOrder)
    SELECT x.PayslipId, ct.ComponentTypeId, ct.Name, ct.Category, ct.[Sign],
           s.NoticePayAmount, s.CurrencyCode, 'Separation', s.SeparationId,
           NULL, NULL, CONCAT(N'Pay in lieu of ',s.NoticeShortfallDays,N' notice day(s)'), 61
    FROM #Emp x
    JOIN payroll.fn_RunSeparations(@PayrollRunId) fs ON fs.EmployeeId=x.EmployeeId
    JOIN workflow.SEPARATION s ON s.SeparationId=fs.SeparationId
    JOIN #CT ct ON ct.Code='BASIC'
    WHERE ISNULL(s.NoticePayAmount,0) > 0;

    /* -- J2. the leave balance on termination (script 86 D5; QA3 PAY-2 / REL-14 / LEV-8): the balance as of the
          termination date, at the day rate in force then; paid by the leaving month or, when that month was locked
          first, by the next open primary. Approving the run posts the settlement to the ledger, so it is paid once. -- */
    INSERT INTO payroll.PAYSLIP_LINE
        (PayslipId,ComponentTypeId,ComponentName,Category,[Sign],Amount,CurrencyCode,
         SourceType,SourceId,Quantity,UnitAmount,Note,SortOrder)
    SELECT r.PayslipId, ct.ComponentTypeId, ct.Name, ct.Category, ct.[Sign],
           ROUND(ABS(lp.Balance) * r.DayRate, 2), r.CurrencyCode, 'LeavePayout', NULL, ABS(lp.Balance), r.DayRate,
           CONCAT(CASE WHEN lp.Balance > 0 THEN N'Unused leave on leaving (' ELSE N'Leave taken beyond the balance on leaving (' END,
                  FORMAT(ABS(lp.Balance), '0.##'), N' day(s) ', NCHAR(215), N' the day rate), last day ', CONVERT(NVARCHAR(10), lp.TerminationDate, 23)), 62
    FROM payroll.fn_RunLeavePayouts(@PayrollRunId) lp
    JOIN #Rate r ON r.EmployeeId = lp.EmployeeId
    JOIN #CT ct ON ct.Code = CASE WHEN lp.Balance > 0 THEN 'LEAVE_PAYOUT' ELSE 'LEAVE_DEDUCTION' END;

    /* QA3 REL-11: every line's currency must have a rate in the run. In Review the frozen snapshot is kept and only a
       currency missing from it is added (as of the period end); a currency with no rate on file at all is refused, never
       converted to NULL. */
    INSERT INTO payroll.PAYROLL_RUN_RATE (PayrollRunId,FromCurrency,ToCurrency,Rate,RateType,SourceEffectiveDate)
    SELECT @PayrollRunId, c.CurrencyCode, @Primary, x.Rate, x.RateType, x.EffectiveDate
    FROM (SELECT DISTINCT l.CurrencyCode FROM payroll.PAYSLIP_LINE l JOIN payroll.PAYSLIP ps ON ps.PayslipId=l.PayslipId
          WHERE ps.PayrollRunId=@PayrollRunId AND l.CurrencyCode <> @Primary) c
    CROSS APPLY (SELECT TOP 1 CAST(CASE WHEN er.FromCurrency=c.CurrencyCode THEN er.Rate ELSE 1.0/er.Rate END AS DECIMAL(28,12)) AS Rate,
                        er.RateType, er.EffectiveDate
                 FROM core.EXCHANGE_RATE er
                 WHERE ((er.FromCurrency=c.CurrencyCode AND er.ToCurrency=@Primary) OR (er.FromCurrency=@Primary AND er.ToCurrency=c.CurrencyCode))
                   AND er.RateType=@RateType AND er.EffectiveDate <= @End AND er.Rate > 0
                 ORDER BY er.EffectiveDate DESC, er.ExchangeRateId DESC) x
    WHERE payroll.fn_RunRate(@PayrollRunId, c.CurrencyCode, @Primary) IS NULL;
    DECLARE @NoRate CHAR(3) = (SELECT TOP 1 l.CurrencyCode FROM payroll.PAYSLIP_LINE l JOIN payroll.PAYSLIP ps ON ps.PayslipId=l.PayslipId
                               WHERE ps.PayrollRunId=@PayrollRunId AND l.CurrencyCode <> @Primary
                                 AND payroll.fn_RunRate(@PayrollRunId, l.CurrencyCode, @Primary) IS NULL);
    IF @NoRate IS NOT NULL
    BEGIN
        ROLLBACK TRAN;
        DECLARE @EndText VARCHAR(10) = CONVERT(VARCHAR(10), @End, 23);
        RAISERROR('No %s rate of type %s is on file for %s (on or before %s). Add it on Exchange rates, then generate the run again.',16,1,@NoRate,@RateType,@Period,@EndText);
        RETURN 1;
    END

    /* -- K. STATUTORY: NSSF then tax, on the wage-like base in primary (script 86).
          QA3 PAY-9: ONE version per scheme per month - the rows in force on the period's last day; one tax table. -- */
    SELECT l.PayslipId,
           SUM(payroll.fn_ToPrimary(@PayrollRunId, l.Amount, l.CurrencyCode) * l.[Sign]) AS BaseP
    INTO #NssfBase
    FROM payroll.PAYSLIP_LINE l
    JOIN payroll.PAYSLIP ps ON ps.PayslipId=l.PayslipId AND ps.PayrollRunId=@PayrollRunId
    WHERE l.SourceType IN ('Salary','Overtime','Leave','Attendance','ExitPermission')
      AND l.Category IN ('Earning','Deduction')
    GROUP BY l.PayslipId;

    /* employee share, ceilinged schemes capped */
    INSERT INTO payroll.PAYSLIP_LINE
        (PayslipId,ComponentTypeId,ComponentName,Category,[Sign],Amount,CurrencyCode,
         SourceType,SourceId,Quantity,UnitAmount,Note,SortOrder)
    SELECT nb.PayslipId, ct.ComponentTypeId, ct.Name, ct.Category, ct.[Sign],
           ROUND(SUM(CASE WHEN nr.IsCeilinged=1 AND nb.BaseP > ISNULL(nr.CeilingAmount, @Ceiling)
                          THEN ISNULL(nr.CeilingAmount, @Ceiling) ELSE nb.BaseP END * nr.EmployeeRate), 2),
           @Primary, 'Statutory', NULL, NULL, NULL,
           N'NSSF employee share on the wage base', 70
    FROM #NssfBase nb
    JOIN hr.NSSF_RATE nr ON nr.EffectiveFrom <= @End AND (nr.EffectiveTo IS NULL OR nr.EffectiveTo >= @End)
    JOIN #CT ct ON ct.Code='NSSF_EMPLOYEE'
    WHERE nb.BaseP > 0
    GROUP BY nb.PayslipId, ct.ComponentTypeId, ct.Name, ct.Category, ct.[Sign]
    HAVING SUM(CASE WHEN nr.IsCeilinged=1 AND nb.BaseP > ISNULL(nr.CeilingAmount, @Ceiling)
                    THEN ISNULL(nr.CeilingAmount, @Ceiling) ELSE nb.BaseP END * nr.EmployeeRate) > 0;

    /* employer cost */
    INSERT INTO payroll.PAYSLIP_LINE
        (PayslipId,ComponentTypeId,ComponentName,Category,[Sign],Amount,CurrencyCode,
         SourceType,SourceId,Quantity,UnitAmount,Note,SortOrder)
    SELECT nb.PayslipId, ct.ComponentTypeId, ct.Name, ct.Category, ct.[Sign],
           ROUND(SUM(CASE WHEN nr.IsCeilinged=1 AND nb.BaseP > ISNULL(nr.CeilingAmount, @Ceiling)
                          THEN ISNULL(nr.CeilingAmount, @Ceiling) ELSE nb.BaseP END * nr.EmployerRate), 2),
           @Primary, 'Statutory', NULL, NULL, NULL,
           N'NSSF employer share (all schemes)', 71
    FROM #NssfBase nb
    JOIN hr.NSSF_RATE nr ON nr.EffectiveFrom <= @End AND (nr.EffectiveTo IS NULL OR nr.EffectiveTo >= @End)
    JOIN #CT ct ON ct.Code='NSSF_EMPLOYER'
    WHERE nb.BaseP > 0
    GROUP BY nb.PayslipId, ct.ComponentTypeId, ct.Name, ct.Category, ct.[Sign]
    HAVING SUM(CASE WHEN nr.IsCeilinged=1 AND nb.BaseP > ISNULL(nr.CeilingAmount, @Ceiling)
                    THEN ISNULL(nr.CeilingAmount, @Ceiling) ELSE nb.BaseP END * nr.EmployerRate) > 0;

    /* income tax: (base - employee NSSF) x 12, family deduction, brackets of the ONE table in force, /12 */
    ;WITH taxable AS (
        SELECT nb.PayslipId,
               (nb.BaseP - ISNULL(nssf.Amt,0)) * 12 - @FamilyDed AS AnnualTaxable
        FROM #NssfBase nb
        OUTER APPLY (SELECT SUM(l.Amount) AS Amt FROM payroll.PAYSLIP_LINE l
                     JOIN #CT c2 ON c2.ComponentTypeId=l.ComponentTypeId AND c2.Code='NSSF_EMPLOYEE'
                     WHERE l.PayslipId=nb.PayslipId AND l.SourceType='Statutory') nssf
    )
    INSERT INTO payroll.PAYSLIP_LINE
        (PayslipId,ComponentTypeId,ComponentName,Category,[Sign],Amount,CurrencyCode,
         SourceType,SourceId,Quantity,UnitAmount,Note,SortOrder)
    SELECT t.PayslipId, ct.ComponentTypeId, ct.Name, ct.Category, ct.[Sign],
           ROUND(SUM(
               (CASE WHEN t.AnnualTaxable > ISNULL(b.MaxAnnual, t.AnnualTaxable)
                     THEN ISNULL(b.MaxAnnual, t.AnnualTaxable) ELSE t.AnnualTaxable END
                - b.MinAnnual) * b.Rate) / 12, 2),
           @Primary, 'Statutory', NULL, NULL, NULL,
           N'Income tax, annualised then divided by 12', 72
    FROM taxable t
    JOIN hr.TAX_BRACKET b ON b.MinAnnual < t.AnnualTaxable
                          AND b.EffectiveFrom = @TaxFrom
                          AND (b.EffectiveTo IS NULL OR b.EffectiveTo >= @End)
    JOIN #CT ct ON ct.Code='INCOME_TAX'
    WHERE t.AnnualTaxable > 0
    GROUP BY t.PayslipId, ct.ComponentTypeId, ct.Name, ct.Category, ct.[Sign]
    HAVING SUM((CASE WHEN t.AnnualTaxable > ISNULL(b.MaxAnnual, t.AnnualTaxable)
                     THEN ISNULL(b.MaxAnnual, t.AnnualTaxable) ELSE t.AnnualTaxable END
                - b.MinAnnual) * b.Rate) / 12 >= 0.01;

    /* -- H. ADVANCES, LAST (script 86, D8): MIN(monthly, remaining) - and never more than the net -- */
    ;WITH net AS (
        SELECT l.PayslipId, l.CurrencyCode,
               SUM(CASE WHEN l.Category='Earning' THEN l.Amount WHEN l.Category='Deduction' THEN -l.Amount ELSE 0 END) AS NetBefore
        FROM payroll.PAYSLIP_LINE l
        JOIN payroll.PAYSLIP ps ON ps.PayslipId=l.PayslipId AND ps.PayrollRunId=@PayrollRunId
        GROUP BY l.PayslipId, l.CurrencyCode
    ), adv AS (
        SELECT x.PayslipId, a.SalaryAdvanceId, a.CurrencyCode, a.RemainingAmount,
               CASE WHEN a.MonthlyDeduction < a.RemainingAmount THEN a.MonthlyDeduction ELSE a.RemainingAmount END AS Wanted,
               ISNULL(SUM(CASE WHEN a.MonthlyDeduction < a.RemainingAmount THEN a.MonthlyDeduction ELSE a.RemainingAmount END)
                          OVER (PARTITION BY x.PayslipId, a.CurrencyCode ORDER BY a.SalaryAdvanceId ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS WantedBefore
        FROM #Emp x
        JOIN payroll.SALARY_ADVANCE a ON a.EmployeeId=x.EmployeeId
        WHERE a.IsSettled=0 AND a.RemainingAmount > 0 AND a.FirstDeductionPeriod <= @Period
    ), capped AS (
        SELECT v.*, n.NetBefore,
               CASE WHEN ISNULL(n.NetBefore,0) - v.WantedBefore <= 0 THEN CAST(0 AS DECIMAL(18,2))
                    WHEN v.Wanted <= ISNULL(n.NetBefore,0) - v.WantedBefore THEN v.Wanted
                    ELSE CAST(ISNULL(n.NetBefore,0) - v.WantedBefore AS DECIMAL(18,2)) END AS Taken
        FROM adv v LEFT JOIN net n ON n.PayslipId=v.PayslipId AND n.CurrencyCode=v.CurrencyCode
    )
    INSERT INTO payroll.PAYSLIP_LINE
        (PayslipId,ComponentTypeId,ComponentName,Category,[Sign],Amount,CurrencyCode,
         SourceType,SourceId,Quantity,UnitAmount,Note,SortOrder)
    SELECT c.PayslipId, ct.ComponentTypeId, ct.Name, ct.Category, ct.[Sign],
           c.Taken, c.CurrencyCode, 'Advance', c.SalaryAdvanceId, NULL, NULL,
           CASE WHEN c.Taken < c.Wanted
                THEN CONCAT(N'Instalment of ', FORMAT(c.Wanted,'0.00'), N' capped at the net: ', FORMAT(c.Wanted - c.Taken,'0.00'),
                            N' carried to the next run. Remaining after this: ', FORMAT(c.RemainingAmount - c.Taken,'0.00'))
                ELSE CONCAT(N'Remaining after this: ', FORMAT(c.RemainingAmount - c.Taken,'0.00')) END, 75
    FROM capped c
    JOIN #CT ct ON ct.Code='ADVANCE'
    WHERE c.Taken > 0;

    /* -- totals, attendance story, comparable net, warnings -- */
    UPDATE ps SET
        GrossUsd = ISNULL(t.GU,0), GrossLbp = ISNULL(t.GL,0),
        DeductionsUsd = ISNULL(t.DU,0), DeductionsLbp = ISNULL(t.DL,0),
        NetUsd = ISNULL(t.GU,0)-ISNULL(t.DU,0), NetLbp = ISNULL(t.GL,0)-ISNULL(t.DL,0),
        EmployerCostUsd = ISNULL(t.EU,0), EmployerCostLbp = ISNULL(t.EL,0)
    FROM payroll.PAYSLIP ps
    LEFT JOIN (
        SELECT l.PayslipId,
            SUM(IIF(l.Category='Earning'      AND l.CurrencyCode='USD', l.Amount,0)) AS GU,
            SUM(IIF(l.Category='Earning'      AND l.CurrencyCode='LBP', l.Amount,0)) AS GL,
            SUM(IIF(l.Category='Deduction'    AND l.CurrencyCode='USD', l.Amount,0)) AS DU,
            SUM(IIF(l.Category='Deduction'    AND l.CurrencyCode='LBP', l.Amount,0)) AS DL,
            SUM(IIF(l.Category='EmployerCost' AND l.CurrencyCode='USD', l.Amount,0)) AS EU,
            SUM(IIF(l.Category='EmployerCost' AND l.CurrencyCode='LBP', l.Amount,0)) AS EL
        FROM payroll.PAYSLIP_LINE l GROUP BY l.PayslipId
    ) t ON t.PayslipId=ps.PayslipId
    WHERE ps.PayrollRunId=@PayrollRunId;

    /* QA3 LEV-17: the payslip's leave days are the WORKING days of the approved span inside the period and the
       employment (half a day = 0.5), paid or unpaid by the type as approved (PaidSnapshot) */
    UPDATE ps SET
        NetPrimary = payroll.fn_ToPrimary(@PayrollRunId, ps.NetUsd, 'USD')
                   + CASE WHEN ps.NetLbp = 0 THEN 0 ELSE payroll.fn_ToPrimary(@PayrollRunId, ps.NetLbp, 'LBP') END,
        PaidDayFraction = att.Paid, UnpaidLeaveDays = lv.Unpaid,
        PaidLeaveDays = lv.Paid, OvertimeMinutes = ot.Mins
    FROM payroll.PAYSLIP ps
    JOIN #Emp x ON x.PayslipId = ps.PayslipId
    OUTER APPLY (SELECT CAST(SUM(a.DayFraction) AS DECIMAL(6,2)) AS Paid
                 FROM attendance.ATTENDANCE_RECORD a
                 WHERE a.EmployeeId=ps.EmployeeId AND a.WorkDate BETWEEN x.EmpFrom AND x.EmpTo) att
    OUTER APPLY (SELECT CAST(SUM(IIF(ISNULL(lr.PaidSnapshot, lt.IsPaid)=0, dd.D, 0)) AS DECIMAL(6,2)) AS Unpaid,
                        CAST(SUM(IIF(ISNULL(lr.PaidSnapshot, lt.IsPaid)=1, dd.D, 0)) AS DECIMAL(6,2)) AS Paid
                 FROM workflow.LEAVE_REQUEST lr
                 JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId=lr.RequestInstanceId AND ri.[Status]='Approved'
                 JOIN hr.LEAVE_TYPE lt ON lt.LeaveTypeId=lr.LeaveTypeId
                 CROSS APPLY (SELECT CASE WHEN lr.FromDate > x.EmpFrom THEN lr.FromDate ELSE x.EmpFrom END AS F,
                                     CASE WHEN ISNULL(lr.ApprovedToDate, lr.ToDate) < x.EmpTo THEN ISNULL(lr.ApprovedToDate, lr.ToDate) ELSE x.EmpTo END AS T) w
                 CROSS APPLY (SELECT CAST(CASE WHEN lr.HalfDay IS NOT NULL THEN 0.5 * ISNULL(MAX(CAST(ld.Counts AS INT)), 0)
                                               ELSE ISNULL(SUM(CAST(ld.Counts AS INT)), 0) END AS DECIMAL(6,2)) AS D
                              FROM hr.fn_LeaveDays(lr.EmployeeId, w.F, w.T) ld) dd
                 WHERE lr.EmployeeId=ps.EmployeeId AND w.F <= w.T) lv
    OUTER APPLY (SELECT SUM(l.Quantity) AS Mins FROM payroll.PAYSLIP_LINE l
                 WHERE l.PayslipId=ps.PayslipId AND l.SourceType='Overtime') ot
    WHERE ps.PayrollRunId=@PayrollRunId;

    UPDATE ps SET Notes = NULLIF(LTRIM(CONCAT(
        CASE WHEN x.EmpTo < x.EmpFrom
             THEN CONCAT(N' Settlement only: left on ', CONVERT(NVARCHAR(10), x.TerminationDate, 23), N'.')
             WHEN NOT EXISTS (SELECT 1 FROM payroll.PAYSLIP_LINE l JOIN #CT c ON c.ComponentTypeId=l.ComponentTypeId AND c.Code='BASIC'
                              WHERE l.PayslipId=ps.PayslipId AND l.SourceType='Salary')
             THEN N' NO BASIC SALARY ON FILE.' ELSE N'' END,
        /* a component paid in two currencies over the same days is paid twice: say so (QA3 PAY-6) */
        IIF(EXISTS (SELECT 1 FROM hr.SALARY_COMPONENT s1
                    JOIN hr.SALARY_COMPONENT s2 ON s2.EmployeeId=s1.EmployeeId AND s2.ComponentTypeId=s1.ComponentTypeId
                                               AND s2.CurrencyCode<>s1.CurrencyCode AND s2.SalaryComponentId>s1.SalaryComponentId
                    WHERE s1.EmployeeId=ps.EmployeeId
                      AND s1.EffectiveFrom <= x.EmpTo AND ISNULL(s1.EffectiveTo, x.EmpTo) >= x.EmpFrom
                      AND s2.EffectiveFrom <= x.EmpTo AND ISNULL(s2.EffectiveTo, x.EmpTo) >= x.EmpFrom
                      AND s1.EffectiveFrom <= ISNULL(s2.EffectiveTo, x.EmpTo) AND s2.EffectiveFrom <= ISNULL(s1.EffectiveTo, x.EmpTo)),
            N' THE SAME SALARY COMPONENT RUNS IN TWO CURRENCIES OVER THE SAME DAYS - check the salary tab.', N''),
        IIF(ps.NetUsd < 0 OR ps.NetLbp < 0, N' NEGATIVE NET - review deductions.', N''))), N'')
    FROM payroll.PAYSLIP ps
    JOIN #Emp x ON x.PayslipId = ps.PayslipId
    WHERE ps.PayrollRunId=@PayrollRunId;

    /* QA3 PAY-5: what every payslip was computed from, and the run-wide inputs - Approve compares them */
    INSERT INTO payroll.PAYSLIP_INPUT (PayslipId, Source, RowsCount, Fingerprint)
    SELECT ps.PayslipId, i.Source, i.RowsCount, i.Fingerprint
    FROM payroll.PAYSLIP ps
    CROSS APPLY payroll.fn_PayslipInputs(@PayrollRunId, ps.EmployeeId) i
    WHERE ps.PayrollRunId=@PayrollRunId;

    UPDATE payroll.PAYROLL_RUN
    SET GeneratedAt = SYSUTCDATETIME(), GeneratedUpTo = @UpTo,
        InputsFingerprint = (SELECT c.Fingerprint FROM payroll.fn_RunConfig(@PayrollRunId) c)
    WHERE PayrollRunId=@PayrollRunId;

    DECLARE @Count INT=(SELECT COUNT(*) FROM payroll.PAYSLIP WHERE PayrollRunId=@PayrollRunId);
    DECLARE @Warn INT=(SELECT COUNT(*) FROM payroll.PAYSLIP
                       WHERE PayrollRunId=@PayrollRunId AND Notes IS NOT NULL AND Notes<>N'');
    INSERT INTO payroll.PAYROLL_RUN_EVENT (PayrollRunId,[Action],ActedByUserId,Detail)
    VALUES (@PayrollRunId,'Generated',@ActedByUserId,
            CONCAT(@Count,N' payslip(s), ',@Warn,N' with warnings',
                   CASE WHEN @UpTo < @End THEN CONCAT(N'; attendance counted up to ',CONVERT(NVARCHAR(10),@UpTo,23),N' (completed days), later days as scheduled') ELSE N'' END,
                   CASE WHEN @Status = 'Draft' THEN CONCAT(N'; rates read as of ', CONVERT(NVARCHAR(10), @End, 23)) ELSE N'; rates as frozen at review' END));
    COMMIT TRAN;

    SELECT @PayrollRunId AS PayrollRunId, @Count AS PayslipCount, @Warn AS PayslipsWithWarnings;
END;
GO

/* ------------------------- 8. approve: the lock, once, on what was checked -------------------------
   Body of script 81 with: the refusals checked first (an adjustment paid once - script 81; the early lock - PAY-3;
   readiness - PAY-4; stale inputs - PAY-5), then the transaction whose FIRST statement claims the run (Status = 'Review'
   and the GeneratedAt that was checked, row count verified - PAY-11), then the lock effects: expenses, advances,
   adjustments as before, plus the separation stamp and the leave-payout settlement (PAY-2 / REL-14). */
CREATE OR ALTER PROCEDURE payroll.usp_PayrollRun_Approve
    @PayrollRunId INT, @ActedByUserId INT,
    @AllowEarlyLock BIT = 0,    -- QA3 PAY-3: the Owner explicitly locks a primary before its period is over
    @AsOfDate DATE = NULL       -- the clock. NULL = today in Beirut; a caller passes a date only to test the rule
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;

    IF payroll.fn_UserHasRole(@ActedByUserId, N'Owner') = 0
    BEGIN RAISERROR('Only the Owner approves and locks a payroll run.',16,1); RETURN 1; END

    DECLARE @S VARCHAR(12), @Gen DATETIME2, @Type VARCHAR(12), @Period CHAR(7), @End DATE, @GenUpTo DATE;
    SELECT @S=[Status], @Gen=GeneratedAt, @Type=RunType, @Period=PeriodYearMonth, @End=PeriodEnd, @GenUpTo=GeneratedUpTo
    FROM payroll.PAYROLL_RUN WHERE PayrollRunId=@PayrollRunId;
    IF @S IS NULL BEGIN RAISERROR('No such payroll run.',16,1); RETURN 1; END
    IF @S = 'Approved' BEGIN RAISERROR('This run is already approved and locked.',16,1); RETURN 1; END
    IF @S <> 'Review'
    BEGIN RAISERROR('A run is approved from Review - HR sends it there once the figures are ready.',16,1); RETURN 1; END
    IF @Gen IS NULL
    BEGIN RAISERROR('Nothing has been generated - there is nothing to approve.',16,1); RETURN 1; END

    /* script 81: AN ADJUSTMENT IS PAID ONCE - consumed by another run's payslip, or (for a primary) held by an open
       supplemental. QA3: or no longer there at all (its request was taken back after the run was generated). */
    DECLARE @Twice INT = (
        SELECT COUNT(DISTINCT adj.PayrollAdjustmentId)
        FROM payroll.PAYSLIP_LINE l
        JOIN payroll.PAYSLIP ps ON ps.PayslipId=l.PayslipId AND ps.PayrollRunId=@PayrollRunId
        JOIN payroll.PAYROLL_ADJUSTMENT adj ON adj.PayrollAdjustmentId=l.SourceId
        WHERE l.SourceType='Adjustment'
          AND (   EXISTS (SELECT 1 FROM payroll.PAYSLIP paid
                          WHERE paid.PayslipId=adj.AppliedToPayslipId AND paid.PayrollRunId<>@PayrollRunId)
               OR (@Type='Primary' AND EXISTS (
                          SELECT 1 FROM payroll.PAYSLIP_LINE sl
                          JOIN payroll.PAYSLIP sp ON sp.PayslipId=sl.PayslipId
                          JOIN payroll.PAYROLL_RUN sr ON sr.PayrollRunId=sp.PayrollRunId
                          WHERE sl.SourceType='Adjustment' AND sl.SourceId=adj.PayrollAdjustmentId
                            AND sr.PayrollRunId<>@PayrollRunId
                            AND sr.RunType='Supplemental' AND sr.[Status] IN ('Draft','Review')))));
    IF @Twice > 0
    BEGIN
        RAISERROR('This run carries %d adjustment(s) that a supplemental run pays. Regenerate the run so each adjustment is paid once, then approve it.',16,1,@Twice);
        RETURN 1;
    END
    DECLARE @Gone INT = (
        SELECT COUNT(DISTINCT l.SourceId)
        FROM payroll.PAYSLIP_LINE l
        JOIN payroll.PAYSLIP ps ON ps.PayslipId=l.PayslipId AND ps.PayrollRunId=@PayrollRunId
        WHERE l.SourceType='Adjustment'
          AND NOT EXISTS (SELECT 1 FROM payroll.PAYROLL_ADJUSTMENT adj WHERE adj.PayrollAdjustmentId=l.SourceId));
    IF @Gone > 0
    BEGIN
        RAISERROR('This run pays %d adjustment(s) that no longer exist (the request was taken back). Regenerate the run, then approve it.',16,1,@Gone);
        RETURN 1;
    END

    DECLARE @Today DATE = ISNULL(@AsOfDate, CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE));
    DECLARE @Early BIT = 0, @rc INT;
    IF @Type = 'Primary'
    BEGIN
        /* QA3 PAY-3: a primary is locked once its last day is over. Before that, only by the Owner's explicit early lock -
           whatever happens after the run's attendance cut-off is then not paid by it (and the month counts as paid). */
        IF @Today <= @End
        BEGIN
            IF ISNULL(@AllowEarlyLock, 0) = 0
            BEGIN
                DECLARE @EndText VARCHAR(10) = CONVERT(VARCHAR(10), @End, 23),
                        @NextText VARCHAR(10) = CONVERT(VARCHAR(10), DATEADD(DAY, 1, @End), 23),
                        @CutText VARCHAR(10) = CONVERT(VARCHAR(10), ISNULL(@GenUpTo, DATEADD(DAY, -1, @Today)), 23);
                RAISERROR('The period %s runs until %s; it can be locked from %s. Locking it now is an EARLY LOCK, the Owner''s choice: the days after %s are paid as scheduled, and absences, overtime, holiday work and tips dated after that day, or anything entered for the month later, will not be paid by this run.',16,1,@Period,@EndText,@NextText,@CutText);
                RETURN 1;
            END
            SET @Early = 1;
        END

        /* QA3 PAY-4: the readiness gate of Create and Generate, asked once more for the completed days */
        EXEC @rc = payroll.usp_PayrollRun_AssertReady @PeriodYearMonth = @Period, @AsOfDate = @Today;
        IF @rc <> 0 RETURN 1;

        /* QA3 PAY-5 / REL-3 / ATT-11: nothing the payslips were computed from may have changed since they were generated */
        DECLARE @StaleN INT, @StaleWhat NVARCHAR(1000);
        ;WITH st AS (SELECT DISTINCT EmployeeId, EmployeeName, Source FROM payroll.fn_RunStaleness(@PayrollRunId)),
              per AS (SELECT EmployeeId, EmployeeName, STRING_AGG(CAST(Source AS NVARCHAR(MAX)), N', ') WITHIN GROUP (ORDER BY Source) AS Sources
                      FROM st GROUP BY EmployeeId, EmployeeName)
        SELECT @StaleN = COUNT(*),
               @StaleWhat = LEFT(STRING_AGG(CAST(CONCAT(ISNULL(EmployeeName, N'the run'), N': ', Sources) AS NVARCHAR(MAX)), N'; ')
                                 WITHIN GROUP (ORDER BY EmployeeName), 900)
        FROM per;
        IF @StaleN > 0
        BEGIN
            RAISERROR(N'This run is out of date: what %d payslip(s) were computed from changed after it was generated (%s). Regenerate the run, check it, then approve it.',16,1,@StaleN,@StaleWhat);
            RETURN 1;
        END
    END

    BEGIN TRAN;
    /* QA3 PAY-11: the FIRST statement claims the run - only from Review and only as it was checked above. A second approval
       (or a regenerate or cancel in between) finds no row and changes nothing. */
    UPDATE payroll.PAYROLL_RUN
    SET [Status]='Approved', ApprovedByUserId=@ActedByUserId,
        ApprovedAt=SYSUTCDATETIME(), LockedAt=SYSUTCDATETIME(),
        LockedEarly = CASE WHEN @Early = 1 THEN CAST(1 AS BIT) ELSE NULL END
    WHERE PayrollRunId=@PayrollRunId AND [Status]='Review' AND GeneratedAt=@Gen;
    IF @@ROWCOUNT <> 1
    BEGIN
        ROLLBACK TRAN;
        RAISERROR('This run changed while it was being approved - approved, regenerated or cancelled by someone else. Open it again.',16,1);
        RETURN 1;
    END

    UPDATE er SET ReimbursedInPayrollAt=SYSUTCDATETIME()
    FROM workflow.EXPENSE_REIMBURSEMENT er
    WHERE er.ReimbursedInPayrollAt IS NULL
      AND EXISTS (SELECT 1 FROM payroll.PAYSLIP_LINE l
                  JOIN payroll.PAYSLIP ps ON ps.PayslipId=l.PayslipId
                  WHERE ps.PayrollRunId=@PayrollRunId
                    AND l.SourceType='Expense' AND l.SourceId=er.ExpenseReimbursementId);

    UPDATE a SET RemainingAmount = a.RemainingAmount - d.Deducted,
                 IsSettled = IIF(a.RemainingAmount - d.Deducted <= 0, 1, 0)
    FROM payroll.SALARY_ADVANCE a
    JOIN (SELECT l.SourceId, SUM(l.Amount) AS Deducted
          FROM payroll.PAYSLIP_LINE l
          JOIN payroll.PAYSLIP ps ON ps.PayslipId=l.PayslipId
          WHERE ps.PayrollRunId=@PayrollRunId AND l.SourceType='Advance'
          GROUP BY l.SourceId) d ON d.SourceId=a.SalaryAdvanceId;

    UPDATE adj SET AppliedToPayslipId = l.PayslipId
    FROM payroll.PAYROLL_ADJUSTMENT adj
    JOIN (SELECT l2.SourceId, MIN(l2.PayslipId) AS PayslipId
          FROM payroll.PAYSLIP_LINE l2
          JOIN payroll.PAYSLIP ps2 ON ps2.PayslipId=l2.PayslipId
          WHERE ps2.PayrollRunId=@PayrollRunId AND l2.SourceType='Adjustment'
          GROUP BY l2.SourceId) l ON l.SourceId=adj.PayrollAdjustmentId
    WHERE adj.AppliedToPayslipId IS NULL;

    /* QA3 PAY-2: the settlement is paid - by this payslip */
    UPDATE s SET PaidInPayslipId = l.PayslipId
    FROM workflow.SEPARATION s
    JOIN (SELECT l2.SourceId, MIN(l2.PayslipId) AS PayslipId
          FROM payroll.PAYSLIP_LINE l2
          JOIN payroll.PAYSLIP ps2 ON ps2.PayslipId=l2.PayslipId
          WHERE ps2.PayrollRunId=@PayrollRunId AND l2.SourceType='Separation'
          GROUP BY l2.SourceId) l ON l.SourceId=s.SeparationId
    WHERE s.PaidInPayslipId IS NULL;

    /* QA3 REL-14 / LEV-8: the leave balance paid (or recovered) on termination - by the payout line, or by the separation
       settlement's unused-leave line - is SETTLED in the ledger, per type, as of the termination date: the balance reads 0,
       so a moved termination date (or a later employment of the same person) never pays it twice */
    INSERT INTO hr.LEAVE_LEDGER (EmployeeId, LeaveTypeId, PeriodYearMonth, MovementType, LeaveRequestId, Days, EffectiveDate, Note, CreatedBy, SourceType, SourceRef)
    SELECT e.EmployeeId, b.LeaveTypeId, CONVERT(CHAR(7), e.TerminationDate, 23), 'Adjustment', NULL, -b.Balance, e.TerminationDate,
           CONCAT(N'Leave balance settled on termination (payroll ', @Period, N', payslip ', ps.PayslipId, N').'), @ActedByUserId, 'TerminationPayout', ps.PayslipId
    FROM payroll.PAYSLIP ps
    JOIN hr.EMPLOYEE e ON e.EmployeeId=ps.EmployeeId AND e.TerminationDate IS NOT NULL
    CROSS APPLY (SELECT l.LeaveTypeId, CAST(SUM(l.Days) AS DECIMAL(9,2)) AS Balance
                 FROM hr.LEAVE_LEDGER l
                 JOIN hr.LEAVE_TYPE lt ON lt.LeaveTypeId=l.LeaveTypeId AND lt.IsPaid=1
                 WHERE l.EmployeeId=e.EmployeeId AND l.EffectiveDate <= e.TerminationDate
                   AND EXISTS (SELECT 1 FROM hr.LEAVE_ACCRUAL_TIER t WHERE t.LeaveTypeId=l.LeaveTypeId)
                 GROUP BY l.LeaveTypeId) b
    WHERE ps.PayrollRunId=@PayrollRunId
      AND EXISTS (SELECT 1 FROM payroll.PAYSLIP_LINE pl
                  LEFT JOIN hr.COMPONENT_TYPE pc ON pc.ComponentTypeId=pl.ComponentTypeId
                  WHERE pl.PayslipId=ps.PayslipId
                    AND (pl.SourceType='LeavePayout' OR (pl.SourceType='Separation' AND pc.SystemCode='UNUSED_LEAVE')))
      AND b.Balance <> 0
      AND NOT EXISTS (SELECT 1 FROM hr.LEAVE_LEDGER z WHERE z.SourceType='TerminationPayout' AND z.SourceRef=ps.PayslipId AND z.LeaveTypeId=b.LeaveTypeId);

    INSERT INTO payroll.PAYROLL_RUN_EVENT (PayrollRunId,[Action],ActedByUserId,Detail)
    VALUES (@PayrollRunId,'Approved',@ActedByUserId,
            CONCAT(N'Locked by the Owner; expenses stamped, advances reduced, adjustments applied, settlements stamped, leave payouts settled in the ledger',
                   CASE WHEN @Early = 1
                        THEN CONCAT(N'; EARLY LOCK on ', CONVERT(NVARCHAR(10), @Today, 23), N': days after ',
                                    CONVERT(NVARCHAR(10), ISNULL(@GenUpTo, DATEADD(DAY, -1, @Today)), 23), N' paid as scheduled')
                        ELSE N'' END));
    COMMIT TRAN;

    SELECT @PayrollRunId AS PayrollRunId, 'Approved' AS [Status],
           (SELECT LockedAt FROM payroll.PAYROLL_RUN WHERE PayrollRunId=@PayrollRunId) AS LockedAt;
END;
GO

/* What the run page shows in its "out of date" banner (QA3 PAY-5 / REL-3). Two result sets:
   1. the run: its status, period end and the last completed day the generation counted (GeneratedUpTo) - the page's
      early-lock warning names that day;
   2. one row per employee and source that changed: for a generated primary, its fingerprints against the data now; for a
      supplemental, its adjustment lines whose adjustment is gone or was paid elsewhere. None when the run is not open or
      was never generated. */
CREATE OR ALTER PROCEDURE payroll.usp_PayrollRun_GetStaleness
    @PayrollRunId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @S VARCHAR(12), @Gen DATETIME2, @Type VARCHAR(12);
    SELECT @S=[Status], @Gen=GeneratedAt, @Type=RunType FROM payroll.PAYROLL_RUN WHERE PayrollRunId=@PayrollRunId;

    SELECT PayrollRunId, [Status], RunType, PeriodEnd, GeneratedAt, GeneratedUpTo, LockedEarly
    FROM payroll.PAYROLL_RUN WHERE PayrollRunId=@PayrollRunId;

    IF @S IS NULL OR @S NOT IN ('Draft','Review') OR @Gen IS NULL
        SELECT CAST(NULL AS INT) AS EmployeeId, CAST(NULL AS NVARCHAR(200)) AS EmployeeName, CAST(NULL AS VARCHAR(20)) AS Source WHERE 1 = 0;
    ELSE IF @Type = 'Primary'
        SELECT DISTINCT EmployeeId, CAST(EmployeeName AS NVARCHAR(200)) AS EmployeeName, Source
        FROM payroll.fn_RunStaleness(@PayrollRunId)
        ORDER BY EmployeeName, Source;
    ELSE
        SELECT DISTINCT ps.EmployeeId, CAST(ps.EmployeeName AS NVARCHAR(200)) AS EmployeeName, CAST('Adjustments' AS VARCHAR(20)) AS Source
        FROM payroll.PAYSLIP_LINE l
        JOIN payroll.PAYSLIP ps ON ps.PayslipId=l.PayslipId AND ps.PayrollRunId=@PayrollRunId
        LEFT JOIN payroll.PAYROLL_ADJUSTMENT adj ON adj.PayrollAdjustmentId=l.SourceId
        WHERE l.SourceType='Adjustment'
          AND (adj.PayrollAdjustmentId IS NULL
               OR EXISTS (SELECT 1 FROM payroll.PAYSLIP paid WHERE paid.PayslipId=adj.AppliedToPayslipId AND paid.PayrollRunId<>@PayrollRunId))
        ORDER BY EmployeeName;
    RETURN 0;
END;
GO

/* ------------------------- 9. system component types stay what payroll expects (QA3 PAY-10 / REL-7) -------------------------
   Bodies of script 70 with the refusal for a type that carries a SystemCode. GetAll also returns the code. */
CREATE OR ALTER PROCEDURE hr.usp_ComponentType_GetAll
AS BEGIN SET NOCOUNT ON;
    SELECT ComponentTypeId, Name, Category, Sign, IsActive, SystemCode,
           CAST(CASE WHEN SystemCode IS NULL THEN 0 ELSE 1 END AS BIT) AS IsSystem
    FROM hr.COMPONENT_TYPE ORDER BY ComponentTypeId; END;
GO
CREATE OR ALTER PROCEDURE hr.usp_ComponentType_Update
    @ComponentTypeId INT, @Name NVARCHAR(60), @Category VARCHAR(20), @Sign SMALLINT, @IsActive BIT = NULL
AS BEGIN SET NOCOUNT ON;
    DECLARE @Code VARCHAR(30), @OldName NVARCHAR(60), @OldCategory VARCHAR(20), @OldSign SMALLINT;
    SELECT @Code = SystemCode, @OldName = Name, @OldCategory = Category, @OldSign = [Sign]
    FROM hr.COMPONENT_TYPE WHERE ComponentTypeId = @ComponentTypeId;
    IF @Code IS NOT NULL
       AND (ISNULL(@Name, N'') <> @OldName OR ISNULL(@Category, '') <> @OldCategory OR ISNULL(@Sign, 0) <> @OldSign OR @IsActive = 0)
    BEGIN
        RAISERROR(N'''%s'' is a system component type: payroll writes it on every payslip, so it cannot be renamed, re-categorised or deactivated.', 16, 1, @OldName);
        RETURN 1;
    END
    UPDATE hr.COMPONENT_TYPE
    SET Name = @Name, Category = @Category, Sign = @Sign, IsActive = ISNULL(@IsActive, IsActive)
    WHERE ComponentTypeId = @ComponentTypeId; END;
GO
CREATE OR ALTER PROCEDURE hr.usp_ComponentType_SetActive @ComponentTypeId INT, @IsActive BIT
AS BEGIN SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM hr.COMPONENT_TYPE WHERE ComponentTypeId = @ComponentTypeId)
    BEGIN RAISERROR('Salary component type not found.', 16, 1); RETURN 1; END
    DECLARE @Name NVARCHAR(60) = (SELECT Name FROM hr.COMPONENT_TYPE WHERE ComponentTypeId = @ComponentTypeId AND SystemCode IS NOT NULL);
    IF @Name IS NOT NULL AND @IsActive = 0
    BEGIN
        RAISERROR(N'''%s'' is a system component type: payroll writes it on every payslip, so it cannot be deactivated.', 16, 1, @Name);
        RETURN 1;
    END
    UPDATE hr.COMPONENT_TYPE SET IsActive = @IsActive WHERE ComponentTypeId = @ComponentTypeId; END;
GO
CREATE OR ALTER PROCEDURE hr.usp_ComponentType_Delete @ComponentTypeId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Name NVARCHAR(120), @Code VARCHAR(30);
    SELECT @Name = Name, @Code = SystemCode FROM hr.COMPONENT_TYPE WHERE ComponentTypeId = @ComponentTypeId;
    IF @Name IS NULL BEGIN RAISERROR('Salary component type not found.', 16, 1); RETURN 1; END
    IF @Code IS NOT NULL
    BEGIN
        RAISERROR(N'''%s'' is a system component type: payroll writes it on every payslip, so it cannot be deleted.', 16, 1, @Name);
        RETURN 1;
    END

    DECLARE @Summary NVARCHAR(MAX);
    EXEC core.usp_Object_GetReferences 'hr', 'COMPONENT_TYPE', 'ComponentTypeId', @ComponentTypeId, @Summary OUTPUT;
    IF @Summary IS NOT NULL
    BEGIN
        SET @Summary = core.fn_ListWithAnd(@Summary);
        RAISERROR('Cannot delete ''%s'': it is used by %s. Deactivate it instead.', 16, 1, @Name, @Summary);
        RETURN 1;
    END
    DELETE FROM hr.COMPONENT_TYPE WHERE ComponentTypeId = @ComponentTypeId;
END;
GO

/* ------------------------- 10. exchange-rate writes at full precision (CON-9) -------------------------
   NEW procedures - the live usp_ExchangeRate_Create / _Update are newer than the repo's copies (CON-7) and keep their
   DECIMAL(18,4) parameter, which would round 1/89,500 to 0 on the way in. The API calls these instead. */
CREATE OR ALTER PROCEDURE core.usp_ExchangeRate_Add
    @FromCurrency CHAR(3), @ToCurrency CHAR(3), @RateType VARCHAR(20), @EffectiveDate DATE, @Rate DECIMAL(28,12)
AS
BEGIN
    SET NOCOUNT ON;
    SET @FromCurrency = UPPER(LTRIM(RTRIM(@FromCurrency)));
    SET @ToCurrency   = UPPER(LTRIM(RTRIM(@ToCurrency)));
    SET @RateType     = NULLIF(LTRIM(RTRIM(@RateType)), '');
    IF @Rate IS NULL OR @Rate <= 0 BEGIN RAISERROR('A rate must be above zero.', 16, 1); RETURN 1; END
    IF @FromCurrency IS NULL OR @ToCurrency IS NULL OR @FromCurrency = @ToCurrency
    BEGIN RAISERROR('A rate converts one currency into another - choose two different currencies.', 16, 1); RETURN 1; END
    IF NOT EXISTS (SELECT 1 FROM core.CURRENCY WHERE CurrencyCode = @FromCurrency)
    BEGIN RAISERROR('Unknown currency %s - add it on Currencies first.', 16, 1, @FromCurrency); RETURN 1; END
    IF NOT EXISTS (SELECT 1 FROM core.CURRENCY WHERE CurrencyCode = @ToCurrency)
    BEGIN RAISERROR('Unknown currency %s - add it on Currencies first.', 16, 1, @ToCurrency); RETURN 1; END
    IF @RateType IS NULL BEGIN RAISERROR('Choose the rate type (for example Official).', 16, 1); RETURN 1; END
    IF @EffectiveDate IS NULL BEGIN RAISERROR('The date the rate takes effect is required.', 16, 1); RETURN 1; END
    IF EXISTS (SELECT 1 FROM core.EXCHANGE_RATE WHERE FromCurrency = @FromCurrency AND ToCurrency = @ToCurrency
               AND RateType = @RateType AND EffectiveDate = @EffectiveDate)
    BEGIN
        DECLARE @msg NVARCHAR(400) = CONCAT(CASE WHEN LEFT(@RateType, 1) IN ('A','E','I','O','U') THEN N'An ' ELSE N'A ' END, @RateType,
            N' rate for ', @FromCurrency, N' ', NCHAR(8594), N' ', @ToCurrency, N' on ', CONVERT(CHAR(10), @EffectiveDate, 23),
            N' already exists. Edit that rate instead of adding a second one.');
        RAISERROR(N'%s', 16, 1, @msg);
        RETURN 1;
    END
    INSERT INTO core.EXCHANGE_RATE (FromCurrency, ToCurrency, RateType, EffectiveDate, Rate)
    VALUES (@FromCurrency, @ToCurrency, @RateType, @EffectiveDate, @Rate);
    SELECT CAST(SCOPE_IDENTITY() AS INT) AS ExchangeRateId;
END;
GO
/* Corrects a rate's figure and, optionally, the date it takes effect; the pair and the type stay. Returns the stored row
   (nothing when the id is unknown). A run snapshots its rates, so a locked run never moves. */
CREATE OR ALTER PROCEDURE core.usp_ExchangeRate_SetRate
    @ExchangeRateId INT, @Rate DECIMAL(28,12), @EffectiveDate DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @Rate IS NULL OR @Rate <= 0 BEGIN RAISERROR('A rate must be above zero.', 16, 1); RETURN 1; END
    DECLARE @From CHAR(3), @To CHAR(3), @Type VARCHAR(20), @Date DATE;
    SELECT @From = FromCurrency, @To = ToCurrency, @Type = RateType, @Date = EffectiveDate FROM core.EXCHANGE_RATE WHERE ExchangeRateId = @ExchangeRateId;
    IF @From IS NULL RETURN 0;
    SET @Date = ISNULL(@EffectiveDate, @Date);
    IF EXISTS (SELECT 1 FROM core.EXCHANGE_RATE WHERE FromCurrency = @From AND ToCurrency = @To AND RateType = @Type
               AND EffectiveDate = @Date AND ExchangeRateId <> @ExchangeRateId)
    BEGIN
        DECLARE @msg NVARCHAR(400) = CONCAT(CASE WHEN LEFT(@Type, 1) IN ('A','E','I','O','U') THEN N'An ' ELSE N'A ' END, @Type,
            N' rate for ', @From, N' ', NCHAR(8594), N' ', @To, N' on ', CONVERT(CHAR(10), @Date, 23),
            N' already exists. Edit that rate instead of moving this one onto its date.');
        RAISERROR(N'%s', 16, 1, @msg);
        RETURN 1;
    END
    UPDATE core.EXCHANGE_RATE SET Rate = @Rate, EffectiveDate = @Date WHERE ExchangeRateId = @ExchangeRateId;
    SELECT ExchangeRateId, FromCurrency, ToCurrency, RateType, EffectiveDate, Rate FROM core.EXCHANGE_RATE WHERE ExchangeRateId = @ExchangeRateId;
END;
GO

/* ------------------------- 11. one NSSF / tax version at a time (QA3 PAY-9) -------------------------
   Publishing a NEW version (an insert) closes the previous one the day before it starts; a version starting on or before
   a later one of the same scheme (NSSF) / table (tax) is refused, and so is an edit that makes two versions overlap.
   Existing overlaps are closed first (section 13). The refusal is THROW, not RAISERROR + ROLLBACK: in a trigger the
   latter adds "The transaction ended in the trigger" to the message the user reads.
   The scheme column is read from the table (the live schema calls it Scheme; older stand-ins SchemeName). */
DECLARE @col SYSNAME = CASE WHEN COL_LENGTH('hr.NSSF_RATE', 'Scheme') IS NOT NULL THEN N'Scheme'
                            WHEN COL_LENGTH('hr.NSSF_RATE', 'SchemeName') IS NOT NULL THEN N'SchemeName' END;
IF @col IS NULL
    PRINT 'OWNER CHECK: hr.NSSF_RATE has no Scheme column - the NSSF version trigger was not created.';
ELSE
BEGIN
    DECLARE @t NVARCHAR(MAX) = N'
CREATE OR ALTER TRIGGER hr.trg_NssfRate_OneVersion ON hr.NSSF_RATE
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) RETURN;
    IF NOT EXISTS (SELECT 1 FROM deleted)
    BEGIN
        IF EXISTS (SELECT 1 FROM inserted i
                   JOIN hr.NSSF_RATE n ON n.' + QUOTENAME(@col) + N' = i.' + QUOTENAME(@col) + N' AND n.NssfRateId <> i.NssfRateId AND n.EffectiveFrom >= i.EffectiveFrom
                   WHERE NOT EXISTS (SELECT 1 FROM inserted i2 WHERE i2.NssfRateId = n.NssfRateId))
            THROW 50000, N''A version of this NSSF scheme already starts on or after that date. A new version must start after the latest one - edit that one instead.'', 1;
        /* the new version closes the one in force before it, the day before it starts */
        UPDATE n SET EffectiveTo = DATEADD(DAY, -1, i.EffectiveFrom)
        FROM hr.NSSF_RATE n
        JOIN inserted i ON i.' + QUOTENAME(@col) + N' = n.' + QUOTENAME(@col) + N' AND i.NssfRateId <> n.NssfRateId
        WHERE n.EffectiveFrom < i.EffectiveFrom AND (n.EffectiveTo IS NULL OR n.EffectiveTo >= i.EffectiveFrom)
          AND NOT EXISTS (SELECT 1 FROM inserted i2 WHERE i2.NssfRateId = n.NssfRateId);
    END
    IF EXISTS (SELECT 1 FROM hr.NSSF_RATE a
               JOIN hr.NSSF_RATE b ON b.' + QUOTENAME(@col) + N' = a.' + QUOTENAME(@col) + N' AND b.NssfRateId > a.NssfRateId
               WHERE a.' + QUOTENAME(@col) + N' IN (SELECT ' + QUOTENAME(@col) + N' FROM inserted)
                 AND a.EffectiveFrom <= ISNULL(b.EffectiveTo, ''9999-12-31'') AND b.EffectiveFrom <= ISNULL(a.EffectiveTo, ''9999-12-31''))
        THROW 50000, N''Two versions of this NSSF scheme would be in force on the same days. One version per scheme at a time: end the earlier one the day before the next starts.'', 1;
END;';
    EXEC sys.sp_executesql @t;
END
GO
CREATE OR ALTER TRIGGER hr.trg_TaxBracket_OneVersion ON hr.TAX_BRACKET
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) RETURN;
    /* a version of the tax table = the brackets sharing one EffectiveFrom */
    IF NOT EXISTS (SELECT 1 FROM deleted)
    BEGIN
        IF EXISTS (SELECT 1 FROM inserted i
                   JOIN hr.TAX_BRACKET b ON b.EffectiveFrom > i.EffectiveFrom
                   WHERE NOT EXISTS (SELECT 1 FROM inserted i2 WHERE i2.TaxBracketId = b.TaxBracketId))
            THROW 50000, N'A later version of the tax table already exists. A new version must start after the latest one - edit that one instead.', 1;
        UPDATE b SET EffectiveTo = DATEADD(DAY, -1, i.F)
        FROM hr.TAX_BRACKET b
        JOIN (SELECT MAX(EffectiveFrom) AS F FROM inserted) i ON 1 = 1
        WHERE b.EffectiveFrom < i.F AND (b.EffectiveTo IS NULL OR b.EffectiveTo >= i.F)
          AND NOT EXISTS (SELECT 1 FROM inserted i2 WHERE i2.TaxBracketId = b.TaxBracketId);
    END
    IF EXISTS (SELECT 1 FROM hr.TAX_BRACKET a
               JOIN hr.TAX_BRACKET b ON b.EffectiveFrom > a.EffectiveFrom
               WHERE a.EffectiveFrom <= ISNULL(b.EffectiveTo, '9999-12-31') AND b.EffectiveFrom <= ISNULL(a.EffectiveTo, '9999-12-31'))
        THROW 50000, N'Two versions of the tax table would be in force on the same days. One table at a time: end the earlier one the day before the next starts.', 1;
END;
GO

/* ------------------------- 12. permissions (QA3 PAY-12 / WEB-4) -------------------------
   PAYROLL_VIEW opens the payroll pages and every payroll read; REPORT_VIEW the reports. Given to every role that holds
   PAYROLL_RUN or PAYROLL_APPROVE (resp. ATTENDANCE_VIEW) today, so nobody loses a page. Idempotent. */
INSERT INTO security.PERMISSION (Code, Name, Module)
SELECT 'PAYROLL_VIEW', N'View payroll runs and payslips', 'Payroll'
WHERE NOT EXISTS (SELECT 1 FROM security.PERMISSION WHERE Code = 'PAYROLL_VIEW');
INSERT INTO security.PERMISSION (Code, Name, Module)
SELECT 'REPORT_VIEW', N'View reports', 'Reports'
WHERE NOT EXISTS (SELECT 1 FROM security.PERMISSION WHERE Code = 'REPORT_VIEW');
INSERT INTO security.ROLE_PERMISSION (RoleId, PermissionId)
SELECT DISTINCT rp.RoleId, v.PermissionId
FROM security.ROLE_PERMISSION rp
JOIN security.PERMISSION p ON p.PermissionId = rp.PermissionId AND p.Code IN ('PAYROLL_RUN', 'PAYROLL_APPROVE')
CROSS JOIN (SELECT PermissionId FROM security.PERMISSION WHERE Code = 'PAYROLL_VIEW') v
WHERE NOT EXISTS (SELECT 1 FROM security.ROLE_PERMISSION x WHERE x.RoleId = rp.RoleId AND x.PermissionId = v.PermissionId);
INSERT INTO security.ROLE_PERMISSION (RoleId, PermissionId)
SELECT DISTINCT rp.RoleId, v.PermissionId
FROM security.ROLE_PERMISSION rp
JOIN security.PERMISSION p ON p.PermissionId = rp.PermissionId AND p.Code = 'ATTENDANCE_VIEW'
CROSS JOIN (SELECT PermissionId FROM security.PERMISSION WHERE Code = 'REPORT_VIEW') v
WHERE NOT EXISTS (SELECT 1 FROM security.ROLE_PERMISSION x WHERE x.RoleId = rp.RoleId AND x.PermissionId = v.PermissionId);
GO

/* ------------------------- 13. data repairs (idempotent; a locked run's payslips are never touched) ------------------------- */

/* 13a. QA3 PAY-6: a standing salary row still open (or still in force) when a later row of the same employee, type and
   currency starts was paid IN FULL next to it. It is closed the day before the later row starts - but never inside a
   month already paid for that employee: there it stays in force to the end of the last paid month, so the data keeps
   saying what those locked payslips paid. Rows starting on the same day are left for the owner. */
DECLARE @fix TABLE (SalaryComponentId INT PRIMARY KEY, EmployeeId INT, NewTo DATE, OldTo DATE, LaterFrom DATE, PaidThrough DATE);
INSERT INTO @fix (SalaryComponentId, EmployeeId, NewTo, OldTo, LaterFrom, PaidThrough)
SELECT a.SalaryComponentId, a.EmployeeId,
       CASE WHEN pd.PaidThrough IS NOT NULL AND pd.PaidThrough > DATEADD(DAY, -1, nx.LaterFrom) THEN pd.PaidThrough ELSE DATEADD(DAY, -1, nx.LaterFrom) END,
       a.EffectiveTo, nx.LaterFrom, pd.PaidThrough
FROM hr.SALARY_COMPONENT a
CROSS APPLY (SELECT MIN(b.EffectiveFrom) AS LaterFrom FROM hr.SALARY_COMPONENT b
             WHERE b.EmployeeId = a.EmployeeId AND b.ComponentTypeId = a.ComponentTypeId AND b.CurrencyCode = a.CurrencyCode
               AND b.EffectiveFrom > a.EffectiveFrom) nx
OUTER APPLY (SELECT MAX(r.PeriodEnd) AS PaidThrough
             FROM payroll.PAYROLL_RUN r JOIN payroll.PAYSLIP ps ON ps.PayrollRunId = r.PayrollRunId AND ps.EmployeeId = a.EmployeeId
             WHERE r.RunType = 'Primary' AND r.[Status] = 'Approved' AND r.PeriodEnd >= nx.LaterFrom
               AND r.PeriodStart <= ISNULL(a.EffectiveTo, '9999-12-31')) pd
WHERE nx.LaterFrom IS NOT NULL AND (a.EffectiveTo IS NULL OR a.EffectiveTo >= nx.LaterFrom);
DELETE FROM @fix WHERE NewTo >= ISNULL(OldTo, '9999-12-31');
UPDATE sc SET EffectiveTo = f.NewTo FROM hr.SALARY_COMPONENT sc JOIN @fix f ON f.SalaryComponentId = sc.SalaryComponentId;
DECLARE @msg NVARCHAR(MAX) = (SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), CONCAT(N'row ', SalaryComponentId, N' (employee ', EmployeeId, N') now ends ', CONVERT(CHAR(10), NewTo, 23),
                                     CASE WHEN PaidThrough IS NOT NULL THEN CONCAT(N' - PAID TWICE in locked months up to ', CONVERT(CHAR(10), PaidThrough, 23), N': raise an adjustment') ELSE N'' END)), N'; ')
                              FROM @fix);
IF @msg IS NOT NULL PRINT CONCAT('PAY-6 repair - overlapping salary rows closed: ', @msg);
SET @msg = (SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), CONCAT(N'rows ', a.SalaryComponentId, N'/', b.SalaryComponentId, N' (employee ', a.EmployeeId, N')')), N'; ')
            FROM hr.SALARY_COMPONENT a JOIN hr.SALARY_COMPONENT b
              ON b.EmployeeId = a.EmployeeId AND b.ComponentTypeId = a.ComponentTypeId AND b.CurrencyCode = a.CurrencyCode
             AND b.EffectiveFrom = a.EffectiveFrom AND b.SalaryComponentId > a.SalaryComponentId);
IF @msg IS NOT NULL PRINT CONCAT('OWNER CHECK: salary rows of the same type starting the same day (payroll pays the later one): ', @msg);
GO

/* 13b. QA3 PAY-2: the settlements already paid by a locked run carry the payslip that paid them */
UPDATE s SET PaidInPayslipId = x.PayslipId
FROM workflow.SEPARATION s
JOIN (SELECT l.SourceId, MIN(l.PayslipId) AS PayslipId
      FROM payroll.PAYSLIP_LINE l
      JOIN payroll.PAYSLIP ps ON ps.PayslipId = l.PayslipId
      JOIN payroll.PAYROLL_RUN r ON r.PayrollRunId = ps.PayrollRunId AND r.[Status] = 'Approved'
      WHERE l.SourceType = 'Separation'
      GROUP BY l.SourceId) x ON x.SourceId = s.SeparationId
WHERE s.PaidInPayslipId IS NULL;
IF @@ROWCOUNT > 0 PRINT 'PAY-2 repair - separations already paid stamped with their payslip.';
GO

/* 13c. QA3 REL-14 / LEV-8: a leave balance a locked run already paid on termination (a payout line, or the unused leave of
   a separation settlement) is settled in the ledger (as of the termination date, per type), so it reads 0 and is never
   paid again. Where today's balance differs from what was paid, the owner is told (the difference is history: settle it
   with an adjustment if it matters). */
DECLARE @paid TABLE (PayslipId INT, EmployeeId INT, PaidDays DECIMAL(9,2), Period CHAR(7));
INSERT INTO @paid
SELECT ps.PayslipId, ps.EmployeeId,
       SUM(CASE WHEN l.SourceType = 'Separation' THEN ISNULL(s.UnusedLeaveDays, 0)
                WHEN c.SystemCode = 'LEAVE_DEDUCTION' THEN -l.Quantity ELSE l.Quantity END), MIN(r.PeriodYearMonth)
FROM payroll.PAYSLIP_LINE l
JOIN payroll.PAYSLIP ps ON ps.PayslipId = l.PayslipId
JOIN payroll.PAYROLL_RUN r ON r.PayrollRunId = ps.PayrollRunId AND r.[Status] = 'Approved'
LEFT JOIN hr.COMPONENT_TYPE c ON c.ComponentTypeId = l.ComponentTypeId
LEFT JOIN workflow.SEPARATION s ON l.SourceType = 'Separation' AND s.SeparationId = l.SourceId
WHERE (l.SourceType = 'LeavePayout' OR (l.SourceType = 'Separation' AND c.SystemCode = 'UNUSED_LEAVE'))
  AND NOT EXISTS (SELECT 1 FROM hr.LEAVE_LEDGER z WHERE z.SourceType = 'TerminationPayout' AND z.SourceRef = ps.PayslipId)
GROUP BY ps.PayslipId, ps.EmployeeId;
DECLARE @msg NVARCHAR(MAX) = (
    SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), CONCAT(N'employee ', p.EmployeeId, N' paid ', p.PaidDays, N' day(s) in ', p.Period, N', balance now ', ISNULL(b.Bal, 0))), N'; ')
    FROM @paid p
    JOIN hr.EMPLOYEE e ON e.EmployeeId = p.EmployeeId
    OUTER APPLY (SELECT CAST(SUM(l.Days) AS DECIMAL(9,2)) AS Bal FROM hr.LEAVE_LEDGER l
                 JOIN hr.LEAVE_TYPE lt ON lt.LeaveTypeId = l.LeaveTypeId AND lt.IsPaid = 1
                 WHERE l.EmployeeId = p.EmployeeId AND l.EffectiveDate <= ISNULL(e.TerminationDate, '9999-12-31')
                   AND EXISTS (SELECT 1 FROM hr.LEAVE_ACCRUAL_TIER t WHERE t.LeaveTypeId = l.LeaveTypeId)) b
    WHERE ISNULL(b.Bal, 0) <> p.PaidDays);
INSERT INTO hr.LEAVE_LEDGER (EmployeeId, LeaveTypeId, PeriodYearMonth, MovementType, LeaveRequestId, Days, EffectiveDate, Note, CreatedBy, SourceType, SourceRef)
SELECT e.EmployeeId, b.LeaveTypeId, CONVERT(CHAR(7), e.TerminationDate, 23), 'Adjustment', NULL, -b.Balance, e.TerminationDate,
       CONCAT(N'Leave balance settled on termination (payroll ', p.Period, N', payslip ', p.PayslipId, N'; recorded by script 103).'), NULL, 'TerminationPayout', p.PayslipId
FROM @paid p
JOIN hr.EMPLOYEE e ON e.EmployeeId = p.EmployeeId AND e.TerminationDate IS NOT NULL
CROSS APPLY (SELECT l.LeaveTypeId, CAST(SUM(l.Days) AS DECIMAL(9,2)) AS Balance
             FROM hr.LEAVE_LEDGER l
             JOIN hr.LEAVE_TYPE lt ON lt.LeaveTypeId = l.LeaveTypeId AND lt.IsPaid = 1
             WHERE l.EmployeeId = e.EmployeeId AND l.EffectiveDate <= e.TerminationDate
               AND EXISTS (SELECT 1 FROM hr.LEAVE_ACCRUAL_TIER t WHERE t.LeaveTypeId = l.LeaveTypeId)
             GROUP BY l.LeaveTypeId) b
WHERE b.Balance <> 0;
IF @msg IS NOT NULL PRINT CONCAT('OWNER CHECK: leave paid out on termination differs from the balance on file (settled at the balance): ', @msg);
GO

/* 13d. QA3 PAY-9: overlapping NSSF versions of a scheme and overlapping tax tables - the earlier one ends the day before
   the later one starts (configuration only; locked runs keep their lines). */
DECLARE @col SYSNAME = CASE WHEN COL_LENGTH('hr.NSSF_RATE', 'Scheme') IS NOT NULL THEN N'Scheme'
                            WHEN COL_LENGTH('hr.NSSF_RATE', 'SchemeName') IS NOT NULL THEN N'SchemeName' END;
IF @col IS NOT NULL
BEGIN
    DECLARE @r NVARCHAR(MAX) = N'
    DISABLE TRIGGER hr.trg_NssfRate_OneVersion ON hr.NSSF_RATE;
    UPDATE a SET EffectiveTo = DATEADD(DAY, -1, nx.LaterFrom)
    FROM hr.NSSF_RATE a
    CROSS APPLY (SELECT MIN(b.EffectiveFrom) AS LaterFrom FROM hr.NSSF_RATE b
                 WHERE b.' + QUOTENAME(@col) + N' = a.' + QUOTENAME(@col) + N' AND b.EffectiveFrom > a.EffectiveFrom) nx
    WHERE nx.LaterFrom IS NOT NULL AND (a.EffectiveTo IS NULL OR a.EffectiveTo >= nx.LaterFrom);
    IF @@ROWCOUNT > 0 PRINT ''PAY-9 repair - overlapping NSSF versions closed the day before the next one.'';
    ENABLE TRIGGER hr.trg_NssfRate_OneVersion ON hr.NSSF_RATE;';
    EXEC sys.sp_executesql @r;
END
GO
DISABLE TRIGGER hr.trg_TaxBracket_OneVersion ON hr.TAX_BRACKET;
UPDATE a SET EffectiveTo = DATEADD(DAY, -1, nx.LaterFrom)
FROM hr.TAX_BRACKET a
CROSS APPLY (SELECT MIN(b.EffectiveFrom) AS LaterFrom FROM hr.TAX_BRACKET b WHERE b.EffectiveFrom > a.EffectiveFrom) nx
WHERE nx.LaterFrom IS NOT NULL AND (a.EffectiveTo IS NULL OR a.EffectiveTo >= nx.LaterFrom);
IF @@ROWCOUNT > 0 PRINT 'PAY-9 repair - overlapping tax tables closed the day before the next one.';
ENABLE TRIGGER hr.trg_TaxBracket_OneVersion ON hr.TAX_BRACKET;
GO

/* ------------------------- 14. verification ------------------------- */
DECLARE @rate VARCHAR(20) = (SELECT CONCAT('DECIMAL(', c.precision, ',', c.scale, ')') FROM sys.columns c WHERE c.object_id = OBJECT_ID('core.EXCHANGE_RATE') AND c.name = 'Rate');
DECLARE @codes INT = (SELECT COUNT(*) FROM hr.COMPONENT_TYPE WHERE SystemCode IS NOT NULL);
DECLARE @perm INT = (SELECT COUNT(*) FROM security.PERMISSION WHERE Code IN ('PAYROLL_VIEW', 'REPORT_VIEW'));
DECLARE @earlyLock INT = (SELECT COUNT(*) FROM sys.parameters WHERE object_id = OBJECT_ID('payroll.usp_PayrollRun_Approve') AND name IN ('@AllowEarlyLock', '@AsOfDate'));
PRINT CONCAT('core.EXCHANGE_RATE.Rate = ', @rate, ' (expected DECIMAL(28,12)); system component types = ', @codes, ' (expected 16); ',
             'PAYROLL_VIEW/REPORT_VIEW = ', @perm, ' (expected 2); Approve @AllowEarlyLock/@AsOfDate = ', @earlyLock, ' (expected 2)');
PRINT 'QA3 payroll (103): staleness check, completed days, settlements catch-up, component codes, one NSSF/tax version, full-precision rates in place';
GO
