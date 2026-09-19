/* ============================================================================
   81_payroll_run_timing.sql — "Supplemental and Primary can be generated at any time".

   a. SUPPLEMENTAL AT ANY TIME. payroll.usp_PayrollRun_Create no longer refuses a supplemental with
      "A supplemental follows an approved primary… not locked yet". It needs only what it pays:
      approved, unconsumed adjustments targeting the period; and still at most ONE open supplemental.
      AN ADJUSTMENT IS PAID ONCE, by three guards that together cover every order of events:
        1. consumed flag (unchanged): approving a run stamps PAYROLL_ADJUSTMENT.AppliedToPayslipId, and
           both generators take only adjustments where it IS NULL — a later primary regenerate never
           sees what an approved supplemental paid;
        2. usp_PayrollRun_Generate (primary) also leaves out adjustments sitting on an OPEN
           supplemental's payslips (Draft / Review) — they come back if that supplemental is cancelled;
        3. usp_PayrollRun_Approve refuses a run whose adjustment lines were consumed by another run, or
           (for a primary) are held by an open supplemental: a primary generated before the
           supplemental existed must be regenerated before it can be locked.

   b. PRIMARY ON ANY DAY OF ITS PERIOD. attendance.usp_Attendance_PayrollReadiness looks only at the
      days up to today in Beirut (never past the month's end): unprocessed punches, unresolved PINs,
      open anomalies, pending corrections, rostered days with no record, undecided exit variances and
      undecided anomalies. Later days count as scheduled: section D of the generator stops at the same
      day. A period that has not started is refused. Kept: one primary per period, one open
      supplemental at a time, the anomaly gate. The run's Created / Generated events say which day
      attendance was counted up to when that day is before the period's end.

   c. Refusal texts (usp_PayrollRun_Create):
        new      The period %s has not started yet. Its primary run can be created from %s.
        changed  Attendance for %s has %d undecided anomal(y|ies) up to %s (…). Decide them in Attendance > Anomalies before running payroll.
        changed  Attendance for %s is not ready for payroll up to %s. Open the readiness check and clear the counts.
        changed  An open supplemental for this period already exists. Finish or cancel it first.
        changed  No approved, unpaid adjustments target %s. There is nothing for a supplemental to pay.
        removed  A supplemental follows an approved primary. The %s primary is not locked yet - put the money in it and regenerate.
      new (usp_PayrollRun_Approve):
                 This run carries %d adjustment(s) that a supplemental run pays. Regenerate the run so each adjustment is paid once, then approve it.

   @AsOfDate (Readiness, Create, Generate; optional, last, default NULL = today in Beirut) is the
   clock made injectable so the rule can be tested; the API never passes it. Result shapes are
   unchanged (Readiness still answers 11 columns, PeriodEnd = the month's end).

   Bodies are the live ones (script 78 / 77) with only the changes above. Idempotent: CREATE OR ALTER.
   Locked runs are not touched. Apply with sqlcmd -C -I.
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/* ───────────────────────── 1. readiness: the days that have happened ───────────────────────── */
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
                      WHERE rm.BranchId = e.BranchId
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

/* ───────────────────────── 2. create: any time ───────────────────────── */
CREATE OR ALTER PROCEDURE payroll.usp_PayrollRun_Create
    @PeriodYearMonth CHAR(7), @CreatedByUserId INT,
    @Notes NVARCHAR(500)=NULL, @RunType VARCHAR(12)='Primary',
    @AsOfDate DATE = NULL      -- script 81: the clock. NULL = today in Beirut; a caller passes a date only to test the rule
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
    /* script 81: runs may be prepared at any time. "Today" is Beirut's, the same day the roster lock uses. */
    DECLARE @Today DATE = ISNULL(@AsOfDate, CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE));
    DECLARE @UpTo  DATE = CASE WHEN @Today < @End THEN @Today ELSE @End END;

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
        /* script 81: a primary may be created on ANY DAY OF ITS PERIOD — from the 1st on, not before */
        IF @Start > @Today
        BEGIN
            DECLARE @P0 CHAR(7)=@PeriodYearMonth; DECLARE @P0d VARCHAR(10)=CONVERT(VARCHAR(10),@Start,23);
            RAISERROR('The period %s has not started yet. Its primary run can be created from %s.',16,1,@P0,@P0d);
            RETURN;
        END
        DECLARE @Ready TABLE (PeriodYearMonth CHAR(7), PeriodStart DATE, PeriodEnd DATE,
            UnprocessedPunches INT, UnresolvedPinPunches INT, OpenAnomalies INT,
            PendingCorrections INT, RosteredDaysWithNoRecord INT, UndecidedExitVariances INT,
            UndecidedAnomalies INT, IsReady BIT);
        /* the gates look at the days up to today only (script 81); later days count as scheduled */
        INSERT INTO @Ready EXEC attendance.usp_Attendance_PayrollReadiness @PeriodYearMonth, @Today;
        DECLARE @UpToText VARCHAR(10) = CONVERT(VARCHAR(10), @UpTo, 23);
        /* script 77: undecided late / early / missing-punch anomalies are named first, with their count */
        DECLARE @Undecided INT = (SELECT UndecidedAnomalies FROM @Ready);
        IF @Undecided > 0
        BEGIN
            DECLARE @P2a CHAR(7)=@PeriodYearMonth;
            DECLARE @Plural VARCHAR(3) = CASE WHEN @Undecided = 1 THEN 'y' ELSE 'ies' END;
            RAISERROR('Attendance for %s has %d undecided anomal%s up to %s (late arrival, early departure or missing punch). Decide them in Attendance > Anomalies before running payroll.',16,1,@P2a,@Undecided,@Plural,@UpToText);
            RETURN;
        END
        IF (SELECT IsReady FROM @Ready) = 0
        BEGIN
            DECLARE @P2 CHAR(7)=@PeriodYearMonth;
            RAISERROR('Attendance for %s is not ready for payroll up to %s. Open the readiness check and clear the counts.',16,1,@P2,@UpToText);
            RETURN;
        END
    END
    ELSE
    BEGIN
        /* script 81: A SUPPLEMENTAL MAY BE CREATED AT ANY TIME — before the primary exists, while it is a
           draft, or after it is locked. It pays only signed, unconsumed adjustments targeting the
           period, and what it pays is never paid again: an open supplemental's adjustments are left
           out of the primary's generate, and approving it stamps them consumed (AppliedToPayslipId). */
        IF EXISTS (SELECT 1 FROM payroll.PAYROLL_RUN
                   WHERE PeriodYearMonth=@PeriodYearMonth
                     AND RunType='Supplemental' AND [Status] IN ('Draft','Review'))
        BEGIN RAISERROR('An open supplemental for this period already exists. Finish or cancel it first.',16,1); RETURN; END
        IF NOT EXISTS (SELECT 1 FROM payroll.PAYROLL_ADJUSTMENT
                       WHERE TargetPeriod=@PeriodYearMonth AND AppliedToPayslipId IS NULL)
        BEGIN
            DECLARE @P3 CHAR(7)=@PeriodYearMonth;
            RAISERROR('No approved, unpaid adjustments target %s. There is nothing for a supplemental to pay.',16,1,@P3);
            RETURN;
        END
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
            CONCAT(@RunType,N' run for ',@PeriodYearMonth,N', rates frozen',
                   CASE WHEN @RunType='Primary' AND @UpTo < @End
                        THEN CONCAT(N'; created on ',CONVERT(NVARCHAR(10),@Today,23),N', attendance checked up to that day') ELSE N'' END));
    COMMIT TRAN;

    SELECT @RunId AS PayrollRunId, @PeriodYearMonth AS PeriodYearMonth,
           'Draft' AS [Status], @Primary AS PrimaryCurrency, @RunType AS RunType;
END;
GO

/* ───────────────────────── 3. primary generate: up to today; an open supplemental keeps its adjustments ───────────────────────── */
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
        WHERE a.WorkDate BETWEEN @Start AND @UpTo          -- script 81: days after today count as scheduled
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
            CONCAT(@Count,N' payslip(s), ',@Warn,N' with warnings',
                   CASE WHEN @UpTo < @End THEN CONCAT(N'; attendance counted up to ',CONVERT(NVARCHAR(10),@UpTo,23),N', later days as scheduled') ELSE N'' END));
    COMMIT TRAN;

    SELECT @PayrollRunId AS PayrollRunId, @Count AS PayslipCount, @Warn AS PayslipsWithWarnings;
END;
GO

/* ───────────────────────── 4. approve: an adjustment is paid once ───────────────────────── */
CREATE OR ALTER PROCEDURE payroll.usp_PayrollRun_Approve
    @PayrollRunId INT, @ActedByUserId INT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;

    IF payroll.fn_UserHasRole(@ActedByUserId, N'Owner') = 0
    BEGIN RAISERROR('Only the Owner approves and locks a payroll run.',16,1); RETURN; END

    DECLARE @S VARCHAR(12), @Gen DATETIME2, @Type VARCHAR(12);
    SELECT @S=[Status], @Gen=GeneratedAt, @Type=RunType FROM payroll.PAYROLL_RUN WHERE PayrollRunId=@PayrollRunId;
    IF @S IS NULL BEGIN RAISERROR('No such payroll run.',16,1); RETURN; END
    IF @S <> 'Review'
    BEGIN RAISERROR('A run is approved from Review - HR sends it there once the figures are ready.',16,1); RETURN; END
    IF @Gen IS NULL
    BEGIN RAISERROR('Nothing has been generated - there is nothing to approve.',16,1); RETURN; END

    /* script 81: AN ADJUSTMENT IS PAID ONCE. A supplemental may now be prepared while the primary is
       still open, so a primary generated BEFORE the supplemental can still carry the same adjustment
       lines. It is refused here until it is regenerated (which drops them): either the adjustment was
       already consumed by another run's payslip, or — for a primary — an open supplemental holds it. */
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
        RETURN;
    END

    BEGIN TRAN;
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

    UPDATE payroll.PAYROLL_RUN
    SET [Status]='Approved', ApprovedByUserId=@ActedByUserId,
        ApprovedAt=SYSUTCDATETIME(), LockedAt=SYSUTCDATETIME()
    WHERE PayrollRunId=@PayrollRunId;

    INSERT INTO payroll.PAYROLL_RUN_EVENT (PayrollRunId,[Action],ActedByUserId,Detail)
    VALUES (@PayrollRunId,'Approved',@ActedByUserId,N'Locked by the Owner; expenses stamped, advances reduced, adjustments applied');
    COMMIT TRAN;

    SELECT @PayrollRunId AS PayrollRunId, 'Approved' AS [Status],
           (SELECT LockedAt FROM payroll.PAYROLL_RUN WHERE PayrollRunId=@PayrollRunId) AS LockedAt;
END;
GO

/* ───────────────────────── 5. verification ───────────────────────── */
DECLARE @gone INT = (SELECT COUNT(*) FROM sys.sql_modules WHERE object_id = OBJECT_ID('payroll.usp_PayrollRun_Create') AND definition LIKE '%A supplemental follows an approved primary%');
DECLARE @clock INT = (SELECT COUNT(*) FROM sys.parameters WHERE name = '@AsOfDate' AND object_id IN (OBJECT_ID('payroll.usp_PayrollRun_Create'), OBJECT_ID('payroll.usp_PayrollRun_Generate'), OBJECT_ID('attendance.usp_Attendance_PayrollReadiness')));
PRINT CONCAT('old supplemental refusal still present = ', @gone, ' (expected 0)');
PRINT CONCAT('procedures with the @AsOfDate clock = ', @clock, ' (expected 3)');
PRINT 'Script 81 applied.';
GO
