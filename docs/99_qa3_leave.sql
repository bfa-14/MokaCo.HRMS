/* ============================================================================
   99_qa3_leave.sql -- QA3 unit D: leave. Apply after 98 (it needs 82-98: 82 LEAVE_REQUEST.HalfDay, fn_IsPeriodPaid,
   branch history, holidays; 84 the leave poster; 70 LEAVE_TYPE.IsActive; workflow_exit_permission LEAVE_LEDGER.SourceType).
   Apply with sqlcmd -I -b. Idempotent: CREATE OR ALTER, guarded ALTER TABLE / UPDATE / DELETE; a second run changes nothing.

   CONTRACT (other units code against these)
   - workflow.LEAVE_REQUEST.ApprovedToDate DATE NULL: the last day an Approved leave covers -- ToDate, or, for a partial
     approval, the last day the ledger allocated (a partial approval keeps the FIRST days). Readers of an Approved
     request use ISNULL(lr.ApprovedToDate, lr.ToDate). hr.usp_LeaveLedger_PostRequest sets it at final approval; unit A
     clears it (NULL) when an approval is undone.
   - workflow.LEAVE_REQUEST.PaidSnapshot BIT NULL: the type's IsPaid at final approval. Payroll reads
     ISNULL(lr.PaidSnapshot, lt.IsPaid), so flipping a type later never re-prices approved leave.
   - hr.usp_LeaveLedger_Reprice @EmployeeId, @FromDate, @ToDate: re-posts the Usage rows (and the discretionary
     Adjustment pairs) of the employee's posted Approved leave overlapping the range, against the current roster, the
     holidays of the branch of each day and the weekly pattern, skipping the months already paid for that employee.
     Idempotent, no result set, safe inside a caller's transaction or an INSERT..EXEC chain.
   - hr.fn_LeaveRequestDays(@LeaveRequestId, @Fresh): an approved leave day by day (WorkDate, Part): every calendar day
     of From..ApprovedToDate with what it costs (0 for a rest day, a holiday, a day outside employment). The one
     allocation the poster, the re-pricing and the carry-over expiry share.
   - REQUEST_STEP_INSTANCE.ValueBefore of a leave decision = '<standing days>|<discretionary 0/1>', e.g. '5.0|0': the
     figure (DaysApproved, else DaysRequested) and the IsDiscretionary flag as they stood before that decision.
     Unit A restores both from it on retract / reopen / withdraw.
   - hr.usp_LeaveLedger_PostMovement @Quiet = 1: posts without a result set (ATT-15: callers inside a loop or INSERT..EXEC).

   FIXES
   LEV-2 PAY-8 ATT-8 REL-6  partial approval: the approved span is stored (ApprovedToDate + backfill R1); the overlap
                    guard, the payload and the employee's list read it; the comment of LeaveRequestDecideRequest (C#) said
                    the opposite.
   LEV-4 REL-12 ROS-12  a leave costs the working days of the roster as it stands: hr.usp_LeaveLedger_Reprice (new).
                    hr.fn_LeaveDays: a day with no roster row is priced from the employee's weekly pattern when there is
                    one (a rest day there is free), else it is a working day as before; a day before HireDate or after
                    TerminationDate costs nothing (column IsEmployed). Fixed-entitlement types still count calendar days.
   LEV-1            the "Year close" / "Unused ... expired" adjustment belongs to the CLOSING year (December, 31 Dec), so the
                    new year's card no longer subtracts last year's remainder (repair R4 moves the old rows).
   LEV-9            usp_LeaveYear_Open: the close and the carry each have their own NOT EXISTS guard; the opening row is written
                    even for 0 days (a 0-day tier, or no tier for the service: the old year is still closed, once); NEW
                    hr.usp_LeaveYear_Undo; hr.usp_LeaveLedger_Delete deletes manual adjustments only (others refused with
                    a sentence), and usp_LeaveLedger_GetByEmployee says which rows may go (CanDelete). Repairs R2, R3.
   LEV-6            carry-over expiry: discretionary days do not consume carried days; the expiry month is counted day by
                    day (mid-month expiry); later postings are corrected by a delta until the expiry month is paid; '02-29'
                    is the last day of February; a value that is not MM-DD expires nothing and says so (@Problem, logged
                    by the nightly job).
   LEV-11 WF-16     create, decide and the ledger posting refuse days already paid for the employee
                    ("This period is paid -- raise a payroll adjustment instead.", with an em dash); a manual Usage
                    movement too.
   REL-4 (part)     create and decide refuse dates after the employee's TerminationDate.
   LEV-12           whole years / months of service (year opening tier, usage gate).
   LEV-13           an inactive leave type is not granted at year open and not accepted by create.
   LEV-14 CON-8     usp_LeaveBalance_Get and report.usp_Report_LeaveBalance return Adjusted; the columns add up.
   LEV-7 WF-4       usp_LeaveRequest_Decide records ValueBefore on the decided step.
   convention 4     usp_LeaveRequest_Create checks the INSERT..EXEC of usp_Request_Submit; Decide is one transaction.
   suspicions       usp_Leave_GetBalanceByYear defaulted the year from GETDATE() (UTC): now Beirut. usp_Leave_CountWorkingDays
                    showed 1 where create stores 0.5 (half day of a fixed-entitlement type): it now counts as create does,
                    and returns PendingDays + BalanceEnforced so the form warns like the server refuses.

   DATA REPAIRS (guarded, idempotent; ledger day-markers only: no payroll run, payslip or money row is read for change)
   R1  backfill ApprovedToDate (partial approvals: the last day of the first DaysApproved working days, by the same
       allocation the poster used) and PaidSnapshot (the type's IsPaid today) of the Approved requests posted before.
   R2  mark the rows usp_LeaveYear_Open wrote (opening, carry-over, year close): SourceType 'LeaveYear', SourceRef = the
       year opened -- what the guards, the undo and the delete rule recognise.
   R3  remove duplicated year-opening rows (the 0-day-tier re-runs and the delete-and-reopen workaround posted the
       close and the carry again): the first row per employee, type, kind and year is kept.
   R4  move the year-close adjustments still in January of the new year to 31 December of the closing year (LEV-1).

   STALE REPO COPIES (CON-7): hr.usp_LeaveLedger_GetByEmployee / _PostMovement / _Delete, hr.usp_LeaveBalance_Get and
   report.usp_Report_LeaveBalance were last defined in unnumbered scripts; the guard batch below stops the script when
   the live version has a parameter or a first-result column the version here lacks.
   ============================================================================ */
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ------------------------- 0. prerequisites ------------------------- */
IF OBJECT_ID('hr.usp_LeaveLedger_PostRequest') IS NULL OR OBJECT_ID('payroll.fn_IsPeriodPaid') IS NULL
   OR OBJECT_ID('hr.fn_EmployeeBranchOn') IS NULL OR OBJECT_ID('core.fn_IsHoliday') IS NULL
   OR OBJECT_ID('attendance.EMPLOYEE_SHIFT_PATTERN') IS NULL
   OR COL_LENGTH('workflow.LEAVE_REQUEST', 'HalfDay') IS NULL OR COL_LENGTH('hr.LEAVE_TYPE', 'IsActive') IS NULL
   OR COL_LENGTH('hr.LEAVE_LEDGER', 'SourceType') IS NULL OR COL_LENGTH('workflow.REQUEST_STEP_INSTANCE', 'ValueBefore') IS NULL
    RAISERROR('99_qa3_leave.sql: apply the numbered scripts up to 98 first (82, 84, 70 and workflow_exit_permission.sql are not all in place).', 16, 1);
GO

/* STALE REPO COPIES (QA3 CON-7). Five procedures redefined below were last defined in an unnumbered script. When the live
   database holds a NEWER version -- a parameter, or a column of its first result, that the version below lacks -- stop
   here, before anything is changed, so that version is merged into this script instead of being overwritten. */
DECLARE @mine TABLE (ProcName SYSNAME, Kind CHAR(1), Item SYSNAME);     -- Kind: P = parameter, C = first-result column
INSERT INTO @mine (ProcName, Kind, Item) VALUES
 ('hr.usp_LeaveLedger_GetByEmployee', 'P', '@EmployeeId'), ('hr.usp_LeaveLedger_GetByEmployee', 'P', '@PeriodYearMonth'),
 ('hr.usp_LeaveLedger_GetByEmployee', 'C', 'LeaveLedgerId'), ('hr.usp_LeaveLedger_GetByEmployee', 'C', 'EmployeeId'),
 ('hr.usp_LeaveLedger_GetByEmployee', 'C', 'LeaveTypeId'), ('hr.usp_LeaveLedger_GetByEmployee', 'C', 'PeriodYearMonth'),
 ('hr.usp_LeaveLedger_GetByEmployee', 'C', 'MovementType'), ('hr.usp_LeaveLedger_GetByEmployee', 'C', 'LeaveRequestId'),
 ('hr.usp_LeaveLedger_GetByEmployee', 'C', 'Days'), ('hr.usp_LeaveLedger_GetByEmployee', 'C', 'EffectiveDate'),
 ('hr.usp_LeaveLedger_GetByEmployee', 'C', 'Note'), ('hr.usp_LeaveLedger_GetByEmployee', 'C', 'CreatedAt'),
 ('hr.usp_LeaveLedger_GetByEmployee', 'C', 'SourceType'), ('hr.usp_LeaveLedger_GetByEmployee', 'C', 'CanDelete'),
 ('hr.usp_LeaveLedger_PostMovement', 'P', '@EmployeeId'), ('hr.usp_LeaveLedger_PostMovement', 'P', '@LeaveTypeId'),
 ('hr.usp_LeaveLedger_PostMovement', 'P', '@MovementType'), ('hr.usp_LeaveLedger_PostMovement', 'P', '@Days'),
 ('hr.usp_LeaveLedger_PostMovement', 'P', '@EffectiveDate'), ('hr.usp_LeaveLedger_PostMovement', 'P', '@LeaveRequestId'),
 ('hr.usp_LeaveLedger_PostMovement', 'P', '@Note'), ('hr.usp_LeaveLedger_PostMovement', 'P', '@CreatedBy'),
 ('hr.usp_LeaveLedger_PostMovement', 'P', '@SourceType'), ('hr.usp_LeaveLedger_PostMovement', 'P', '@SourceRef'),
 ('hr.usp_LeaveLedger_PostMovement', 'P', '@Quiet'), ('hr.usp_LeaveLedger_PostMovement', 'C', 'LeaveLedgerId'),
 ('hr.usp_LeaveLedger_Delete', 'P', '@LeaveLedgerId'),
 ('hr.usp_LeaveBalance_Get', 'P', '@EmployeeId'), ('hr.usp_LeaveBalance_Get', 'P', '@PeriodYearMonth'),
 ('hr.usp_LeaveBalance_Get', 'C', 'EmployeeId'), ('hr.usp_LeaveBalance_Get', 'C', 'LeaveTypeId'),
 ('hr.usp_LeaveBalance_Get', 'C', 'PeriodYearMonth'), ('hr.usp_LeaveBalance_Get', 'C', 'Accrued'),
 ('hr.usp_LeaveBalance_Get', 'C', 'CarriedOver'), ('hr.usp_LeaveBalance_Get', 'C', 'Used'),
 ('hr.usp_LeaveBalance_Get', 'C', 'Adjusted'), ('hr.usp_LeaveBalance_Get', 'C', 'Remaining'),
 ('report.usp_Report_LeaveBalance', 'P', '@AsOfYearMonth'), ('report.usp_Report_LeaveBalance', 'P', '@EmployeeId'),
 ('report.usp_Report_LeaveBalance', 'P', '@BranchId'),
 ('report.usp_Report_LeaveBalance', 'C', 'ReportTitle'), ('report.usp_Report_LeaveBalance', 'C', 'AsOfPeriod'),
 ('report.usp_Report_LeaveBalance', 'C', 'BranchName'), ('report.usp_Report_LeaveBalance', 'C', 'GeneratedUtc');
DECLARE @newer NVARCHAR(2000) = (
    SELECT STRING_AGG(CAST(x.What AS NVARCHAR(MAX)), N', ')
    FROM (SELECT CONCAT(m.ProcName, N' parameter ', p.name) AS What
          FROM (SELECT DISTINCT ProcName FROM @mine) m
          JOIN sys.parameters p ON p.object_id = OBJECT_ID(m.ProcName)
          WHERE p.name <> N''
            AND NOT EXISTS (SELECT 1 FROM @mine k WHERE k.ProcName = m.ProcName AND k.Kind = 'P' AND k.Item = p.name)
          UNION ALL
          SELECT CONCAT(m.ProcName, N' column ', r.name)
          FROM (SELECT DISTINCT ProcName FROM @mine) m
          CROSS APPLY sys.dm_exec_describe_first_result_set_for_object(OBJECT_ID(m.ProcName), 0) r
          WHERE OBJECT_ID(m.ProcName) IS NOT NULL AND r.name IS NOT NULL AND r.error_number IS NULL
            AND NOT EXISTS (SELECT 1 FROM @mine k WHERE k.ProcName = m.ProcName AND k.Kind = 'C' AND k.Item = r.name)) x);
IF @newer IS NOT NULL
    RAISERROR('99_qa3_leave.sql: the live database has a newer version of a procedure this script redefines (%s). Nothing was changed: merge that version into this script first.', 16, 1, @newer);
GO

/* ------------------------- 1. the approved span and the paid flag of a leave (contract) ------------------------- */
IF COL_LENGTH('workflow.LEAVE_REQUEST', 'ApprovedToDate') IS NULL
    ALTER TABLE workflow.LEAVE_REQUEST ADD ApprovedToDate DATE NULL;
IF COL_LENGTH('workflow.LEAVE_REQUEST', 'PaidSnapshot') IS NULL
    ALTER TABLE workflow.LEAVE_REQUEST ADD PaidSnapshot BIT NULL;
GO

/* R1. The Approved requests posted before this script. A partial approval (DaysApproved below DaysRequested) ends on the
   day its DaysApproved-th working day falls -- the allocation the poster used (hr.fn_LeaveDays as it stands when this
   runs: on the first run, still script 84's); everything else ends on ToDate. PaidSnapshot = the type's IsPaid today.
   Markers only: no ledger row is changed. */
DECLARE @r1 INT, @r1p INT;
UPDATE lr
SET ApprovedToDate = CASE WHEN lr.HalfDay IS NULL AND lr.DaysApproved IS NOT NULL AND lr.DaysApproved < lr.DaysRequested
                          THEN ISNULL(cut.LastDay, lr.ToDate) ELSE lr.ToDate END
FROM workflow.LEAVE_REQUEST lr
JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = lr.RequestInstanceId
JOIN hr.LEAVE_TYPE lt ON lt.LeaveTypeId = lr.LeaveTypeId
OUTER APPLY (
    SELECT MAX(d.WorkDate) AS LastDay
    FROM (SELECT TOP (CAST(CEILING(ISNULL(lr.DaysApproved, 0)) AS INT)) f.WorkDate
          FROM hr.fn_LeaveDays(lr.EmployeeId, lr.FromDate, lr.ToDate) f
          WHERE lt.FixedEntitlementDays IS NOT NULL OR f.Counts = 1
          ORDER BY f.WorkDate) d
    HAVING COUNT(*) = CEILING(ISNULL(lr.DaysApproved, 0))
) cut
WHERE ri.[Status] = 'Approved' AND lr.ApprovedToDate IS NULL;
SET @r1 = @@ROWCOUNT;
UPDATE lr SET PaidSnapshot = lt.IsPaid
FROM workflow.LEAVE_REQUEST lr
JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = lr.RequestInstanceId
JOIN hr.LEAVE_TYPE lt ON lt.LeaveTypeId = lr.LeaveTypeId
WHERE ri.[Status] = 'Approved' AND lr.PaidSnapshot IS NULL;
SET @r1p = @@ROWCOUNT;
PRINT CONCAT('R1: ApprovedToDate set on ', @r1, ' approved request(s), PaidSnapshot on ', @r1p, '.');
GO
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints
               WHERE name = 'CK_LEAVE_REQUEST_ApprovedToDate' AND parent_object_id = OBJECT_ID('workflow.LEAVE_REQUEST'))
    ALTER TABLE workflow.LEAVE_REQUEST WITH CHECK ADD CONSTRAINT CK_LEAVE_REQUEST_ApprovedToDate
        CHECK (ApprovedToDate IS NULL OR (ApprovedToDate >= FromDate AND ApprovedToDate <= ToDate));
GO

/* ------------------------- 2. the year-opening rows: marked, de-duplicated, the close in the closing year ------------------------- */
DECLARE @n2 INT = 0, @n3 INT, @n4 INT;
/* R2. What usp_LeaveYear_Open wrote, recognised by its own notes: the opening ('Annual entitlement YYYY...' in YYYY-01), the
   carry ('Carried over from YYYY-1.' on 1 January) and the close ('Year close YYYY-1 ...' / 'Unused YYYY-1 days expired
   (no carry-over).'). SourceRef = the year that was opened. */
UPDATE l SET SourceType = 'LeaveYear', SourceRef = TRY_CAST(LEFT(l.PeriodYearMonth, 4) AS INT)
FROM hr.LEAVE_LEDGER l
WHERE l.SourceType IS NULL AND l.LeaveRequestId IS NULL AND l.MovementType = 'Accrual'
  AND l.PeriodYearMonth LIKE '[12][0-9][0-9][0-9]-01'
  AND l.Note LIKE N'Annual entitlement ' + LEFT(l.PeriodYearMonth, 4) + N'%';
SET @n2 += @@ROWCOUNT;
UPDATE l SET SourceType = 'LeaveYear', SourceRef = YEAR(l.EffectiveDate)
FROM hr.LEAVE_LEDGER l
WHERE l.SourceType IS NULL AND l.LeaveRequestId IS NULL AND l.MovementType = 'CarryOver'
  AND l.Note = CONCAT(N'Carried over from ', YEAR(l.EffectiveDate) - 1, N'.');
SET @n2 += @@ROWCOUNT;
UPDATE l SET SourceType = 'LeaveYear', SourceRef = c.ClosedYear + 1
FROM hr.LEAVE_LEDGER l
CROSS APPLY (SELECT TRY_CAST(SUBSTRING(l.Note, CASE WHEN l.Note LIKE N'Year close %' THEN 12 ELSE 8 END, 4) AS INT) AS ClosedYear) c
WHERE l.SourceType IS NULL AND l.LeaveRequestId IS NULL AND l.MovementType = 'Adjustment'
  AND (l.Note LIKE N'Year close [12][0-9][0-9][0-9]%' OR l.Note LIKE N'Unused [12][0-9][0-9][0-9] days expired (no carry-over).')
  AND c.ClosedYear IS NOT NULL;
SET @n2 += @@ROWCOUNT;
/* R3. One opening, one carry and one close per employee, type and year: an IDENTICAL second one (same days) was a re-run
   of the same close (the 0-day-tier bug re-posted it on every run; deleting the entitlement and opening again posted it
   twice). The first is kept. A second one with different days is not touched -- it is counted below for a person to
   look at. */
DELETE l
FROM hr.LEAVE_LEDGER l
WHERE l.SourceType = 'LeaveYear'
  AND EXISTS (SELECT 1 FROM hr.LEAVE_LEDGER k
              WHERE k.SourceType = 'LeaveYear' AND k.SourceRef = l.SourceRef AND k.EmployeeId = l.EmployeeId
                AND k.LeaveTypeId = l.LeaveTypeId AND k.MovementType = l.MovementType AND k.Days = l.Days
                AND k.LeaveLedgerId < l.LeaveLedgerId);
SET @n3 = @@ROWCOUNT;
DECLARE @n3x INT = (SELECT COUNT(*) FROM (SELECT 1 AS x FROM hr.LEAVE_LEDGER WHERE SourceType = 'LeaveYear'
                                          GROUP BY SourceRef, EmployeeId, LeaveTypeId, MovementType HAVING COUNT(*) > 1) g);
IF @n3x > 0
    PRINT CONCAT('R3: ', @n3x, ' employee/type/year group(s) still hold two year-opening rows of one kind with DIFFERENT days -- ',
                 'review them (SELECT ... FROM hr.LEAVE_LEDGER WHERE SourceType = ''LeaveYear'') and correct with an adjustment.');
/* R4 (LEV-1). The close belongs to the year it closes: 31 December, period YYYY-12 -- not January of the new year,
   where the new year's card subtracted it from the new entitlement. */
UPDATE l
SET PeriodYearMonth = CONCAT(l.SourceRef - 1, '-12'), EffectiveDate = DATEFROMPARTS(l.SourceRef - 1, 12, 31)
FROM hr.LEAVE_LEDGER l
WHERE l.SourceType = 'LeaveYear' AND l.MovementType = 'Adjustment' AND l.PeriodYearMonth = CONCAT(l.SourceRef, '-01');
SET @n4 = @@ROWCOUNT;
PRINT CONCAT('R2: ', @n2, ' year-opening row(s) marked; R3: ', @n3, ' duplicated year-opening row(s) removed; R4: ',
             @n4, ' year-close row(s) moved to 31 December of the closing year.');
GO

/* ------------------------- 3. what a day of leave costs (LEV-4) ------------------------- */
/* Every calendar day of a range for one employee and whether it COSTS a day of leave. A rest day of the roster costs nothing
   (setting LeaveCountsRestDays = 0); a public holiday of the branch the employee belonged to that day never does. QA3:
   - a day with NO roster row is priced from the employee's weekly pattern (attendance.EMPLOYEE_SHIFT_PATTERN, ISO
     weekday) when there is one -- a rest day there is free -- and is a working day otherwise, as before;
   - a day before HireDate or after TerminationDate is not a working day for anyone: it costs nothing (IsEmployed = 0).
   A fixed-entitlement type (maternity) is a span of the calendar: its callers count the IsEmployed days, not Counts. */
CREATE OR ALTER FUNCTION hr.fn_LeaveDays (@EmployeeId INT, @FromDate DATE, @ToDate DATE)
RETURNS @d TABLE (WorkDate DATE PRIMARY KEY, IsRestDay BIT, IsHoliday BIT, Counts BIT, IsEmployed BIT)
AS
BEGIN
    IF @FromDate IS NULL OR @ToDate IS NULL OR @ToDate < @FromDate OR DATEDIFF(DAY, @FromDate, @ToDate) > 1500 RETURN;
    DECLARE @CountRest BIT = CASE WHEN (SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'LeaveCountsRestDays') = '1' THEN 1 ELSE 0 END;
    DECLARE @Hire DATE, @Term DATE;
    SELECT @Hire = HireDate, @Term = TerminationDate FROM hr.EMPLOYEE WHERE EmployeeId = @EmployeeId;
    DECLARE @HasPattern BIT = CASE WHEN EXISTS (SELECT 1 FROM attendance.EMPLOYEE_SHIFT_PATTERN
                                                 WHERE EmployeeId = @EmployeeId AND IsActive = 1) THEN 1 ELSE 0 END;
    DECLARE @day DATE = @FromDate, @rest BIT, @hol BIT, @emp BIT;
    WHILE @day <= @ToDate
    BEGIN
        SET @rest = NULL;
        SELECT TOP 1 @rest = sa.IsRestDay FROM attendance.SHIFT_ASSIGNMENT sa WHERE sa.EmployeeId = @EmployeeId AND sa.WorkDate = @day;
        IF @rest IS NULL AND @HasPattern = 1
            SELECT TOP 1 @rest = p.IsRestDay FROM attendance.EMPLOYEE_SHIFT_PATTERN p
            WHERE p.EmployeeId = @EmployeeId AND p.IsActive = 1
              AND p.DayOfWeek = DATEDIFF(DAY, '19000101', @day) % 7 + 1;          -- 1 = Monday .. 7 = Sunday, whatever DATEFIRST is
        SET @rest = ISNULL(@rest, 0);
        SET @hol = core.fn_IsHoliday(@day, hr.fn_EmployeeBranchOn(@EmployeeId, @day));
        SET @emp = CASE WHEN (@Hire IS NULL OR @day >= @Hire) AND (@Term IS NULL OR @day <= @Term) THEN 1 ELSE 0 END;
        INSERT INTO @d VALUES (@day, @rest, @hol,
                               CASE WHEN @emp = 0 OR @hol = 1 THEN 0 WHEN @rest = 1 AND @CountRest = 0 THEN 0 ELSE 1 END,
                               @emp);
        SET @day = DATEADD(DAY, 1, @day);
    END
    RETURN;
END;
GO

/* An APPROVED leave, day by day: every calendar day of From..End with what it costs (Part; 0 = free that day). End is
   ApprovedToDate once posted; with @Fresh = 1 (the posting itself) it is derived again: ToDate, or, for a partial approval
   (DaysApproved below DaysRequested), the day the DaysApproved-th costing day falls -- a partial approval keeps the FIRST
   days; when the range no longer has that many, the whole range. A fractional approval (2.5 of 5) costs its fraction on
   that last day. A half-day request costs 0.5 on its day. The days are FIXED at approval; what each one costs follows the
   roster, the holidays, the pattern and the employment as they stand (hr.fn_LeaveDays) -- which is what re-pricing means. */
CREATE OR ALTER FUNCTION hr.fn_LeaveRequestDays (@LeaveRequestId INT, @Fresh BIT = 0)
RETURNS @a TABLE (WorkDate DATE PRIMARY KEY, Part NUMERIC(20,1) NOT NULL)
AS
BEGIN
    DECLARE @Emp INT, @From DATE, @To DATE, @End DATE, @Requested NUMERIC(20,1), @Approved NUMERIC(20,1),
            @Half CHAR(2), @Calendar BIT;
    SELECT @Emp = lr.EmployeeId, @From = lr.FromDate, @To = lr.ToDate, @End = lr.ApprovedToDate,
           @Requested = lr.DaysRequested, @Approved = lr.DaysApproved, @Half = lr.HalfDay,
           @Calendar = CASE WHEN lt.FixedEntitlementDays IS NOT NULL THEN 1 ELSE 0 END
    FROM workflow.LEAVE_REQUEST lr
    JOIN hr.LEAVE_TYPE lt ON lt.LeaveTypeId = lr.LeaveTypeId
    WHERE lr.LeaveRequestId = @LeaveRequestId;
    IF @Emp IS NULL RETURN;

    DECLARE @d TABLE (WorkDate DATE PRIMARY KEY, Costs BIT NOT NULL);
    INSERT INTO @d (WorkDate, Costs)
    SELECT f.WorkDate, CASE WHEN @Calendar = 1 THEN f.IsEmployed ELSE f.Counts END
    FROM hr.fn_LeaveDays(@Emp, @From, @To) f;

    IF @Half IS NOT NULL
    BEGIN
        INSERT INTO @a (WorkDate, Part) SELECT WorkDate, CASE WHEN Costs = 1 THEN 0.5 ELSE 0 END FROM @d WHERE WorkDate = @From;
        RETURN;
    END

    DECLARE @Partial BIT = CASE WHEN @Approved IS NOT NULL AND @Approved < @Requested THEN 1 ELSE 0 END;
    IF @Fresh = 1 OR @End IS NULL OR @End < @From OR @End > @To
    BEGIN
        SET @End = @To;
        IF @Partial = 1
            SELECT @End = x.WorkDate
            FROM (SELECT WorkDate, ROW_NUMBER() OVER (ORDER BY WorkDate) AS n FROM @d WHERE Costs = 1) x
            WHERE x.n = CAST(CEILING(@Approved) AS INT);                    -- fewer costing days than that: stays ToDate
    END
    DECLARE @Last NUMERIC(20,1) = CASE WHEN @Partial = 1 AND @Approved <> FLOOR(@Approved) THEN @Approved - FLOOR(@Approved) ELSE 1 END;
    INSERT INTO @a (WorkDate, Part)
    SELECT WorkDate, CASE WHEN Costs = 0 THEN 0 WHEN WorkDate = @End THEN @Last ELSE 1 END
    FROM @d WHERE WorkDate <= @End;
    RETURN;
END;
GO

/* The first month of a range already paid for the employee (a locked Primary run holds their payslip), else NULL. */
CREATE OR ALTER FUNCTION hr.fn_LeaveFirstPaidMonth (@EmployeeId INT, @FromDate DATE, @ToDate DATE)
RETURNS CHAR(7)
AS
BEGIN
    IF @EmployeeId IS NULL OR @FromDate IS NULL OR @ToDate IS NULL OR @ToDate < @FromDate RETURN NULL;
    DECLARE @m DATE = DATEFROMPARTS(YEAR(@FromDate), MONTH(@FromDate), 1);
    WHILE @m <= @ToDate
    BEGIN
        IF payroll.fn_IsPeriodPaid(@EmployeeId, @m) = 1 RETURN CONVERT(CHAR(7), @m, 23);
        SET @m = DATEADD(MONTH, 1, @m);
    END
    RETURN NULL;
END;
GO

/* The leave form's preview: what a range would cost, the SAME figure usp_LeaveRequest_Create stores (calendar days for a
   fixed-entitlement type, else working days; a one-day half day costs 0.5 when that day costs anything -- it showed 1
   for a fixed-entitlement half day). QA3: PendingDays (promised to requests still waiting) and BalanceEnforced (create
   refuses beyond Balance - PendingDays for this type) so the form warns exactly when the server will refuse. */
CREATE OR ALTER PROCEDURE hr.usp_Leave_CountWorkingDays
    @EmployeeId INT, @LeaveTypeId INT = NULL, @FromDate DATE, @ToDate DATE, @HalfDay CHAR(2) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @ToDate < @FromDate BEGIN RAISERROR('The end date is before the start date.', 16, 1); RETURN 1; END
    SET @HalfDay = NULLIF(UPPER(LTRIM(RTRIM(@HalfDay))), '');
    DECLARE @Calendar BIT = CASE WHEN EXISTS (SELECT 1 FROM hr.LEAVE_TYPE WHERE LeaveTypeId = @LeaveTypeId AND FixedEntitlementDays IS NOT NULL) THEN 1 ELSE 0 END;
    DECLARE @Days NUMERIC(20,1) = CASE WHEN @Calendar = 1 THEN DATEDIFF(DAY, @FromDate, @ToDate) + 1
                                       ELSE hr.fn_LeaveWorkingDays(@EmployeeId, @FromDate, @ToDate) END;
    IF @HalfDay IS NOT NULL AND @FromDate = @ToDate AND @Days > 0 SET @Days = 0.5;
    DECLARE @Pending NUMERIC(20,1) = ISNULL((SELECT SUM(ISNULL(lr.DaysApproved, lr.DaysRequested))
                                             FROM workflow.LEAVE_REQUEST lr
                                             JOIN workflow.REQUEST_INSTANCE r ON r.RequestInstanceId = lr.RequestInstanceId
                                             WHERE lr.EmployeeId = @EmployeeId AND lr.LeaveTypeId = @LeaveTypeId
                                               AND r.[Status] IN ('Pending', 'OnHold')), 0);
    DECLARE @Enforced BIT = CASE WHEN ISNULL((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'LeaveAllowNegativeBalance'), '0') <> '1'
                                  AND EXISTS (SELECT 1 FROM hr.LEAVE_TYPE lt WHERE lt.LeaveTypeId = @LeaveTypeId AND lt.IsPaid = 1 AND ISNULL(lt.IsDiscretionary, 0) = 0)
                                  AND EXISTS (SELECT 1 FROM hr.LEAVE_ACCRUAL_TIER a WHERE a.LeaveTypeId = @LeaveTypeId)
                                 THEN 1 ELSE 0 END;
    SELECT CalendarDays = DATEDIFF(DAY, @FromDate, @ToDate) + 1,
           WorkingDays  = @Days,
           RestDays     = ISNULL(SUM(CASE WHEN IsRestDay = 1 AND IsHoliday = 0 THEN 1 ELSE 0 END), 0),
           Holidays     = ISNULL(SUM(CAST(IsHoliday AS INT)), 0),
           CountsCalendarDays = @Calendar,
           Balance      = (SELECT ISNULL(SUM(Days), 0) FROM hr.LEAVE_LEDGER WHERE EmployeeId = @EmployeeId AND LeaveTypeId = @LeaveTypeId),
           PendingDays  = @Pending,
           BalanceEnforced = @Enforced
    FROM hr.fn_LeaveDays(@EmployeeId, @FromDate, @ToDate);
END;
GO

/* ------------------------- 4. the one poster (LEV-2, LEV-11) ------------------------- */
/* Posts an approved leave to the ledger once (AppliedToLedgerAt): Usage per month from hr.fn_LeaveRequestDays (the
   discretionary give-back mirrors it), stamps ApprovedToDate (the last day of the approved span) and PaidSnapshot (the
   type's IsPaid now), then re-derives the attendance days. QA3: refuses (RETURN 1, nothing written) when a day of the
   approved span is in a period already paid for the employee. The claim on AppliedToLedgerAt is the first write, so two
   posters racing post once. No result set. */
CREATE OR ALTER PROCEDURE hr.usp_LeaveLedger_PostRequest
    @RequestInstanceId INT, @ActorUserId INT = NULL, @UsageNote NVARCHAR(300) = N'Approved leave request.'
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @LrId INT, @Emp INT, @Type INT, @To DATE, @Disc BIT, @IsPaid BIT;
    SELECT @LrId = lr.LeaveRequestId, @Emp = lr.EmployeeId, @Type = lr.LeaveTypeId, @To = lr.ToDate,
           @Disc = ISNULL(lr.IsDiscretionary, 0), @IsPaid = lt.IsPaid
    FROM workflow.LEAVE_REQUEST lr JOIN hr.LEAVE_TYPE lt ON lt.LeaveTypeId = lr.LeaveTypeId
    WHERE lr.RequestInstanceId = @RequestInstanceId AND lr.AppliedToLedgerAt IS NULL;
    IF @LrId IS NULL RETURN 0;                              -- not a leave, or already posted

    DECLARE @alloc TABLE (WorkDate DATE PRIMARY KEY, Part NUMERIC(20,1) NOT NULL);
    INSERT INTO @alloc (WorkDate, Part) SELECT WorkDate, Part FROM hr.fn_LeaveRequestDays(@LrId, 1);
    DECLARE @End DATE = ISNULL((SELECT MAX(WorkDate) FROM @alloc), @To);

    IF hr.fn_LeaveFirstPaidMonth(@Emp, (SELECT MIN(WorkDate) FROM @alloc), @End) IS NOT NULL
    BEGIN
        DECLARE @Paid NVARCHAR(200) = CONCAT(N'This period is paid ', NCHAR(8212), N' raise a payroll adjustment instead.');
        RAISERROR(@Paid, 16, 1);
        RETURN 1;
    END

    BEGIN TRAN;
    UPDATE workflow.LEAVE_REQUEST
    SET AppliedToLedgerAt = SYSUTCDATETIME(), ApprovedToDate = @End, PaidSnapshot = @IsPaid
    WHERE LeaveRequestId = @LrId AND AppliedToLedgerAt IS NULL;
    IF @@ROWCOUNT = 0 BEGIN COMMIT; RETURN 0; END            -- posted by somebody else meanwhile: nothing written here

    INSERT INTO hr.LEAVE_LEDGER (EmployeeId, LeaveTypeId, PeriodYearMonth, MovementType, LeaveRequestId, Days, EffectiveDate, Note, CreatedBy)
    SELECT @Emp, @Type, CONVERT(CHAR(7), MIN(WorkDate), 23), 'Usage', @LrId, -SUM(Part), MIN(WorkDate), @UsageNote, @ActorUserId
    FROM @alloc WHERE Part > 0
    GROUP BY CONVERT(CHAR(7), WorkDate, 23);
    IF @Disc = 1
        INSERT INTO hr.LEAVE_LEDGER (EmployeeId, LeaveTypeId, PeriodYearMonth, MovementType, LeaveRequestId, Days, EffectiveDate, Note, CreatedBy)
        SELECT @Emp, @Type, CONVERT(CHAR(7), MIN(WorkDate), 23), 'Adjustment', @LrId, SUM(Part), MIN(WorkDate),
               CONCAT(N'Discretionary grant ', NCHAR(8212), N' days returned to the balance by the approver.'), @ActorUserId
        FROM @alloc WHERE Part > 0
        GROUP BY CONVERT(CHAR(7), WorkDate, 23);
    COMMIT;

    /* the days already processed become Leave now, not at the next nightly run */
    EXEC attendance.usp_Attendance_RecomputeLeaveRange @RequestInstanceId = @RequestInstanceId;
    RETURN 0;
END;
GO

/* ------------------------- 5. re-pricing an approved leave (LEV-4 / REL-12 / ROS-12, contract) ------------------------- */
/* A leave costs the working days of the roster as it finally stands. Called after a roster approval and a branch transfer
   (unit C) and after a holiday is added, moved or removed (unit B). For every POSTED Approved leave of the employee
   overlapping @FromDate..@ToDate it recomputes the Usage of each month (hr.fn_LeaveRequestDays: the approved days stay,
   what each costs follows the roster, the branch-of-day holidays, the weekly pattern and the employment) and re-posts the
   months whose rows differ -- the discretionary give-back with them. A month already paid for the employee is never
   touched (the leave stays as it was paid; a correction there is a payroll adjustment). Idempotent: a second call finds
   every month right and writes nothing. No result set, no ROLLBACK: safe inside a caller's transaction or INSERT..EXEC. */
CREATE OR ALTER PROCEDURE hr.usp_LeaveLedger_Reprice
    @EmployeeId INT, @FromDate DATE, @ToDate DATE
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    IF @EmployeeId IS NULL OR @FromDate IS NULL OR @ToDate IS NULL OR @ToDate < @FromDate RETURN 0;

    DECLARE @r TABLE (LeaveRequestId INT PRIMARY KEY, LeaveTypeId INT NOT NULL, Disc BIT NOT NULL);
    INSERT INTO @r (LeaveRequestId, LeaveTypeId, Disc)
    SELECT lr.LeaveRequestId, lr.LeaveTypeId, ISNULL(lr.IsDiscretionary, 0)
    FROM workflow.LEAVE_REQUEST lr
    JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = lr.RequestInstanceId
    WHERE lr.EmployeeId = @EmployeeId AND ri.[Status] = 'Approved' AND lr.AppliedToLedgerAt IS NOT NULL
      AND lr.FromDate <= @ToDate AND ISNULL(lr.ApprovedToDate, lr.ToDate) >= @FromDate;
    IF NOT EXISTS (SELECT 1 FROM @r) RETURN 0;

    /* what each month of each leave costs now */
    DECLARE @want TABLE (LeaveRequestId INT NOT NULL, Ym CHAR(7) NOT NULL, Days NUMERIC(20,1) NOT NULL, EffDate DATE NOT NULL,
                         PRIMARY KEY (LeaveRequestId, Ym));
    INSERT INTO @want (LeaveRequestId, Ym, Days, EffDate)
    SELECT r.LeaveRequestId, CONVERT(CHAR(7), a.WorkDate, 23), SUM(a.Part), MIN(a.WorkDate)
    FROM @r r CROSS APPLY hr.fn_LeaveRequestDays(r.LeaveRequestId, 0) a
    WHERE a.Part > 0
    GROUP BY r.LeaveRequestId, CONVERT(CHAR(7), a.WorkDate, 23);

    /* the months to look at: the ones it costs now and the ones holding its rows, less the paid ones */
    DECLARE @m TABLE (LeaveRequestId INT NOT NULL, Ym CHAR(7) NOT NULL, PRIMARY KEY (LeaveRequestId, Ym));
    INSERT INTO @m (LeaveRequestId, Ym)
    SELECT LeaveRequestId, Ym FROM @want
    UNION
    SELECT l.LeaveRequestId, l.PeriodYearMonth
    FROM hr.LEAVE_LEDGER l JOIN @r r ON r.LeaveRequestId = l.LeaveRequestId
    WHERE l.MovementType IN ('Usage', 'Adjustment');
    DELETE m FROM @m m WHERE payroll.fn_IsPeriodPaid(@EmployeeId, CAST(m.Ym + '-01' AS DATE)) = 1;

    /* already right: one Usage row of the wanted days and date and, for a discretionary leave, one mirror, nothing else */
    DELETE m
    FROM @m m
    JOIN @r r ON r.LeaveRequestId = m.LeaveRequestId
    LEFT JOIN @want w ON w.LeaveRequestId = m.LeaveRequestId AND w.Ym = m.Ym
    CROSS APPLY (SELECT COUNT(*) AS UsageRows, -SUM(l.Days) AS UsageDays, MIN(l.EffectiveDate) AS UsageDate
                 FROM hr.LEAVE_LEDGER l
                 WHERE l.LeaveRequestId = m.LeaveRequestId AND l.PeriodYearMonth = m.Ym AND l.MovementType = 'Usage') cu
    CROSS APPLY (SELECT COUNT(*) AS AdjRows, SUM(l.Days) AS AdjDays
                 FROM hr.LEAVE_LEDGER l
                 WHERE l.LeaveRequestId = m.LeaveRequestId AND l.PeriodYearMonth = m.Ym AND l.MovementType = 'Adjustment') ca
    WHERE (w.LeaveRequestId IS NULL AND cu.UsageRows = 0 AND ca.AdjRows = 0)
       OR (w.LeaveRequestId IS NOT NULL AND cu.UsageRows = 1 AND cu.UsageDays = w.Days AND cu.UsageDate = w.EffDate
           AND ((r.Disc = 0 AND ca.AdjRows = 0) OR (r.Disc = 1 AND ca.AdjRows = 1 AND ca.AdjDays = w.Days)));
    IF NOT EXISTS (SELECT 1 FROM @m) RETURN 0;

    DECLARE @Note NVARCHAR(200) = CONCAT(N'Approved leave request (re-priced ', CONVERT(CHAR(10), CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE), 23),
                                         N': the roster, the holidays or the branch changed).');
    BEGIN TRAN;
    DELETE l
    FROM hr.LEAVE_LEDGER l
    JOIN @m m ON m.LeaveRequestId = l.LeaveRequestId AND m.Ym = l.PeriodYearMonth
    WHERE l.MovementType IN ('Usage', 'Adjustment');
    INSERT INTO hr.LEAVE_LEDGER (EmployeeId, LeaveTypeId, PeriodYearMonth, MovementType, LeaveRequestId, Days, EffectiveDate, Note, CreatedBy)
    SELECT @EmployeeId, r.LeaveTypeId, w.Ym, 'Usage', w.LeaveRequestId, -w.Days, w.EffDate, @Note, NULL
    FROM @m m JOIN @want w ON w.LeaveRequestId = m.LeaveRequestId AND w.Ym = m.Ym JOIN @r r ON r.LeaveRequestId = m.LeaveRequestId;
    INSERT INTO hr.LEAVE_LEDGER (EmployeeId, LeaveTypeId, PeriodYearMonth, MovementType, LeaveRequestId, Days, EffectiveDate, Note, CreatedBy)
    SELECT @EmployeeId, r.LeaveTypeId, w.Ym, 'Adjustment', w.LeaveRequestId, w.Days, w.EffDate,
           CONCAT(N'Discretionary grant ', NCHAR(8212), N' days returned to the balance by the approver.'), NULL
    FROM @m m JOIN @want w ON w.LeaveRequestId = m.LeaveRequestId AND w.Ym = m.Ym JOIN @r r ON r.LeaveRequestId = m.LeaveRequestId
    WHERE r.Disc = 1;
    COMMIT;
    RETURN 0;
END;
GO

/* ------------------------- 6. manual movements (LEV-9, LEV-11, ATT-15) ------------------------- */
/* Posts ONE movement. The movement type decides the sign (callers pass a positive magnitude; only an Adjustment keeps the
   caller's sign). QA3: @Quiet = 1 returns no result set (callers inside a loop or an INSERT..EXEC chain, ATT-15); a
   MANUAL Usage (no SourceType) dated in a period already paid for the employee is refused -- it would move what a locked
   payslip paid. */
CREATE OR ALTER PROCEDURE hr.usp_LeaveLedger_PostMovement
    @EmployeeId INT, @LeaveTypeId INT, @MovementType VARCHAR(20),
    @Days DECIMAL(6,2), @EffectiveDate DATE, @LeaveRequestId INT = NULL,
    @Note NVARCHAR(200) = NULL, @CreatedBy INT = NULL,
    @SourceType VARCHAR(30) = NULL, @SourceRef INT = NULL,
    @Quiet BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @MovementType NOT IN ('Accrual','Usage','CarryOver','Adjustment')
    BEGIN
        RAISERROR('MovementType must be Accrual, Usage, CarryOver or Adjustment.', 16, 1);
        RETURN 1;
    END
    IF @MovementType = 'Usage' AND @SourceType IS NULL AND payroll.fn_IsPeriodPaid(@EmployeeId, @EffectiveDate) = 1
    BEGIN
        DECLARE @Paid NVARCHAR(200) = CONCAT(N'This period is paid ', NCHAR(8212), N' raise a payroll adjustment instead.');
        RAISERROR(@Paid, 16, 1);
        RETURN 1;
    END

    DECLARE @Period CHAR(7) = FORMAT(@EffectiveDate, 'yyyy-MM');
    DECLARE @Signed DECIMAL(6,2) =
        CASE @MovementType
            WHEN 'Accrual'   THEN  ABS(@Days)
            WHEN 'CarryOver' THEN  ABS(@Days)
            WHEN 'Usage'     THEN -ABS(@Days)
            ELSE @Days                       -- Adjustment keeps the caller's sign
        END;

    INSERT INTO hr.LEAVE_LEDGER (EmployeeId, LeaveTypeId, PeriodYearMonth, MovementType,
                                 LeaveRequestId, Days, EffectiveDate, Note, CreatedBy,
                                 SourceType, SourceRef)
    VALUES (@EmployeeId, @LeaveTypeId, @Period, @MovementType,
            @LeaveRequestId, @Signed, @EffectiveDate, @Note, @CreatedBy,
            @SourceType, @SourceRef);
    DECLARE @Id INT = CAST(SCOPE_IDENTITY() AS INT);

    IF ISNULL(@Quiet, 0) = 0
        SELECT @Id AS LeaveLedgerId;
    RETURN 0;
END;
GO

/* Only a MANUAL adjustment (an HR correction: no leave request, no source) may be deleted. Every other row belongs to
   something that keeps it right -- an approved leave (retract or reopen it), the year opening (undo it), an exit
   permission's conversion, the carry-over expiry -- and is refused with a sentence that says so. */
CREATE OR ALTER PROCEDURE hr.usp_LeaveLedger_Delete @LeaveLedgerId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Type VARCHAR(20), @Lr INT, @Src VARCHAR(30), @Msg NVARCHAR(400);
    SELECT @Type = MovementType, @Lr = LeaveRequestId, @Src = SourceType
    FROM hr.LEAVE_LEDGER WHERE LeaveLedgerId = @LeaveLedgerId;
    IF @Type IS NULL BEGIN RAISERROR('That leave movement does not exist.', 16, 1); RETURN 1; END

    IF NOT (@Type = 'Adjustment' AND @Lr IS NULL AND @Src IS NULL)
    BEGIN
        SET @Msg = CASE
            WHEN @Lr IS NOT NULL
                THEN CONCAT(N'This movement belongs to an approved leave request; it changes only with that request ', NCHAR(8212), N' retract or reopen it instead.')
            WHEN @Src = 'LeaveYear'
                THEN CONCAT(N'This movement was written when the leave year was opened ', NCHAR(8212), N' undo the year opening instead.')
            WHEN @Src = 'ExitPermission'
                THEN CONCAT(N'This movement converts exit-permission time to leave and cannot be deleted ', NCHAR(8212), N' post a correcting adjustment instead.')
            WHEN @Type = 'Expiry'
                THEN CONCAT(N'This movement is the carry-over expiry, kept right by the nightly job, and cannot be deleted ', NCHAR(8212), N' post a correcting adjustment instead.')
            ELSE CONCAT(N'Only a manual adjustment can be deleted ', NCHAR(8212), N' post a correcting adjustment instead.') END;
        RAISERROR(@Msg, 16, 1);
        RETURN 1;
    END

    DELETE FROM hr.LEAVE_LEDGER WHERE LeaveLedgerId = @LeaveLedgerId;
    RETURN 0;
END;
GO

/* All ledger movements for an employee (optionally one period). QA3: SourceType, and CanDelete = the rule of
   hr.usp_LeaveLedger_Delete, so the screen offers the delete only where it can work. */
CREATE OR ALTER PROCEDURE hr.usp_LeaveLedger_GetByEmployee
    @EmployeeId INT, @PeriodYearMonth CHAR(7) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT LeaveLedgerId, EmployeeId, LeaveTypeId, PeriodYearMonth, MovementType,
           LeaveRequestId, Days, EffectiveDate, Note, CreatedAt, SourceType,
           CAST(CASE WHEN MovementType = 'Adjustment' AND LeaveRequestId IS NULL AND SourceType IS NULL THEN 1 ELSE 0 END AS BIT) AS CanDelete
    FROM hr.LEAVE_LEDGER
    WHERE EmployeeId = @EmployeeId
      AND (@PeriodYearMonth IS NULL OR PeriodYearMonth = @PeriodYearMonth)
    ORDER BY EffectiveDate, LeaveLedgerId;
END;
GO

/* Derived balance per month (optionally one period), from the view. QA3 LEV-14: with Adjusted, so the row adds up:
   Remaining = Accrued + CarriedOver - Used + Adjusted. */
CREATE OR ALTER PROCEDURE hr.usp_LeaveBalance_Get
    @EmployeeId INT, @PeriodYearMonth CHAR(7) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT EmployeeId, LeaveTypeId, PeriodYearMonth, Accrued, CarriedOver, Used, Adjusted, Remaining
    FROM hr.vw_LEAVE_BALANCE
    WHERE EmployeeId = @EmployeeId
      AND (@PeriodYearMonth IS NULL OR PeriodYearMonth = @PeriodYearMonth)
    ORDER BY PeriodYearMonth, LeaveTypeId;
END;
GO

/* ------------------------- 7. raising a leave ------------------------- */
/* Script 84's create with, QA3: an inactive type is refused (LEV-13); dates after the employee's TerminationDate are
   refused (REL-4); a date in a period already paid for the employee is refused (LEV-11); the service gate counts WHOLE
   months (LEV-12); an Approved leave blocks only its approved days (ApprovedToDate, LEV-2); the INSERT..EXEC of
   usp_Request_Submit is checked (convention 4) and the insert is undone when it returned nothing. */
CREATE OR ALTER PROCEDURE workflow.usp_LeaveRequest_Create
    @EmployeeId INT, @RaisedByUserId INT, @LeaveTypeId INT,
    @FromDate DATE, @ToDate DATE, @Reason NVARCHAR(500)=NULL,
    @Title NVARCHAR(150)=NULL, @RelationToEmployee NVARCHAR(30)=NULL,
    @HalfDay CHAR(2)=NULL              -- script 84 (D3): 'AM' | 'PM' for a ONE-day request = half a day
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @Msg NVARCHAR(400);

    IF @ToDate < @FromDate
    BEGIN RAISERROR('The end date is before the start date.',16,1); RETURN 1; END
    SET @HalfDay = NULLIF(UPPER(LTRIM(RTRIM(@HalfDay))), '');
    IF @HalfDay IS NOT NULL AND @HalfDay NOT IN ('AM','PM')
    BEGIN RAISERROR('A half day is AM or PM.',16,1); RETURN 1; END
    IF @HalfDay IS NOT NULL AND @FromDate <> @ToDate
    BEGIN RAISERROR('A half day is for a one-day request: the start and end dates must be the same.',16,1); RETURN 1; END

    DECLARE @LtName NVARCHAR(60), @MinSvc INT, @Notice INT, @FixedDays NUMERIC(20,1), @LtActive BIT,
            @NeedsRelation BIT = 0;
    SELECT @LtName=Name, @MinSvc=ISNULL(MinServiceMonthsToUse,0), @Notice=ISNULL(NoticePreferredDays,0),
           @FixedDays=FixedEntitlementDays, @LtActive=IsActive
    FROM hr.LEAVE_TYPE WHERE LeaveTypeId=@LeaveTypeId;
    IF @LtName IS NULL BEGIN RAISERROR('That leave type does not exist.',16,1); RETURN 1; END
    /* QA3 LEV-13: a deactivated type is history -- it stays on the requests already made, it is not offered for new ones */
    IF @LtActive = 0
    BEGIN
        SET @Msg = CONCAT(@LtName, N' leave is no longer offered (the type was deactivated); choose another leave type.');
        RAISERROR(N'%s', 16, 1, @Msg); RETURN 1;
    END

    DECLARE @EmpName NVARCHAR(200), @Hire DATE, @Term DATE;
    SELECT @EmpName = FullName, @Hire = HireDate, @Term = TerminationDate FROM hr.EMPLOYEE WHERE EmployeeId=@EmployeeId;
    IF @EmpName IS NULL BEGIN RAISERROR('That employee does not exist.',16,1); RETURN 1; END
    /* QA3 REL-4: employment ends on TerminationDate; there is no leave to take after it */
    IF @Term IS NOT NULL AND @ToDate > @Term
    BEGIN
        SET @Msg = CONCAT(@EmpName, N' leaves on ', CONVERT(CHAR(10), @Term, 23), N'; leave after that day cannot be taken.');
        RAISERROR(N'%s', 16, 1, @Msg); RETURN 1;
    END
    /* QA3 LEV-11: a paid period is settled; a leave inside it would re-price a locked payslip */
    IF hr.fn_LeaveFirstPaidMonth(@EmployeeId, @FromDate, @ToDate) IS NOT NULL
    BEGIN
        SET @Msg = CONCAT(N'This period is paid ', NCHAR(8212), N' raise a payroll adjustment instead.');
        RAISERROR(@Msg, 16, 1); RETURN 1;
    END

    SET @NeedsRelation = CASE WHEN EXISTS (SELECT 1 FROM hr.LEAVE_RELATION_ENTITLEMENT
                                           WHERE LeaveTypeId=@LeaveTypeId) THEN 1 ELSE 0 END;

    /* QA3 LEV-12: WHOLE months of service at the start date (15 Jan -> 14 Feb is 0, -> 15 Feb is 1), not month boundaries */
    DECLARE @SvcMonths INT = DATEDIFF(MONTH, @Hire, @FromDate) - CASE WHEN DAY(@Hire) > DAY(@FromDate) THEN 1 ELSE 0 END;

    /* service gate: the balance is granted from day one; USE is gated. %d is fine here - both substitutions are ints. */
    IF @SvcMonths < @MinSvc
    BEGIN
        RAISERROR('%s leave can be used after %d months of service; this employee will have %d at the start date. The balance keeps accruing meanwhile.',
                  16,1,@LtName,@MinSvc,@SvcMonths);
        RETURN 1;
    END

    /* script 84 (D2): what a leave COSTS is the employee's working days in the range; a fixed-entitlement type counts
       calendar days; a half day costs 0.5 */
    DECLARE @CalendarType BIT = CASE WHEN @FixedDays IS NOT NULL THEN 1 ELSE 0 END;
    DECLARE @Days NUMERIC(20,1) = CASE WHEN @CalendarType = 1 THEN DATEDIFF(DAY,@FromDate,@ToDate)+1
                                       ELSE hr.fn_LeaveWorkingDays(@EmployeeId,@FromDate,@ToDate) END;
    IF @Days <= 0
    BEGIN RAISERROR('These dates contain no working day for this employee (rest days and public holidays only) - there is nothing to take as leave.',16,1); RETURN 1; END
    IF @HalfDay IS NOT NULL SET @Days = 0.5;

    DECLARE @DaysText VARCHAR(20) =
        CASE WHEN @Days = FLOOR(@Days) THEN CONVERT(VARCHAR(20), CAST(@Days AS INT))
             ELSE CONVERT(VARCHAR(20), @Days) END;

    /* relation-capped types (bereavement) */
    IF @NeedsRelation = 1
    BEGIN
        IF @RelationToEmployee IS NULL
        BEGIN RAISERROR('State the relation (Parent, Sibling, Child, Spouse, Grandparent, Aunt, Uncle).',16,1); RETURN 1; END
        DECLARE @Cap NUMERIC(20,1) = (SELECT Days FROM hr.LEAVE_RELATION_ENTITLEMENT
                                     WHERE LeaveTypeId=@LeaveTypeId AND Relation=@RelationToEmployee);
        IF @Cap IS NULL
        BEGIN RAISERROR('Bereavement leave does not cover that relation.',16,1); RETURN 1; END
        IF @Days > @Cap
        BEGIN
            DECLARE @CapText VARCHAR(20) =
                CASE WHEN @Cap = FLOOR(@Cap) THEN CONVERT(VARCHAR(20), CAST(@Cap AS INT))
                     ELSE CONVERT(VARCHAR(20), @Cap) END;
            RAISERROR('%s allows %s day(s) for a %s; %s were requested.',
                      16,1,@LtName,@CapText,@RelationToEmployee,@DaysText);
            RETURN 1;
        END
    END

    /* fixed-entitlement types (maternity): cap at the entitlement */
    IF @FixedDays IS NOT NULL AND @Days > @FixedDays
    BEGIN
        DECLARE @FixedText VARCHAR(20) =
            CASE WHEN @FixedDays = FLOOR(@FixedDays) THEN CONVERT(VARCHAR(20), CAST(@FixedDays AS INT))
                 ELSE CONVERT(VARCHAR(20), @FixedDays) END;
        RAISERROR('%s leave is %s days; %s were requested.',16,1,@LtName,@FixedText,@DaysText);
        RETURN 1;
    END

    /* script 84: THE BALANCE. A paid, accruing, non-discretionary type cannot be requested beyond what is left (less what
       requests still waiting have been promised) unless the setting allows a negative balance. */
    DECLARE @AllowNegative BIT = CASE WHEN (SELECT SettingValue FROM core.SETTING WHERE SettingKey='LeaveAllowNegativeBalance') = '1' THEN 1 ELSE 0 END;
    IF @AllowNegative = 0
       AND EXISTS (SELECT 1 FROM hr.LEAVE_TYPE lt WHERE lt.LeaveTypeId=@LeaveTypeId AND lt.IsPaid=1 AND ISNULL(lt.IsDiscretionary,0)=0)
       AND EXISTS (SELECT 1 FROM hr.LEAVE_ACCRUAL_TIER a WHERE a.LeaveTypeId=@LeaveTypeId)
    BEGIN
        DECLARE @Balance NUMERIC(20,1) = ISNULL((SELECT SUM(Days) FROM hr.LEAVE_LEDGER WHERE EmployeeId=@EmployeeId AND LeaveTypeId=@LeaveTypeId),0);
        DECLARE @Pending NUMERIC(20,1) = ISNULL((SELECT SUM(ISNULL(lr.DaysApproved, lr.DaysRequested))
                                                 FROM workflow.LEAVE_REQUEST lr
                                                 JOIN workflow.REQUEST_INSTANCE r ON r.RequestInstanceId=lr.RequestInstanceId
                                                 WHERE lr.EmployeeId=@EmployeeId AND lr.LeaveTypeId=@LeaveTypeId AND r.[Status] IN ('Pending','OnHold')),0);
        IF @Days > @Balance - @Pending
        BEGIN
            DECLARE @LeftText VARCHAR(20) = CASE WHEN @Balance-@Pending = FLOOR(@Balance-@Pending) THEN CONVERT(VARCHAR(20), CAST(@Balance-@Pending AS INT)) ELSE CONVERT(VARCHAR(20), @Balance-@Pending) END;
            RAISERROR('The %s leave balance has %s day(s) left; %s were requested.',16,1,@LtName,@LeftText,@DaysText);
            RETURN 1;
        END
    END

    /* overlap guard. QA3 LEV-2: an Approved leave occupies its APPROVED days only -- the days a partial approval did not
       grant are free to ask for again. */
    DECLARE @Clash NVARCHAR(200);
    SELECT TOP 1 @Clash = CONCAT(N'from ',CONVERT(char(10),lr.FromDate,23),
                                 N' to ',CONVERT(char(10),x.LastDay,23),N' (',r.[Status],N')')
    FROM workflow.LEAVE_REQUEST lr
    JOIN workflow.REQUEST_INSTANCE r ON r.RequestInstanceId=lr.RequestInstanceId
    CROSS APPLY (SELECT CASE WHEN r.[Status] = 'Approved' THEN ISNULL(lr.ApprovedToDate, lr.ToDate) ELSE lr.ToDate END AS LastDay) x
    WHERE lr.EmployeeId=@EmployeeId AND r.[Status] IN ('Pending','OnHold','Approved')
      AND lr.FromDate<=@ToDate AND x.LastDay>=@FromDate
    ORDER BY lr.FromDate;
    IF @Clash IS NOT NULL
    BEGIN RAISERROR('These dates overlap an existing leave request %s. Cancel or change it first.',16,1,@Clash); RETURN 1; END

    IF @Title IS NULL OR LTRIM(RTRIM(@Title))=''
        SET @Title = CASE WHEN @HalfDay IS NOT NULL
                          THEN CONCAT(@LtName,N' leave ',CONVERT(char(10),@FromDate,23),N' (half day, ',@HalfDay,N')')
                          ELSE CONCAT(@LtName,N' leave ',CONVERT(char(10),@FromDate,23),
                                      N' to ',CONVERT(char(10),@ToDate,23),N' (',@DaysText,
                                      CASE WHEN @CalendarType = 1 THEN N' days)' WHEN @Days = 1 THEN N' working day)' ELSE N' working days)' END) END;

    /* one transaction, or a savepoint inside the caller's */
    DECLARE @OuterTran INT = @@TRANCOUNT;
    IF @OuterTran = 0 BEGIN TRAN; ELSE SAVE TRANSACTION LeaveRequestCreate;

    DECLARE @Submitted TABLE (RequestInstanceId INT,[Status] VARCHAR(20),CurrentStepNo INT,
                              WorkflowDefinitionId INT,WorkflowVersion INT,MinRequesterTier INT);
    INSERT INTO @Submitted
    EXEC workflow.usp_Request_Submit @RequestTypeCode='LEAVE_REQUEST',
         @EmployeeId=@EmployeeId, @RaisedByUserId=@RaisedByUserId, @Title=@Title;

    DECLARE @ReqId INT = (SELECT TOP 1 RequestInstanceId FROM @Submitted);
    /* QA3 convention 4: the submit refused (its sentence is already on its way to the caller) -- nothing is kept */
    IF @ReqId IS NULL
    BEGIN
        IF @OuterTran = 0 ROLLBACK; ELSE ROLLBACK TRANSACTION LeaveRequestCreate;
        RETURN 1;
    END

    INSERT INTO workflow.LEAVE_REQUEST
        (RequestInstanceId,EmployeeId,LeaveTypeId,FromDate,ToDate,DaysRequested,Reason,RelationToEmployee,HalfDay)
    VALUES (@ReqId,@EmployeeId,@LeaveTypeId,@FromDate,@ToDate,@Days,@Reason,@RelationToEmployee,@HalfDay);

    /* FIX 06b (script 84): the payload exists only now, so a chain that auto-approved at submit gets its effect here.
       Idempotent and type-guarded. */
    IF EXISTS (SELECT 1 FROM @Submitted WHERE [Status] = 'Approved')
        EXEC workflow.usp_Request_ApplyApprovalEffects
             @RequestInstanceId = @ReqId, @ActorUserId = @RaisedByUserId;

    IF @OuterTran = 0 COMMIT TRAN;

    SELECT s.RequestInstanceId, s.[Status], s.CurrentStepNo, s.WorkflowVersion,
           @Days AS DaysRequested,
           CAST(CASE WHEN @Notice>0 AND DATEDIFF(DAY,CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE),@FromDate)<@Notice
                THEN 1 ELSE 0 END AS BIT) AS NoticeShorterThanPreferred,
           @Notice AS NoticePreferredDays
    FROM @Submitted s;
    RETURN 0;
END;
GO

/* ------------------------- 8. deciding a leave ------------------------- */
/* Script 84's typed approval with, QA3: refused for dates after TerminationDate (REL-4) and for a period already paid
   (LEV-11), checked BEFORE anything is signed; ONE transaction (the request row locked first) so no half decision is
   ever visible and a second decision waits; ValueBefore = '<standing days>|<discretionary 0/1>' on the decided step
   (LEV-7 / WF-4, restored by unit A on retract / reopen / withdraw); the poster's refusal is honoured. */
CREATE OR ALTER PROCEDURE [workflow].[usp_LeaveRequest_Decide]
    @RequestInstanceId INT, @ActedByUserId INT,
    @ApprovedDays NUMERIC(20,1)=NULL, @Comment NVARCHAR(1000)=NULL,
    @SignedWithPassword BIT=0,
    @MakeDiscretionary BIT=0
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @Msg NVARCHAR(400);

    IF @MakeDiscretionary = 1 AND LTRIM(RTRIM(ISNULL(@Comment, N''))) = N''
    BEGIN
        SET @Msg = CONCAT(N'A note is required when granting as discretionary ', NCHAR(8212), N' say why the days are not deducted.');
        RAISERROR(@Msg, 16, 1);
        RETURN 1;
    END

    DECLARE @EmpId INT,@LtId INT,@Requested NUMERIC(20,1),@From DATE,@To DATE,@NeedsCert BIT,
            @Standing NUMERIC(20,1),@EmpName NVARCHAR(200),@Term DATE;
    SELECT @EmpId=lr.EmployeeId,@LtId=lr.LeaveTypeId,@Requested=lr.DaysRequested,
           @From=lr.FromDate,@To=lr.ToDate,@NeedsCert=lt.RequiresCertificate,
           @Standing=ISNULL(lr.DaysApproved, lr.DaysRequested),
           @EmpName=e.FullName,@Term=e.TerminationDate
    FROM workflow.LEAVE_REQUEST lr
    JOIN hr.LEAVE_TYPE lt ON lt.LeaveTypeId=lr.LeaveTypeId
    JOIN hr.EMPLOYEE e ON e.EmployeeId=lr.EmployeeId
    WHERE lr.RequestInstanceId=@RequestInstanceId;
    IF @EmpId IS NULL BEGIN RAISERROR('This is not a leave request.',16,1); RETURN 1; END

    IF @NeedsCert=1 AND NOT EXISTS (SELECT 1 FROM workflow.REQUEST_ATTACHMENT
                                    WHERE RequestInstanceId=@RequestInstanceId)
    BEGIN RAISERROR('This leave type requires a certificate. Attach it to the request before approving.',16,1); RETURN 1; END

    /* QA3 REL-4 */
    IF @Term IS NOT NULL AND @To > @Term
    BEGIN
        SET @Msg = CONCAT(@EmpName, N' leaves on ', CONVERT(CHAR(10), @Term, 23), N'; leave after that day cannot be taken.');
        RAISERROR(N'%s', 16, 1, @Msg); RETURN 1;
    END
    /* QA3 LEV-11 / WF-16 */
    IF hr.fn_LeaveFirstPaidMonth(@EmpId, @From, @To) IS NOT NULL
    BEGIN
        SET @Msg = CONCAT(N'This period is paid ', NCHAR(8212), N' raise a payroll adjustment instead.');
        RAISERROR(@Msg, 16, 1); RETURN 1;
    END

    DECLARE @Granted NUMERIC(20,1)=ISNULL(@ApprovedDays,@Standing);
    IF @Granted<=0 OR @Granted>@Standing
    BEGIN
        DECLARE @StandingText VARCHAR(20) =
            CASE WHEN @Standing = FLOOR(@Standing) THEN CONVERT(VARCHAR(20), CAST(@Standing AS INT))
                 ELSE CONVERT(VARCHAR(20), @Standing) END;
        RAISERROR('Approved days must be more than 0 and no more than the %s currently approved.',
                  16,1,@StandingText);
        RETURN 1;
    END

    DECLARE @ChangeSummary NVARCHAR(300)=
        CASE WHEN @Granted<>@Standing
             THEN CONCAT(N'Days: ',CONVERT(VARCHAR(20),@Standing),N' -> ',CONVERT(VARCHAR(20),@Granted)) END;
    IF @MakeDiscretionary=1
        SET @ChangeSummary = CONCAT(ISNULL(@ChangeSummary + CONCAT(N' ', NCHAR(183), N' '), N''),
                                    N'Discretionary ', NCHAR(8212), N' days returned to balance');

    DECLARE @OuterTran INT = @@TRANCOUNT;
    IF @OuterTran = 0 BEGIN TRAN; ELSE SAVE TRANSACTION LeaveRequestDecide;

    /* the request row is held for the whole decision: a second decision on it waits, and reads what this one wrote */
    DECLARE @Step INT, @WasDisc BIT;
    SELECT @Step = CurrentStepNo FROM workflow.REQUEST_INSTANCE WITH (UPDLOCK, ROWLOCK)
    WHERE RequestInstanceId = @RequestInstanceId;
    SELECT @Standing = ISNULL(DaysApproved, DaysRequested), @WasDisc = ISNULL(IsDiscretionary, 0)
    FROM workflow.LEAVE_REQUEST WITH (UPDLOCK) WHERE RequestInstanceId = @RequestInstanceId;

    DECLARE @Result TABLE (RequestInstanceId INT,[Status] VARCHAR(20),CurrentStepNo INT,
                           ClosedReason NVARCHAR(300),Decision VARCHAR(25),
                           SignedAsDeputy BIT,SignedWithPassword BIT);
    INSERT INTO @Result
    EXEC workflow.usp_Request_Approve @RequestInstanceId=@RequestInstanceId,
         @ActedByUserId=@ActedByUserId,@Comment=@Comment,
         @ChangeSummary=@ChangeSummary,@SignedWithPassword=@SignedWithPassword;
    IF NOT EXISTS (SELECT 1 FROM @Result)
    BEGIN
        IF @OuterTran = 0 ROLLBACK; ELSE ROLLBACK TRANSACTION LeaveRequestDecide;
        RETURN 1;                                           -- the engine's refusal is the caller's message
    END

    /* QA3 LEV-7 / WF-4: what stood before THIS decision, on the step it decided (the format is the contract) */
    IF @Step IS NOT NULL
        UPDATE workflow.REQUEST_STEP_INSTANCE
        SET ValueBefore = CONCAT(CONVERT(VARCHAR(20), @Standing), '|', CASE WHEN @WasDisc = 1 THEN '1' ELSE '0' END)
        WHERE RequestInstanceId = @RequestInstanceId AND StepNo = @Step;

    UPDATE workflow.LEAVE_REQUEST
    SET DaysApproved=@Granted, IsDiscretionary=@MakeDiscretionary
    WHERE RequestInstanceId=@RequestInstanceId;

    /* script 84: one place posts a leave (per month, working days, half days, the discretionary give-back, ApprovedToDate)
       and re-derives its attendance days: hr.usp_LeaveLedger_PostRequest. */
    IF (SELECT TOP 1 [Status] FROM @Result)='Approved'
    BEGIN
        DECLARE @rc INT;
        EXEC @rc = hr.usp_LeaveLedger_PostRequest @RequestInstanceId=@RequestInstanceId, @ActorUserId=@ActedByUserId,
             @UsageNote=N'Approved leave request.';
        IF @rc <> 0
        BEGIN
            IF @OuterTran = 0 ROLLBACK; ELSE ROLLBACK TRANSACTION LeaveRequestDecide;
            RETURN 1;                                       -- the poster said why
        END
    END

    IF @OuterTran = 0 COMMIT TRAN;

    DECLARE @Balance DECIMAL(6,2)=(SELECT ISNULL(SUM(Days),0) FROM hr.LEAVE_LEDGER
                                   WHERE EmployeeId=@EmpId AND LeaveTypeId=@LtId);
    SELECT r.*,@Granted AS DaysApproved,@Balance AS BalanceAfter,
           CAST(CASE WHEN @Balance<0 THEN 1 ELSE 0 END AS BIT) AS BalanceIsNegative,
           CAST(@MakeDiscretionary AS BIT) AS DiscretionaryGranted
    FROM @Result r;
    RETURN 0;
END;
GO

/* ------------------------- 9. the two leave reads carry the approved span ------------------------- */
CREATE OR ALTER PROCEDURE [workflow].[usp_LeaveRequest_GetPayload]
    @RequestInstanceId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT lr.LeaveRequestId, lr.EmployeeId, e.FullName AS EmployeeName,
           lr.LeaveTypeId, lt.Name AS LeaveTypeName, lt.IsPaid,
           lr.FromDate, lr.ToDate, lr.DaysRequested, lr.DaysApproved,
           lr.Reason, lr.AppliedToLedgerAt,
           lr.RelationToEmployee,
           lt.RequiresCertificate,
           lr.IsDiscretionary,
           att.AttachmentCount,
           bal.CurrentBalance,
           n.NoticeGivenDays,
           lt.NoticePreferredDays,
           CAST(CASE WHEN lt.NoticePreferredDays > 0
                      AND n.NoticeGivenDays < lt.NoticePreferredDays
                     THEN 1 ELSE 0 END AS BIT) AS NoticeShorterThanPreferred,
           lr.HalfDay,                      -- script 84 (D3): 'AM' | 'PM' | NULL
           lr.ApprovedToDate,               -- QA3: the last approved day (a partial approval keeps the first days)
           lr.PaidSnapshot                  -- QA3: paid or unpaid as approved
    FROM workflow.LEAVE_REQUEST lr
    JOIN hr.EMPLOYEE e    ON e.EmployeeId  = lr.EmployeeId
    JOIN hr.LEAVE_TYPE lt ON lt.LeaveTypeId = lr.LeaveTypeId
    JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = lr.RequestInstanceId
    OUTER APPLY (SELECT DATEDIFF(DAY, CAST(ri.SubmittedAt AS DATE), lr.FromDate)
                 AS NoticeGivenDays) n
    OUTER APPLY (SELECT ISNULL(SUM(Days),0) AS CurrentBalance
                 FROM hr.LEAVE_LEDGER ll
                 WHERE ll.EmployeeId = lr.EmployeeId
                   AND ll.LeaveTypeId = lr.LeaveTypeId) bal
    OUTER APPLY (SELECT COUNT(*) AS AttachmentCount
                 FROM workflow.REQUEST_ATTACHMENT ra
                 WHERE ra.RequestInstanceId = lr.RequestInstanceId) att
    WHERE lr.RequestInstanceId = @RequestInstanceId;
END;
GO

CREATE OR ALTER PROCEDURE workflow.usp_LeaveRequest_GetForEmployee
    @EmployeeId INT, @FromDate DATE = NULL, @ToDate DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT lr.LeaveRequestId, lr.RequestInstanceId, r.[Status],
           lt.Name AS LeaveTypeName, lr.FromDate, lr.ToDate,
           lr.DaysRequested, lr.DaysApproved, lr.Reason, r.SubmittedAt,
           lr.HalfDay,                      -- script 84 (D3)
           lr.ApprovedToDate                -- QA3
    FROM workflow.LEAVE_REQUEST lr
    JOIN workflow.REQUEST_INSTANCE r ON r.RequestInstanceId = lr.RequestInstanceId
    JOIN hr.LEAVE_TYPE lt ON lt.LeaveTypeId = lr.LeaveTypeId
    WHERE lr.EmployeeId = @EmployeeId
      AND (@FromDate IS NULL OR CASE WHEN r.[Status] = 'Approved' THEN ISNULL(lr.ApprovedToDate, lr.ToDate) ELSE lr.ToDate END >= @FromDate)
      AND (@ToDate   IS NULL OR lr.FromDate <= @ToDate)
    ORDER BY lr.FromDate DESC;
END;
GO

/* ------------------------- 10. the leave year: open, undo (LEV-1, LEV-9, LEV-12, LEV-13) ------------------------- */
/* Script 84's opening with, QA3:
   - LEV-1  the close of the old year ("Year close ..." / "Unused ... expired") is posted in the CLOSING year, on
            31 December; only the carry-over and the new entitlement are in January. The new year's card no longer
            subtracts last year's remainder, and the old year's card ends at 0 once closed.
   - LEV-9  the close and the carry each have their own NOT EXISTS guard (marker SourceType 'LeaveYear', SourceRef = the
            year opened, plus the legacy notes), so no run posts them twice; the opening row is written even for 0 days
            (a 0-day tier, or no tier for the employee's service) -- it is what marks the year as opened, so a re-run
            neither re-posts the close nor leaves the old year unclosed for the employee with no matching tier.
   - LEV-12 the tier is chosen by WHOLE years of service at 1 January (hired 15 Jan 2021: 4 years at 1 Jan 2026, not 5).
   - LEV-13 an inactive leave type is not granted (nor closed: its ledger is left as it stands).
   Same parameters and the same six-column summary as before. */
CREATE OR ALTER PROCEDURE [hr].[usp_LeaveYear_Open]
    @Year          INT,
    @ActedByUserId INT = NULL,
    @EmployeeId    INT = NULL,               -- script 84: open ONE employee (a new hire, a test) instead of everybody still unopened
    @CarryOverMaxDays DECIMAL(6,2) = NULL    -- script 84 (D4): NULL = the LeaveCarryOverMaxDays setting (empty = no cap)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Now INT = YEAR(CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE));
    IF @Year <> @Now
    BEGIN
        DECLARE @m nvarchar(200) = CONCAT(N'Only the current year (', @Now,
            N') can be opened. Next January, open ', @Now + 1, N'.');
        RAISERROR(@m, 16, 1); RETURN 1;
    END

    DECLARE @Jan1   DATE    = DATEFROMPARTS(@Year, 1, 1);
    DECLARE @NextJ1 DATE    = DATEADD(YEAR, 1, @Jan1);
    DECLARE @Period CHAR(7) = CONVERT(CHAR(7), @Jan1, 23);
    DECLARE @PrevYr INT     = @Year - 1;
    DECLARE @PrevDec CHAR(7) = CONCAT(@PrevYr, '-12');
    DECLARE @Dec31  DATE    = DATEFROMPARTS(@PrevYr, 12, 31);
    DECLARE @Cap DECIMAL(6,2) = COALESCE(@CarryOverMaxDays,
                                         TRY_CAST(NULLIF(LTRIM(RTRIM((SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'LeaveCarryOverMaxDays'))), '') AS DECIMAL(6,2)));
    IF @Cap IS NOT NULL AND @Cap < 0 SET @Cap = 0;

    SELECT
        e.EmployeeId, e.FullName, e.HireDate,
        lt.LeaveTypeId, lt.Name AS LeaveTypeName, lt.CarryOver,
        svc.Years AS ServiceYears,
        CAST(CASE WHEN t.AnnualDays IS NULL THEN 0
                  WHEN e.HireDate >= @Jan1 THEN ROUND(t.AnnualDays * (13 - MONTH(e.HireDate)) / 12.0 * 2, 0) / 2
                  ELSE t.AnnualDays END AS DECIMAL(6,2)) AS GrantDays,
        CAST(CASE WHEN e.HireDate >= @Jan1 AND t.AnnualDays IS NOT NULL THEN 1 ELSE 0 END AS BIT) AS Prorated,
        CAST(CASE WHEN t.AnnualDays IS NULL THEN 0 ELSE 1 END AS BIT) AS HasTier,
        ISNULL(prev.Remaining, 0) AS PrevRemaining,
        CAST(CASE WHEN EXISTS (SELECT 1 FROM hr.LEAVE_LEDGER c
                               WHERE c.EmployeeId = e.EmployeeId AND c.LeaveTypeId = lt.LeaveTypeId AND c.MovementType = 'Adjustment'
                                 AND c.LeaveRequestId IS NULL
                                 AND (   (c.SourceType = 'LeaveYear' AND c.SourceRef = @Year)
                                      OR c.Note LIKE CONCAT(N'Year close ', @PrevYr, N'%')
                                      OR c.Note LIKE CONCAT(N'Unused ', @PrevYr, N' days expired%')))
                  THEN 1 ELSE 0 END AS BIT) AS Closed,
        CAST(CASE WHEN EXISTS (SELECT 1 FROM hr.LEAVE_LEDGER c
                               WHERE c.EmployeeId = e.EmployeeId AND c.LeaveTypeId = lt.LeaveTypeId AND c.MovementType = 'CarryOver'
                                 AND c.LeaveRequestId IS NULL
                                 AND (   (c.SourceType = 'LeaveYear' AND c.SourceRef = @Year)
                                      OR c.Note = CONCAT(N'Carried over from ', @PrevYr, N'.')))
                  THEN 1 ELSE 0 END AS BIT) AS Carried
    INTO #grant
    FROM hr.EMPLOYEE e
    CROSS JOIN hr.LEAVE_TYPE lt
    /* QA3 LEV-12: whole years of service at 1 January: months = DATEDIFF(MONTH) less one when the day of the month is not reached */
    CROSS APPLY (SELECT CASE WHEN e.HireDate >= @Jan1 THEN 0
                             ELSE (DATEDIFF(MONTH, e.HireDate, @Jan1) - CASE WHEN DAY(e.HireDate) > DAY(@Jan1) THEN 1 ELSE 0 END) / 12 END AS Years) svc
    OUTER APPLY (
        SELECT TOP 1 a.AnnualDays
        FROM hr.LEAVE_ACCRUAL_TIER a
        WHERE a.LeaveTypeId = lt.LeaveTypeId AND a.MinServiceYears <= svc.Years
        ORDER BY a.MinServiceYears DESC
    ) t
    OUTER APPLY (
        SELECT SUM(l.Days) AS Remaining
        FROM hr.LEAVE_LEDGER l
        WHERE l.EmployeeId = e.EmployeeId AND l.LeaveTypeId = lt.LeaveTypeId
          AND l.PeriodYearMonth < @Period
    ) prev
    WHERE e.IsDeleted = 0
      AND (@EmployeeId IS NULL OR e.EmployeeId = @EmployeeId)
      AND e.HireDate < @NextJ1
      AND (e.TerminationDate IS NULL OR e.TerminationDate >= @Jan1)
      AND lt.IsActive = 1                                                           -- QA3 LEV-13
      AND EXISTS (SELECT 1 FROM hr.LEAVE_ACCRUAL_TIER a2 WHERE a2.LeaveTypeId = lt.LeaveTypeId)
      AND NOT EXISTS (SELECT 1 FROM hr.LEAVE_LEDGER l2
                      WHERE l2.EmployeeId = e.EmployeeId AND l2.LeaveTypeId = lt.LeaveTypeId
                        AND l2.PeriodYearMonth = @Period
                        AND l2.MovementType = 'Accrual'
                        AND l2.Note LIKE N'Annual entitlement%');

    BEGIN TRAN;

    /* the close of the old year, in the old year (LEV-1), once (LEV-9) */
    INSERT INTO hr.LEAVE_LEDGER (EmployeeId, LeaveTypeId, PeriodYearMonth, MovementType,
                                 Days, EffectiveDate, Note, CreatedBy, SourceType, SourceRef)
    SELECT EmployeeId, LeaveTypeId, @PrevDec, 'Adjustment',
           -PrevRemaining, @Dec31,
           CASE WHEN CarryOver = 1 AND @Cap IS NOT NULL AND PrevRemaining > @Cap
                THEN CONCAT(N'Year close ', @PrevYr, N' ', NCHAR(8212), N' ', FORMAT(@Cap, '0.##'), N' moved to carry-over; ', FORMAT(PrevRemaining - @Cap, '0.##'), N' beyond the cap lapsed.')
                WHEN CarryOver = 1
                THEN CONCAT(N'Year close ', @PrevYr, N' ', NCHAR(8212), N' moved to carry-over.')
                ELSE CONCAT(N'Unused ', @PrevYr, N' days expired (no carry-over).') END,
           @ActedByUserId, 'LeaveYear', @Year
    FROM #grant WHERE PrevRemaining > 0 AND Closed = 0;

    /* the carry into the new year, once (LEV-9) */
    INSERT INTO hr.LEAVE_LEDGER (EmployeeId, LeaveTypeId, PeriodYearMonth, MovementType,
                                 Days, EffectiveDate, Note, CreatedBy, SourceType, SourceRef)
    SELECT EmployeeId, LeaveTypeId, @Period, 'CarryOver',
           CASE WHEN @Cap IS NOT NULL AND PrevRemaining > @Cap THEN @Cap ELSE PrevRemaining END, @Jan1,
           CONCAT(N'Carried over from ', @PrevYr, N'.'), @ActedByUserId, 'LeaveYear', @Year
    FROM #grant WHERE PrevRemaining > 0 AND CarryOver = 1 AND (@Cap IS NULL OR @Cap > 0) AND Carried = 0 AND Closed = 0;

    /* the entitlement -- written even at 0 days: it is what says the year is opened for the employee */
    INSERT INTO hr.LEAVE_LEDGER (EmployeeId, LeaveTypeId, PeriodYearMonth, MovementType,
                                 Days, EffectiveDate, Note, CreatedBy, SourceType, SourceRef)
    SELECT EmployeeId, LeaveTypeId, @Period, 'Accrual',
           GrantDays, @Jan1,
           CASE WHEN HasTier = 0
                THEN CONCAT(N'Annual entitlement ', @Year, N': no tier for ', ServiceYears, N' whole year(s) of service.')
                WHEN Prorated = 1
                THEN CONCAT(N'Annual entitlement ', @Year, N' (prorated from ', FORMAT(HireDate, 'MMM yyyy'), N').')
                ELSE CONCAT(N'Annual entitlement ', @Year, N'.') END,
           @ActedByUserId, 'LeaveYear', @Year
    FROM #grant;

    COMMIT;

    SELECT LeaveTypeName,
           COUNT(*)                                          AS EmployeesOpened,
           SUM(GrantDays)                                    AS DaysGranted,
           SUM(CASE WHEN Prorated = 1 THEN 1 ELSE 0 END)     AS ProratedEmployees,
           SUM(CASE WHEN CarryOver = 1 AND PrevRemaining > 0 AND Closed = 0
                    THEN CASE WHEN @Cap IS NOT NULL AND PrevRemaining > @Cap THEN @Cap ELSE PrevRemaining END ELSE 0 END) AS DaysCarriedOver,
           SUM(CASE WHEN Closed = 1 OR PrevRemaining <= 0 THEN 0
                    WHEN CarryOver = 0 THEN PrevRemaining
                    WHEN @Cap IS NOT NULL AND PrevRemaining > @Cap THEN PrevRemaining - @Cap
                    ELSE 0 END)                              AS DaysExpired
    FROM #grant
    GROUP BY LeaveTypeName ORDER BY LeaveTypeName;
    RETURN 0;
END;
GO

/* NEW (LEV-9). Takes back what opening the CURRENT year wrote -- the entitlement, the carry-over, the close of the old
   year, and the carry-over expiry that followed from it -- for one employee or everybody, so the year can be opened again
   (a wrong tier grid, a wrong hire date). Refused when leave of that year was already used in a period paid for one of the
   employees concerned: the balance that leave was taken from is settled; correct it with an adjustment instead.
   Result: EmployeesUndone, MovementsRemoved. */
CREATE OR ALTER PROCEDURE hr.usp_LeaveYear_Undo
    @Year INT, @ActedByUserId INT = NULL, @EmployeeId INT = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @Msg NVARCHAR(400);
    DECLARE @Now INT = YEAR(CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE));
    IF @Year IS NULL OR @Year <> @Now
    BEGIN
        SET @Msg = CONCAT(N'Only the current year (', @Now, N') can be undone.');
        RAISERROR(@Msg, 16, 1); RETURN 1;
    END
    IF @EmployeeId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM hr.EMPLOYEE WHERE EmployeeId = @EmployeeId)
    BEGIN RAISERROR('That employee does not exist.', 16, 1); RETURN 1; END

    DECLARE @Period CHAR(7) = CONCAT(@Year, '-01');
    DECLARE @rows TABLE (LeaveLedgerId INT PRIMARY KEY, EmployeeId INT NOT NULL);
    INSERT INTO @rows (LeaveLedgerId, EmployeeId)
    SELECT l.LeaveLedgerId, l.EmployeeId
    FROM hr.LEAVE_LEDGER l
    WHERE (@EmployeeId IS NULL OR l.EmployeeId = @EmployeeId)
      AND l.LeaveRequestId IS NULL
      AND (   (l.SourceType = 'LeaveYear' AND l.SourceRef = @Year)
           OR (l.SourceType IS NULL AND l.MovementType = 'Accrual' AND l.PeriodYearMonth = @Period AND l.Note LIKE N'Annual entitlement%')
           OR (l.MovementType = 'Expiry' AND l.EffectiveDate >= DATEFROMPARTS(@Year, 1, 1) AND l.EffectiveDate < DATEFROMPARTS(@Year + 1, 1, 1)));

    DECLARE @PaidName NVARCHAR(200), @PaidMonth CHAR(7);
    SELECT TOP 1 @PaidName = e.FullName, @PaidMonth = u.PeriodYearMonth
    FROM hr.LEAVE_LEDGER u
    JOIN hr.EMPLOYEE e ON e.EmployeeId = u.EmployeeId
    WHERE u.MovementType = 'Usage'
      AND u.EffectiveDate >= DATEFROMPARTS(@Year, 1, 1) AND u.EffectiveDate < DATEFROMPARTS(@Year + 1, 1, 1)
      AND u.EmployeeId IN (SELECT EmployeeId FROM @rows)
      AND payroll.fn_IsPeriodPaid(u.EmployeeId, u.EffectiveDate) = 1
    ORDER BY u.EffectiveDate, e.FullName;
    IF @PaidName IS NOT NULL
    BEGIN
        SET @Msg = CONCAT(N'The ', @Year, N' leave year cannot be undone: ', @PaidName, N' took leave in ', @PaidMonth,
                          N', a period already paid ', NCHAR(8212), N' correct the balance with an adjustment instead.');
        RAISERROR(N'%s', 16, 1, @Msg); RETURN 1;
    END

    BEGIN TRAN;
    DELETE l FROM hr.LEAVE_LEDGER l JOIN @rows r ON r.LeaveLedgerId = l.LeaveLedgerId;
    COMMIT;

    SELECT COUNT(DISTINCT EmployeeId) AS EmployeesUndone, COUNT(*) AS MovementsRemoved FROM @rows;
    RETURN 0;
END;
GO

/* ------------------------- 11. carried-over days expire (LEV-6) ------------------------- */
/* Once LeaveCarryOverExpiresOn (MM-DD) has passed, the carried days of this year still unused on that date expire: an
   'Expiry' ledger line per employee and type. Usage consumes the carried days first. QA3:
   - a discretionary grant consumes nothing: its usage and its give-back net to zero;
   - the expiry month is counted day by day (a leave over a mid-month expiry date counts only its days up to it); the
     months before it are taken from the ledger as posted;
   - every run recomputes the figure and posts the DIFFERENCE from what was already expired (a positive Expiry gives days
     back), until the expiry month's Primary run is approved for the employee -- then that employee's expiry is final
     (the first posting is still made: the expiry is days, not money);
   - '02-29' is the last day of February in a year without one; a value that is not MM-DD expires nothing, and
     @Problem (OUTPUT) says so for the nightly job's log.
   Same parameters (plus @Problem at the end) and the same two-column result as before. */
CREATE OR ALTER PROCEDURE hr.usp_LeaveCarryOver_Expire
    @AsOfDate      DATE = NULL,              -- NULL = today in Beirut; a caller passes a date only to test the rule
    @ExpiresOn     VARCHAR(5) = NULL,        -- 'MM-DD'; NULL = the LeaveCarryOverExpiresOn setting (empty = never)
    @EmployeeId    INT = NULL,
    @ActedByUserId INT = NULL,
    @Problem       NVARCHAR(300) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    SET @Problem = NULL;
    DECLARE @Today DATE = ISNULL(@AsOfDate, CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE));
    DECLARE @MmDd NVARCHAR(400) = NULLIF(LTRIM(RTRIM(ISNULL(CAST(@ExpiresOn AS NVARCHAR(400)),
                                         (SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'LeaveCarryOverExpiresOn')))), N'');
    IF @MmDd IS NULL
    BEGIN SELECT CAST(0 AS INT) AS EmployeesExpired, CAST(0 AS DECIMAL(9,2)) AS DaysExpired; RETURN 0; END   -- never expires

    DECLARE @Mm INT = CASE WHEN @MmDd LIKE N'[01][0-9]-[0-3][0-9]' THEN CAST(LEFT(@MmDd, 2) AS INT) END;
    DECLARE @Dd INT = CASE WHEN @MmDd LIKE N'[01][0-9]-[0-3][0-9]' THEN CAST(RIGHT(@MmDd, 2) AS INT) END;
    DECLARE @Valid BIT = CASE WHEN @Mm IS NULL OR @Dd IS NULL OR @Mm NOT BETWEEN 1 AND 12 OR @Dd < 1 THEN 0
                              WHEN @Dd > DAY(EOMONTH(DATEFROMPARTS(2000, @Mm, 1))) THEN 0          -- 2000: 02-29 is a date
                              ELSE 1 END;
    IF @Valid = 0
    BEGIN
        SET @Problem = CONCAT(N'LeaveCarryOverExpiresOn "', LEFT(@MmDd, 40), N'" is not a MM-DD date (for example 03-31); carried-over leave was not expired.');
        SELECT CAST(0 AS INT) AS EmployeesExpired, CAST(0 AS DECIMAL(9,2)) AS DaysExpired;
        RETURN 0;
    END

    DECLARE @Year INT = YEAR(@Today);
    DECLARE @Expiry DATE = CASE WHEN @Mm = 2 AND @Dd = 29 THEN EOMONTH(DATEFROMPARTS(@Year, 2, 1)) ELSE DATEFROMPARTS(@Year, @Mm, @Dd) END;
    IF @Today <= @Expiry
    BEGIN SELECT CAST(0 AS INT) AS EmployeesExpired, CAST(0 AS DECIMAL(9,2)) AS DaysExpired; RETURN 0; END  -- not yet

    DECLARE @Jan1 DATE = DATEFROMPARTS(@Year, 1, 1), @NextJ1 DATE = DATEFROMPARTS(@Year + 1, 1, 1);
    DECLARE @MonthStart DATE = DATEFROMPARTS(@Year, MONTH(@Expiry), 1);
    DECLARE @ExpMonth CHAR(7) = CONVERT(CHAR(7), @Expiry, 23), @FirstMonth CHAR(7) = CONCAT(@Year, '-01');

    DECLARE @c TABLE (EmployeeId INT NOT NULL, LeaveTypeId INT NOT NULL, Carried DECIMAL(9,2) NOT NULL,
                      Consumed DECIMAL(9,2) NOT NULL DEFAULT 0, Posted DECIMAL(9,2) NOT NULL DEFAULT 0,
                      HasExpiry BIT NOT NULL DEFAULT 0, PRIMARY KEY (EmployeeId, LeaveTypeId));
    INSERT INTO @c (EmployeeId, LeaveTypeId, Carried)
    SELECT EmployeeId, LeaveTypeId, SUM(Days)
    FROM hr.LEAVE_LEDGER
    WHERE MovementType = 'CarryOver' AND EffectiveDate >= @Jan1 AND EffectiveDate < @NextJ1
      AND (@EmployeeId IS NULL OR EmployeeId = @EmployeeId)
    GROUP BY EmployeeId, LeaveTypeId;

    UPDATE c
    SET Posted = ISNULL(x.Posted, 0), HasExpiry = CASE WHEN x.Rows > 0 THEN 1 ELSE 0 END
    FROM @c c
    CROSS APPLY (SELECT -SUM(e.Days) AS Posted, COUNT(*) AS Rows
                 FROM hr.LEAVE_LEDGER e
                 WHERE e.EmployeeId = c.EmployeeId AND e.LeaveTypeId = c.LeaveTypeId AND e.MovementType = 'Expiry'
                   AND e.EffectiveDate >= @Jan1 AND e.EffectiveDate < @NextJ1) x;
    /* final once the expiry month is paid for the employee */
    DELETE c FROM @c c WHERE c.HasExpiry = 1 AND payroll.fn_IsPeriodPaid(c.EmployeeId, @Expiry) = 1;

    /* the months before the expiry month, from the ledger: usage net of the discretionary give-back */
    UPDATE c
    SET Consumed = ISNULL((SELECT -SUM(l.Days) FROM hr.LEAVE_LEDGER l
                           WHERE l.EmployeeId = c.EmployeeId AND l.LeaveTypeId = c.LeaveTypeId
                             AND l.PeriodYearMonth >= @FirstMonth AND l.PeriodYearMonth < @ExpMonth
                             AND (l.MovementType = 'Usage' OR (l.MovementType = 'Adjustment' AND l.LeaveRequestId IS NOT NULL))), 0)
    FROM @c c;
    /* the expiry month, day by day up to the expiry date: a posted, non-discretionary leave by its own days; any other
       usage (exit permissions converted to leave, a manual usage) by its date */
    UPDATE c
    SET Consumed = c.Consumed
        + ISNULL((SELECT SUM(a.Part)
                  FROM workflow.LEAVE_REQUEST lr
                  CROSS APPLY hr.fn_LeaveRequestDays(lr.LeaveRequestId, 0) a
                  WHERE lr.EmployeeId = c.EmployeeId AND lr.LeaveTypeId = c.LeaveTypeId
                    AND ISNULL(lr.IsDiscretionary, 0) = 0
                    AND EXISTS (SELECT 1 FROM hr.LEAVE_LEDGER u
                                WHERE u.LeaveRequestId = lr.LeaveRequestId AND u.MovementType = 'Usage' AND u.PeriodYearMonth = @ExpMonth)
                    AND a.WorkDate >= @MonthStart AND a.WorkDate <= @Expiry), 0)
        + ISNULL((SELECT -SUM(u.Days) FROM hr.LEAVE_LEDGER u
                  WHERE u.EmployeeId = c.EmployeeId AND u.LeaveTypeId = c.LeaveTypeId
                    AND u.MovementType = 'Usage' AND u.LeaveRequestId IS NULL
                    AND u.PeriodYearMonth = @ExpMonth AND u.EffectiveDate <= @Expiry), 0)
    FROM @c c;

    DECLARE @x TABLE (EmployeeId INT NOT NULL, LeaveTypeId INT NOT NULL, Delta DECIMAL(9,2) NOT NULL, HasExpiry BIT NOT NULL);
    INSERT INTO @x (EmployeeId, LeaveTypeId, Delta, HasExpiry)
    SELECT EmployeeId, LeaveTypeId,
           CASE WHEN Carried - Consumed > 0 THEN Carried - Consumed ELSE 0 END - Posted, HasExpiry
    FROM @c;
    DELETE FROM @x WHERE Delta = 0;

    BEGIN TRAN;
    INSERT INTO hr.LEAVE_LEDGER (EmployeeId, LeaveTypeId, PeriodYearMonth, MovementType, Days, EffectiveDate, Note, CreatedBy)
    SELECT EmployeeId, LeaveTypeId, @ExpMonth, 'Expiry', -Delta, @Expiry,
           CASE WHEN HasExpiry = 0
                THEN CONCAT(FORMAT(Delta, '0.##'), N' day(s) carried over from ', @Year - 1, N' were still unused on ', CONVERT(CHAR(10), @Expiry, 23), N' and expired.')
                WHEN Delta > 0
                THEN CONCAT(N'Expiry corrected: ', FORMAT(Delta, '0.##'), N' more carried-over day(s) were unused on ', CONVERT(CHAR(10), @Expiry, 23), N'.')
                ELSE CONCAT(N'Expiry corrected: ', FORMAT(-Delta, '0.##'), N' carried-over day(s) given back ', NCHAR(8212),
                            N' leave dated on or before ', CONVERT(CHAR(10), @Expiry, 23), N' was recorded after the expiry ran.') END,
           @ActedByUserId
    FROM @x;
    COMMIT;

    SELECT COUNT(*) AS EmployeesExpired, CAST(ISNULL(SUM(Delta), 0) AS DECIMAL(9,2)) AS DaysExpired FROM @x;
    RETURN 0;
END;
GO

/* ------------------------- 12. balance reads (LEV-14, the Beirut year) ------------------------- */
/* Script 73's per-year balance; QA3: the default year is Beirut's (it was GETDATE(), the server's UTC date). */
CREATE OR ALTER PROCEDURE hr.usp_Leave_GetBalanceByYear
    @EmployeeId INT, @Year INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Year = ISNULL(@Year, YEAR(CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE)));
    DECLARE @From CHAR(7) = CONCAT(@Year, '-01'), @To CHAR(7) = CONCAT(@Year, '-12');

    DECLARE @Opened BIT = CASE WHEN EXISTS (
        SELECT 1 FROM hr.LEAVE_LEDGER
        WHERE EmployeeId = @EmployeeId AND PeriodYearMonth = @From
          AND MovementType = 'Accrual' AND Note LIKE N'Annual entitlement%') THEN 1 ELSE 0 END;

    SELECT @Opened AS YearOpened, @Year AS [Year];

    SELECT lt.LeaveTypeId,
           lt.Name                                   AS LeaveType,
           lt.IsPaid,
           CAST(ISNULL(SUM(b.Accrued),     0) AS DECIMAL(7,2)) AS Entitlement,
           CAST(ISNULL(SUM(b.CarriedOver), 0) AS DECIMAL(7,2)) AS CarriedOver,
           CAST(ISNULL(SUM(b.Used),        0) AS DECIMAL(7,2)) AS Used,
           CAST(ISNULL(SUM(b.Adjusted),    0) AS DECIMAL(7,2)) AS Adjusted,
           CAST(ISNULL(SUM(b.Remaining),   0) AS DECIMAL(7,2)) AS Remaining,
           @Year                                     AS [Year]
    FROM hr.LEAVE_TYPE lt
    LEFT JOIN hr.vw_LEAVE_BALANCE b
           ON b.LeaveTypeId = lt.LeaveTypeId AND b.EmployeeId = @EmployeeId
          AND b.PeriodYearMonth BETWEEN @From AND @To
    WHERE @Opened = 1
      AND (lt.IsActive = 1 OR b.LeaveTypeId IS NOT NULL)   -- inactive types only when they carry movements
    GROUP BY lt.LeaveTypeId, lt.Name, lt.IsPaid
    ORDER BY lt.Name;
END;
GO

/* The leave balance report (report_procedures.sql), QA3 LEV-14: with Adjusted (adjustments and expiries), so each row
   adds up: Remaining = Accrued + CarriedOver - Used + Adjusted. Otherwise unchanged. */
CREATE OR ALTER PROCEDURE report.usp_Report_LeaveBalance
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

    ;WITH bal AS (
        SELECT EmployeeId, LeaveTypeId,
               SUM(Accrued)     AS Accrued,
               SUM(CarriedOver) AS CarriedOver,
               SUM(Used)        AS Used,
               SUM(Adjusted)    AS Adjusted,
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
        ISNULL(bal.Adjusted, 0)    AS Adjusted,
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

/* ------------------------- 13. verification ------------------------- */
DECLARE @cols INT = (SELECT COUNT(*) FROM sys.columns WHERE object_id = OBJECT_ID('workflow.LEAVE_REQUEST') AND name IN ('ApprovedToDate', 'PaidSnapshot'));
DECLARE @new INT = (SELECT COUNT(*) FROM sys.objects WHERE object_id IN (OBJECT_ID('hr.usp_LeaveLedger_Reprice'), OBJECT_ID('hr.usp_LeaveYear_Undo'),
                                                                         OBJECT_ID('hr.fn_LeaveRequestDays'), OBJECT_ID('hr.fn_LeaveFirstPaidMonth')));
DECLARE @open INT = (SELECT COUNT(*) FROM workflow.LEAVE_REQUEST lr JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = lr.RequestInstanceId
                     WHERE ri.[Status] = 'Approved' AND (lr.ApprovedToDate IS NULL OR lr.PaidSnapshot IS NULL));
DECLARE @close INT = (SELECT COUNT(*) FROM hr.LEAVE_LEDGER WHERE SourceType = 'LeaveYear' AND MovementType = 'Adjustment' AND PeriodYearMonth = CONCAT(SourceRef, '-01'));
PRINT CONCAT('LEAVE_REQUEST columns = ', @cols, ' (expected 2); new objects = ', @new, ' (expected 4); approved requests without the markers = ',
             @open, ' (expected 0); year-close rows still in January = ', @close, ' (expected 0)');
PRINT '99_qa3_leave.sql in place';
GO
