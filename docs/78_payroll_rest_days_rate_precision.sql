/* ============================================================================
   78_payroll_rest_days_rate_precision.sql — QA fix pack Q3.

   BUG-06 (blocker)  Every employee lost one day of pay per rest day. Section D of
                     payroll.usp_PayrollRun_Generate deducted (1 − DayFraction) × DayRate for EVERY
                     attendance record with DayFraction < 1, and MarkAbsentees used to write RestDay
                     rows with DayFraction 0. Section D now counts only worked / absent days on a
                     ROSTERED SHIFT: Status NOT IN ('RestDay','Leave','Holiday'), DayFraction NOT NULL,
                     and a shift (IsRestDay = 0, ShiftId set) in an APPROVED roster month. The line text
                     "N day(s) short across M date(s)" is unchanged, computed from the filtered set.

   BUG-07 (blocker)  The LBP→USD run rate was stored as 0. PAYROLL_RUN_RATE.Rate was DECIMAL(18,4) and
                     usp_PayrollRun_Create stored 1.0/90000 = 0.0000111… → 0.0000, so every LBP amount
                     became 0 USD (fn_ToPrimary(17, 6000000, 'LBP') = 0.00; NSSF and tax bases missed the
                     LBP allowance). The column is widened to DECIMAL(28,12); the snapshot is stored at
                     full precision; fn_RunRate returns DECIMAL(28,12) and fn_ToPrimary multiplies at
                     that precision before rounding to cents. Existing rows (runs 17 and 18) are NOT
                     rewritten: a locked run is never altered — docs/payroll_run_compare.sql shows what
                     they would have been, and HR settles the differences through a supplemental.
                     No object is schema-bound to the column, so nothing has to be dropped; the two
                     functions and the two procedures are re-created here regardless.

   BUG-18 (major)    A run created without runType took the supplemental path: the API passed NULL and
                     IF @RunType = 'Primary' is false for NULL. The procedure now defaults
                     SET @RunType = ISNULL(@RunType, 'Primary') and still refuses any other value; the DTO
                     and the service default to 'Primary' as well and reject other values with a 400.

   BUG-17 (minor)    core.SETTING TaxFamilyDeductionAnnualUsd is read by the generator but did not exist,
                     so nothing on the Settings page could change it. Idempotent insert, Section Payroll,
                     default '0'.

   Idempotent: re-running the script is harmless. Backward compatible with the running API build
   (PayrollRunRate.Rate is a System.Decimal; widening the SQL precision is transparent to Dapper).
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/* ───────────────────────── 1. BUG-17: the family deduction setting ───────────────────────── */
IF NOT EXISTS (SELECT 1 FROM core.SETTING WHERE SettingKey = 'TaxFamilyDeductionAnnualUsd')
BEGIN
    INSERT INTO core.SETTING (SettingKey, SettingValue, DataType, [Description], Section, SortOrder, ModifiedAt)
    VALUES ('TaxFamilyDeductionAnnualUsd', '0', 'decimal',
            N'Annual family/personal income-tax deduction in USD (Lebanese law); 0 = none.',
            'Payroll', 45, NULL);
    PRINT 'core.SETTING: TaxFamilyDeductionAnnualUsd added (Payroll, default 0).';
END
ELSE
    PRINT 'core.SETTING: TaxFamilyDeductionAnnualUsd already present.';
GO

/* ───────────────────────── 2. BUG-07: the rate column keeps its precision ───────────────────────── */
IF EXISTS (SELECT 1 FROM sys.columns c
           WHERE c.object_id = OBJECT_ID('payroll.PAYROLL_RUN_RATE') AND c.name = 'Rate'
             AND NOT (c.precision = 28 AND c.scale = 12))
BEGIN
    /* Nothing is schema-bound to the column (fn_RunRate, usp_PayrollRun_Create and usp_PayrollRun_Get
       reference it without SCHEMABINDING, and no index or constraint includes it), so ALTER COLUMN
       is enough. Existing values are widened unchanged: run 17/18 keep their 0.0000 snapshot. */
    ALTER TABLE payroll.PAYROLL_RUN_RATE ALTER COLUMN Rate DECIMAL(28,12) NOT NULL;
    PRINT 'payroll.PAYROLL_RUN_RATE.Rate widened to DECIMAL(28,12).';
END
ELSE
    PRINT 'payroll.PAYROLL_RUN_RATE.Rate is already DECIMAL(28,12).';
GO

/* ───────────────────────── 3. BUG-07: the helpers read it at full precision ───────────────────────── */
CREATE OR ALTER FUNCTION payroll.fn_RunRate (@PayrollRunId INT, @FromCcy CHAR(3), @ToCcy CHAR(3))
RETURNS DECIMAL(28,12)
AS
BEGIN
    IF @FromCcy = @ToCcy RETURN 1;
    DECLARE @r DECIMAL(28,12) =
        (SELECT Rate FROM payroll.PAYROLL_RUN_RATE
         WHERE PayrollRunId=@PayrollRunId AND FromCurrency=@FromCcy AND ToCurrency=@ToCcy);
    IF @r IS NULL
        SET @r = (SELECT CAST(1.0/Rate AS DECIMAL(28,12)) FROM payroll.PAYROLL_RUN_RATE
                  WHERE PayrollRunId=@PayrollRunId AND FromCurrency=@ToCcy AND ToCurrency=@FromCcy
                    AND Rate <> 0);
    RETURN @r;   -- NULL means the pair was never snapshotted: a generation error
END;
GO

CREATE OR ALTER FUNCTION payroll.fn_ToPrimary (@PayrollRunId INT, @Amount DECIMAL(18,2), @Ccy CHAR(3))
RETURNS DECIMAL(18,2)
AS
BEGIN
    DECLARE @p CHAR(3) = (SELECT PrimaryCurrency FROM payroll.PAYROLL_RUN WHERE PayrollRunId=@PayrollRunId);
    /* DECIMAL(18,2) × DECIMAL(19,12) = DECIMAL(38,14): the product keeps all twelve decimals of the
       rate, so 6,000,000 LBP × 0.000011111111 = 66.666666 → 66.67, and only the final figure is
       rounded to cents. (Without the CAST the product would overflow precision 38 and SQL Server
       would silently drop decimals from the rate.) */
    RETURN ROUND(@Amount * CAST(payroll.fn_RunRate(@PayrollRunId,@Ccy,@p) AS DECIMAL(19,12)), 2);
END;
GO

/* ───────────────────────── 4. BUG-18 + BUG-07: usp_PayrollRun_Create ─────────────────────────
   Body as live (script 77: 11-column readiness capture, undecided-anomaly refusal) plus the RunType
   default and the full-precision rate snapshot. */
CREATE OR ALTER PROCEDURE payroll.usp_PayrollRun_Create
    @PeriodYearMonth CHAR(7), @CreatedByUserId INT,
    @Notes NVARCHAR(500)=NULL, @RunType VARCHAR(12)='Primary'
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;

    /* script 78 (BUG-18): an explicit NULL or blank from the API means "the default", i.e. Primary.
       The parameter default only covers a caller that omits the argument. */
    SET @RunType = ISNULL(NULLIF(LTRIM(RTRIM(@RunType)), ''), 'Primary');

    IF payroll.fn_UserHasRole(@CreatedByUserId, N'HR') = 0
       AND payroll.fn_UserHasRole(@CreatedByUserId, N'Admin') = 0
    BEGIN RAISERROR('Payroll runs are prepared by HR.',16,1); RETURN; END
    IF @RunType NOT IN ('Primary','Supplemental')
    BEGIN RAISERROR('RunType is Primary or Supplemental.',16,1); RETURN; END
    IF @PeriodYearMonth NOT LIKE '[12][0-9][0-9][0-9]-[01][0-9]'
    BEGIN RAISERROR('The period must look like 2026-08.',16,1); RETURN; END

    DECLARE @Start DATE = CAST(@PeriodYearMonth + '-01' AS DATE);
    DECLARE @End   DATE = EOMONTH(@Start);

    IF @RunType = 'Primary'
    BEGIN
        IF EXISTS (SELECT 1 FROM payroll.PAYROLL_RUN
                   WHERE PeriodYearMonth=@PeriodYearMonth
                     AND RunType='Primary' AND [Status] <> 'Cancelled')
        BEGIN
            DECLARE @P1 CHAR(7)=@PeriodYearMonth;
            RAISERROR('A primary run for %s already exists. Cancel it first if it must be redone.',16,1,@P1);
            RETURN;
        END
        DECLARE @Ready TABLE (PeriodYearMonth CHAR(7), PeriodStart DATE, PeriodEnd DATE,
            UnprocessedPunches INT, UnresolvedPinPunches INT, OpenAnomalies INT,
            PendingCorrections INT, RosteredDaysWithNoRecord INT, UndecidedExitVariances INT,
            UndecidedAnomalies INT, IsReady BIT);
        INSERT INTO @Ready EXEC attendance.usp_Attendance_PayrollReadiness @PeriodYearMonth;
        /* script 77: undecided late / early / missing-punch anomalies are named first, with their count */
        DECLARE @Undecided INT = (SELECT UndecidedAnomalies FROM @Ready);
        IF @Undecided > 0
        BEGIN
            DECLARE @P2a CHAR(7)=@PeriodYearMonth;
            DECLARE @Plural VARCHAR(3) = CASE WHEN @Undecided = 1 THEN 'y' ELSE 'ies' END;
            RAISERROR('Attendance for %s has %d undecided anomal%s (late arrival, early departure or missing punch). Decide them in Attendance > Anomalies before running payroll.',16,1,@P2a,@Undecided,@Plural);
            RETURN;
        END
        IF (SELECT IsReady FROM @Ready) = 0
        BEGIN
            DECLARE @P2 CHAR(7)=@PeriodYearMonth;
            RAISERROR('Attendance for %s is not ready for payroll. Open the readiness check and clear the counts.',16,1,@P2);
            RETURN;
        END
    END
    ELSE
    BEGIN
        /* a supplemental follows a LOCKED primary, and pays only signed corrections */
        IF NOT EXISTS (SELECT 1 FROM payroll.PAYROLL_RUN
                       WHERE PeriodYearMonth=@PeriodYearMonth
                         AND RunType='Primary' AND [Status]='Approved')
        BEGIN
            DECLARE @P3 CHAR(7)=@PeriodYearMonth;
            RAISERROR('A supplemental follows an approved primary. The %s primary is not locked yet - put the money in it and regenerate.',16,1,@P3);
            RETURN;
        END
        IF EXISTS (SELECT 1 FROM payroll.PAYROLL_RUN
                   WHERE PeriodYearMonth=@PeriodYearMonth
                     AND RunType='Supplemental' AND [Status] IN ('Draft','Review'))
        BEGIN RAISERROR('An open supplemental for this period already exists - finish or cancel it first.',16,1); RETURN; END
        IF NOT EXISTS (SELECT 1 FROM payroll.PAYROLL_ADJUSTMENT
                       WHERE TargetPeriod=@PeriodYearMonth AND AppliedToPayslipId IS NULL)
        BEGIN RAISERROR('No approved, unconsumed adjustments target this period - there is nothing for a supplemental to pay.',16,1); RETURN; END
    END

    DECLARE @Primary CHAR(3) = ISNULL((SELECT SettingValue FROM core.SETTING
                                       WHERE SettingKey='PayrollPrimaryCurrency'),'USD');
    DECLARE @RateType VARCHAR(20) = ISNULL((SELECT SettingValue FROM core.SETTING
                                            WHERE SettingKey='PayrollRateType'),'Official');

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
               /* script 78 (BUG-07): the inverse is kept at full precision — 1/90000 = 0.000011111111,
                  which DECIMAL(18,4) used to round to 0.0000 and so priced every LBP amount at 0 */
               CAST(CASE WHEN er.FromCurrency=c.CurrencyCode THEN er.Rate ELSE 1.0/er.Rate END AS DECIMAL(28,12)) AS Rate,
               er.RateType, er.EffectiveDate
        FROM core.EXCHANGE_RATE er
        WHERE ((er.FromCurrency=c.CurrencyCode AND er.ToCurrency=@Primary)
            OR (er.FromCurrency=@Primary AND er.ToCurrency=c.CurrencyCode))
          AND er.RateType=@RateType AND er.EffectiveDate <= @End
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
            RETURN;
        END
    END

    INSERT INTO payroll.PAYROLL_RUN_EVENT (PayrollRunId,[Action],ActedByUserId,Detail)
    VALUES (@RunId,'Created',@CreatedByUserId,
            CONCAT(@RunType,N' run for ',@PeriodYearMonth,N', rates frozen'));
    COMMIT TRAN;

    SELECT @RunId AS PayrollRunId, @PeriodYearMonth AS PeriodYearMonth,
           'Draft' AS [Status], @Primary AS PrimaryCurrency, @RunType AS RunType;
END;
GO

/* ───────────────────────── 5. BUG-06: usp_PayrollRun_Generate ─────────────────────────
   Body as live (own NSSF ceilings per scheme) with section D restricted to worked/absent days on a
   rostered shift. */
CREATE OR ALTER PROCEDURE payroll.usp_PayrollRun_Generate
    @PayrollRunId INT, @ActedByUserId INT
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

    /* ── A. standing components, prorated by coverage ── */
    INSERT INTO payroll.PAYSLIP_LINE
        (PayslipId,ComponentTypeId,ComponentName,Category,[Sign],Amount,CurrencyCode,
         SourceType,SourceId,Quantity,UnitAmount,Note,SortOrder)
    SELECT x.PayslipId, ct.ComponentTypeId, ct.Name, ct.Category, ct.[Sign],
           ROUND(sc.Amount * x.Coverage, 2), sc.CurrencyCode,
           'Salary', sc.SalaryComponentId, NULL, NULL,
           CASE WHEN x.Coverage < 1 THEN CONCAT(N'Prorated ',FORMAT(x.Coverage,'0.00'),N' of the month') END,
           10
    FROM #Emp x
    JOIN hr.SALARY_COMPONENT sc ON sc.EmployeeId=x.EmployeeId
    JOIN hr.COMPONENT_TYPE ct ON ct.ComponentTypeId=sc.ComponentTypeId AND ct.IsStanding=1
    WHERE sc.EffectiveFrom <= @End AND (sc.EffectiveTo IS NULL OR sc.EffectiveTo >= @Start);

    /* day and hour rates, per employee, from the BASIC component's own currency */
    SELECT x.PayslipId, x.EmployeeId, sc.CurrencyCode,
           CAST(sc.Amount / @DaysPerMonth AS DECIMAL(18,4)) AS DayRate,
           CAST(sc.Amount / @DaysPerMonth / @HoursPerDay AS DECIMAL(18,4)) AS HourRate
    INTO #Rate
    FROM #Emp x
    JOIN hr.SALARY_COMPONENT sc ON sc.EmployeeId=x.EmployeeId
        AND sc.EffectiveFrom <= @End AND (sc.EffectiveTo IS NULL OR sc.EffectiveTo >= @Start)
    JOIN hr.COMPONENT_TYPE ct ON ct.ComponentTypeId=sc.ComponentTypeId AND ct.Name=N'Basic Salary';

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
               CAST(DATEDIFF(DAY,
                    CASE WHEN lr.FromDate > @Start THEN lr.FromDate ELSE @Start END,
                    CASE WHEN lr.ToDate   < @End   THEN lr.ToDate   ELSE @End END) + 1
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
               CAST(SUM(1 - a.DayFraction) AS DECIMAL(6,2)) AS MissingDays,
               COUNT(*) AS DaysAffected
        FROM attendance.ATTENDANCE_RECORD a
        JOIN hr.EMPLOYEE e ON e.EmployeeId=a.EmployeeId
        WHERE a.WorkDate BETWEEN @Start AND @End
          AND a.[Status] NOT IN ('RestDay','Leave','Holiday')
          AND a.DayFraction IS NOT NULL
          AND a.DayFraction < 1
          AND EXISTS (SELECT 1
                      FROM attendance.SHIFT_ASSIGNMENT sa
                      JOIN attendance.ROSTER_MONTH rm
                        ON rm.BranchId=e.BranchId
                       AND rm.MonthDate=DATEFROMPARTS(YEAR(a.WorkDate),MONTH(a.WorkDate),1)
                       AND rm.[Status]='Approved'
                      WHERE sa.EmployeeId=a.EmployeeId AND sa.WorkDate=a.WorkDate
                        AND sa.IsRestDay=0 AND sa.ShiftId IS NOT NULL)
          AND NOT EXISTS (SELECT 1 FROM workflow.LEAVE_REQUEST lr
                          JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId=lr.RequestInstanceId
                          WHERE ri.[Status]='Approved' AND lr.EmployeeId=a.EmployeeId
                            AND a.WorkDate BETWEEN lr.FromDate AND lr.ToDate)
        GROUP BY a.EmployeeId
        HAVING SUM(1 - a.DayFraction) > 0.01
    ) sh ON sh.EmployeeId=r.EmployeeId
    CROSS APPLY (SELECT ComponentTypeId, Name, Category, [Sign]
                 FROM hr.COMPONENT_TYPE WHERE Name=N'Late Deduction') ct;

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

    /* ── H. advances: MIN(monthly, remaining); balance moves only at lock ── */
    INSERT INTO payroll.PAYSLIP_LINE
        (PayslipId,ComponentTypeId,ComponentName,Category,[Sign],Amount,CurrencyCode,
         SourceType,SourceId,Quantity,UnitAmount,Note,SortOrder)
    SELECT x.PayslipId, ct.ComponentTypeId, ct.Name, ct.Category, ct.[Sign],
           CASE WHEN a.MonthlyDeduction < a.RemainingAmount
                THEN a.MonthlyDeduction ELSE a.RemainingAmount END,
           a.CurrencyCode, 'Advance', a.SalaryAdvanceId, NULL, NULL,
           CONCAT(N'Remaining after this: ',
                  FORMAT(a.RemainingAmount - CASE WHEN a.MonthlyDeduction < a.RemainingAmount
                       THEN a.MonthlyDeduction ELSE a.RemainingAmount END,'0.00')), 50
    FROM #Emp x
    JOIN payroll.SALARY_ADVANCE a ON a.EmployeeId=x.EmployeeId
    CROSS APPLY (SELECT ComponentTypeId, Name, Category, [Sign]
                 FROM hr.COMPONENT_TYPE WHERE Name=N'Advance Repayment') ct
    WHERE a.IsSettled=0 AND a.RemainingAmount > 0 AND a.FirstDeductionPeriod <= @Period;

    /* ── I. adjustments targeted at this period, not yet applied ── */
    INSERT INTO payroll.PAYSLIP_LINE
        (PayslipId,ComponentTypeId,ComponentName,Category,[Sign],Amount,CurrencyCode,
         SourceType,SourceId,Quantity,UnitAmount,Note,SortOrder)
    SELECT x.PayslipId, ct.ComponentTypeId, ct.Name, ct.Category, ct.[Sign],
           adj.Amount, adj.CurrencyCode, 'Adjustment', adj.PayrollAdjustmentId,
           NULL, NULL, adj.Reason, 55
    FROM #Emp x
    JOIN payroll.PAYROLL_ADJUSTMENT adj ON adj.EmployeeId=x.EmployeeId
    JOIN hr.COMPONENT_TYPE ct ON ct.ComponentTypeId=adj.ComponentTypeId
    WHERE adj.TargetPeriod=@Period AND adj.AppliedToPayslipId IS NULL;

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

    /* ── K. STATUTORY: NSSF then tax, on the wage-like base in primary ──
       Base = Earning lines from Salary/Overtime/Leave/Attendance sources
       (i.e., wages) minus their deductions - NOT tips, expenses or separation
       payouts. Your accountant may widen or narrow this: edit here. */
    SELECT l.PayslipId,
           SUM(payroll.fn_ToPrimary(@PayrollRunId, l.Amount, l.CurrencyCode) * l.[Sign]) AS BaseP
    INTO #NssfBase
    FROM payroll.PAYSLIP_LINE l
    JOIN payroll.PAYSLIP ps ON ps.PayslipId=l.PayslipId AND ps.PayrollRunId=@PayrollRunId
    WHERE l.SourceType IN ('Salary','Overtime','Leave','Attendance')
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
            CONCAT(@Count,N' payslip(s), ',@Warn,N' with warnings'));
    COMMIT TRAN;

    SELECT @PayrollRunId AS PayrollRunId, @Count AS PayslipCount, @Warn AS PayslipsWithWarnings;
END;
GO

/* ───────────────────────── 6. verification ───────────────────────── */
DECLARE @p INT, @s INT, @fam NVARCHAR(400), @r17 DECIMAL(28,12);
SELECT @p = c.precision, @s = c.scale FROM sys.columns c
WHERE c.object_id = OBJECT_ID('payroll.PAYROLL_RUN_RATE') AND c.name = 'Rate';
SELECT @fam = SettingValue FROM core.SETTING WHERE SettingKey = 'TaxFamilyDeductionAnnualUsd';
SET @r17 = payroll.fn_RunRate(17, 'LBP', 'USD');
PRINT CONCAT('PAYROLL_RUN_RATE.Rate = DECIMAL(', @p, ',', @s, ')');
PRINT CONCAT('TaxFamilyDeductionAnnualUsd = ', @fam);
PRINT CONCAT('fn_RunRate(17, LBP, USD) = ', @r17, '  (run 17 keeps its 0 snapshot; see docs/payroll_run_compare.sql)');
PRINT 'Script 78 applied.';
GO
