/* ============================================================================
   86_qa2_payroll.sql — the payroll fixes and features of the QA2 scenario suite (tests/qa2, cases A5, A3i, A3j). Needs 82-85.

   QA2-20 (blocker) A SALARY CHANGE INSIDE THE MONTH PAID BOTH SALARIES IN FULL. Section A multiplied every standing component
          by the employee's coverage only; with 1500 until the 15th and 1800 from the 16th the payslip carried 3300. Each
          component row is now prorated by ITS OWN days in the period (hire, termination and its EffectiveFrom / To), and
          the line says so. The day / hour rate is taken from ONE basic row — the one in force on the employee's last day
          in the period — so deductions and overtime are no longer duplicated by a second basic row.
   QA2-22 (major)   deductions for short days are computed from the EXACT share missing (shortfall minutes ÷ the day's standard),
          rounded once on the money; 1 − DayFraction used a fraction already rounded to two decimals (20 min of 450 = 2.00
          instead of 2.22 at a day rate of 50).
   D8  ADVANCES: an instalment is capped at the net of the payslip (it is computed last, after the statutory lines); the rest
       is carried — the line says how much — and no net goes negative.
   D5  LEAVE BALANCE ON TERMINATION (setting LeavePayoutOnTermination): "Leave Balance Payout" / "Leave Balance Deduction" in
       the month the employee leaves, at the day rate; not when an approved separation settlement already pays the leave.
   D1  HOLIDAY WORK: worked minutes on a public holiday × (day rate ÷ standard) × (HolidayWorkRate − 1), line "Holiday Work";
       an UNPAID holiday costs whoever was rostered to work it the day.
   D2/D3 unpaid leave costs its WORKING days inside the period (0.5 for a half day).
   A3j EXIT PERMISSIONS AT PERIOD CLOSE: usp_ExitPermission_PostLeaveUsage posted the DAY's minutes once per permission (two
       permissions on a day = twice), and could take the balance negative. It now posts once per employee-day, never more
       than the balance holds, and records the rest on the day (ATTENDANCE_RECORD.ExitUnpaidDays) — the payslip deducts it
       as "Unpaid Leave Deduction". Idempotent as before.
   D7  the readiness gate and section D resolve the branch of the DAY (hr.fn_EmployeeBranchOn).

   Locked runs are not touched. Idempotent. Apply with sqlcmd -C -I.
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/* ───────────────────────── 1. component types and the column ───────────────────────── */
INSERT INTO hr.COMPONENT_TYPE (Name, Category, [Sign], IsStanding, IsBasicSalary, IsActive)
SELECT v.Name, v.Category, v.[Sign], 0, 0, 1
FROM (VALUES (N'Holiday Work',            'Earning',    1),
             (N'Leave Balance Payout',    'Earning',    1),
             (N'Leave Balance Deduction', 'Deduction', -1)) v(Name, Category, [Sign])
WHERE NOT EXISTS (SELECT 1 FROM hr.COMPONENT_TYPE c WHERE c.Name = v.Name);
GO
IF COL_LENGTH('attendance.ATTENDANCE_RECORD', 'ExitUnpaidDays') IS NULL
    ALTER TABLE attendance.ATTENDANCE_RECORD ADD ExitUnpaidDays DECIMAL(6,2) NULL;
GO

/* ───────────────────────── 2. exit permissions converted to leave at period close ───────────────────────── */
CREATE OR ALTER PROCEDURE workflow.usp_ExitPermission_PostLeaveUsage
    @PeriodYearMonth CHAR(7),          -- e.g. '2026-07'
    @LeaveTypeId     INT,              -- which balance it draws from (Annual)
    @PostedBy        INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @from DATE = CAST(@PeriodYearMonth + '-01' AS DATE);
    DECLARE @to   DATE = EOMONTH(@from);
    DECLARE @Posted INT = 0;

    /* ONE posting per employee-day. ExitLeaveMinutes is the DAY's figure (it honours the basis setting and HR's override),
       so with two permissions on a day it must not be posted once per permission. The day is keyed by its LATEST
       convert-to-leave permission; a day any of whose permissions was already posted is done. */
    DECLARE @Id INT, @Emp INT, @Date DATE, @Days DECIMAL(6,2), @AttId BIGINT, @Balance DECIMAL(9,2), @Use DECIMAL(6,2), @Paid BIT;
    DECLARE lp_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT d.ExitPermissionId, d.EmployeeId, d.ExitDate, core.fn_MinutesToLeaveDays(a.ExitLeaveMinutes), a.AttendanceId
        FROM (SELECT ep.EmployeeId, ep.ExitDate, MAX(ep.ExitPermissionId) AS ExitPermissionId
              FROM workflow.EXIT_PERMISSION ep
              JOIN workflow.REQUEST_INSTANCE r ON r.RequestInstanceId = ep.RequestInstanceId
              WHERE r.[Status] = 'Approved' AND ep.ConvertToLeave = 1 AND ep.ExitDate BETWEEN @from AND @to
              GROUP BY ep.EmployeeId, ep.ExitDate) d
        JOIN attendance.ATTENDANCE_RECORD a ON a.EmployeeId = d.EmployeeId AND a.WorkDate = d.ExitDate
        WHERE a.ExitLeaveMinutes > 0
          AND NOT EXISTS (SELECT 1 FROM hr.LEAVE_LEDGER l
                          JOIN workflow.EXIT_PERMISSION e2 ON e2.ExitPermissionId = l.SourceRef
                          WHERE l.SourceType = 'ExitPermission' AND e2.EmployeeId = d.EmployeeId AND e2.ExitDate = d.ExitDate)
          AND ISNULL(a.ExitUnpaidDays, 0) = 0
        ORDER BY d.EmployeeId, d.ExitDate;

    OPEN lp_cur;
    FETCH NEXT FROM lp_cur INTO @Id, @Emp, @Date, @Days, @AttId;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF @Days > 0
        BEGIN
            /* NEVER A NEGATIVE BALANCE: the leave takes what the balance holds; the rest of the minutes is unpaid and is
               written on the day for the payslip to deduct. A day that is already paid cannot be deducted any more, so
               there the remainder is simply not converted. */
            SET @Balance = ISNULL((SELECT SUM(Days) FROM hr.LEAVE_LEDGER WHERE EmployeeId = @Emp AND LeaveTypeId = @LeaveTypeId), 0);
            SET @Use = CASE WHEN @Balance <= 0 THEN 0 WHEN @Days <= @Balance THEN @Days ELSE @Balance END;
            SET @Paid = payroll.fn_IsPeriodPaid(@Emp, @Date);
            IF @Use > 0
            BEGIN
                EXEC hr.usp_LeaveLedger_PostMovement
                     @EmployeeId    = @Emp,
                     @LeaveTypeId   = @LeaveTypeId,
                     @MovementType  = 'Usage',
                     @Days          = @Use,           -- positive magnitude; the proc applies the sign
                     @EffectiveDate = @Date,
                     @Note          = N'Exit permission converted to leave.',
                     @CreatedBy     = @PostedBy,
                     @SourceType    = 'ExitPermission',
                     @SourceRef     = @Id;
                SET @Posted = @Posted + 1;
            END
            IF @Days > @Use AND @Paid = 0
                UPDATE attendance.ATTENDANCE_RECORD SET ExitUnpaidDays = @Days - @Use WHERE AttendanceId = @AttId;
        END
        FETCH NEXT FROM lp_cur INTO @Id, @Emp, @Date, @Days, @AttId;
    END
    CLOSE lp_cur;
    DEALLOCATE lp_cur;

    SELECT @Posted AS LeaveMovementsPosted;
END;
GO

/* ───────────────────────── 3. the readiness gate: the branch of the day ───────────────────────── */
CREATE OR ALTER PROCEDURE attendance.usp_Attendance_PayrollReadiness
    @PeriodYearMonth CHAR(7),
    @AsOfDate DATE = NULL      -- script 81: the clock. NULL = today in Beirut; a caller passes a date only to test the rule
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @from DATE = CAST(@PeriodYearMonth + '-01' AS DATE);
    DECLARE @monthEnd DATE = EOMONTH(@from);
    /* script 81: A PRIMARY MAY BE RUN ON ANY DAY OF ITS PERIOD, so the gates look only at the days that
       have happened — up to today in Beirut, never past the end of the month. Later days have nothing
       to be unready about: payroll counts them as scheduled. A period that has not started yields
       an empty range (every count 0). PeriodEnd in the answer stays the month's end (INSERT-EXEC shape). */
    DECLARE @today DATE = ISNULL(@AsOfDate, CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE));
    DECLARE @to   DATE = CASE WHEN @today < @monthEnd THEN @today ELSE @monthEnd END;

    DECLARE @Unprocessed INT = (SELECT COUNT(*) FROM attendance.RAW_DEVICE_LOG
        WHERE IsProcessed = 0 AND EmployeeId IS NOT NULL AND CAST(PunchTimeUtc AS DATE) BETWEEN @from AND @to);

    DECLARE @Unresolved INT = (SELECT COUNT(*) FROM attendance.RAW_DEVICE_LOG
        WHERE EmployeeId IS NULL AND CAST(PunchTimeUtc AS DATE) BETWEEN @from AND @to);

    DECLARE @Anomalies INT = (SELECT COUNT(*) FROM attendance.ATTENDANCE_RECORD
        WHERE HasAnomaly = 1 AND WorkDate BETWEEN @from AND @to);

    DECLARE @PendingCorr INT = (SELECT COUNT(*)
        FROM attendance.ATTENDANCE_CORRECTION c
        JOIN attendance.ATTENDANCE_RECORD a ON a.AttendanceId = c.AttendanceId
        WHERE c.ApprovalStatus = 'Pending' AND a.WorkDate BETWEEN @from AND @to);

    /* a rostered day is one of an APPROVED roster month — the same gate the day rule applies */
    DECLARE @MissingDays INT = (SELECT COUNT(*)
        FROM attendance.SHIFT_ASSIGNMENT sa
        JOIN hr.EMPLOYEE e ON e.EmployeeId = sa.EmployeeId AND e.IsDeleted = 0
        WHERE sa.WorkDate BETWEEN @from AND @to
          AND EXISTS (SELECT 1 FROM attendance.ROSTER_MONTH rm
                      WHERE rm.BranchId = hr.fn_EmployeeBranchOn(sa.EmployeeId, sa.WorkDate)      -- script 86 (D7): the branch of the DAY
                        AND rm.MonthDate = DATEFROMPARTS(YEAR(sa.WorkDate), MONTH(sa.WorkDate), 1)
                        AND rm.[Status] = 'Approved')
          AND NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD a
                          WHERE a.EmployeeId = sa.EmployeeId AND a.WorkDate = sa.WorkDate));

    DECLARE @OpenVariances INT = (SELECT COUNT(*) FROM attendance.ATTENDANCE_RECORD
        WHERE WorkDate BETWEEN @from AND @to
          AND ExitVarianceMinutes > 0
          AND ExitVarianceDisposition IS NULL);

    /* late arrivals / early departures at or beyond the tolerance (and missing punches) HR has not decided */
    DECLARE @Undecided INT = (SELECT COUNT(*) FROM attendance.ATTENDANCE_ANOMALY
        WHERE WorkDate BETWEEN @from AND @to AND Decision IS NULL);

    SELECT
        @PeriodYearMonth AS PeriodYearMonth,
        @from            AS PeriodStart,
        @monthEnd        AS PeriodEnd,
        @Unprocessed     AS UnprocessedPunches,
        @Unresolved      AS UnresolvedPinPunches,
        @Anomalies       AS OpenAnomalies,
        @PendingCorr     AS PendingCorrections,
        @MissingDays     AS RosteredDaysWithNoRecord,
        @OpenVariances   AS UndecidedExitVariances,
        @Undecided       AS UndecidedAnomalies,
        CASE WHEN @Unprocessed = 0 AND @Unresolved = 0 AND @Anomalies = 0
                  AND @PendingCorr = 0 AND @MissingDays = 0 AND @OpenVariances = 0 AND @Undecided = 0
             THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END AS IsReady;
END;
GO

/* ───────────────────────── 4. the primary generator ───────────────────────── */
CREATE OR ALTER PROCEDURE payroll.usp_PayrollRun_Generate
    @PayrollRunId INT, @ActedByUserId INT,
    @AsOfDate DATE = NULL      -- script 81: the clock. NULL = today in Beirut; a caller passes a date only to test the rule
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;

    DECLARE @Status VARCHAR(12), @Start DATE, @End DATE, @Primary CHAR(3), @Period CHAR(7);
    SELECT @Status=[Status], @Start=PeriodStart, @End=PeriodEnd,
           @Primary=PrimaryCurrency, @Period=PeriodYearMonth
    FROM payroll.PAYROLL_RUN WHERE PayrollRunId=@PayrollRunId;
    IF @Status IS NULL BEGIN RAISERROR('No such payroll run.',16,1); RETURN; END
    IF @Status NOT IN ('Draft','Review')
    BEGIN RAISERROR('This run is locked. A locked run is never regenerated - corrections go to the next period.',16,1); RETURN; END

    DECLARE @DaysPerMonth DECIMAL(6,2) = ISNULL(TRY_CAST((SELECT SettingValue FROM core.SETTING
        WHERE SettingKey='StandardWorkingDaysPerMonth') AS DECIMAL(6,2)),26);
    DECLARE @HoursPerDay DECIMAL(6,2) = ISNULL(TRY_CAST((SELECT SettingValue FROM core.SETTING
        WHERE SettingKey='StandardHoursPerDay') AS DECIMAL(6,2)),8);
    /* Global FALLBACK ceiling — used only for ceilinged schemes whose row has no CeilingAmount. */
    DECLARE @Ceiling DECIMAL(18,2) = ISNULL(TRY_CAST((SELECT SettingValue FROM core.SETTING
        WHERE SettingKey='NssfCeilingUsd') AS DECIMAL(18,2)),999999);
    DECLARE @FamilyDed DECIMAL(18,2) = ISNULL(TRY_CAST((SELECT SettingValue FROM core.SETTING
        WHERE SettingKey='TaxFamilyDeductionAnnualUsd') AS DECIMAL(18,2)),0);
    DECLARE @DaysInMonth INT = DAY(@End);
    /* script 81: a primary generated before its period has ended counts attendance UP TO TODAY (Beirut);
       the days still to come are paid as scheduled — they have no record to be short on, and a record
       written ahead of time must not cost anything either. */
    DECLARE @Today DATE = ISNULL(@AsOfDate, CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE));
    DECLARE @UpTo  DATE = CASE WHEN @Today < @End THEN @Today ELSE @End END;

    BEGIN TRAN;
    DELETE FROM payroll.PAYSLIP WHERE PayrollRunId=@PayrollRunId;   -- lines cascade

    /* ── payslip shells: everyone employed during any part of the period ── */
    INSERT INTO payroll.PAYSLIP
        (PayrollRunId,EmployeeId,EmployeeName,PositionTitle,BranchName,NssfNumber,HireDate)
    SELECT @PayrollRunId, e.EmployeeId, e.FullName, p.Title, b.Name, e.NssfNumber, e.HireDate
    FROM hr.EMPLOYEE e
    JOIN hr.[POSITION] p ON p.PositionId=e.PositionId
    JOIN hr.BRANCH b ON b.BranchId=e.BranchId
    WHERE e.IsDeleted=0
      AND e.HireDate <= @End
      AND (e.TerminationDate IS NULL OR e.TerminationDate >= @Start);

    /* proration per employee: employed calendar days / days in month */
    SELECT ps.PayslipId, ps.EmployeeId, e.HireDate, e.TerminationDate,
           CAST(DATEDIFF(DAY,
                CASE WHEN e.HireDate > @Start THEN e.HireDate ELSE @Start END,
                CASE WHEN e.TerminationDate IS NOT NULL AND e.TerminationDate < @End
                     THEN e.TerminationDate ELSE @End END) + 1 AS DECIMAL(6,2))
                / @DaysInMonth AS Coverage
    INTO #Emp
    FROM payroll.PAYSLIP ps
    JOIN hr.EMPLOYEE e ON e.EmployeeId=ps.EmployeeId
    WHERE ps.PayrollRunId=@PayrollRunId;

    /* ── A. standing components, prorated by the days EACH ONE was in force ──
          script 86 (QA2-20): a component used to be multiplied by the EMPLOYEE's coverage only, so a salary change inside the
          month paid BOTH rows in full (1500 until the 15th + 1800 from the 16th = 3300). Each row now counts its own
          days: from the latest of (period start, hire, the row's EffectiveFrom) to the earliest of (period end,
          termination, the row's EffectiveTo), over the days of the month. The line says the proration. ── */
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
    CROSS APPLY (SELECT FromD = (SELECT MAX(v) FROM (VALUES (@Start), (x.HireDate), (sc.EffectiveFrom)) f(v)),
                        ToD   = (SELECT MIN(v) FROM (VALUES (@End), (ISNULL(x.TerminationDate, @End)), (ISNULL(sc.EffectiveTo, @End))) t(v))) r0
    CROSS APPLY (SELECT r0.FromD, r0.ToD, CAST(DATEDIFF(DAY, r0.FromD, r0.ToD) + 1 AS DECIMAL(9,4)) AS CoverDays) w
    WHERE sc.EffectiveFrom <= @End AND (sc.EffectiveTo IS NULL OR sc.EffectiveTo >= @Start)
      AND w.CoverDays > 0;

    /* day and hour rates, per employee, from the BASIC component's own currency */
    SELECT x.PayslipId, x.EmployeeId, sc.CurrencyCode,
           CAST(sc.Amount / @DaysPerMonth AS DECIMAL(18,4)) AS DayRate,
           CAST(sc.Amount / @DaysPerMonth / @HoursPerDay AS DECIMAL(18,4)) AS HourRate
    INTO #Rate
    FROM #Emp x
    JOIN hr.SALARY_COMPONENT sc ON sc.EmployeeId=x.EmployeeId
        AND sc.EffectiveFrom <= @End AND (sc.EffectiveTo IS NULL OR sc.EffectiveTo >= @Start)
    JOIN hr.COMPONENT_TYPE ct ON ct.ComponentTypeId=sc.ComponentTypeId AND ct.Name=N'Basic Salary'
    /* script 86: ONE rate per employee — the basic in force on their last day in the period. With two basic rows in the
       month (a raise on the 16th) the join produced two rate rows, and every deduction and overtime line twice. */
    WHERE sc.SalaryComponentId = (SELECT TOP 1 s2.SalaryComponentId
                                  FROM hr.SALARY_COMPONENT s2
                                  JOIN hr.COMPONENT_TYPE c2 ON c2.ComponentTypeId=s2.ComponentTypeId AND c2.Name=N'Basic Salary'
                                  WHERE s2.EmployeeId=x.EmployeeId AND s2.EffectiveFrom <= @End AND (s2.EffectiveTo IS NULL OR s2.EffectiveTo >= @Start)
                                  ORDER BY s2.EffectiveFrom DESC, s2.SalaryComponentId DESC);

    /* ── B. unpaid leave: approved unpaid-type days inside the period ── */
    INSERT INTO payroll.PAYSLIP_LINE
        (PayslipId,ComponentTypeId,ComponentName,Category,[Sign],Amount,CurrencyCode,
         SourceType,SourceId,Quantity,UnitAmount,Note,SortOrder)
    SELECT r.PayslipId, ct.ComponentTypeId, ct.Name, ct.Category, ct.[Sign],
           ROUND(d.DaysInPeriod * r.DayRate, 2), r.CurrencyCode,
           'Leave', d.LeaveRequestId, d.DaysInPeriod, r.DayRate,
           CONCAT(d.DaysInPeriod, N' unpaid day(s)'), 20
    FROM #Rate r
    JOIN (
        SELECT lr.EmployeeId, lr.LeaveRequestId,
               /* script 86 (D2 / D3): what the leave COSTS inside the period — its working days (rest days and public
                  holidays are not unpaid days), half a day for a half-day request */
               CAST(CASE WHEN lr.HalfDay IS NOT NULL THEN 0.5
                         ELSE (SELECT ISNULL(SUM(CAST(ld.Counts AS INT)), 0)
                               FROM hr.fn_LeaveDays(lr.EmployeeId,
                                        CASE WHEN lr.FromDate > @Start THEN lr.FromDate ELSE @Start END,
                                        CASE WHEN lr.ToDate   < @End   THEN lr.ToDate   ELSE @End END) ld) END
                    AS DECIMAL(6,2)) AS DaysInPeriod
        FROM workflow.LEAVE_REQUEST lr
        JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId=lr.RequestInstanceId
        JOIN hr.LEAVE_TYPE lt ON lt.LeaveTypeId=lr.LeaveTypeId
        WHERE ri.[Status]='Approved' AND lt.IsPaid=0
          AND lr.FromDate <= @End AND lr.ToDate >= @Start
    ) d ON d.EmployeeId=r.EmployeeId
    CROSS APPLY (SELECT ComponentTypeId, Name, Category, [Sign]
                 FROM hr.COMPONENT_TYPE WHERE Name=N'Unpaid Leave Deduction') ct
    WHERE d.DaysInPeriod > 0;

    /* ── C. sick partial pay: year-to-date tier allocation ──
       Sick days are numbered across the YEAR by date; each day in THIS period
       costs (1 - its pay percent) of a day. FullPayDays at 100%, then
       HalfPayDays at 50%, then zero. */
    ;WITH sick AS (
        SELECT lr.EmployeeId, lr.FromDate, lr.ToDate,
               ISNULL(lr.DaysApproved, lr.DaysRequested) AS D,
               SUM(ISNULL(lr.DaysApproved, lr.DaysRequested))
                   OVER (PARTITION BY lr.EmployeeId ORDER BY lr.FromDate
                         ROWS UNBOUNDED PRECEDING) AS RunningEnd,
               lr.LeaveRequestId
        FROM workflow.LEAVE_REQUEST lr
        JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId=lr.RequestInstanceId
        JOIN hr.LEAVE_TYPE lt ON lt.LeaveTypeId=lr.LeaveTypeId
        WHERE ri.[Status]='Approved' AND lt.Name=N'Sick'
          AND lr.FromDate >= DATEFROMPARTS(YEAR(@Start),1,1) AND lr.FromDate <= @End
    ), tiered AS (
        SELECT s.EmployeeId, s.LeaveRequestId, s.FromDate,
               s.RunningEnd - s.D AS StartIdx, s.RunningEnd AS EndIdx, s.D,
               t.FullPayDays, t.FullPayDays + t.HalfPayDays AS FullPlusHalf
        FROM sick s
        JOIN hr.EMPLOYEE e ON e.EmployeeId=s.EmployeeId
        CROSS APPLY (
            SELECT TOP 1 pt.FullPayDays, pt.HalfPayDays
            FROM hr.LEAVE_PAY_TIER pt
            JOIN hr.LEAVE_TYPE lt2 ON lt2.LeaveTypeId=pt.LeaveTypeId AND lt2.Name=N'Sick'
            WHERE pt.MinServiceYears <= DATEDIFF(YEAR,e.HireDate,@Start)
            ORDER BY pt.MinServiceYears DESC
        ) t
        WHERE s.FromDate BETWEEN @Start AND @End   -- only this period's requests cost this period
    )
    INSERT INTO payroll.PAYSLIP_LINE
        (PayslipId,ComponentTypeId,ComponentName,Category,[Sign],Amount,CurrencyCode,
         SourceType,SourceId,Quantity,UnitAmount,Note,SortOrder)
    SELECT r.PayslipId, ct.ComponentTypeId, ct.Name, ct.Category, ct.[Sign],
           ROUND(cost.CostDays * r.DayRate, 2), r.CurrencyCode,
           'Leave', td.LeaveRequestId, cost.CostDays, r.DayRate,
           CONCAT(N'Sick pay tiers: ',FORMAT(cost.CostDays,'0.##'),N' day(s) unpaid portion'), 21
    FROM tiered td
    JOIN #Rate r ON r.EmployeeId=td.EmployeeId
    CROSS APPLY (
        SELECT CAST(
            /* half-pay band: days falling between FullPayDays and FullPlusHalf cost 0.5 */
            0.5 * (SELECT MAX(v) FROM (VALUES (0),
                   (IIF(td.EndIdx < td.FullPayDays, 0,
                        IIF(td.StartIdx > td.FullPlusHalf, 0,
                            IIF(td.EndIdx   < td.FullPlusHalf, td.EndIdx,   td.FullPlusHalf)
                          - IIF(td.StartIdx > td.FullPayDays,  td.StartIdx, td.FullPayDays))))) m(v))
            /* zero-pay band: days beyond FullPlusHalf cost 1.0 */
          + 1.0 * (SELECT MAX(v) FROM (VALUES (0),
                   (IIF(td.EndIdx <= td.FullPlusHalf, 0, td.EndIdx
                      - IIF(td.StartIdx > td.FullPlusHalf, td.StartIdx, td.FullPlusHalf)))) z(v))
        AS DECIMAL(6,2)) AS CostDays
    ) cost
    CROSS APPLY (SELECT ComponentTypeId, Name, Category, [Sign]
                 FROM hr.COMPONENT_TYPE WHERE Name=N'Absence Deduction') ct
    WHERE cost.CostDays > 0;

    /* ── D. short days: a WORKED or ABSENT day on a ROSTERED SHIFT whose DayFraction is below 1
          and is not explained by approved leave (script 78, BUG-06).
          Counted:  Status Present / Absent (any worked-or-absent status) with a non-NULL DayFraction,
                    on a date the employee's APPROVED roster gives a real shift (IsRestDay = 0, ShiftId set).
          Never:    RestDay / Leave / Holiday rows (DayFraction NULL since script 76, but excluded by
                    Status too so an old row with DayFraction 0 can no longer cost a day), rows with
                    DayFraction NULL, and days with no rostered shift (no assignment, a rest-day
                    assignment, or a roster month that is not Approved — the roster is inert until then). ── */
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
               /* script 86 (QA2-22): the EXACT share of the day that is missing — shortfall minutes over the day's standard.
                  1 − DayFraction works on a fraction already rounded to 2 decimals: 20 late minutes of 450 came out as 0.04
                  of a day instead of 0.0444. Rounded once, on the money. */
               SUM(CASE WHEN a.ShortfallMinutes > 0 AND a.StandardMinutes > 0
                        THEN CAST(a.ShortfallMinutes AS DECIMAL(18,8)) / a.StandardMinutes
                        ELSE CAST(1 - a.DayFraction AS DECIMAL(18,8)) END) AS MissingDays,
               COUNT(*) AS DaysAffected
        FROM attendance.ATTENDANCE_RECORD a
        JOIN hr.EMPLOYEE e ON e.EmployeeId=a.EmployeeId
        WHERE a.WorkDate BETWEEN @Start AND @UpTo          -- script 81: days after today count as scheduled
          AND a.[Status] NOT IN ('RestDay','Leave','Holiday')
          AND a.DayFraction IS NOT NULL
          AND a.DayFraction < 1
          AND EXISTS (SELECT 1
                      FROM attendance.SHIFT_ASSIGNMENT sa
                      JOIN attendance.ROSTER_MONTH rm
                        ON rm.BranchId=hr.fn_EmployeeBranchOn(a.EmployeeId, a.WorkDate)      -- script 86 (D7): the branch of the DAY
                       AND rm.MonthDate=DATEFROMPARTS(YEAR(a.WorkDate),MONTH(a.WorkDate),1)
                       AND rm.[Status]='Approved'
                      WHERE sa.EmployeeId=a.EmployeeId AND sa.WorkDate=a.WorkDate
                        AND sa.IsRestDay=0 AND sa.ShiftId IS NOT NULL)
          AND NOT EXISTS (SELECT 1 FROM workflow.LEAVE_REQUEST lr
                          JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId=lr.RequestInstanceId
                          WHERE ri.[Status]='Approved' AND lr.EmployeeId=a.EmployeeId
                            AND lr.HalfDay IS NULL          -- script 86 (D3): a HALF-day leave covers half the day; the other half is measured
                            AND a.WorkDate BETWEEN lr.FromDate AND lr.ToDate)
        GROUP BY a.EmployeeId
        HAVING SUM(CASE WHEN a.ShortfallMinutes > 0 AND a.StandardMinutes > 0
                        THEN CAST(a.ShortfallMinutes AS DECIMAL(18,8)) / a.StandardMinutes
                        ELSE CAST(1 - a.DayFraction AS DECIMAL(18,8)) END) > 0.0005
    ) sh ON sh.EmployeeId=r.EmployeeId
    CROSS APPLY (SELECT ComponentTypeId, Name, Category, [Sign]
                 FROM hr.COMPONENT_TYPE WHERE Name=N'Late Deduction') ct;

    /* ── D2. HOLIDAY WORK (script 86, D1): the holiday itself is paid like any day (nothing is deducted for it), so working it
          earns the DIFFERENCE: worked minutes × (day rate ÷ the day's standard minutes) × (HolidayWorkRate − 1). Wage-like:
          it is part of the NSSF / tax base. ── */
    DECLARE @HolidayRate DECIMAL(6,2) = ISNULL(TRY_CAST((SELECT SettingValue FROM core.SETTING WHERE SettingKey='HolidayWorkRate') AS DECIMAL(6,2)), 2.0);
    IF @HolidayRate > 1
        INSERT INTO payroll.PAYSLIP_LINE
            (PayslipId,ComponentTypeId,ComponentName,Category,[Sign],Amount,CurrencyCode,
             SourceType,SourceId,Quantity,UnitAmount,Note,SortOrder)
        SELECT r.PayslipId, ct.ComponentTypeId, ct.Name, ct.Category, ct.[Sign],
               ROUND(hw.PaidShare * r.DayRate * (@HolidayRate - 1), 2), r.CurrencyCode,
               'Attendance', NULL, hw.Minutes, r.DayRate,
               CONCAT(hw.Minutes, N' min worked on ', hw.DaysWorked, N' public holiday(s), premium ', FORMAT(@HolidayRate - 1, '0.##'), N' × the day rate'), 23
        FROM #Rate r
        JOIN (SELECT a.EmployeeId, SUM(a.WorkedMinutes) AS Minutes, COUNT(*) AS DaysWorked,
                     SUM(CAST(a.WorkedMinutes AS DECIMAL(18,8)) / CASE WHEN a.StandardMinutes > 0 THEN a.StandardMinutes ELSE core.fn_StandardDayMinutes() END) AS PaidShare
              FROM attendance.ATTENDANCE_RECORD a
              WHERE a.WorkDate BETWEEN @Start AND @UpTo AND a.[Status] = 'Holiday' AND a.WorkedMinutes > 0
              GROUP BY a.EmployeeId) hw ON hw.EmployeeId = r.EmployeeId
        CROSS APPLY (SELECT ComponentTypeId, Name, Category, [Sign] FROM hr.COMPONENT_TYPE WHERE Name=N'Holiday Work') ct;

    /* an UNPAID public holiday (core.HOLIDAY.IsPaid = 0): nobody is absent, but whoever was rostered to work it loses the day */
    INSERT INTO payroll.PAYSLIP_LINE
        (PayslipId,ComponentTypeId,ComponentName,Category,[Sign],Amount,CurrencyCode,
         SourceType,SourceId,Quantity,UnitAmount,Note,SortOrder)
    SELECT r.PayslipId, ct.ComponentTypeId, ct.Name, ct.Category, ct.[Sign],
           ROUND(uh.Days * r.DayRate, 2), r.CurrencyCode, 'Attendance', NULL, uh.Days, r.DayRate,
           CONCAT(uh.Days, N' unpaid public holiday(s)'), 24
    FROM #Rate r
    JOIN (SELECT sa.EmployeeId, CAST(COUNT(*) AS DECIMAL(6,2)) AS Days
          FROM attendance.SHIFT_ASSIGNMENT sa
          JOIN core.HOLIDAY h ON h.HolidayDate = sa.WorkDate AND h.IsPaid = 0
                             AND (h.BranchId IS NULL OR h.BranchId = hr.fn_EmployeeBranchOn(sa.EmployeeId, sa.WorkDate))
          WHERE sa.WorkDate BETWEEN @Start AND @UpTo AND sa.IsRestDay = 0 AND sa.ShiftId IS NOT NULL
            AND NOT EXISTS (SELECT 1 FROM attendance.ATTENDANCE_RECORD a WHERE a.EmployeeId = sa.EmployeeId AND a.WorkDate = sa.WorkDate AND a.WorkedMinutes > 0)
          GROUP BY sa.EmployeeId) uh ON uh.EmployeeId = r.EmployeeId
    CROSS APPLY (SELECT ComponentTypeId, Name, Category, [Sign] FROM hr.COMPONENT_TYPE WHERE Name=N'Absence Deduction') ct;

    /* ── D3. EXIT PERMISSIONS BEYOND THE LEAVE BALANCE (script 86): at period close the permission minutes are converted to
          leave; what the balance could not cover (ATTENDANCE_RECORD.ExitUnpaidDays) is unpaid — the balance never goes negative. ── */
    INSERT INTO payroll.PAYSLIP_LINE
        (PayslipId,ComponentTypeId,ComponentName,Category,[Sign],Amount,CurrencyCode,
         SourceType,SourceId,Quantity,UnitAmount,Note,SortOrder)
    SELECT r.PayslipId, ct.ComponentTypeId, ct.Name, ct.Category, ct.[Sign],
           ROUND(xu.Days * r.DayRate, 2), r.CurrencyCode, 'ExitPermission', NULL, xu.Days, r.DayRate,
           CONCAT(FORMAT(xu.Days, '0.##'), N' day(s) of exit permissions beyond the leave balance'), 25
    FROM #Rate r
    JOIN (SELECT a.EmployeeId, CAST(SUM(a.ExitUnpaidDays) AS DECIMAL(6,2)) AS Days
          FROM attendance.ATTENDANCE_RECORD a
          WHERE a.WorkDate BETWEEN @Start AND @End AND a.ExitUnpaidDays > 0
          GROUP BY a.EmployeeId) xu ON xu.EmployeeId = r.EmployeeId
    CROSS APPLY (SELECT ComponentTypeId, Name, Category, [Sign] FROM hr.COMPONENT_TYPE WHERE Name=N'Unpaid Leave Deduction') ct
    WHERE xu.Days > 0;

    /* ── E. overtime: payable = LEAST(cap, detected), at the request's multiplier ── */
    INSERT INTO payroll.PAYSLIP_LINE
        (PayslipId,ComponentTypeId,ComponentName,Category,[Sign],Amount,CurrencyCode,
         SourceType,SourceId,Quantity,UnitAmount,Note,SortOrder)
    SELECT r.PayslipId, ct.ComponentTypeId, ct.Name, ct.Category, ct.[Sign],
           ROUND(ot.PayMinutes / 60.0 * r.HourRate * ot.RateMultiplier, 2), r.CurrencyCode,
           'Overtime', ot.OvertimeRequestId, ot.PayMinutes, r.HourRate,
           CONCAT(ot.PayMinutes, N' min at ', FORMAT(ot.RateMultiplier,'0.0#'), N'x'), 30
    FROM #Rate r
    JOIN (
        SELECT o.EmployeeId, o.OvertimeRequestId, o.RateMultiplier,
               CASE WHEN ISNULL(a.OvertimeMinutes,0) < o.ApprovedMinutes
                    THEN ISNULL(a.OvertimeMinutes,0) ELSE o.ApprovedMinutes END AS PayMinutes
        FROM workflow.OVERTIME_REQUEST o
        JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId=o.RequestInstanceId
        LEFT JOIN attendance.ATTENDANCE_RECORD a
               ON a.EmployeeId=o.EmployeeId AND a.WorkDate=o.WorkDate
        WHERE ri.[Status]='Approved' AND o.ApprovedMinutes IS NOT NULL
          AND o.WorkDate BETWEEN @Start AND @End
    ) ot ON ot.EmployeeId=r.EmployeeId
    CROSS APPLY (SELECT ComponentTypeId, Name, Category, [Sign]
                 FROM hr.COMPONENT_TYPE WHERE Name=N'Overtime') ct
    WHERE ot.PayMinutes > 0;

    /* ── F. tips: finalized lines dated in the period, per currency ── */
    INSERT INTO payroll.PAYSLIP_LINE
        (PayslipId,ComponentTypeId,ComponentName,Category,[Sign],Amount,CurrencyCode,
         SourceType,SourceId,Quantity,UnitAmount,Note,SortOrder)
    SELECT x.PayslipId, ct.ComponentTypeId, ct.Name, ct.Category, ct.[Sign],
           t.Amount, t.CurrencyCode, 'Tip', t.TipDistributionId,
           NULL, NULL, CONCAT(t.Shifts, N' shift(s)'), 40
    FROM #Emp x
    JOIN (
        SELECT l.EmployeeId, l.CurrencyCode, SUM(l.Amount) AS Amount,
               COUNT(DISTINCT td.TipDistributionId) AS Shifts,
               MIN(td.TipDistributionId) AS TipDistributionId
        FROM workflow.TIP_DISTRIBUTION_LINE l
        JOIN workflow.TIP_DISTRIBUTION td ON td.TipDistributionId=l.TipDistributionId
        WHERE td.FinalizedAt IS NOT NULL AND td.ShiftDate BETWEEN @Start AND @End
        GROUP BY l.EmployeeId, l.CurrencyCode
    ) t ON t.EmployeeId=x.EmployeeId
    CROSS APPLY (SELECT ComponentTypeId, Name, Category, [Sign]
                 FROM hr.COMPONENT_TYPE WHERE Name=N'Tips') ct;

    /* ── G. expenses: approved and never reimbursed ── */
    INSERT INTO payroll.PAYSLIP_LINE
        (PayslipId,ComponentTypeId,ComponentName,Category,[Sign],Amount,CurrencyCode,
         SourceType,SourceId,Quantity,UnitAmount,Note,SortOrder)
    SELECT x.PayslipId, ct.ComponentTypeId, ct.Name, ct.Category, ct.[Sign],
           ISNULL(er.ApprovedAmount, er.Amount), er.CurrencyCode,
           'Expense', er.ExpenseReimbursementId, NULL, NULL,
           CONCAT(er.Category, N' ', CONVERT(char(10),er.ExpenseDate,23)), 45
    FROM #Emp x
    JOIN workflow.EXPENSE_REIMBURSEMENT er ON er.EmployeeId=x.EmployeeId
    JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId=er.RequestInstanceId
    CROSS APPLY (SELECT ComponentTypeId, Name, Category, [Sign]
                 FROM hr.COMPONENT_TYPE WHERE Name=N'Expense Reimbursement') ct
    WHERE ri.[Status]='Approved' AND er.ReimbursedInPayrollAt IS NULL;

    /* ── H. advances: moved below the statutory lines (script 86, D8) — an instalment is capped at the net, which is only known there ── */

    /* ── I. adjustments targeted at this period, not yet applied ──
          script 81: and NOT CLAIMED BY AN OPEN SUPPLEMENTAL. A supplemental may now exist before the
          primary is locked; whatever sits on its payslips is the supplemental's to pay, so the primary
          leaves it out (and picks it up again on a regenerate if that supplemental is cancelled).
          Once the supplemental is approved the adjustment is consumed and the first filter excludes it. ── */
    INSERT INTO payroll.PAYSLIP_LINE
        (PayslipId,ComponentTypeId,ComponentName,Category,[Sign],Amount,CurrencyCode,
         SourceType,SourceId,Quantity,UnitAmount,Note,SortOrder)
    SELECT x.PayslipId, ct.ComponentTypeId, ct.Name, ct.Category, ct.[Sign],
           adj.Amount, adj.CurrencyCode, 'Adjustment', adj.PayrollAdjustmentId,
           NULL, NULL, adj.Reason, 55
    FROM #Emp x
    JOIN payroll.PAYROLL_ADJUSTMENT adj ON adj.EmployeeId=x.EmployeeId
    JOIN hr.COMPONENT_TYPE ct ON ct.ComponentTypeId=adj.ComponentTypeId
    WHERE adj.TargetPeriod=@Period AND adj.AppliedToPayslipId IS NULL
      AND NOT EXISTS (SELECT 1
                      FROM payroll.PAYSLIP_LINE sl
                      JOIN payroll.PAYSLIP sp ON sp.PayslipId=sl.PayslipId
                      JOIN payroll.PAYROLL_RUN sr ON sr.PayrollRunId=sp.PayrollRunId
                      WHERE sl.SourceType='Adjustment' AND sl.SourceId=adj.PayrollAdjustmentId
                        AND sr.PayrollRunId<>@PayrollRunId
                        AND sr.RunType='Supplemental' AND sr.[Status] IN ('Draft','Review'));

    /* ── J. separation settlements landing in this period ── */
    INSERT INTO payroll.PAYSLIP_LINE
        (PayslipId,ComponentTypeId,ComponentName,Category,[Sign],Amount,CurrencyCode,
         SourceType,SourceId,Quantity,UnitAmount,Note,SortOrder)
    SELECT x.PayslipId, ct.ComponentTypeId, ct.Name, ct.Category, ct.[Sign],
           v.Amount, s.CurrencyCode, 'Separation', s.SeparationId,
           NULL, NULL, v.Note, 60
    FROM #Emp x
    JOIN workflow.SEPARATION s ON s.EmployeeId=x.EmployeeId
    JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId=s.RequestInstanceId
    CROSS APPLY (VALUES
        (N'Unused Leave Payout',       s.UnusedLeaveAmount, CONCAT(FORMAT(s.UnusedLeaveDays,'0.##'),N' day(s)')),
        (N'End-of-Service Indemnity',  s.IndemnityAmount,   CONCAT(FORMAT(s.ServiceYears,'0.##'),N' year(s) of service')),
        (N'Overtime',                  NULL, NULL),   -- placeholder row skipped below
        (N'Expense Reimbursement',     s.OtherDues,         N'Other dues on separation'),
        (N'Absence Deduction',         s.Deductions,        N'Deductions on separation')
    ) v(CtName, Amount, Note)
    JOIN hr.COMPONENT_TYPE ct ON ct.Name=v.CtName
    LEFT JOIN (VALUES (0)) noticeDummy(z) ON 1=0
    WHERE ri.[Status]='Approved' AND s.PreparedAt IS NOT NULL
      AND s.LastWorkingDate BETWEEN @Start AND @End
      AND v.Amount IS NOT NULL AND v.Amount > 0;
    /* notice pay in lieu, its own line */
    INSERT INTO payroll.PAYSLIP_LINE
        (PayslipId,ComponentTypeId,ComponentName,Category,[Sign],Amount,CurrencyCode,
         SourceType,SourceId,Quantity,UnitAmount,Note,SortOrder)
    SELECT x.PayslipId, ct.ComponentTypeId, ct.Name, ct.Category, ct.[Sign],
           s.NoticePayAmount, s.CurrencyCode, 'Separation', s.SeparationId,
           NULL, NULL, CONCAT(N'Pay in lieu of ',s.NoticeShortfallDays,N' notice day(s)'), 61
    FROM #Emp x
    JOIN workflow.SEPARATION s ON s.EmployeeId=x.EmployeeId
    JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId=s.RequestInstanceId
    CROSS APPLY (SELECT ComponentTypeId, Name, Category, [Sign]
                 FROM hr.COMPONENT_TYPE WHERE Name=N'Basic Salary') ct
    WHERE ri.[Status]='Approved' AND s.PreparedAt IS NOT NULL
      AND s.LastWorkingDate BETWEEN @Start AND @End
      AND ISNULL(s.NoticePayAmount,0) > 0;

    /* ── J2. LEAVE BALANCE ON TERMINATION (script 86, D5; setting LeavePayoutOnTermination, default 1) ──
          The payslip of the month an employee leaves settles the leave balance of every paid, accruing type at the day
          rate: "Leave Balance Payout" when days are left, "Leave Balance Deduction" when more was taken than was earned.
          The balance is the ledger as it stands. Not when an approved separation settlement landing in the period
          already pays its own "Unused Leave Payout" (section J) — a balance is settled once. Like that line, it is a
          settlement, not a wage: outside the NSSF / tax base. ── */
    IF ISNULL((SELECT SettingValue FROM core.SETTING WHERE SettingKey='LeavePayoutOnTermination'), '1') = '1'
        INSERT INTO payroll.PAYSLIP_LINE
            (PayslipId,ComponentTypeId,ComponentName,Category,[Sign],Amount,CurrencyCode,
             SourceType,SourceId,Quantity,UnitAmount,Note,SortOrder)
        SELECT r.PayslipId, ct.ComponentTypeId, ct.Name, ct.Category, ct.[Sign],
               ROUND(ABS(b.Balance) * r.DayRate, 2), r.CurrencyCode, 'LeavePayout', NULL, ABS(b.Balance), r.DayRate,
               CONCAT(CASE WHEN b.Balance > 0 THEN N'Unused leave on leaving (' ELSE N'Leave taken beyond the balance on leaving (' END,
                      FORMAT(ABS(b.Balance), '0.##'), N' day(s) × the day rate), last day ', CONVERT(NVARCHAR(10), x.TerminationDate, 23)), 62
        FROM #Emp x
        JOIN #Rate r ON r.EmployeeId = x.EmployeeId
        CROSS APPLY (SELECT CAST(SUM(l.Days) AS DECIMAL(9,2)) AS Balance
                     FROM hr.LEAVE_LEDGER l
                     JOIN hr.LEAVE_TYPE lt ON lt.LeaveTypeId = l.LeaveTypeId AND lt.IsPaid = 1
                     WHERE l.EmployeeId = x.EmployeeId
                       AND EXISTS (SELECT 1 FROM hr.LEAVE_ACCRUAL_TIER t WHERE t.LeaveTypeId = l.LeaveTypeId)) b
        CROSS APPLY (SELECT ComponentTypeId, Name, Category, [Sign] FROM hr.COMPONENT_TYPE
                     WHERE Name = CASE WHEN b.Balance > 0 THEN N'Leave Balance Payout' ELSE N'Leave Balance Deduction' END) ct
        WHERE x.TerminationDate BETWEEN @Start AND @End
          AND b.Balance IS NOT NULL AND b.Balance <> 0
          AND NOT EXISTS (SELECT 1 FROM workflow.SEPARATION s
                          JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = s.RequestInstanceId
                          WHERE s.EmployeeId = x.EmployeeId AND ri.[Status] = 'Approved' AND s.PreparedAt IS NOT NULL
                            AND s.LastWorkingDate BETWEEN @Start AND @End AND ISNULL(s.UnusedLeaveAmount, 0) > 0);

    /* ── K. STATUTORY: NSSF then tax, on the wage-like base in primary ──
       Base = Earning lines from Salary/Overtime/Leave/Attendance sources
       (i.e., wages) minus their deductions - NOT tips, expenses or separation
       payouts. Your accountant may widen or narrow this: edit here. */
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
    JOIN hr.NSSF_RATE nr ON nr.EffectiveFrom <= @End
                         AND (nr.EffectiveTo IS NULL OR nr.EffectiveTo >= @Start)
    CROSS APPLY (SELECT ComponentTypeId, Name, Category, [Sign]
                 FROM hr.COMPONENT_TYPE WHERE Name=N'NSSF Employee Share') ct
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
    JOIN hr.NSSF_RATE nr ON nr.EffectiveFrom <= @End
                         AND (nr.EffectiveTo IS NULL OR nr.EffectiveTo >= @Start)
    CROSS APPLY (SELECT ComponentTypeId, Name, Category, [Sign]
                 FROM hr.COMPONENT_TYPE WHERE Name=N'NSSF Employer Share') ct
    WHERE nb.BaseP > 0
    GROUP BY nb.PayslipId, ct.ComponentTypeId, ct.Name, ct.Category, ct.[Sign]
    HAVING SUM(CASE WHEN nr.IsCeilinged=1 AND nb.BaseP > ISNULL(nr.CeilingAmount, @Ceiling)
                    THEN ISNULL(nr.CeilingAmount, @Ceiling) ELSE nb.BaseP END * nr.EmployerRate) > 0;

    /* income tax: (base - employee NSSF) x 12, family deduction, brackets, /12 */
    ;WITH taxable AS (
        SELECT nb.PayslipId,
               (nb.BaseP - ISNULL(nssf.Amt,0)) * 12 - @FamilyDed AS AnnualTaxable
        FROM #NssfBase nb
        OUTER APPLY (SELECT SUM(l.Amount) AS Amt FROM payroll.PAYSLIP_LINE l
                     JOIN hr.COMPONENT_TYPE c2 ON c2.ComponentTypeId=l.ComponentTypeId
                     WHERE l.PayslipId=nb.PayslipId AND c2.Name=N'NSSF Employee Share') nssf
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
                          AND b.EffectiveFrom <= @End
                          AND (b.EffectiveTo IS NULL OR b.EffectiveTo >= @Start)
    CROSS APPLY (SELECT ComponentTypeId, Name, Category, [Sign]
                 FROM hr.COMPONENT_TYPE WHERE Name=N'Income Tax') ct
    WHERE t.AnnualTaxable > 0
    GROUP BY t.PayslipId, ct.ComponentTypeId, ct.Name, ct.Category, ct.[Sign]
    HAVING SUM((CASE WHEN t.AnnualTaxable > ISNULL(b.MaxAnnual, t.AnnualTaxable)
                     THEN ISNULL(b.MaxAnnual, t.AnnualTaxable) ELSE t.AnnualTaxable END
                - b.MinAnnual) * b.Rate) / 12 >= 0.01;

    /* ── H. ADVANCES, LAST (script 86, D8): MIN(monthly, remaining) — AND NEVER MORE THAN THE NET. The instalment used to be
          taken whole: 2000 off a net of 951.20 made a payslip of −1048.80. It is capped at what is left of the payslip in
          the advance's currency after every other line (several advances: oldest first); the rest stays on the advance and
          is recovered from the next run. The balance still moves only at lock, by the amount on the line. ── */
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
    CROSS APPLY (SELECT ComponentTypeId, Name, Category, [Sign]
                 FROM hr.COMPONENT_TYPE WHERE Name=N'Advance Repayment') ct
    WHERE c.Taken > 0;

    /* ── totals, attendance story, comparable net, warnings ── */
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

    UPDATE ps SET
        NetPrimary = payroll.fn_ToPrimary(@PayrollRunId, ps.NetUsd, 'USD')
                   + payroll.fn_ToPrimary(@PayrollRunId, ps.NetLbp, 'LBP'),
        PaidDayFraction = att.Paid, UnpaidLeaveDays = lv.Unpaid,
        PaidLeaveDays = lv.Paid, OvertimeMinutes = ot.Mins
    FROM payroll.PAYSLIP ps
    OUTER APPLY (SELECT CAST(SUM(a.DayFraction) AS DECIMAL(6,2)) AS Paid
                 FROM attendance.ATTENDANCE_RECORD a
                 WHERE a.EmployeeId=ps.EmployeeId AND a.WorkDate BETWEEN @Start AND @End) att
    OUTER APPLY (SELECT
                 SUM(IIF(lt.IsPaid=0, dd.D, 0)) AS Unpaid,
                 SUM(IIF(lt.IsPaid=1, dd.D, 0)) AS Paid
                 FROM workflow.LEAVE_REQUEST lr
                 JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId=lr.RequestInstanceId
                 JOIN hr.LEAVE_TYPE lt ON lt.LeaveTypeId=lr.LeaveTypeId
                 CROSS APPLY (SELECT CAST(DATEDIFF(DAY,
                      IIF(lr.FromDate>@Start,lr.FromDate,@Start),
                      IIF(lr.ToDate<@End,lr.ToDate,@End))+1 AS DECIMAL(6,2)) AS D) dd
                 WHERE ri.[Status]='Approved' AND lr.EmployeeId=ps.EmployeeId
                   AND lr.FromDate<=@End AND lr.ToDate>=@Start) lv
    OUTER APPLY (SELECT SUM(l.Quantity) AS Mins FROM payroll.PAYSLIP_LINE l
                 WHERE l.PayslipId=ps.PayslipId AND l.SourceType='Overtime') ot
    WHERE ps.PayrollRunId=@PayrollRunId;

    UPDATE ps SET Notes = LTRIM(CONCAT(
        IIF(NOT EXISTS (SELECT 1 FROM payroll.PAYSLIP_LINE l
                        JOIN hr.COMPONENT_TYPE c ON c.ComponentTypeId=l.ComponentTypeId
                        WHERE l.PayslipId=ps.PayslipId AND c.Name=N'Basic Salary'),
            N' NO BASIC SALARY ON FILE.', N''),
        IIF(ps.NetUsd < 0 OR ps.NetLbp < 0, N' NEGATIVE NET - review deductions.', N'')))
    FROM payroll.PAYSLIP ps WHERE ps.PayrollRunId=@PayrollRunId;

    UPDATE payroll.PAYROLL_RUN SET GeneratedAt=SYSUTCDATETIME() WHERE PayrollRunId=@PayrollRunId;

    DECLARE @Count INT=(SELECT COUNT(*) FROM payroll.PAYSLIP WHERE PayrollRunId=@PayrollRunId);
    DECLARE @Warn INT=(SELECT COUNT(*) FROM payroll.PAYSLIP
                       WHERE PayrollRunId=@PayrollRunId AND Notes IS NOT NULL AND Notes<>N'');
    INSERT INTO payroll.PAYROLL_RUN_EVENT (PayrollRunId,[Action],ActedByUserId,Detail)
    VALUES (@PayrollRunId,'Generated',@ActedByUserId,
            CONCAT(@Count,N' payslip(s), ',@Warn,N' with warnings',
                   CASE WHEN @UpTo < @End THEN CONCAT(N'; attendance counted up to ',CONVERT(NVARCHAR(10),@UpTo,23),N', later days as scheduled') ELSE N'' END));
    COMMIT TRAN;

    SELECT @PayrollRunId AS PayrollRunId, @Count AS PayslipCount, @Warn AS PayslipsWithWarnings;
END;
GO

/* ───────────────────────── 5. verification ───────────────────────── */
DECLARE @c INT = (SELECT COUNT(*) FROM hr.COMPONENT_TYPE WHERE Name IN (N'Holiday Work', N'Leave Balance Payout', N'Leave Balance Deduction'));
PRINT CONCAT('new component types = ', @c, ' (expected 3); ExitUnpaidDays column = ', CASE WHEN COL_LENGTH('attendance.ATTENDANCE_RECORD', 'ExitUnpaidDays') IS NULL THEN 'missing' ELSE 'present' END);
PRINT 'Script 86 applied.';
GO
